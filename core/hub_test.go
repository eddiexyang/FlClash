package main

import (
	"errors"
	"testing"

	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

type closeErrorTracker struct {
	statistic.Tracker
	id         string
	closeCalls int
}

func (t *closeErrorTracker) ID() string {
	return t.id
}

func (t *closeErrorTracker) Close() error {
	t.closeCalls++
	return errors.New("close failed")
}

func TestCloseConnectionsContinuesAfterErrors(t *testing.T) {
	previousManager := statistic.DefaultManager
	statistic.DefaultManager = &statistic.Manager{}
	t.Cleanup(func() {
		statistic.DefaultManager = previousManager
	})

	trackers := []*closeErrorTracker{
		{id: "first"},
		{id: "second"},
		{id: "third"},
	}
	for _, tracker := range trackers {
		statistic.DefaultManager.Join(tracker)
	}

	if closeConnections() {
		t.Fatal("closeConnections returned success despite close errors")
	}
	for _, tracker := range trackers {
		if tracker.closeCalls != 1 {
			t.Fatalf("tracker %q close calls = %d, want 1", tracker.id, tracker.closeCalls)
		}
	}
}

type chainTracker struct {
	statistic.Tracker
	id         string
	chain      C.Chain
	metadata   *C.Metadata
	manager    *statistic.Manager
	closeCalls int
}

func (t *chainTracker) ID() string {
	return t.id
}

func (t *chainTracker) Chains() C.Chain {
	return t.chain
}

func (t *chainTracker) Info() *statistic.TrackerInfo {
	return &statistic.TrackerInfo{Metadata: t.metadata}
}

func (t *chainTracker) Close() error {
	t.closeCalls++
	if t.manager != nil {
		t.manager.Leave(t)
	}
	return nil
}

func TestConnectionsUsingGroupFiltersByChain(t *testing.T) {
	previousManager := statistic.DefaultManager
	statistic.DefaultManager = &statistic.Manager{}
	t.Cleanup(func() {
		statistic.DefaultManager = previousManager
	})

	trackers := []*chainTracker{
		{id: "direct-group", chain: C.Chain{"node-a", "group-a"}},
		{id: "nested-group", chain: C.Chain{"node-b", "group-a", "outer-group"}},
		{id: "same-node-other-group", chain: C.Chain{"node-a", "group-b"}},
		{id: "similar-group-name", chain: C.Chain{"node-c", "group-a-backup"}},
	}
	for _, tracker := range trackers {
		statistic.DefaultManager.Join(tracker)
	}

	closeTrackedConnections(connectionsUsingGroup("group-a"))

	for index, tracker := range trackers {
		wantCloseCalls := 0
		if index < 2 {
			wantCloseCalls = 1
		}
		if tracker.closeCalls != wantCloseCalls {
			t.Fatalf(
				"tracker %q close calls = %d, want %d",
				tracker.id,
				tracker.closeCalls,
				wantCloseCalls,
			)
		}
	}
}

func TestUpdateConfigClosesConnectionsWhenRuntimeModeChanges(t *testing.T) {
	previousConfig := currentConfig
	previousRunning := isRunning
	previousMode := tunnel.Mode()
	previousManager := statistic.DefaultManager
	parsedConfig, err := config.ParseRawConfig(config.DefaultRawConfig())
	if err != nil {
		t.Fatalf("parse default config: %v", err)
	}
	parsedConfig.General.Mode = tunnel.Direct
	currentConfig = parsedConfig
	isRunning = false
	statistic.DefaultManager = &statistic.Manager{}
	tunnel.SetMode(tunnel.Rule)
	t.Cleanup(func() {
		currentConfig = previousConfig
		isRunning = previousRunning
		tunnel.SetMode(previousMode)
		statistic.DefaultManager = previousManager
	})

	tracker := &chainTracker{
		id:    "existing-proxy",
		chain: C.Chain{"node-a"},
		metadata: &C.Metadata{
			RouteRevision:    ^uint64(0),
			RouteRevisionSet: true,
		},
		manager: statistic.DefaultManager,
	}
	statistic.DefaultManager.Join(tracker)
	directMode := tunnel.Direct
	updateConfig(&UpdateParams{Mode: &directMode})

	if tunnel.Mode() != tunnel.Direct {
		t.Fatalf("runtime mode = %s, want direct", tunnel.Mode())
	}
	if tracker.closeCalls != 1 {
		t.Fatalf("existing connection close calls = %d, want 1", tracker.closeCalls)
	}
	if statistic.DefaultManager.Get(tracker.id) != nil {
		t.Fatal("existing connection remains in the manager")
	}
}
