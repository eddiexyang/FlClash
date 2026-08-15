package main

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

type proxyChainTestProvider struct {
	name        string
	vehicleType P.VehicleType
	proxies     []C.Proxy
	version     uint32
}

func (p *proxyChainTestProvider) Name() string               { return p.name }
func (p *proxyChainTestProvider) VehicleType() P.VehicleType { return p.vehicleType }
func (p *proxyChainTestProvider) Type() P.ProviderType       { return P.Proxy }
func (p *proxyChainTestProvider) Initial() error             { return nil }
func (p *proxyChainTestProvider) Update() error              { return nil }
func (p *proxyChainTestProvider) Proxies() []C.Proxy         { return p.proxies }
func (p *proxyChainTestProvider) Count() int                 { return len(p.proxies) }
func (p *proxyChainTestProvider) Touch()                     {}
func (p *proxyChainTestProvider) HealthCheck()               {}
func (p *proxyChainTestProvider) Version() uint32            { return p.version }
func (p *proxyChainTestProvider) HealthCheckURL() string     { return "" }
func (p *proxyChainTestProvider) RegisterHealthCheckTask(
	string,
	utils.IntRanges[uint16],
	string,
	uint,
) {
}

func parseProxyChainTestProxy(t *testing.T, mapping map[string]any) C.Proxy {
	t.Helper()
	proxy, err := adapter.ParseProxy(
		mapping,
		adapter.WithTunnelForAPI(tunnel.Tunnel),
	)
	if err != nil {
		t.Fatalf("parse proxy %q: %v", mapping["name"], err)
	}
	t.Cleanup(func() {
		_ = proxy.Close()
	})
	return proxy
}

func installProxyChainTestRuntime(
	t *testing.T,
	proxies map[string]C.Proxy,
	providers map[string]P.ProxyProvider,
) map[string]*proxyChainSelectorOverlay {
	t.Helper()
	previousProxies := tunnel.Proxies()
	previousProviders := tunnel.Providers()
	proxyChainRuntimeState.Lock()
	previousStaged := proxyChainRuntimeState.staged
	proxyChainRuntimeState.staged = nil
	overlays := installProxyChainSelectorOverlays(proxies)
	proxyChainRuntimeState.Unlock()
	tunnel.UpdateProxies(proxies, providers)
	t.Cleanup(func() {
		proxyChainRuntimeState.Lock()
		proxyChainRuntimeState.staged = previousStaged
		proxyChainRuntimeState.Unlock()
		tunnel.UpdateProxies(previousProxies, previousProviders)
	})
	return overlays
}

func TestProxyChainStageFailureClearsPreviousState(t *testing.T) {
	proxyChainRuntimeState.Lock()
	previousStaged := proxyChainRuntimeState.staged
	proxyChainRuntimeState.staged = &proxyChainRuntimeConfig{
		proxyNames: []string{"old"},
	}
	err := stageProxyChainLocked(UpdateProxyChainParams{})
	staged := proxyChainRuntimeState.staged
	proxyChainRuntimeState.staged = previousStaged
	proxyChainRuntimeState.Unlock()

	if err == nil {
		t.Fatal("empty Chain stage unexpectedly succeeded")
	}
	if staged != nil {
		t.Fatal("failed Chain stage retained previous state")
	}
}

func TestProxyChainPrepareFailureConsumesStagedState(t *testing.T) {
	proxyChainRuntimeState.Lock()
	previousStaged := proxyChainRuntimeState.staged
	proxyChainRuntimeState.staged = &proxyChainRuntimeConfig{}
	_, err := prepareProxyChainConfigLocked(&config.Config{}, nil)
	staged := proxyChainRuntimeState.staged
	proxyChainRuntimeState.staged = previousStaged
	proxyChainRuntimeState.Unlock()

	if err == nil {
		t.Fatal("empty staged Chain unexpectedly prepared")
	}
	if staged != nil {
		t.Fatal("failed Chain preparation retained staged state")
	}
}

