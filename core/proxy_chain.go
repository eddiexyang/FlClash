package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/utils"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

const (
	flClashChainName      = "__FLCLASH_INTERNAL_CHAIN__"
	flClashChainHopPrefix = "__FLCLASH_INTERNAL_CHAIN_HOP_"
	flClashChainGroup     = "PROXY"
)

type proxyChainProvider struct {
	delegate P.ProxyProvider
	mutex    sync.RWMutex
	proxies  []C.Proxy
	version  uint32
}

func newProxyChainProvider(delegate P.ProxyProvider, proxies []C.Proxy) *proxyChainProvider {
	return &proxyChainProvider{
		delegate: delegate,
		proxies:  proxies,
		version:  delegate.Version() + 1,
	}
}

func (p *proxyChainProvider) setProxies(proxies []C.Proxy) {
	p.mutex.Lock()
	p.proxies = proxies
	p.version++
	p.mutex.Unlock()
}

func (p *proxyChainProvider) Name() string {
	return p.delegate.Name()
}

func (p *proxyChainProvider) VehicleType() P.VehicleType {
	return p.delegate.VehicleType()
}

func (p *proxyChainProvider) Type() P.ProviderType {
	return p.delegate.Type()
}

func (p *proxyChainProvider) Initial() error {
	return nil
}

func (p *proxyChainProvider) Update() error {
	return nil
}

func (p *proxyChainProvider) Proxies() []C.Proxy {
	p.mutex.RLock()
	defer p.mutex.RUnlock()
	return append([]C.Proxy(nil), p.proxies...)
}

func (p *proxyChainProvider) Count() int {
	p.mutex.RLock()
	defer p.mutex.RUnlock()
	return len(p.proxies)
}

func (p *proxyChainProvider) Touch() {
	p.delegate.Touch()
}

func (p *proxyChainProvider) HealthCheck() {
	p.delegate.HealthCheck()
}

func (p *proxyChainProvider) Version() uint32 {
	p.mutex.RLock()
	defer p.mutex.RUnlock()
	return p.version
}

func (p *proxyChainProvider) RegisterHealthCheckTask(url string, expectedStatus utils.IntRanges[uint16], filter string, interval uint) {
	p.delegate.RegisterHealthCheckTask(url, expectedStatus, filter, interval)
}

func (p *proxyChainProvider) HealthCheckURL() string {
	return p.delegate.HealthCheckURL()
}

func isFlClashChainProxy(name string) bool {
	return name == flClashChainName || strings.HasPrefix(name, flClashChainHopPrefix)
}

func parseProxyChain(configs []map[string]interface{}) (map[string]C.Proxy, C.Proxy, error) {
	if len(configs) == 0 {
		return nil, nil, fmt.Errorf("proxy chain overlay is empty")
	}
	proxies := make(map[string]C.Proxy, len(configs))
	var chainProxy C.Proxy
	for index, mapping := range configs {
		proxy, err := adapter.ParseProxy(mapping, adapter.WithTunnelForAPI(tunnel.Tunnel))
		if err != nil {
			return nil, nil, fmt.Errorf("parse proxy chain hop %d: %w", index, err)
		}
		name := proxy.Name()
		if !isFlClashChainProxy(name) {
			return nil, nil, fmt.Errorf("invalid proxy chain hop %q", name)
		}
		if _, exists := proxies[name]; exists {
			return nil, nil, fmt.Errorf("duplicate proxy chain hop %q", name)
		}
		proxies[name] = proxy
		if name == flClashChainName {
			chainProxy = proxy
		}
	}
	if chainProxy == nil {
		return nil, nil, fmt.Errorf("proxy chain entry is missing")
	}
	return proxies, chainProxy, nil
}

func getProxyChainGroup() (outboundgroup.ProxyGroup, error) {
	for name, proxy := range tunnel.Proxies() {
		if !strings.EqualFold(name, flClashChainGroup) {
			continue
		}
		group, ok := proxy.Adapter().(outboundgroup.ProxyGroup)
		if !ok {
			return nil, fmt.Errorf("%s is not a proxy group", name)
		}
		if _, ok := proxy.Adapter().(outboundgroup.SelectAble); !ok {
			return nil, fmt.Errorf("%s is not selectable", name)
		}
		return group, nil
	}
	return nil, fmt.Errorf("%s proxy group is missing", flClashChainGroup)
}

func updateProxyChain(configs []map[string]interface{}) error {
	parsedProxies, chainProxy, err := parseProxyChain(configs)
	if err != nil {
		return err
	}
	group, err := getProxyChainGroup()
	if err != nil {
		return err
	}

	groupProviders := group.Providers()
	providerIndex := -1
	for index, provider := range groupProviders {
		if _, ok := provider.(*proxyChainProvider); ok {
			providerIndex = index
			break
		}
		if provider.VehicleType() == P.Compatible && strings.EqualFold(provider.Name(), group.Name()) {
			providerIndex = index
			break
		}
	}
	if providerIndex == -1 {
		return fmt.Errorf("%s compatible provider is missing", group.Name())
	}

	currentProvider := groupProviders[providerIndex]
	groupProxies := []C.Proxy{chainProxy}
	for _, proxy := range currentProvider.Proxies() {
		if !isFlClashChainProxy(proxy.Name()) {
			groupProxies = append(groupProxies, proxy)
		}
	}

	var chainProvider *proxyChainProvider
	if current, ok := currentProvider.(*proxyChainProvider); ok {
		chainProvider = current
		chainProvider.setProxies(groupProxies)
	} else {
		chainProvider = newProxyChainProvider(currentProvider, groupProxies)
		groupProviders[providerIndex] = chainProvider
	}

	proxies := make(map[string]C.Proxy, len(tunnel.Proxies())+len(parsedProxies))
	for name, proxy := range tunnel.Proxies() {
		if !isFlClashChainProxy(name) {
			proxies[name] = proxy
		}
	}
	for name, proxy := range parsedProxies {
		proxies[name] = proxy
	}
	providers := make(map[string]P.ProxyProvider, len(tunnel.Providers()))
	for name, provider := range tunnel.Providers() {
		providers[name] = provider
	}
	providers[currentProvider.Name()] = chainProvider
	tunnel.UpdateProxies(proxies, providers)
	return nil
}

func handleUpdateProxyChain(data []byte) string {
	runLock.Lock()
	defer runLock.Unlock()
	var params UpdateProxyChainParams
	if err := json.Unmarshal(data, &params); err != nil {
		return err.Error()
	}
	var affectedConnections []statistic.Tracker
	if params.CloseConnections {
		affectedConnections = connectionsUsingGroup(flClashChainName)
	}
	if err := updateProxyChain(params.Proxies); err != nil {
		return err.Error()
	}
	if params.CloseConnections {
		closeTrackedConnections(affectedConnections)
	}
	return ""
}
