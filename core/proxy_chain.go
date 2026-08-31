package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/callback"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

const (
	flClashChainName      = "__FLCLASH_INTERNAL_CHAIN__"
	flClashChainHopPrefix = "__FLCLASH_INTERNAL_CHAIN_HOP_"
)

var proxyChainState = struct {
	sync.RWMutex
	proxyNames []string
}{}

type proxyChainRuntimeConfig struct {
	proxyNames []string
	configs    []map[string]interface{}
}

var proxyChainRuntimeState = struct {
	sync.RWMutex
	staged  *proxyChainRuntimeConfig
	current *proxyChainRuntime
}{}

var errProxyChainRuntimeRetired = errors.New(
	"proxy chain changed during connection setup",
)

const proxyChainCloseAttempts = 3

type proxyChainConnection interface {
	Close() error
}

// proxyChainRuntime only owns one parsed dialer-proxy graph and its lifetime.
// Mihomo's native adapters still perform all proxy chaining.
type proxyChainRuntime struct {
	entry   C.Proxy
	proxies map[string]C.Proxy

	mutex            sync.Mutex
	context          context.Context
	cancel           context.CancelFunc
	retired          bool
	closeConnections bool
	inFlight         int
	inFlightWait     sync.WaitGroup
	connections      map[proxyChainConnection]struct{}
	closeOnce        sync.Once
}

func newProxyChainRuntime(
	proxies map[string]C.Proxy,
	entry C.Proxy,
) *proxyChainRuntime {
	runtimeContext, cancel := context.WithCancel(context.Background())
	return &proxyChainRuntime{
		entry:       entry,
		proxies:     proxies,
		context:     runtimeContext,
		cancel:      cancel,
		connections: map[proxyChainConnection]struct{}{},
	}
}

func (r *proxyChainRuntime) beginOperation(
	ctx context.Context,
) (context.Context, func(), error) {
	r.mutex.Lock()
	if r.retired {
		r.mutex.Unlock()
		return nil, nil, errProxyChainRuntimeRetired
	}
	r.inFlight++
	r.inFlightWait.Add(1)
	runtimeContext := r.context
	r.mutex.Unlock()

	operationContext, cancel := context.WithCancel(ctx)
	stopRuntimeCancel := make(chan struct{})
	go func() {
		select {
		case <-runtimeContext.Done():
			cancel()
		case <-stopRuntimeCancel:
		}
	}()
	return operationContext, func() {
		close(stopRuntimeCancel)
		cancel()
		r.finishOperation()
	}, nil
}

func (r *proxyChainRuntime) finishOperation() {
	r.mutex.Lock()
	r.inFlight--
	closeRuntime := r.retired && !r.closeConnections &&
		r.inFlight == 0 && len(r.connections) == 0
	r.mutex.Unlock()
	r.inFlightWait.Done()
	if closeRuntime {
		r.closeProxies()
	}
}

func (r *proxyChainRuntime) trackConn(conn C.Conn) (C.Conn, error) {
	var tracked C.Conn
	tracked = callback.NewCloseCallbackConn(conn, func() {
		r.removeConnection(tracked)
	})
	r.mutex.Lock()
	closeConnection := r.retired && r.closeConnections
	if !closeConnection {
		r.connections[tracked] = struct{}{}
	}
	r.mutex.Unlock()
	if closeConnection {
		closeProxyChainConnection(tracked)
		return nil, errProxyChainRuntimeRetired
	}
	return tracked, nil
}

func (r *proxyChainRuntime) trackPacketConn(
	packetConn C.PacketConn,
) (C.PacketConn, error) {
	var tracked C.PacketConn
	tracked = callback.NewCloseCallbackPacketConn(packetConn, func() {
		r.removeConnection(tracked)
	})
	r.mutex.Lock()
	closeConnection := r.retired && r.closeConnections
	if !closeConnection {
		r.connections[tracked] = struct{}{}
	}
	r.mutex.Unlock()
	if closeConnection {
		closeProxyChainConnection(tracked)
		return nil, errProxyChainRuntimeRetired
	}
	return tracked, nil
}

func (r *proxyChainRuntime) removeConnection(connection proxyChainConnection) {
	r.mutex.Lock()
	delete(r.connections, connection)
	closeRuntime := r.retired && !r.closeConnections &&
		r.inFlight == 0 && len(r.connections) == 0
	r.mutex.Unlock()
	if closeRuntime {
		r.closeProxies()
	}
}

