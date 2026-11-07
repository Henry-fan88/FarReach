package main

import (
	"bytes"
	"encoding/binary"
	"io"
	"testing"
	"time"

	"farreach.local/networking/internal/video"
	"farreach.local/networking/internal/wire"
)

func outputTestFrame(t *testing.T, index, size int, generation uint64) wire.Frame {
	t.Helper()
	data := make([]byte, 43+size)
	copy(data, "FRS1")
	binary.BigEndian.PutUint64(data[4:], generation)
	body := data[12:]
	copy(body, "FRV1")
	binary.BigEndian.PutUint32(body[4:], 1280)
	binary.BigEndian.PutUint32(body[8:], 720)
	if index == 0 {
		body[12] = 1
	}
	binary.BigEndian.PutUint32(body[13:], 1)
	binary.BigEndian.PutUint32(body[17:], 1)
	binary.BigEndian.PutUint32(body[21:], uint32(4+size))
	body[25] = 0x67
	body[26] = 0x68
	binary.BigEndian.PutUint32(body[27:], uint32(size))
	for i := 31; i < len(body); i++ {
		body[i] = 0x55
	}
	body[31] = 0x41
	if index == 0 {
		body[31] = 0x65
	}
	body[len(body)-1] = byte(index)
	if !video.ValidFrame(data) {
		t.Fatal("invalid output fixture")
	}
	return wire.Frame{Kind: wire.Video, Payload: data}
}

func TestOutputPreservesRecoveredReferenceBurstWithPriorityControl(t *testing.T) {
	q := newOutputQueue()
	q.setMediaGeneration(42)
	expected := make([][]byte, 12)
	for i := 0; i < 12; i++ {
		f := outputTestFrame(t, i, 32*1024, 42)
		expected[i] = f.Payload
		if !q.send(f) {
			t.Fatalf("recovered reference frame%d dropped", i)
		}
	}
	if q.send(outputTestFrame(t, 12, 32*1024, 42)) {
		t.Fatal("thirteenth queued frame exceeded count bound")
	}
	if !q.send(wire.Frame{Kind: wire.Ping, Payload: []byte("before")}) {
		t.Fatal("control rejected by video burst")
	}
	reader, writer := io.Pipe()
	go q.writeLoop(writer)
	t.Cleanup(func() { reader.Close(); writer.Close(); q.close() })
	packets := make(chan wire.Frame)
	go func() {
		defer close(packets)
		for {
			f, err := wire.Read(reader)
			if err != nil {
				return
			}
			packets <- f
		}
	}()
	deadline := time.NewTimer(3 * time.Second)
	defer deadline.Stop()
	var assembler wire.MediaAssembler
	completed := 0
	before, during, injected := false, false, false
	for completed < 12 || !during {
		select {
		case f, ok := <-packets:
			if !ok {
				t.Fatal("output ended before burst completed")
			}
			if f.Kind == wire.Ping {
				switch string(f.Payload) {
				case "before":
					if injected {
						t.Fatal("initial control waited behind media")
					}
					before = true
				case "during":
					if completed > 1 {
						t.Fatal("concurrent control waited behind recovered frame burst")
					}
					during = true
				}
				continue
			}
			if f.Kind != wire.MediaChunk || !before {
				t.Fatal("unexpected output ordering")
			}
			if !injected {
				injected = true
				if !q.send(wire.Frame{Kind: wire.Ping, Payload: []byte("during")}) {
					t.Fatal("mid-transfer control rejected")
				}
			}
			frame, err := assembler.Push(f.Payload, time.Now())
			if err != nil {
				t.Fatal(err)
			}
			if frame != nil {
				if completed >= 12 || !bytes.Equal(frame, expected[completed]) {
					t.Fatal("reference frame order or content changed")
				}
				completed++
			}
		case <-deadline.C:
			t.Fatalf("recovered burst stalled after%d frames", completed)
		}
	}
	q.videoMu.Lock()
	remaining := q.videoBytes
	q.videoMu.Unlock()
	if remaining != 0 {
		t.Fatalf("dequeued media retained byte budget: %d", remaining)
	}
}

func TestOutputVideoByteBoundAndGenerationFlush(t *testing.T) {
	q := newOutputQueue()
	q.setMediaGeneration(7)
	large := outputTestFrame(t, 0, 2*1024*1024-43, 7)
	for i := 0; i < 4; i++ {
		if !q.send(large) {
			t.Fatal("8MiB queue rejected within bound")
		}
	}
	if q.videoBytes != maximumOutputVideoBytes || q.send(large) {
		t.Fatal("video aggregate byte bound not enforced")
	}
	q.setMediaGeneration(8)
	if q.videoBytes != 0 || len(q.video) != 0 {
		t.Fatal("generation change retained queued references")
	}
	if !q.send(large) || len(q.video) != 0 {
		t.Fatal("stale generation should be ignored without triggering reference loss")
	}
	if !q.send(outputTestFrame(t, 0, 1024, 8)) {
		t.Fatal("fresh generation cannot enqueue")
	}
	q.setMediaGeneration(0)
	if q.videoBytes != 0 || len(q.video) != 0 {
		t.Fatal("authorization revocation retained media")
	}
}
