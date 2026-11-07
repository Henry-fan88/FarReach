// Package video fragments lossy H.264 frames and bounds their reassembly.
package video

import (
	"bytes"
	"encoding/binary"
	"errors"
	"time"
)

const ChunkSize = 16 * 1024
const HeaderSize = 24
const DataSize = ChunkSize - HeaderSize
const MaxFrame = 16 * 1024 * 1024
const MaxFrames = 2
const Timeout = 250 * time.Millisecond

// Recovery IDRs can be much larger than deltas; cap their completion budget
// separately so a useful picture can arrive over a constrained uplink.
const KeyframeTimeout = 2 * time.Second

var magic = []byte("FRC1")
var ErrChunk = errors.New("invalid video fragment")

type Frame struct {
	Sequence uint64
	Data     []byte
}
type partial struct {
	created                time.Time
	total, count, received int
	parts                  map[int][]byte
	kindKnown              bool
	keyframe               bool
}

// Until fragment zero arrives, the bounded reassembly may be an IDR.
func (p *partial) timeout() time.Duration {
	if !p.kindKnown || p.keyframe {
		return KeyframeTimeout
	}
	return Timeout
}

type Reassembler struct {
	frames       map[uint64]*partial
	last         uint64
	haveLast     bool
	needKeyframe bool
}

func NewReassembler() *Reassembler {
	return &Reassembler{frames: make(map[uint64]*partial), needKeyframe: true}
}

// frameBody identifies the legacy FRV1 frame or its FRS1 generation envelope.
// The generation is opaque to transport; the viewer enforces capture availability.
// Fragment zero contains the entire header, but need not contain the entire frame.
func frameBody(b []byte) ([]byte, bool) {
	if len(b) >= 4 && bytes.Equal(b[:4], []byte("FRS1")) {
		if len(b) < 12+25 {
			return nil, false
		}
		b = b[12:]
	}
	if len(b) >= 4 && bytes.Equal(b[:4], []byte("FRV2")) && len(b) < 49 {
		return nil, false
	}
	if len(b) < 25 || (!bytes.Equal(b[:4], []byte("FRV1")) && !bytes.Equal(b[:4], []byte("FRV2"))) {
		return nil, false
	}
	return b, true
}
func IsKeyframe(b []byte) bool {
	body, ok := frameBody(b)
	return ok && body[12] == 1
}
func ValidFrame(b []byte) bool {
	if len(b) > MaxFrame {
		return false
	}
	body, ok := frameBody(b)
	if !ok || body[12] > 1 {
		return false
	}
	w := binary.BigEndian.Uint32(body[4:8])
	h := binary.BigEndian.Uint32(body[8:12])
	s := binary.BigEndian.Uint32(body[13:17])
	p := binary.BigEndian.Uint32(body[17:21])
	n := binary.BigEndian.Uint32(body[21:25])
	header := uint64(25)
	if bytes.Equal(body[:4], []byte("FRV2")) {
		header = 49
	}
	return w >= 2 && w <= 8192 && h >= 2 && h <= 8192 && s > 0 && s <= 65536 && p > 0 && p <= 65536 && n > 0 && n <= 12*1024*1024 && header+uint64(s)+uint64(p)+uint64(n) == uint64(len(body))
}
func Fragments(sequence uint64, b []byte) ([][]byte, error) {
	if !ValidFrame(b) {
		return nil, ErrChunk
	}
	count := (len(b) + DataSize - 1) / DataSize
	out := make([][]byte, 0, count)
	for i, start := 0, 0; start < len(b); i, start = i+1, start+DataSize {
		end := min(start+DataSize, len(b))
		chunk := make([]byte, HeaderSize+end-start)
		copy(chunk, magic)
		binary.BigEndian.PutUint64(chunk[4:12], sequence)
		binary.BigEndian.PutUint32(chunk[12:16], uint32(len(b)))
		binary.BigEndian.PutUint16(chunk[16:18], uint16(i))
		binary.BigEndian.PutUint16(chunk[18:20], uint16(count))
		binary.BigEndian.PutUint32(chunk[20:24], uint32(start))
		copy(chunk[HeaderSize:], b[start:end])
		out = append(out, chunk)
	}
	return out, nil
}

