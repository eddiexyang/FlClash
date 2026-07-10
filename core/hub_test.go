package main

import (
	"errors"
	"testing"

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
