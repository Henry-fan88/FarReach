package wire

import (
	"bytes"
	"testing"
)

func TestBoundsAndRoundTrip(t *testing.T) {
	f := Frame{Kind: Input, Payload: []byte("input")}
	b, e := Encode(f)
	if e != nil {
		t.Fatal(e)
	}
	r, e := Read(bytes.NewReader(b))
	if e != nil || !bytes.Equal(r.Payload, f.Payload) || r.Kind != f.Kind {
		t.Fatal("roundtrip")
	}
	for i := 0; i < len(b); i++ {
		if _, e = Read(bytes.NewReader(b[:i])); e == nil {
			t.Fatal("accepted truncation")
		}
	}
	if _, e = Decode(append(b, 0)); e == nil {
		t.Fatal("accepted trailing bytes")
	}
	if _, e = Encode(Frame{Kind: Ping, Payload: make([]byte, 33)}); e == nil {
		t.Fatal("accepted oversize")
	}
	if _, e = Read(bytes.NewReader([]byte{240, 1, 0, 0, 0})); e == nil {
		t.Fatal("accepted large configuration")
	}
}

func TestPairingStandbyControlKindsAndLocalIPCSeparation(t *testing.T) {
	for _, kind := range []byte{Pairing, SessionControl, StreamState} {
		if !IsApplicationKind(kind) || !IsControlKind(kind) {
			t.Fatalf("new application kind%d rejected", kind)
		}
		payload := bytes.Repeat([]byte{0x5a}, 4096)
		encoded, err := Encode(Frame{Kind: kind, Payload: payload})
		if err != nil {
			t.Fatal(err)
		}
		decoded, err := Read(bytes.NewReader(encoded))
		if err != nil || decoded.Kind != kind || !bytes.Equal(decoded.Payload, payload) {
			t.Fatal("control message roundtrip failed")
		}
		if _, err = Encode(Frame{Kind: kind, Payload: append(payload, 0)}); err == nil {
			t.Fatal("oversized control message admitted")
		}
	}
	for _, kind := range []byte{0, 12, Configure, ApplyAnswer, Event, MediaChunk, MediaAuthorization, 255} {
		if IsApplicationKind(kind) || IsControlKind(kind) {
			t.Fatalf("local/unknown kind%d allowed remotely", kind)
		}
	}
	if !IsApplicationKind(Pointer) || IsControlKind(Pointer) {
		t.Fatal("pointer must use its independent channel")
	}
	if IsControlKind(Video) {
		t.Fatal("video allowed on reliable control channel")
	}
}