// Push returns a complete admitted frame, and whether reference loss requires an IDR.
// Call from one goroutine or protect it externally. At most two16MiB frames retained.
func (r *Reassembler) Push(b []byte, now time.Time) (*Frame, bool, error) {
	dropped := r.Expire(now)
	if len(b) <= HeaderSize || len(b) > ChunkSize || !bytes.Equal(b[:4], magic) {
		return nil, true, ErrChunk
	}
	seq := binary.BigEndian.Uint64(b[4:12])
	total := int(binary.BigEndian.Uint32(b[12:16]))
	index := int(binary.BigEndian.Uint16(b[16:18]))
	count := int(binary.BigEndian.Uint16(b[18:20]))
	offset := int(binary.BigEndian.Uint32(b[20:24]))
	if total < 25 || total > MaxFrame || count != (total+DataSize-1)/DataSize || index >= count || offset != index*DataSize || len(b)-HeaderSize != min(DataSize, total-offset) {
		return nil, true, ErrChunk
	}
	if r.haveLast && seq <= r.last {
		return nil, dropped, nil
	}
	p, ok := r.frames[seq]
	if !ok {
		if len(r.frames) >= MaxFrames {
			var oldest uint64 = ^uint64(0)
			for id := range r.frames {
				if id < oldest {
					oldest = id
				}
			}
			delete(r.frames, oldest)
			r.needKeyframe = true
			dropped = true
		}
		p = &partial{created: now, total: total, count: count, parts: make(map[int][]byte)}
		r.frames[seq] = p
	} else if p.total != total || p.count != count {
		return nil, true, ErrChunk
	}
	if index == 0 {
		payload, ok := frameBody(b[HeaderSize:])
		if !ok || payload[12] > 1 {
			return nil, true, ErrChunk
		}
		p.kindKnown = true
		p.keyframe = payload[12] == 1
		// A late first fragment may reveal that an unknown frame is a delta,
		// whose short lifetime has already elapsed. Do not grant it an IDR budget.
		if now.Sub(p.created) > p.timeout() {
			delete(r.frames, seq)
			r.needKeyframe = true
			return nil, true, nil
		}
	}
	if previous, ok := p.parts[index]; ok {
		if !bytes.Equal(previous, b[HeaderSize:]) {
			return nil, true, ErrChunk
		}
		return nil, dropped, nil
	}
	p.parts[index] = bytes.Clone(b[HeaderSize:])
	p.received += len(b) - HeaderSize
	if len(p.parts) != p.count {
		return nil, dropped, nil
	}
	delete(r.frames, seq)
	if p.received != p.total {
		return nil, true, ErrChunk
	}
	data := make([]byte, p.total)
	for i := 0; i < p.count; i++ {
		copy(data[i*DataSize:], p.parts[i])
	}
	if !ValidFrame(data) {
		return nil, true, ErrChunk
	}
	if r.haveLast && seq != r.last+1 {
		r.needKeyframe = true
		dropped = true
	}
	if r.needKeyframe && !IsKeyframe(data) {
		return nil, true, nil
	}
	r.needKeyframe = false
	r.last = seq
	r.haveLast = true
	for id := range r.frames {
		if id <= seq {
			delete(r.frames, id)
		}
	}
	return &Frame{seq, data}, dropped, nil
}
func (r *Reassembler) Expire(now time.Time) bool {
	dropped := false
	for id, p := range r.frames {
		if now.Sub(p.created) > p.timeout() {
			delete(r.frames, id)
			r.needKeyframe = true
			dropped = true
		}
	}
	return dropped
}
func (r *Reassembler) MarkLost() { r.needKeyframe = true }
func (r *Reassembler) PendingBytes() int {
	n := 0
	for _, p := range r.frames {
		n += p.received
	}
	return n
}
