package peer

import (
	"encoding/json"
	"farreach.local/networking/internal/invitation"
	"farreach.local/networking/internal/wire"
	"strings"
	"testing"
	"time"
)

func TestRTPNegotiationChannelsBecomeReady(t *testing.T) {
	hostEvents := make(chan Event, 64)
	viewerEvents := make(chan Event, 64)
	output := func(events chan Event) func(wire.Frame) bool {
		return func(f wire.Frame) bool {
			if f.Kind == wire.Event {
				var e Event
				json.Unmarshal(f.Payload, &e)
				events <- e
			}
			return true
		}
	}
	host, err := New(Config{ProtocolVersion: 2, Role: "host"}, output(hostEvents))
	if err != nil {
		t.Fatal(err)
	}
	defer host.Close()
	if err = host.Start(); err != nil {
		t.Fatal(err)
	}
	offer := <-hostEvents
	parsedOffer, err := invitation.ParseOffer(offer.Value, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(parsedOffer.SDP, "profile-level-id=4d0033") {
		t.Fatal("H264 Main5.1 ceiling missing from offer")
	}
	viewer, err := New(Config{ProtocolVersion: 2, Role: "viewer", Invitation: offer.Value}, output(viewerEvents))
	if err != nil {
		t.Fatal(err)
	}
	defer viewer.Close()
	if err = viewer.Start(); err != nil {
		t.Fatal(err)
	}
	answer := <-viewerEvents
	parsedAnswer, err := invitation.ParseAnswer(answer.Value, parsedOffer, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(parsedAnswer.SDP, "profile-level-id=4d0033") {
		t.Fatal("H264 Main5.1 ceiling missing from answer")
	}
	if err = host.ApplyAnswer(answer.Value); err != nil {
		t.Fatal(err)
	}
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	hostReady, viewerReady := false, false
	for !hostReady || !viewerReady {
		select {
		case e := <-hostEvents:
			t.Log("host", e.Type)
			if e.Type == "ready" {
				hostReady = true
			}
			if e.Type == "error" {
				t.Fatal(e.Value)
			}
		case e := <-viewerEvents:
			t.Log("viewer", e.Type)
			if e.Type == "ready" {
				viewerReady = true
			}
			if e.Type == "error" {
				t.Fatal(e.Value)
			}
		case <-deadline.C:
			host.mu.Lock()
			t.Logf("host ready=%v connected=%v control=%v pointer=%v pc=%v ice=%v", host.ready, host.connected, host.controlOpen, host.videoOpen, host.pc.ConnectionState(), host.pc.ICEConnectionState())
			host.mu.Unlock()
			viewer.mu.Lock()
			t.Logf("viewer ready=%v connected=%v control=%v pointer=%v pc=%v ice=%v", viewer.ready, viewer.connected, viewer.controlOpen, viewer.videoOpen, viewer.pc.ConnectionState(), viewer.pc.ICEConnectionState())
			viewer.mu.Unlock()
			t.Fatal("connection timeout")
		}
	}
}