func TestProxyChainSelectorOverlayBypassesGroupExclusions(t *testing.T) {
	node := parseProxyChainTestProxy(t, map[string]any{
		"name": "node-a",
		"type": "direct",
	})
	chain := parseProxyChainTestProxy(t, map[string]any{
		"name": flClashChainName,
		"type": "reject",
	})
	provider := &proxyChainTestProvider{
		name:        "inline-selector-provider",
		vehicleType: P.Compatible,
		proxies:     []C.Proxy{node},
		version:     7,
	}
	selector, err := outboundgroup.NewSelector(
		outboundgroup.GroupCommonOption{
			Name:        "Any configured name",
			Type:        "select",
			ExcludeType: "Reject",
		},
		outboundgroup.SelectorOption{},
		node,
		[]P.ProxyProvider{provider},
	)
	if err != nil {
		t.Fatalf("create selector: %v", err)
	}
	proxies := map[string]C.Proxy{
		"Any configured name": adapter.NewProxy(selector),
		flClashChainName:      chain,
	}
	overlays := installProxyChainTestRuntime(
		t,
		proxies,
		map[string]P.ProxyProvider{provider.Name(): provider},
	)
	overlay := overlays["Any configured name"]

	if err := overlay.Set(flClashChainName); err != nil {
		t.Fatalf("select Chain despite exclude-type: %v", err)
	}
	if overlay.Now() != flClashChainName {
		t.Fatalf("selector now = %q, want Chain", overlay.Now())
	}
	if selector.Providers()[0] != provider {
		t.Fatal("selector provider was modified")
	}
	data, err := overlay.MarshalJSON()
	if err != nil {
		t.Fatalf("marshal selector: %v", err)
	}
	var mapping map[string]any
	if err := json.Unmarshal(data, &mapping); err != nil {
		t.Fatalf("unmarshal selector: %v", err)
	}
	if mapping["now"] != flClashChainName {
		t.Fatalf("marshaled now = %v, want Chain", mapping["now"])
	}
	all, _ := mapping["all"].([]any)
	if len(all) == 0 || all[0] != flClashChainName {
		t.Fatalf("marshaled all = %v, want Chain first", all)
	}
}

func TestProxyChainSelectorOverlayRejectsGroupCycle(t *testing.T) {
	node := parseProxyChainTestProxy(t, map[string]any{
		"name": "node-a",
		"type": "direct",
	})
	chain := parseProxyChainTestProxy(t, map[string]any{
		"name":         flClashChainName,
		"type":         "socks5",
		"server":       "127.0.0.1",
		"port":         1,
		"dialer-proxy": "Loop selector",
	})
	provider := &proxyChainTestProvider{
		name:        "loop-selector-provider",
		vehicleType: P.Compatible,
		proxies:     []C.Proxy{node},
	}
	selector, err := outboundgroup.NewSelector(
		outboundgroup.GroupCommonOption{
			Name: "Loop selector",
			Type: "select",
		},
		outboundgroup.SelectorOption{},
		node,
		[]P.ProxyProvider{provider},
	)
	if err != nil {
		t.Fatalf("create selector: %v", err)
	}
	proxies := map[string]C.Proxy{
		"Loop selector":  adapter.NewProxy(selector),
		flClashChainName: chain,
	}
	overlays := installProxyChainTestRuntime(
		t,
		proxies,
		map[string]P.ProxyProvider{provider.Name(): provider},
	)

	err = overlays["Loop selector"].Set(flClashChainName)
	if err == nil || !strings.Contains(err.Error(), "dependency cycle") {
		t.Fatalf("select cyclic Chain error = %v", err)
	}
	if overlays["Loop selector"].Now() != "node-a" {
		t.Fatalf(
			"selector changed after rejected cycle: %q",
			overlays["Loop selector"].Now(),
		)
	}
}

type proxyChainTestTracker struct {
	statistic.Tracker
	info *statistic.TrackerInfo
}

func (t *proxyChainTestTracker) Info() *statistic.TrackerInfo {
	return t.info
}

func (t *proxyChainTestTracker) Chains() C.Chain {
	return t.info.Chain
}