func (r *proxyChainRuntime) DialContext(
	ctx context.Context,
	metadata *C.Metadata,
) (C.Conn, error) {
	operationContext, finish, err := r.beginOperation(ctx)
	if err != nil {
		return nil, err
	}
	defer finish()
	conn, err := r.entry.DialContext(operationContext, metadata)
	if err != nil {
		return nil, err
	}
	return r.trackConn(conn)
}

func (r *proxyChainRuntime) ListenPacketContext(
	ctx context.Context,
	metadata *C.Metadata,
) (C.PacketConn, error) {
	operationContext, finish, err := r.beginOperation(ctx)
	if err != nil {
		return nil, err
	}
	defer finish()
	packetConn, err := r.entry.ListenPacketContext(
		operationContext,
		metadata,
	)
	if err != nil {
		return nil, err
	}
	return r.trackPacketConn(packetConn)
}

func (r *proxyChainRuntime) URLTest(
	ctx context.Context,
	url string,
	expectedStatus utils.IntRanges[uint16],
) (uint16, error) {
	operationContext, finish, err := r.beginOperation(ctx)
	if err != nil {
		return 0, err
	}
	defer finish()
	return r.entry.URLTest(operationContext, url, expectedStatus)
}

func (r *proxyChainRuntime) retire(closeConnections bool) {
	if r == nil {
		return
	}
	r.mutex.Lock()
	if closeConnections {
		r.closeConnections = true
	}
	r.retired = true
	connections := make([]proxyChainConnection, 0, len(r.connections))
	if r.closeConnections {
		for connection := range r.connections {
			connections = append(connections, connection)
		}
	}
	closeRuntime := !r.closeConnections &&
		r.inFlight == 0 && len(r.connections) == 0
	r.mutex.Unlock()

	if r.closeConnections {
		r.cancel()
		for _, connection := range connections {
			closeProxyChainConnection(connection)
		}
		r.inFlightWait.Wait()
		r.closeProxies()
		return
	}
	if closeRuntime {
		r.closeProxies()
	}
}

func (r *proxyChainRuntime) closeProxies() {
	r.closeOnce.Do(func() {
		r.cancel()
		closeProxyChainProxies(r.proxies)
	})
}

func closeProxyChainConnection(connection proxyChainConnection) bool {
	var err error
	for attempt := 0; attempt < proxyChainCloseAttempts; attempt++ {
		err = connection.Close()
		if err == nil || errors.Is(err, net.ErrClosed) {
			return true
		}
	}
	log.Errorln(
		"[APP] close retired proxy chain connection failed after %d attempts: %v",
		proxyChainCloseAttempts,
		err,
	)
	return false
}

// proxyChainSelectorOverlay lets a native selector choose the runtime Chain
// without changing its provider list or the subscription's filter settings.
// Traffic is still handled by the native proxies assembled with dialer-proxy.
type proxyChainSelectorOverlay struct {
	outboundgroup.ProxyGroup
	selector outboundgroup.SelectAble
	mutex    sync.RWMutex
	useChain bool
}

func newProxyChainSelectorOverlay(
	group outboundgroup.ProxyGroup,
	selector outboundgroup.SelectAble,
) *proxyChainSelectorOverlay {
	return &proxyChainSelectorOverlay{
		ProxyGroup: group,
		selector:   selector,
	}
}

func (p *proxyChainSelectorOverlay) usesChain() bool {
	p.mutex.RLock()
	defer p.mutex.RUnlock()
	return p.useChain
}

func (p *proxyChainSelectorOverlay) currentTarget() string {
	p.mutex.RLock()
	defer p.mutex.RUnlock()
	if p.useChain {
		return flClashChainName
	}
	return p.ProxyGroup.Now()
}

func (p *proxyChainSelectorOverlay) setTargetLocked(name string, force bool) error {
	p.mutex.Lock()
	defer p.mutex.Unlock()
	if name == flClashChainName {
		p.useChain = true
		return nil
	}
	if force {
		p.selector.ForceSet(name)
	} else if err := p.selector.Set(name); err != nil {
		return err
	}
	p.useChain = false
	return nil
}

func (p *proxyChainSelectorOverlay) Set(name string) error {
	proxyChainRuntimeState.Lock()
	defer proxyChainRuntimeState.Unlock()
	runtime := proxyChainRuntimeState.current
	if name == flClashChainName && runtime == nil {
		return fmt.Errorf("proxy chain is unavailable")
	}
	proxies := tunnel.Proxies()
	if runtime != nil {
		proxies = buildProxyChainProxyMap(proxies, runtime.proxies)
	}
	if err := validateProxyChainRuntimeGraph(
		proxies,
		map[string]string{p.Name(): name},
	); err != nil {
		return err
	}
	return p.setTargetLocked(name, false)
}

