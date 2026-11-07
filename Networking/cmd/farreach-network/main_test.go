package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"farreach.local/networking/internal/invitation"
	"farreach.local/networking/internal/peer"
	"farreach.local/networking/internal/wire"
)

func TestMain(m *testing.M) {
	if os.Getenv("FARREACH_HELPER_TEST_PROCESS") == "1" {
		os.Exit(run())
	}
	os.Exit(m.Run())
}

type helperProcess struct {
	command *exec.Cmd
	stdin   io.WriteCloser
	frames  chan wire.Frame
	errors  chan error
	path    peer.Path
	binding []byte
}

func launch(t *testing.T) *helperProcess {
	t.Helper()
	exe, e := os.Executable()
	if e != nil {
		t.Fatal(e)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	t.Cleanup(cancel)
	cmd := exec.CommandContext(ctx, exe)
	cmd.Env = append(os.Environ(), "FARREACH_HELPER_TEST_PROCESS=1")
	stdin, e := cmd.StdinPipe()
	if e != nil {
		t.Fatal(e)
	}
	stdout, e := cmd.StdoutPipe()
	if e != nil {
		t.Fatal(e)
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if e = cmd.Start(); e != nil {
		t.Fatal(e)
	}
	p := &helperProcess{command: cmd, stdin: stdin, frames: make(chan wire.Frame, 64), errors: make(chan error, 1)}
	go func() {
		var assembler wire.MediaAssembler
		for {
			f, e := wire.Read(stdout)
			if e != nil {
				p.errors <- e
				return
			}
			if f.Kind == wire.MediaChunk {
				data, err := assembler.Push(f.Payload, time.Now())
				if err != nil {
					p.errors <- err
					return
				}
				if data == nil {
					continue
				}
				f = wire.Frame{Kind: wire.Video, Payload: data}
			}
			p.frames <- f
		}
	}()
	t.Cleanup(func() {
		stdin.Close()
		cmd.Process.Kill()
		cmd.Wait()
		if stderr.Len() > 0 {
			if bytes.Contains(stderr.Bytes(), []byte("WARNING: DATA RACE")) {
				t.Errorf("helper data race: %s", stderr.String())
			} else {
				t.Logf("helper diagnostic bytes: %d", stderr.Len())
			}
		}
	})
	return p
}
func (p *helperProcess) send(t *testing.T, f wire.Frame) {
	t.Helper()
	if e := wire.Write(p.stdin, f); e != nil {
		t.Fatal(e)
	}
}
func (p *helperProcess) config(t *testing.T, c peer.Config) {
	b, _ := json.Marshal(c)
	p.send(t, wire.Frame{Kind: wire.Configure, Payload: b})
}
func (p *helperProcess) next(t *testing.T, timeout time.Duration) wire.Frame {
	t.Helper()
	select {
	case f := <-p.frames:
		return f
	case e := <-p.errors:
		t.Fatalf("helper closed: %v", e)
	case <-time.After(timeout):
		t.Fatal("helper output timeout")
	}
	return wire.Frame{}
}
func (p *helperProcess) event(t *testing.T, want string) string {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		f := p.next(t, time.Until(deadline))
		if f.Kind != wire.Event {
			t.Fatalf("unexpected kind %d waiting for %s", f.Kind, want)
		}
		var e peer.Event
		if json.Unmarshal(f.Payload, &e) != nil {
			t.Fatal("invalid event")
		}
		t.Logf("helper event: %s", e.Type)
		if e.Type == "path" {
			if json.Unmarshal([]byte(e.Value), &p.path) != nil {
				t.Fatal("invalid path")
			}
		}
		if e.Type == "binding" {
			decoded, err := base64.RawURLEncoding.DecodeString(e.Value)
			if err != nil || len(decoded) != 32 || bytes.Equal(decoded, make([]byte, 32)) || base64.RawURLEncoding.EncodeToString(decoded) != e.Value {
				t.Fatal("invalid connection binding")
			}
			if p.binding != nil {
				t.Fatal("duplicate connection binding")
			}
			p.binding = decoded
		}
		if e.Type == "ready" && len(p.binding) != 32 {
			t.Fatal("helper became ready without connection binding")
		}
		if e.Type == want {
			return e.Value
		}
		if e.Type == "error" && want != "closed" {
			t.Fatalf("helper failed: %s", e.Value)
		}
	}
}
func (p *helperProcess) application(t *testing.T, kind byte) wire.Frame {
	t.Helper()
	for {
		f := p.next(t, 10*time.Second)
		if f.Kind == kind {
			return f
		}
		if f.Kind == wire.RequestKeyframe {
			continue
		}
		if f.Kind == wire.Event {
			var e peer.Event
			json.Unmarshal(f.Payload, &e)
			if e.Type == "error" {
				t.Fatalf("helper event %s: %s", e.Type, e.Value)
			}
			continue
		}
		t.Fatalf("unexpected application message %d", f.Kind)
	}
}
func bigFrame() []byte {
	n := 32 * 1024
	b := make([]byte, 27+n)
	copy(b, "FRV1")
	binary.BigEndian.PutUint32(b[4:8], 1920)
	binary.BigEndian.PutUint32(b[8:12], 1080)
	b[12] = 1
	binary.BigEndian.PutUint32(b[13:17], 1)
	binary.BigEndian.PutUint32(b[17:21], 1)
	binary.BigEndian.PutUint32(b[21:25], uint32(n))
	b[25] = 0x67
	b[26] = 0x68
	binary.BigEndian.PutUint32(b[27:31], uint32(n-4))
	b[31] = 0x65
	for i := 32; i < len(b); i++ {
		b[i] = 0x55
	}
	return b
}
func TestTwoHelperProcessesDirectVideoControlAndLifecycle(t *testing.T) {
	host := launch(t)
	viewer := launch(t)
	host.config(t, peer.Config{ProtocolVersion: 2, Role: "host", STUNURLs: []string{}})
	offer := host.event(t, "invitation")
	viewer.config(t, peer.Config{ProtocolVersion: 2, Role: "viewer", Invitation: offer, STUNURLs: []string{}})
	answer := viewer.event(t, "response")
	// Human copy/paste must survive well beyond the former15s ICE failure timeout.
	time.Sleep(31 * time.Second)
	command, _ := json.Marshal(map[string]string{"response": answer})
	host.send(t, wire.Frame{Kind: wire.ApplyAnswer, Payload: command})
	host.event(t, "ready")
	viewer.event(t, "ready")
	if !bytes.Equal(host.binding, viewer.binding) {
		t.Fatal("peers derived different channel bindings")
	}
	for _, p := range []*helperProcess{host, viewer} {
		if p.path.LocalType == "relay" || p.path.RemoteType == "relay" || p.path.Protocol != "udp" {
			t.Fatalf("non-direct selected path: %+v", p.path)
		}
	}
	hello := []byte(`{"protocolVersion":1,"name":"Fixture"}`)
	host.send(t, wire.Frame{Kind: wire.Hello, Payload: hello})
	if got := viewer.application(t, wire.Hello); !bytes.Equal(got.Payload, hello) {
		t.Fatal("hello mismatch")
	}
	// Pairing/session state is opaque to the helper, but allowed only on the
	// authenticated reliable control channel. Standby does not require video.
	for _, kind := range []byte{wire.Pairing, wire.SessionControl, wire.StreamState} {
		payload := []byte(`{"state":"standby","generation":42}`)
		host.send(t, wire.Frame{Kind: kind, Payload: payload})
		if got := viewer.application(t, kind); !bytes.Equal(got.Payload, payload) {
			t.Fatal("standby control changed")
		}
		viewer.send(t, wire.Frame{Kind: kind, Payload: payload})
		if got := host.application(t, kind); !bytes.Equal(got.Payload, payload) {
			t.Fatal("reverse standby control changed")
		}
	}
	// Exceed the8s disconnected threshold with no video, using the same1s
	// application heartbeat as FarReach. The original channel must stay usable.
	for range 10 {
		payload := []byte("standby")
		viewer.send(t, wire.Frame{Kind: wire.Ping, Payload: payload})
		host.application(t, wire.Ping)
		host.send(t, wire.Frame{Kind: wire.Pong, Payload: payload})
		viewer.application(t, wire.Pong)
		time.Sleep(time.Second)
	}
	for _, p := range []*helperProcess{host, viewer} {
		p.send(t, wire.Frame{Kind: wire.MediaAuthorization, Payload: []byte(`{"authorized":true,"generation":42}`)})
	}
	time.Sleep(50 * time.Millisecond)
	original := bigFrame()
	video := make([]byte, 12+len(original))
	copy(video, "FRS1")
	binary.BigEndian.PutUint64(video[4:12], 42)
	copy(video[12:], original)
	host.send(t, wire.Frame{Kind: wire.Video, Payload: video})
	if got := viewer.application(t, wire.Video); !bytes.Equal(got.Payload, video) {
		t.Fatal("RTP video mismatch")
	}
	wrapped := make([]byte, 12+len(original))
	copy(wrapped, "FRS1")
	binary.BigEndian.PutUint64(wrapped[4:12], 42)
	copy(wrapped[12:], original)
	host.send(t, wire.Frame{Kind: wire.Video, Payload: wrapped})
	if got := viewer.application(t, wire.Video); !bytes.Equal(got.Payload, wrapped) {
		t.Fatal("RTP generation mismatch")
	}
	input := []byte(`{"kind":"move","x":0.25,"y":0.75}`)
	viewer.send(t, wire.Frame{Kind: wire.Input, Payload: input})
	if got := host.application(t, wire.Input); !bytes.Equal(got.Payload, input) {
		t.Fatal("input mismatch")
	}
	ping := []byte("ping")
	viewer.send(t, wire.Frame{Kind: wire.Ping, Payload: ping})
	host.application(t, wire.Ping)
	host.send(t, wire.Frame{Kind: wire.Pong, Payload: ping})
	viewer.application(t, wire.Pong)
	viewer.stdin.Close()
	viewer.event(t, "closed")
	host.event(t, "closed")
	// Fresh ephemeral DTLS descriptions must not reuse the identity-proof context.
	nextHost, nextViewer := launch(t), launch(t)
	nextHost.config(t, peer.Config{ProtocolVersion: 2, Role: "host", STUNURLs: []string{}})
	nextOffer := nextHost.event(t, "invitation")
	nextViewer.config(t, peer.Config{ProtocolVersion: 2, Role: "viewer", Invitation: nextOffer, STUNURLs: []string{}})
	nextAnswer := nextViewer.event(t, "response")
	nextCommand, _ := json.Marshal(map[string]string{"response": nextAnswer})
	nextHost.send(t, wire.Frame{Kind: wire.ApplyAnswer, Payload: nextCommand})
	nextHost.event(t, "ready")
	nextViewer.event(t, "ready")
	if !bytes.Equal(nextHost.binding, nextViewer.binding) {
		t.Fatal("fresh peers disagree on binding")
	}
	if bytes.Equal(nextHost.binding, host.binding) {
		t.Fatal("fresh session reused the old channel binding")
	}
	nextViewer.stdin.Close()
	nextViewer.event(t, "closed")
	nextHost.event(t, "closed")
}
func TestHelperRejectsWrongAnswerAuthentication(t *testing.T) {
	host := launch(t)
	host.config(t, peer.Config{ProtocolVersion: 2, Role: "host"})
	s := host.event(t, "invitation")
	offer, e := invitation.ParseOffer(s, time.Now())
	if e != nil {
		t.Fatal(e)
	}
	answer, e := invitation.NewAnswer(offer, offer.SDP, time.Now())
	if e != nil {
		t.Fatal(e)
	}
	answer.MAC = strings.Repeat("A", 43)
	response, _ := answer.String()
	command, _ := json.Marshal(map[string]string{"response": response})
	host.send(t, wire.Frame{Kind: wire.ApplyAnswer, Payload: command})
	err := host.event(t, "error")
	if !strings.Contains(err, "authentication") {
		t.Fatal("wrong authentication result")
	}
}