func TestProxyChainTrackerReplacesInternalHops(t *testing.T) {
	proxyChainState.RLock()
	previousNames := append([]string(nil), proxyChainState.proxyNames...)
	proxyChainState.RUnlock()
	setProxyChainNames([]string{"entry", "exit"})
	t.Cleanup(func() {
		setProxyChainNames(previousNames)
	})
	tracker := &proxyChainTestTracker{
		info: &statistic.TrackerInfo{
			Metadata: &C.Metadata{Type: C.HTTP},
			Chain: C.Chain{
				flClashChainName,
				flClashChainHopPrefix + "0_test",
				"Configured selector",
			},
		},
	}

	if !prepareProxyChainTracker(tracker) {
		t.Fatal("outer Chain tracker was hidden")
	}
	want := C.Chain{
		"exit",
		"entry",
		flClashChainName,
		"Configured selector",
	}
	if !reflect.DeepEqual(tracker.info.Chain, want) {
		t.Fatalf("tracker chain = %v, want %v", tracker.info.Chain, want)
	}
}

func TestProxyChainInnerTrackerIsHiddenForSingleHopChain(t *testing.T) {
	tracker := &proxyChainTestTracker{
		info: &statistic.TrackerInfo{
			Metadata: &C.Metadata{Type: C.INNER},
			Chain:    C.Chain{flClashChainName},
		},
	}

	if prepareProxyChainTracker(tracker) {
		t.Fatal("inner single-hop Chain tracker was exposed")
	}
}

type proxyChainRuntimeTestConn struct {
	C.Conn
	closeCalls    atomic.Int32
	closeFailures int32
}

func (c *proxyChainRuntimeTestConn) Close() error {
	call := c.closeCalls.Add(1)
	if call <= c.closeFailures {
		return errors.New("temporary close failure")
	}
	return nil
}

type proxyChainRuntimeTestPacketConn struct {
	C.PacketConn
	closeCalls atomic.Int32
}

func (c *proxyChainRuntimeTestPacketConn) Close() error {
	c.closeCalls.Add(1)
	return nil
}

type proxyChainRuntimeTestProxy struct {
	C.Proxy
	dial         func(context.Context) (C.Conn, error)
	listenPacket func(context.Context) (C.PacketConn, error)
	closeCalls   atomic.Int32
}

func (p *proxyChainRuntimeTestProxy) Name() string {
	return flClashChainName
}

func (p *proxyChainRuntimeTestProxy) DialContext(
	ctx context.Context,
	_ *C.Metadata,
) (C.Conn, error) {
	return p.dial(ctx)
}

func (p *proxyChainRuntimeTestProxy) ListenPacketContext(
	ctx context.Context,
	_ *C.Metadata,
) (C.PacketConn, error) {
	return p.listenPacket(ctx)
}

func (p *proxyChainRuntimeTestProxy) Close() error {
	p.closeCalls.Add(1)
	return nil
}

func newProxyChainTestRuntime(proxy C.Proxy) *proxyChainRuntime {
	return newProxyChainRuntime(
		map[string]C.Proxy{flClashChainName: proxy},
		proxy,
	)
}

func TestProxyChainRuntimeRetireClosesTCPAndUDPConnections(t *testing.T) {
	tcpConn := &proxyChainRuntimeTestConn{}
	packetConn := &proxyChainRuntimeTestPacketConn{}
	proxy := &proxyChainRuntimeTestProxy{
		dial: func(context.Context) (C.Conn, error) {
			return tcpConn, nil
		},
		listenPacket: func(context.Context) (C.PacketConn, error) {
			return packetConn, nil
		},
	}
	runtime := newProxyChainTestRuntime(proxy)

	if _, err := runtime.DialContext(context.Background(), &C.Metadata{}); err != nil {
		t.Fatalf("dial Chain runtime: %v", err)
	}
	if _, err := runtime.ListenPacketContext(
		context.Background(),
		&C.Metadata{},
	); err != nil {
		t.Fatalf("listen Chain runtime packet: %v", err)
	}
	runtime.retire(true)

	if tcpConn.closeCalls.Load() != 1 {
		t.Fatalf("TCP close calls = %d, want 1", tcpConn.closeCalls.Load())
	}
	if packetConn.closeCalls.Load() != 1 {
		t.Fatalf(
			"UDP close calls = %d, want 1",
			packetConn.closeCalls.Load(),
		)
	}
	if proxy.closeCalls.Load() != 1 {
		t.Fatalf("proxy close calls = %d, want 1", proxy.closeCalls.Load())
	}
	if _, err := runtime.DialContext(
		context.Background(),
		&C.Metadata{},
	); !errors.Is(err, errProxyChainRuntimeRetired) {
		t.Fatalf("dial retired runtime error = %v", err)
	}
}

