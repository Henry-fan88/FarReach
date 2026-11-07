package peer

import (
	"encoding/json"
	"testing"
	"time"

	"farreach.local/networking/internal/video"
	"farreach.local/networking/internal/wire"
	"github.com/pion/interceptor"
	"github.com/pion/rtp"
)

func TestMediaFlowGrantWaitsForEnqueueAndInFlightWriter(t *testing.T) {
	pacer := newPacer()
	entered, release := make(chan struct{}), make(chan struct{})
	defer pacer.Close()
	pacer.AddStream(1, interceptor.RTPWriterFunc(func(_ *rtp.Header, b []byte, _ interceptor.Attributes) (int, error) {
		close(entered)
		<-release
		return len(b), nil
	}))
	pacer.SetGeneration(42)
	events := make(chan Event, 16)
	p := &Connection{cfg: Config{Role: "host", MediaFlowControl: true}, ready: true, connected: true, authorized: true, mediaGeneration: 42, flowSequence: 1, pacer: pacer, output: func(f wire.Frame) bool { var e Event; json.Unmarshal(f.Payload, &e); events <- e; return true }}
	pacer.mu.Lock()
	pacer.onDrained = p.maybeGrantMediaCapacity
	pacer.mu.Unlock()
	m := video.Metadata{Generation: 42, Sequence: 1, Width: 1280, Height: 720, Keyframe: true, Count: 1}
	if !pacer.BeginFrame(m, 500, 1) {
		t.Fatal("frame admission")
	}
	h := rtp.Header{Version: 2, SSRC: 1}
	h.SetExtension(1, m.Marshal())
	if _, err := pacer.Write(&h, make([]byte, 100), nil); err != nil {
		t.Fatal(err)
	}
	select {
	case <-entered:
	case <-time.After(time.Second):
		close(release)
		t.Fatal("writer never entered")
	}
	if pacer.Drained() {
		close(release)
		t.Fatal("in-flight socket write counted as drained")
	}
	p.completeMediaFlow(42, 1)
	select {
	case <-events:
		close(release)
		t.Fatal("credit granted before writer drained")
	case <-time.After(20 * time.Millisecond):
	}
	close(release)
	select {
	case e := <-events:
		var c struct {
			Generation uint64
			Available  bool
		}
		json.Unmarshal([]byte(e.Value), &c)
		if e.Type != "mediaCapacity" || c.Generation != 42 || !c.Available {
			t.Fatal("wrong credit")
		}
	case <-time.After(time.Second):
		t.Fatal("drain did not restore credit")
	}
	p.maybeGrantMediaCapacity()
	p.completeMediaFlow(42, 1)
	select {
	case <-events:
		t.Fatal("duplicate grant for the same frame")
	case <-time.After(20 * time.Millisecond):
	}
}

func TestMediaFlowIgnoresOldGenerationCompletion(t *testing.T) {
	pacer := newPacer()
	defer pacer.Close()
	calls := 0
	p := &Connection{cfg: Config{Role: "host", MediaFlowControl: true}, ready: true, connected: true, authorized: true, mediaGeneration: 43, flowSequence: 2, pacer: pacer, output: func(wire.Frame) bool { calls++; return true }}
	p.completeMediaFlow(42, 1)
	if calls != 0 || p.flowCredit || p.flowNeedsGrant {
		t.Fatal("old completion granted current generation credit")
	}
	p.completeMediaFlow(43, 2)
	if calls != 1 || !p.flowCredit {
		t.Fatal("current frame did not regain credit")
	}
	p.maybeGrantMediaCapacity()
	if calls != 1 {
		t.Fatal("duplicate drain grant")
	}
}