func (p *proxyChainSelectorOverlay) ForceSet(name string) {
	proxyChainRuntimeState.Lock()
	defer proxyChainRuntimeState.Unlock()
	runtime := proxyChainRuntimeState.current
	if name == flClashChainName && runtime == nil {
		return
	}
	proxies := tunnel.Proxies()
	if runtime != nil {
		proxies = buildProxyChainProxyMap(proxies, runtime.proxies)
	}
	if validateProxyChainRuntimeGraph(
		proxies,
		map[string]string{p.Name(): name},
	) != nil {
		return
	}
	_ = p.setTargetLocked(name, true)
}

func currentProxyChainRuntime() *proxyChainRuntime {
	proxyChainRuntimeState.RLock()
	defer proxyChainRuntimeState.RUnlock()
	return proxyChainRuntimeState.current
}

func (p *proxyChainSelectorOverlay) DialContext(
	ctx context.Context,
	metadata *C.Metadata,
) (C.Conn, error) {
	if !p.usesChain() {
		return p.ProxyGroup.DialContext(ctx, metadata)
	}
	runtime := currentProxyChainRuntime()
	if runtime == nil {
		return nil, fmt.Errorf("proxy chain is unavailable")
	}
	conn, err := runtime.DialContext(ctx, metadata)
	if err == nil {
		conn.AppendToChains(p)
	}
	return conn, err
}

func (p *proxyChainSelectorOverlay) ListenPacketContext(
	ctx context.Context,
	metadata *C.Metadata,
) (C.PacketConn, error) {
	if !p.usesChain() {
		return p.ProxyGroup.ListenPacketContext(ctx, metadata)
	}
	runtime := currentProxyChainRuntime()
	if runtime == nil {
		return nil, fmt.Errorf("proxy chain is unavailable")
	}
	packetConn, err := runtime.ListenPacketContext(ctx, metadata)
	if err == nil {
		packetConn.AppendToChains(p)
	}
	return packetConn, err
}

func (p *proxyChainSelectorOverlay) SupportUDP() bool {
	if !p.usesChain() {
		return p.ProxyGroup.SupportUDP()
	}
	runtime := currentProxyChainRuntime()
	return runtime != nil && runtime.entry.SupportUDP()
}

func (p *proxyChainSelectorOverlay) IsL3Protocol(metadata *C.Metadata) bool {
	if !p.usesChain() {
		return p.ProxyGroup.IsL3Protocol(metadata)
	}
	runtime := currentProxyChainRuntime()
	return runtime != nil && runtime.entry.IsL3Protocol(metadata)
}

func (p *proxyChainSelectorOverlay) Unwrap(
	metadata *C.Metadata,
	touch bool,
) C.Proxy {
	if !p.usesChain() {
		return p.ProxyGroup.Unwrap(metadata, touch)
	}
	runtime := currentProxyChainRuntime()
	if runtime == nil {
		return nil
	}
	return runtime.entry
}

func (p *proxyChainSelectorOverlay) Now() string {
	return p.currentTarget()
}

func (p *proxyChainSelectorOverlay) MarshalJSON() ([]byte, error) {
	data, err := p.ProxyGroup.MarshalJSON()
	if err != nil {
		return nil, err
	}
	mapping := map[string]interface{}{}
	if err := json.Unmarshal(data, &mapping); err != nil {
		return nil, err
	}
	mapping["now"] = p.Now()
	all, _ := mapping["all"].([]interface{})
	for _, name := range all {
		if name == flClashChainName {
			return json.Marshal(mapping)
		}
	}
	mapping["all"] = append([]interface{}{flClashChainName}, all...)
	return json.Marshal(mapping)
}

func (p *proxyChainSelectorOverlay) Proxies() []C.Proxy {
	proxies := append([]C.Proxy(nil), p.ProxyGroup.Proxies()...)
	runtime := currentProxyChainRuntime()
	if runtime == nil {
		return proxies
	}
	return append([]C.Proxy{runtime.entry}, proxies...)
}

