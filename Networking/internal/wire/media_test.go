package wire

import (
	"bytes"
	"testing"
	"time"
)

func TestChunkedMediaInterleavesControlAndCancelsGeneration(t *testing.T) {
	data := bytes.Repeat([]byte{0x53}, 100_000)
	var a MediaAssembler
	now := time.Now()
	for offset := 0; offset < len(data); offset += MediaChunkSize {
		chunk := MediaFragment(1, data, offset)
		complete, err := a.Push(chunk.Payload, now)
		if err != nil {
			t.Fatal(err)
		}
		if offset+MediaChunkSize >= len(data) && !bytes.Equal(complete, data) {
			t.Fatal("media chunks changed payload")
		}
		if _, err := Encode(Frame{Kind: Ping, Payload: []byte("ping")}); err != nil {
			t.Fatal(err)
		}
	}
	first := MediaFragment(2, data, 0)
	a.Push(first.Payload, now)
	a.Reset()
	if complete, err := a.Push(MediaFragment(2, data, MediaChunkSize).Payload, now); err != nil || complete != nil {
		t.Fatal("cancelled transfer continuation was not ignored")
	}
}
func TestMediaChunksRejectMalformedBoundsAndOrder(t *testing.T) {
	var a MediaAssembler
	data := bytes.Repeat([]byte{1}, 40_000)
	now := time.Now()
	if _, err := a.Push(make([]byte, 16), now); err == nil {
		t.Fatal("empty chunk accepted")
	}
	a.Push(MediaFragment(1, data, 0).Payload, now)
	if _, err := a.Push(MediaFragment(1, data, 2*MediaChunkSize).Payload, now); err == nil {
		t.Fatal("out of order local IPC accepted")
	}
}
