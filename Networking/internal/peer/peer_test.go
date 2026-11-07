package peer

import (
	"encoding/binary"
	"encoding/hex"
	"farreach.local/networking/internal/wire"
	"github.com/pion/webrtc/v4"
	"testing"
)

func TestNoTURNConfigOrSelectedPair(t *testing.T) {
	for _, u := range []string{"turn:example.com:3478", "turns:example.com:5349", "https://example.com", "stun:host:0", "stun:host:65536", "stun:host:3478?transport=tcp"} {
		if ValidateConfig(Config{ProtocolVersion: 2, Role: "host", STUNURLs: []string{u}}) == nil {
			t.Fatalf("accepted forbidden URL %s", u)
		}
	}
	if e := ValidateConfig(Config{ProtocolVersion: 2, Role: "host", STUNURLs: []string{"stun:stun.cloudflare.com:3478"}}); e != nil {
		t.Fatal(e)
	}
	host := &webrtc.ICECandidate{Typ: webrtc.ICECandidateTypeHost, Protocol: webrtc.ICEProtocolUDP}
	srflx := &webrtc.ICECandidate{Typ: webrtc.ICECandidateTypeSrflx, Protocol: webrtc.ICEProtocolUDP}
	relay := &webrtc.ICECandidate{Typ: webrtc.ICECandidateTypeRelay, Protocol: webrtc.ICEProtocolUDP}
	if !ValidPair(&webrtc.ICECandidatePair{Local: host, Remote: srflx}) {
		t.Fatal("direct pair rejected")
	}
	if ValidPair(&webrtc.ICECandidatePair{Local: host, Remote: relay}) || ValidPair(&webrtc.ICECandidatePair{Local: relay, Remote: host}) || ValidPair(nil) {
		t.Fatal("non-direct pair accepted")
	}
}

func TestConcurrentAdmissionDropCannotBeClearedByEarlierSend(t *testing.T) {
	// Model the real race: frame1 is in flight, frame2 is queued, frame3 cannot
	// enter the queue. Completing frame1 must not hide frame3's reference gap.
	p := &Connection{cfg: Config{Role: "host"}, authorized: true, mediaGeneration: 1, ready: true, output: func(wire.Frame) bool { return true }, videoQueue: make(chan queuedVideo, 1)}
	frame := make([]byte, 28)
	copy(frame, "FRV1")
	binary.BigEndian.PutUint32(frame[4:8], 64)
	binary.BigEndian.PutUint32(frame[8:12], 64)
	frame[12] = 1
	binary.BigEndian.PutUint32(frame[13:17], 1)
	binary.BigEndian.PutUint32(frame[17:21], 1)
	binary.BigEndian.PutUint32(frame[21:25], 1)
	wrapped := make([]byte, 12+len(frame))
	copy(wrapped, "FRS1")
	binary.BigEndian.PutUint64(wrapped[4:12], 1)
	copy(wrapped[12:], frame)
	frame = wrapped
	generation := p.dropGeneration
	if err := p.Send(wire.Frame{Kind: wire.Video, Payload: frame}); err != nil {
		t.Fatal(err)
	}
	if err := p.Send(wire.Frame{Kind: wire.Video, Payload: frame}); err != nil {
		t.Fatal(err)
	}
	p.completeVideo(generation)
	if !p.needSendKeyframe || p.dropGeneration == generation {
		t.Fatal("earlier completion hid a later dropped frame")
	}
	if p.sequence != 2 {
		t.Fatal("dropped admission did not consume a sequence number")
	}
	p.completeVideo(p.dropGeneration)
	if p.needSendKeyframe {
		t.Fatal("fresh recovery frame could not clear loss")
	}
}

func TestIPCCommandsCannotBeSentToPeer(t *testing.T) {
	connection := &Connection{}
	for _, kind := range []byte{wire.Configure, wire.ApplyAnswer, wire.Event, wire.MediaChunk, wire.MediaAuthorization, 0, 12, 255} {
		if err := connection.Send(wire.Frame{Kind: kind}); err == nil || err.Error() != "unknown application message" {
			t.Fatalf("local/unknown kind%d reached peer send admission", kind)
		}
	}
}

func TestConnectionBindingUsesDomainOrderedUTF8AndLengthPrefixes(t *testing.T) {
	// Golden vector independently calculated with Python hashlib and big-endian
	// byte lengths; Unicode distinguishes byte lengths from character counts.
	binding := connectionBinding("offer-☃", "answer-🌐")
	if hex.EncodeToString(binding[:]) != "4fbfbbf14c32801ea871373fa074f9e049a40bdd462facb54584252a50677de5" {
		t.Fatal("connection binding wire formula changed")
	}
	if connectionBinding("ab", "c") == connectionBinding("a", "bc") {
		t.Fatal("ambiguous description concatenation")
	}
	if connectionBinding("offer", "answer") == connectionBinding("answer", "offer") {
		t.Fatal("description roles not bound")
	}
}