func (p *proxyChainSelectorOverlay) URLTest(
	ctx context.Context,
	url string,
	expectedStatus utils.IntRanges[uint16],
) (map[string]uint16, error) {
	type groupURLTestResult struct {
		delays map[string]uint16
		err    error
	}
	groupResult := make(chan groupURLTestResult, 1)
	go func() {
		delays, err := p.ProxyGroup.URLTest(ctx, url, expectedStatus)
		groupResult <- groupURLTestResult{delays: delays, err: err}
	}()

	runtime := currentProxyChainRuntime()
	var chainDelay uint16
	var chainErr error
	if runtime != nil {
		chainDelay, chainErr = runtime.URLTest(ctx, url, expectedStatus)
	}
	result := <-groupResult
	if chainErr == nil && runtime != nil {
		if result.delays == nil {
			result.delays = map[string]uint16{}
		}
		result.delays[flClashChainName] = chainDelay
	}
	return result.delays, result.err
}

func isFlClashChainProxy(name string) bool {
	return name == flClashChainName || strings.HasPrefix(name, flClashChainHopPrefix)
}

func connectionsUsingProxyChain() []statistic.Tracker {
	connections := make([]statistic.Tracker, 0)
	statistic.DefaultManager.Range(func(connection statistic.Tracker) bool {
		for _, name := range connection.Chains() {
			if isFlClashChainProxy(name) {
				connections = append(connections, connection)
				break
			}
		}
		return true
	})
	return connections
}

func setProxyChainNames(proxyNames []string) {
	proxyChainState.Lock()
	proxyChainState.proxyNames = append([]string(nil), proxyNames...)
	proxyChainState.Unlock()
}

func isProxyChainInnerTracker(info *statistic.TrackerInfo) bool {
	// Dialer-proxy trackers bypass the tunnel and have no route revision.
	// Routed INNER traffic, including DNS and internal HTTP requests, does.
	return info != nil && info.Metadata != nil &&
		info.Metadata.Type == C.INNER && !info.Metadata.RouteRevisionSet
}

func prepareProxyChainTracker(tracker statistic.Tracker) bool {
	info := tracker.Info()
	if isProxyChainInnerTracker(info) {
		return false
	}
	usesChain := false
	for _, name := range tracker.Chains() {
		if name == flClashChainName {
			usesChain = true
			break
		}
	}
	if !usesChain {
		return true
	}

	proxyChainState.RLock()
	proxyNames := append([]string(nil), proxyChainState.proxyNames...)
	proxyChainState.RUnlock()
	chain := make(C.Chain, 0, len(proxyNames)+len(info.Chain))
	for index := len(proxyNames) - 1; index >= 0; index-- {
		chain = append(chain, proxyNames[index])
	}
	for _, name := range info.Chain {
		if !strings.HasPrefix(name, flClashChainHopPrefix) {
			chain = append(chain, name)
		}
	}
	info.Chain = chain
	return true
}

func parseProxyChain(
	configs []map[string]interface{},
) (map[string]C.Proxy, C.Proxy, error) {
	if len(configs) == 0 {
		return nil, nil, fmt.Errorf("proxy chain overlay is empty")
	}
	proxies := make(map[string]C.Proxy, len(configs))
	var chainProxy C.Proxy
	for index, mapping := range configs {
		proxy, err := adapter.ParseProxy(
			mapping,
			adapter.WithTunnelForAPI(tunnel.Tunnel),
		)
		if err != nil {
			closeProxyChainProxies(proxies)
			return nil, nil, fmt.Errorf("parse proxy chain hop %d: %w", index, err)
		}
		name := proxy.Name()
		if !isFlClashChainProxy(name) {
			_ = proxy.Close()
			closeProxyChainProxies(proxies)
			return nil, nil, fmt.Errorf("invalid proxy chain hop %q", name)
		}
		if _, exists := proxies[name]; exists {
			_ = proxy.Close()
			closeProxyChainProxies(proxies)
			return nil, nil, fmt.Errorf("duplicate proxy chain hop %q", name)
		}
		proxies[name] = proxy
		if name == flClashChainName {
			chainProxy = proxy
		}
	}
	if chainProxy == nil {
		closeProxyChainProxies(proxies)
		return nil, nil, fmt.Errorf("proxy chain entry is missing")
	}
	return proxies, chainProxy, nil
}

func closeProxyChainProxies(proxies map[string]C.Proxy) {
	for _, proxy := range proxies {
		if err := proxy.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
			log.Errorln(
				"[APP] close retired proxy chain adapter %s failed: %v",
				proxy.Name(),
				err,
			)
		}
	}
}

func cloneProxyChainConfigs(
	configs []map[string]interface{},
) []map[string]interface{} {
	cloned := make([]map[string]interface{}, 0, len(configs))
	for _, mapping := range configs {
		copy := make(map[string]interface{}, len(mapping))
		for key, value := range mapping {
			copy[key] = value
		}
		cloned = append(cloned, copy)
	}
	return cloned
}

