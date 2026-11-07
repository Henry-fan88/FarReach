package peer

import (
	"encoding/json"
	"testing"
	"time"

	"farreach.local/networking/internal/wire"
	"github.com/pion/rtcp"
)

// A legitimate decoder refresh request is not evidence of network congestion.
// This regression sends a real encrypted RTCP PLI after clean media delivery.
func TestPictureLossRequestDoesNotCountAsSenderDrop(t *testing.T) {
	hostFrames, viewerFrames := make(chan wire.Frame, 256), make(chan wire.Frame, 256)
	output := func(ch chan wire.Frame) func(wire.Frame) bool {
		return func(f wire.Frame) bool { ch <- f; return true }
	}
	host, err := New(Config{ProtocolVersion: 2, Role: "host"}, output(hostFrames))
	if err != nil {
		t.Fatal(err)
	}
	defer host.Close()
	if err = host.Start(); err != nil {
		t.Fatal(err)
	}
	offer := awaitDiagnosticEvent(t, hostFrames, "invitation")
	viewer, err := New(Config{ProtocolVersion: 2, Role: "viewer", Invitation: offer}, output(viewerFrames))
	if err != nil {
		t.Fatal(err)
	}
	defer viewer.Close()
	if err = viewer.Start(); err != nil {
		t.Fatal(err)
	}
	answer := awaitDiagnosticEvent(t, viewerFrames, "response")
	if err = host.ApplyAnswer(answer); err != nil {
		t.Fatal(err)
	}
	awaitDiagnosticEvent(t, hostFrames, "ready")
	awaitDiagnosticEvent(t, viewerFrames, "ready")
	if err = host.AuthorizeMedia(MediaAuthorization{true, 42}); err != nil {
		t.Fatal(err)
	}
	if err = viewer.AuthorizeMedia(MediaAuthorization{true, 42}); err != nil {
		t.Fatal(err)
	}
	if err = host.Send(wire.Frame{Kind: wire.Video, Payload: virtualFrame(1, time.Now(), true)}); err != nil {
		t.Fatal(err)
	}
	timeout := time.NewTimer(3 * time.Second)
	defer timeout.Stop()
	received := false
	for !received {
		select {
		case f := <-viewerFrames:
			received = f.Kind == wire.Video
		case <-timeout.C:
			t.Fatal("clean media did not arrive")
		}
	}
	// Drain startup control/events before observing the explicit request.
	for {
		select {
		case <-hostFrames:
		default:
			goto drained
		}
	}
drained:
	before := host.droppedFrames.Load()
	viewer.mu.Lock()
	ssrc := viewer.remoteSSRC
	viewer.mu.Unlock()
	if ssrc == 0 {
		t.Fatal("media SSRC absent")
	}
	if err = viewer.pc.WriteRTCP([]rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: ssrc}}); err != nil {
		t.Fatal(err)
	}
	awaitDiagnosticEvent(t, hostFrames, "videoDropped")
	after := host.droppedFrames.Load()
	if after != before {
		t.Fatalf("legitimate PLI fabricated sender-drop/congestion: before=%d after=%d", before, after)
	}
	if host.keyframeRequests.Load() != 1 {
		t.Fatal("refresh request must remain observable separately")
	}
	host.mu.Lock()
	needsKey := host.needSendKeyframe
	host.mu.Unlock()
	if !needsKey {
		t.Fatal("refresh did not invalidate the reference state")
	}
}

func TestDependencySuppressionDoesNotFabricateCongestion(t *testing.T) {
	p := &Connection{needSendKeyframe: true, dropGeneration: 7, output: func(wire.Frame) bool { return true }}
	for i := 0; i < 30; i++ {
		p.suppressDependentVideo()
	}
	if p.droppedFrames.Load() != 0 || p.dependencySuppressedFrames.Load() != 30 {
		t.Fatal("suppressed dependencies were counted as congestion drops")
	}
	if !p.needSendKeyframe || p.dropGeneration != 7 {
		t.Fatal("suppression invalidated the pending recovery generation")
	}
	p.videoDropped()
	if p.droppedFrames.Load() != 1 || p.dropGeneration != 8 {
		t.Fatal("actual drops stopped triggering recovery")
	}
}
func awaitDiagnosticEvent(t *testing.T, ch <-chan wire.Frame, want string) string {
	t.Helper()
	timer := time.NewTimer(4 * time.Second)
	defer timer.Stop()
	for {
		select {
		case f := <-ch:
			if f.Kind != wire.Event {
				continue
			}
			var e Event
			if json.Unmarshal(f.Payload, &e) != nil {
				t.Fatal("bad diagnostic event")
			}
			if e.Type == want {
				return e.Value
			}
			if e.Type == "error" {
				t.Fatal(e.Value)
			}
		case <-timer.C:
			t.Fatalf("awaiting %s", want)
		}
	}
}
