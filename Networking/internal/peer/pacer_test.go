package peer

import (
	"farreach.local/networking/internal/video"
	"github.com/pion/interceptor"
	"github.com/pion/rtp"
	"sync/atomic"
	"testing"
	"time"
)

func TestPacerBoundsDeadlineAndGeneration(t *testing.T) {
	p := newPacer()
	defer p.Close()
	p.SetGeneration(7)
	p.SetTargetBitrate(200_000)
	var sent atomic.Int64
	p.AddStream(1, interceptor.RTPWriterFunc(func(_ *rtp.Header, b []byte, _ interceptor.Attributes) (int, error) { sent.Add(1); return len(b), nil }))
	m := video.Metadata{Generation: 7, Sequence: 1, Width: 1280, Height: 720, Keyframe: true, Count: 1}
	if p.BeginFrame(m, 1024*1024, 1) {
		t.Fatal("oversize IDR admitted below uplink budget")
	}
	if !p.BeginFrame(m, 1000, 1) {
		t.Fatal("small frame rejected")
	}
	h := rtp.Header{Version: 2, SSRC: 1}
	h.SetExtension(1, m.Marshal())
	if _, err := p.Write(&h, make([]byte, 500), nil); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(time.Second)
	for sent.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if sent.Load() != 1 {
		t.Fatal("pacer did not transmit")
	}
	p.SetGeneration(8)
	if _, err := p.Write(&h, make([]byte, 500), nil); err == nil {
		t.Fatal("old generation retransmitted")
	}
	if n, _ := p.Stats(); n != 0 {
		t.Fatal("generation change retained media")
	}
	m.Generation = 8
	m.Sequence = 2
	if !p.BeginFrame(m, 1000, 1) {
		t.Fatal("next generation rejected")
	}
	p.mu.Lock()
	p.deadlines[[2]uint64{8, 2}] = time.Now().Add(-time.Millisecond)
	p.mu.Unlock()
	h.SetExtension(1, m.Marshal())
	if _, err := p.Write(&h, make([]byte, 500), nil); err == nil {
		t.Fatal("expired repair admitted")
	}
}
func TestRTPGapCountersHandleWrapAndReordering(t *testing.T) {
	var tracker packetLossTracker
	tracker.Push(65534)
	lost, repaired := tracker.Push(1)
	if lost != 2 || repaired != 0 {
		t.Fatal("wrap loss wrong")
	}
	lost, repaired = tracker.Push(65535)
	if lost != 0 || repaired != 1 {
		t.Fatal("late recovery wrong")
	}
	lost, repaired = tracker.Push(65535)
	if lost != 0 || repaired != 0 {
		t.Fatal("duplicate counted as recovered")
	}
}
func TestRejectsOldProtocolVersion(t *testing.T) {
	if ValidateConfig(Config{Role: "host"}) == nil {
		t.Fatal("version1 helper accepted")
	}
}

type testResendCompletion struct {
	owners   atomic.Int64
	failed   atomic.Bool
	finished atomic.Bool
}

func (c *testResendCompletion) Retain() { c.owners.Add(1) }
func (c *testResendCompletion) Release(sent bool) {
	if !sent {
		c.failed.Store(true)
	}
	if c.owners.Add(-1) == 0 {
		c.finished.Store(true)
	}
}

func TestPacerRetainsRepairsUntilGenerationCancellation(t *testing.T) {
	p := &boundedPacer{rate: 2_000_000, streams: map[uint32]interceptor.RTPWriter{1: interceptor.RTPWriterFunc(func(_ *rtp.Header, b []byte, _ interceptor.Attributes) (int, error) { return len(b), nil })}, deadlines: make(map[[2]uint64]time.Time), done: make(chan struct{}), wake: make(chan struct{}, 1)}
	p.SetGeneration(1)
	m := video.Metadata{Generation: 1, Sequence: 1, Width: 1280, Height: 720, Keyframe: true, Count: 1}
	if !p.BeginFrame(m, 500, 1) {
		t.Fatal("admission")
	}
	h := rtp.Header{Version: 2, SSRC: 1}
	h.SetExtension(1, m.Marshal())
	completion := &testResendCompletion{}
	completion.owners.Store(1)
	if _, err := p.Write(&h, make([]byte, 100), interceptor.Attributes{"opaque-pion-key": completion}); err != nil {
		t.Fatal(err)
	}
	completion.Release(true)
	if completion.finished.Load() || completion.owners.Load() != 1 {
		t.Fatal("queued NACK was prematurely marked complete")
	}
	p.SetGeneration(2)
	if !completion.finished.Load() || !completion.failed.Load() || completion.owners.Load() != 0 {
		t.Fatal("cancelled repair was not released exactly once as unsent")
	}
	p.Close()
}

func TestPacerCloseAndGenerationDoNotWaitForBlockedWriter(t *testing.T) {
	p := newPacer()
	entered := make(chan struct{})
	release := make(chan struct{})
	p.AddStream(1, interceptor.RTPWriterFunc(func(_ *rtp.Header, b []byte, _ interceptor.Attributes) (int, error) {
		close(entered)
		<-release
		return len(b), nil
	}))
	p.SetGeneration(1)
	m := video.Metadata{Generation: 1, Sequence: 1, Width: 1280, Height: 720, Keyframe: true, Count: 1}
	p.BeginFrame(m, 500, 1)
	h := rtp.Header{Version: 2, SSRC: 1}
	h.SetExtension(1, m.Marshal())
	p.Write(&h, make([]byte, 100), nil)
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("writer was not called")
	}
	done := make(chan struct{})
	go func() { p.SetGeneration(2); p.Close(); close(done) }()
	select {
	case <-done:
	case <-time.After(200 * time.Millisecond):
		close(release)
		t.Fatal("blocked writer held authorization/shutdown mutex")
	}
	close(release)
}