func buildProxyChainProxyMap(
	base map[string]C.Proxy,
	chainProxies map[string]C.Proxy,
) map[string]C.Proxy {
	proxies := make(map[string]C.Proxy, len(base)+len(chainProxies))
	for name, proxy := range base {
		if !isFlClashChainProxy(name) {
			proxies[name] = proxy
		}
	}
	for name, proxy := range chainProxies {
		proxies[name] = proxy
	}
	return proxies
}

func installProxyChainSelectorOverlays(
	proxies map[string]C.Proxy,
) map[string]*proxyChainSelectorOverlay {
	overlays := map[string]*proxyChainSelectorOverlay{}
	for name, proxy := range proxies {
		if isFlClashChainProxy(name) || proxy.Type() != C.Selector {
			continue
		}
		adapterProxy, ok := proxy.(*adapter.Proxy)
		if !ok {
			continue
		}
		if overlay, ok := adapterProxy.ProxyAdapter.(*proxyChainSelectorOverlay); ok {
			overlays[name] = overlay
			continue
		}
		group, ok := adapterProxy.ProxyAdapter.(outboundgroup.ProxyGroup)
		if !ok {
			continue
		}
		selector, ok := adapterProxy.ProxyAdapter.(outboundgroup.SelectAble)
		if !ok {
			continue
		}
		overlay := newProxyChainSelectorOverlay(group, selector)
		adapterProxy.ProxyAdapter = overlay
		overlays[name] = overlay
	}
	return overlays
}

func ensureProxyChainSelectorOverlay(groupName string) error {
	proxyChainRuntimeState.Lock()
	defer proxyChainRuntimeState.Unlock()
	runtime := proxyChainRuntimeState.current
	if runtime == nil {
		return fmt.Errorf("proxy chain is unavailable")
	}
	proxies := buildProxyChainProxyMap(tunnel.Proxies(), runtime.proxies)
	tunnel.UpdateProxies(proxies, tunnel.Providers())
	group, exists := proxies[groupName]
	if !exists {
		return fmt.Errorf("proxy group %q is unavailable", groupName)
	}
	overlays := installProxyChainSelectorOverlays(map[string]C.Proxy{
		groupName: group,
	})
	if _, exists := overlays[groupName]; !exists {
		return fmt.Errorf("proxy group %q is not selectable", groupName)
	}
	return nil
}

func proxyChainDependencies(
	proxy C.Proxy,
	overrides map[string]string,
) []string {
	if overlay, ok := proxy.Adapter().(*proxyChainSelectorOverlay); ok {
		if target, exists := overrides[overlay.Name()]; exists {
			return []string{target}
		}
		return []string{overlay.currentTarget()}
	}
	if group, ok := proxy.Adapter().(outboundgroup.ProxyGroup); ok {
		return []string{group.Now()}
	}
	if dialerProxy := proxy.ProxyInfo().DialerProxy; dialerProxy != "" {
		return []string{dialerProxy}
	}
	return nil
}

func validateProxyChainRuntimeGraph(
	proxies map[string]C.Proxy,
	overrides map[string]string,
) error {
	visiting := map[string]int{}
	visited := map[string]bool{}
	path := make([]string, 0, len(proxies))
	var visit func(string) error
	visit = func(name string) error {
		if index, exists := visiting[name]; exists {
			cycle := append(append([]string(nil), path[index:]...), name)
			return fmt.Errorf(
				"proxy chain dependency cycle detected: %s",
				strings.Join(cycle, " -> "),
			)
		}
		if visited[name] {
			return nil
		}
		proxy, exists := proxies[name]
		if !exists {
			return nil
		}
		visiting[name] = len(path)
		path = append(path, name)
		for _, dependency := range proxyChainDependencies(proxy, overrides) {
			if err := visit(dependency); err != nil {
				return err
			}
		}
		path = path[:len(path)-1]
		delete(visiting, name)
		visited[name] = true
		return nil
	}
	return visit(flClashChainName)
}

type preparedProxyChainConfig struct {
	proxyNames []string
	runtime    *proxyChainRuntime
}

func prepareProxyChainConfigLocked(
	current *config.Config,
	selectedMap map[string]string,
) (*preparedProxyChainConfig, error) {
	staged := proxyChainRuntimeState.staged
	proxyChainRuntimeState.staged = nil
	return prepareProxyChainRuntimeConfigLocked(current, selectedMap, staged)
}

