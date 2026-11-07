package main

import (
	"bytes"
	"encoding/json"
	"testing"
	"time"

	"farreach.local/networking/internal/peer"
	"farreach.local/networking/internal/wire"
)

func waitMediaCapacity(t *testing.T, p *helperProcess, available bool) {
	t.Helper()
	timer := time.NewTimer(4 * time.Second)
	defer timer.Stop()
	for {
		select {
		case f := <-p.frames:
			if f.Kind != wire.Event {
				continue
			}
			var e peer.Event
			json.Unmarshal(f.Payload, &e)
			if e.Type == "error" {
				t.Fatal(e.Value)
			}
			if e.Type != "mediaCapacity" {
				continue
			}
			var c struct {
				Generation uint64
				Available  bool
			}
			if json.Unmarshal([]byte(e.Value), &c) != nil || c.Generation != 42 {
				t.Fatal("invalid capacity epoch")
			}
			if c.Available == available {
				return
			}
		case err := <-p.errors:
			t.Fatalf("helper stopped: %v", err)
		case <-timer.C:
			t.Fatalf("timed out waiting for capacity=%v", available)
		}
	}
}
func assertNoMediaGrant(t *testing.T, p *helperProcess, duration time.Duration) {
	t.Helper()
	timer := time.NewTimer(duration)
	defer timer.Stop()
	for {
		select {
		case f := <-p.frames:
			if f.Kind != wire.Event {
				continue
			}
			var e peer.Event
			json.Unmarshal(f.Payload, &e)
			if e.Type == "error" {
				t.Fatal(e.Value)
			}
			if e.Type == "mediaCapacity" {
				var c struct{ Available bool }
				json.Unmarshal([]byte(e.Value), &c)
				if c.Available {
					t.Fatal("premature or duplicate media capacity grant")
				}
			}
		case err := <-p.errors:
			t.Fatalf("helper stopped: %v", err)
		case <-timer.C:
			return
		}
	}
}
func TestRealHelperCreditsLargeIDRThenDelta(t *testing.T) {
	host, viewer := launch(t), launch(t)
	host.config(t, peer.Config{ProtocolVersion: 2, Role: "host", MediaFlowControl: true})
	offer := host.event(t, "invitation")
	viewer.config(t, peer.Config{ProtocolVersion: 2, Role: "viewer", Invitation: offer, MediaFlowControl: true})
	answer := viewer.event(t, "response")
	command, _ := json.Marshal(map[string]string{"response": answer})
	host.send(t, wire.Frame{Kind: wire.ApplyAnswer, Payload: command})
	host.event(t, "ready")
	viewer.event(t, "ready")
	for _, p := range []*helperProcess{host, viewer} {
		p.send(t, wire.Frame{Kind: wire.MediaAuthorization, Payload: []byte(`{"authorized":true,"generation":42}`)})
	}
	waitMediaCapacity(t, host, true)
	assertNoMediaGrant(t, host, 50*time.Millisecond)
	large := outputTestFrame(t, 0, 200*1024, 42)
	for offset := 0; offset < len(large.Payload); offset += wire.MediaChunkSize {
		host.send(t, wire.MediaFragment(1, large.Payload, offset))
	}
	waitMediaCapacity(t, host, false)
	assertNoMediaGrant(t, host, 100*time.Millisecond)
	if got := viewer.application(t, wire.Video); !bytes.Equal(got.Payload, large.Payload) {
		t.Fatal("oversized valid IDR did not survive bounded recovery")
	}
	waitMediaCapacity(t, host, true)
	assertNoMediaGrant(t, host, 50*time.Millisecond)
	delta := outputTestFrame(t, 1, 4096, 42)
	host.send(t, wire.MediaFragment(2, delta.Payload, 0))
	waitMediaCapacity(t, host, false)
	if got := viewer.application(t, wire.Video); !bytes.Equal(got.Payload, delta.Payload) {
		t.Fatal("delta reference chain after oversized IDR failed")
	}
	waitMediaCapacity(t, host, true)
	assertNoMediaGrant(t, host, 50*time.Millisecond)
}
