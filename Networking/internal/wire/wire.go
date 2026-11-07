// Package wire implements FarReach's bounded binary IPC and control framing.
package wire

import (
	"encoding/binary"
	"errors"
	"io"
)

const (
	Hello              byte = 1
	Video              byte = 2
	Input              byte = 3
	Ping               byte = 4
	Pong               byte = 5
	Disconnect         byte = 6
	RequestKeyframe    byte = 7
	Pairing            byte = 8
	SessionControl     byte = 9
	StreamState        byte = 10
	Pointer            byte = 11
	Configure          byte = 240
	ApplyAnswer        byte = 241
	Event              byte = 242
	MediaChunk         byte = 243
	MediaAuthorization byte = 244
	MaxVideo                = 16 * 1024 * 1024
	MaxConfiguration        = 256 * 1024
)

type Frame struct {
	Kind    byte
	Payload []byte
}

// Application kinds may cross the authenticated peer channel. IPC commands and
// helper events are local-only, even though they use the same envelope format.
func IsApplicationKind(kind byte) bool { return kind >= Hello && kind <= Pointer }
func IsControlKind(kind byte) bool {
	return IsApplicationKind(kind) && kind != Video && kind != Pointer
}

func Limit(kind byte) (int, bool) {
	switch kind {
	case Video:
		return MaxVideo, true
	case Hello, Input, Pairing, SessionControl, StreamState, Pointer, MediaAuthorization:
		return 4096, true
	case Ping, Pong, RequestKeyframe:
		return 32, true
	case Disconnect:
		return 512, true
	case MediaChunk:
		return 16 + 16384, true
	case Configure, ApplyAnswer, Event:
		return MaxConfiguration, true
	default:
		return 0, false
	}
}
func Read(r io.Reader) (Frame, error) {
	var header [5]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return Frame{}, err
	}
	limit, ok := Limit(header[0])
	n := binary.BigEndian.Uint32(header[1:])
	if !ok || uint64(n) > uint64(limit) {
		return Frame{}, errors.New("invalid message kind or size")
	}
	f := Frame{Kind: header[0], Payload: make([]byte, int(n))}
	_, err := io.ReadFull(r, f.Payload)
	return f, err
}
func Write(w io.Writer, f Frame) error {
	limit, ok := Limit(f.Kind)
	if !ok || len(f.Payload) > limit {
		return errors.New("invalid message kind or size")
	}
	var header [5]byte
	header[0] = f.Kind
	binary.BigEndian.PutUint32(header[1:], uint32(len(f.Payload)))
	if err := writeAll(w, header[:]); err != nil {
		return err
	}
	return writeAll(w, f.Payload)
}
func Encode(f Frame) ([]byte, error) {
	limit, ok := Limit(f.Kind)
	if !ok || len(f.Payload) > limit {
		return nil, errors.New("invalid message kind or size")
	}
	b := make([]byte, 5+len(f.Payload))
	b[0] = f.Kind
	binary.BigEndian.PutUint32(b[1:5], uint32(len(f.Payload)))
	copy(b[5:], f.Payload)
	return b, nil
}
func Decode(b []byte) (Frame, error) {
	if len(b) < 5 {
		return Frame{}, errors.New("truncated control message")
	}
	limit, ok := Limit(b[0])
	n := int(binary.BigEndian.Uint32(b[1:5]))
	if !ok || n > limit || n != len(b)-5 {
		return Frame{}, errors.New("invalid control message")
	}
	return Frame{Kind: b[0], Payload: b[5:]}, nil
}
func writeAll(w io.Writer, b []byte) error {
	for len(b) > 0 {
		n, err := w.Write(b)
		if err != nil {
			return err
		}
		if n <= 0 {
			return io.ErrShortWrite
		}
		b = b[n:]
	}
	return nil
}