func prepareProxyChainRuntimeConfigLocked(
	current *config.Config,
	selectedMap map[string]string,
	staged *proxyChainRuntimeConfig,
) (*preparedProxyChainConfig, error) {
	if staged == nil {
		return nil, nil
	}
	chainProxies, chainProxy, err := parseProxyChain(staged.configs)
	if err != nil {
		return nil, err
	}
	runtime := newProxyChainRuntime(chainProxies, chainProxy)
	current.Proxies = buildProxyChainProxyMap(current.Proxies, chainProxies)
	overlays := installProxyChainSelectorOverlays(current.Proxies)
	for groupName, selected := range selectedMap {
		if overlay, exists := overlays[groupName]; exists {
			_ = overlay.setTargetLocked(selected, true)
			continue
		}
		if selected == flClashChainName {
			continue
		}
		proxy, exists := current.Proxies[groupName]
		if !exists {
			continue
		}
		if selector, ok := proxy.Adapter().(outboundgroup.SelectAble); ok {
			selector.ForceSet(selected)
		}
	}
	if err := validateProxyChainRuntimeGraph(current.Proxies, nil); err != nil {
		runtime.closeProxies()
		return nil, err
	}
	return &preparedProxyChainConfig{
		proxyNames: append([]string(nil), staged.proxyNames...),
		runtime:    runtime,
	}, nil
}

func activatePreparedProxyChainLocked(
	prepared *preparedProxyChainConfig,
) *proxyChainRuntime {
	proxyChainRuntimeState.staged = nil
	previous := proxyChainRuntimeState.current
	if prepared == nil {
		proxyChainRuntimeState.current = nil
		setProxyChainNames(nil)
		return previous
	}
	proxyChainRuntimeState.current = prepared.runtime
	setProxyChainNames(prepared.proxyNames)
	return previous
}

func stageProxyChainLocked(params UpdateProxyChainParams) error {
	proxyChainRuntimeState.staged = nil
	proxies, _, err := parseProxyChain(params.Proxies)
	if err != nil {
		return err
	}
	closeProxyChainProxies(proxies)
	proxyChainRuntimeState.staged = &proxyChainRuntimeConfig{
		proxyNames: append([]string(nil), params.ProxyNames...),
		configs:    cloneProxyChainConfigs(params.Proxies),
	}
	return nil
}

func updateProxyChainLocked(
	params UpdateProxyChainParams,
) (*proxyChainRuntime, error) {
	chainProxies, chainProxy, err := parseProxyChain(params.Proxies)
	if err != nil {
		return nil, err
	}
	runtime := newProxyChainRuntime(chainProxies, chainProxy)
	proxies := buildProxyChainProxyMap(tunnel.Proxies(), chainProxies)
	if err := validateProxyChainRuntimeGraph(proxies, nil); err != nil {
		runtime.closeProxies()
		return nil, err
	}
	providers := make(map[string]P.ProxyProvider, len(tunnel.Providers()))
	for name, provider := range tunnel.Providers() {
		providers[name] = provider
	}
	previous := proxyChainRuntimeState.current
	tunnel.UpdateProxies(proxies, providers)
	proxyChainRuntimeState.current = runtime
	setProxyChainNames(params.ProxyNames)
	return previous, nil
}

func handleUpdateProxyChain(data []byte) string {
	runLock.Lock()
	defer runLock.Unlock()
	var params UpdateProxyChainParams
	if err := json.Unmarshal(data, &params); err != nil {
		log.Errorln("[APP] decode proxy chain update failed: %v", err)
		return err.Error()
	}
	var affectedConnections []statistic.Tracker
	if !params.StageOnly && params.CloseConnections {
		affectedConnections = connectionsUsingProxyChain()
	}
	proxyChainRuntimeState.Lock()
	if params.StageOnly {
		if err := stageProxyChainLocked(params); err != nil {
			proxyChainRuntimeState.Unlock()
			log.Errorln("[APP] stage proxy chain update failed: %v", err)
			return err.Error()
		}
		proxyChainRuntimeState.Unlock()
		return ""
	}
	previous, err := updateProxyChainLocked(params)
	proxyChainRuntimeState.Unlock()
	if err != nil {
		log.Errorln("[APP] apply proxy chain update failed: %v", err)
		return err.Error()
	}
	if params.CloseConnections {
		closeTrackedConnections(affectedConnections)
	}
	previous.retire(params.CloseConnections)
	return ""
}