func TestProxyChainRuntimeRetireCancelsInFlightDial(t *testing.T) {
	dialStarted := make(chan struct{})
	proxy := &proxyChainRuntimeTestProxy{
		dial: func(ctx context.Context) (C.Conn, error) {
			close(dialStarted)
			<-ctx.Done()
			return nil, ctx.Err()
		},
	}
	runtime := newProxyChainTestRuntime(proxy)
	dialResult := make(chan error, 1)
	go func() {
		_, err := runtime.DialContext(context.Background(), &C.Metadata{})
		dialResult <- err
	}()
	<-dialStarted

	runtime.retire(true)

	if err := <-dialResult; !errors.Is(err, context.Canceled) {
		t.Fatalf("in-flight dial error = %v, want context canceled", err)
	}
	if proxy.closeCalls.Load() != 1 {
		t.Fatalf("proxy close calls = %d, want 1", proxy.closeCalls.Load())
	}
}

func TestProxyChainRuntimeClosesConnectionReturnedAfterRetirement(t *testing.T) {
	dialStarted := make(chan struct{})
	runtimeCanceled := make(chan struct{})
	releaseDial := make(chan struct{})
	conn := &proxyChainRuntimeTestConn{}
	proxy := &proxyChainRuntimeTestProxy{
		dial: func(ctx context.Context) (C.Conn, error) {
			close(dialStarted)
			<-ctx.Done()
			close(runtimeCanceled)
			<-releaseDial
			return conn, nil
		},
	}
	runtime := newProxyChainTestRuntime(proxy)
	dialResult := make(chan error, 1)
	go func() {
		_, err := runtime.DialContext(context.Background(), &C.Metadata{})
		dialResult <- err
	}()
	<-dialStarted
	retireDone := make(chan struct{})
	go func() {
		runtime.retire(true)
		close(retireDone)
	}()
	<-runtimeCanceled
	close(releaseDial)

	if err := <-dialResult; !errors.Is(err, errProxyChainRuntimeRetired) {
		t.Fatalf("late dial error = %v, want retired runtime", err)
	}
	<-retireDone
	if conn.closeCalls.Load() != 1 {
		t.Fatalf("late connection close calls = %d, want 1", conn.closeCalls.Load())
	}
	if proxy.closeCalls.Load() != 1 {
		t.Fatalf("proxy close calls = %d, want 1", proxy.closeCalls.Load())
	}
}

func TestProxyChainRuntimeRetriesConnectionClose(t *testing.T) {
	conn := &proxyChainRuntimeTestConn{closeFailures: 2}
	proxy := &proxyChainRuntimeTestProxy{
		dial: func(context.Context) (C.Conn, error) {
			return conn, nil
		},
	}
	runtime := newProxyChainTestRuntime(proxy)
	if _, err := runtime.DialContext(context.Background(), &C.Metadata{}); err != nil {
		t.Fatalf("dial Chain runtime: %v", err)
	}

	runtime.retire(true)

	if conn.closeCalls.Load() != proxyChainCloseAttempts {
		t.Fatalf(
			"connection close calls = %d, want %d",
			conn.closeCalls.Load(),
			proxyChainCloseAttempts,
		)
	}
}

func TestProxyChainRuntimePreservesConnectionsUntilNaturalClose(t *testing.T) {
	conn := &proxyChainRuntimeTestConn{}
	proxy := &proxyChainRuntimeTestProxy{
		dial: func(context.Context) (C.Conn, error) {
			return conn, nil
		},
	}
	runtime := newProxyChainTestRuntime(proxy)
	tracked, err := runtime.DialContext(context.Background(), &C.Metadata{})
	if err != nil {
		t.Fatalf("dial Chain runtime: %v", err)
	}

	runtime.retire(false)
	if conn.closeCalls.Load() != 0 {
		t.Fatalf("preserved connection close calls = %d", conn.closeCalls.Load())
	}
	if proxy.closeCalls.Load() != 0 {
		t.Fatalf("preserved proxy close calls = %d", proxy.closeCalls.Load())
	}
	if err := tracked.Close(); err != nil {
		t.Fatalf("close preserved connection: %v", err)
	}
	if proxy.closeCalls.Load() != 1 {
		t.Fatalf("proxy close calls = %d, want 1", proxy.closeCalls.Load())
	}
}
