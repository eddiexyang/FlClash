package main

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/utils"
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
