package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
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
	staged *proxyChainRuntimeConfig
}{}

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
	if name == flClashChainName {
		if _, exists := tunnel.Proxies()[flClashChainName]; !exists {
			return fmt.Errorf("proxy chain is unavailable")
		}
	}
	if err := validateProxyChainRuntimeGraph(
		tunnel.Proxies(),
		map[string]string{p.Name(): name},
	); err != nil {
		return err
	}
	return p.setTargetLocked(name, false)
}

func (p *proxyChainSelectorOverlay) ForceSet(name string) {
	proxyChainRuntimeState.Lock()
	defer proxyChainRuntimeState.Unlock()
	if validateProxyChainRuntimeGraph(
		tunnel.Proxies(),
		map[string]string{p.Name(): name},
	) != nil {
		return
	}
	_ = p.setTargetLocked(name, true)
}

func currentProxyChain() C.Proxy {
	proxyChainRuntimeState.RLock()
	defer proxyChainRuntimeState.RUnlock()
	return tunnel.Proxies()[flClashChainName]
}

func (p *proxyChainSelectorOverlay) DialContext(
	ctx context.Context,
	metadata *C.Metadata,
) (C.Conn, error) {
	if !p.usesChain() {
		return p.ProxyGroup.DialContext(ctx, metadata)
	}
	chainProxy := currentProxyChain()
	if chainProxy == nil {
		return nil, fmt.Errorf("proxy chain is unavailable")
	}
	conn, err := chainProxy.DialContext(ctx, metadata)
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
	chainProxy := currentProxyChain()
	if chainProxy == nil {
		return nil, fmt.Errorf("proxy chain is unavailable")
	}
	packetConn, err := chainProxy.ListenPacketContext(ctx, metadata)
	if err == nil {
		packetConn.AppendToChains(p)
	}
	return packetConn, err
}

func (p *proxyChainSelectorOverlay) SupportUDP() bool {
	if !p.usesChain() {
		return p.ProxyGroup.SupportUDP()
	}
	chainProxy := currentProxyChain()
	return chainProxy != nil && chainProxy.SupportUDP()
}

func (p *proxyChainSelectorOverlay) IsL3Protocol(metadata *C.Metadata) bool {
	if !p.usesChain() {
		return p.ProxyGroup.IsL3Protocol(metadata)
	}
	chainProxy := currentProxyChain()
	return chainProxy != nil && chainProxy.IsL3Protocol(metadata)
}

func (p *proxyChainSelectorOverlay) Unwrap(
	metadata *C.Metadata,
	touch bool,
) C.Proxy {
	if !p.usesChain() {
		return p.ProxyGroup.Unwrap(metadata, touch)
	}
	return currentProxyChain()
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
	chainProxy := currentProxyChain()
	if chainProxy == nil {
		return proxies
	}
	return append([]C.Proxy{chainProxy}, proxies...)
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

	chainProxy := currentProxyChain()
	var chainDelay uint16
	var chainErr error
	if chainProxy != nil {
		chainDelay, chainErr = chainProxy.URLTest(ctx, url, expectedStatus)
	}
	result := <-groupResult
	if chainErr == nil && chainProxy != nil {
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

func setProxyChainNames(proxyNames []string) {
	proxyChainState.Lock()
	proxyChainState.proxyNames = append([]string(nil), proxyNames...)
	proxyChainState.Unlock()
}

func isProxyChainInnerTracker(info *statistic.TrackerInfo) bool {
	if info == nil || info.Metadata == nil || info.Metadata.Type != C.INNER {
		return false
	}
	for _, name := range info.Chain {
		if isFlClashChainProxy(name) {
			return true
		}
	}
	return false
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
		_ = proxy.Close()
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
}

func prepareProxyChainConfigLocked(
	current *config.Config,
	selectedMap map[string]string,
) (*preparedProxyChainConfig, error) {
	staged := proxyChainRuntimeState.staged
	if staged == nil {
		return nil, nil
	}
	chainProxies, _, err := parseProxyChain(staged.configs)
	if err != nil {
		return nil, err
	}
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
		closeProxyChainProxies(chainProxies)
		return nil, err
	}
	return &preparedProxyChainConfig{
		proxyNames: append([]string(nil), staged.proxyNames...),
	}, nil
}

func activatePreparedProxyChainLocked(prepared *preparedProxyChainConfig) {
	proxyChainRuntimeState.staged = nil
	if prepared == nil {
		setProxyChainNames(nil)
		return
	}
	setProxyChainNames(prepared.proxyNames)
}

func stageProxyChainLocked(params UpdateProxyChainParams) error {
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

func updateProxyChainLocked(params UpdateProxyChainParams) error {
	chainProxies, _, err := parseProxyChain(params.Proxies)
	if err != nil {
		return err
	}
	proxies := buildProxyChainProxyMap(tunnel.Proxies(), chainProxies)
	if err := validateProxyChainRuntimeGraph(proxies, nil); err != nil {
		closeProxyChainProxies(chainProxies)
		return err
	}
	providers := make(map[string]P.ProxyProvider, len(tunnel.Providers()))
	for name, provider := range tunnel.Providers() {
		providers[name] = provider
	}
	tunnel.UpdateProxies(proxies, providers)
	setProxyChainNames(params.ProxyNames)
	return nil
}

func handleUpdateProxyChain(data []byte) string {
	runLock.Lock()
	defer runLock.Unlock()
	var params UpdateProxyChainParams
	if err := json.Unmarshal(data, &params); err != nil {
		return err.Error()
	}
	proxyChainRuntimeState.Lock()
	defer proxyChainRuntimeState.Unlock()
	if params.StageOnly {
		if err := stageProxyChainLocked(params); err != nil {
			return err.Error()
		}
		return ""
	}
	var affectedConnections []statistic.Tracker
	if params.CloseConnections {
		affectedConnections = connectionsUsingGroup(flClashChainName)
	}
	if err := updateProxyChainLocked(params); err != nil {
		return err.Error()
	}
	if params.CloseConnections {
		closeTrackedConnections(affectedConnections)
	}
	return ""
}
