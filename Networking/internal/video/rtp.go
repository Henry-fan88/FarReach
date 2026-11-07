package video

import (
	"bytes"
	"encoding/binary"
	"errors"
	"sort"
	"time"

	"github.com/pion/rtp"
	"github.com/pion/rtp/codecs"
)

const MetadataURI = "urn:farreach:rtp:frame-v2"
const RTPPayloadSize = 1050 // Leaves room for SRTP, TWCC and generation/timing extensions within 1200 bytes.
const MaxRTPFrameBytes = 4 * 1024 * 1024
const MaxRTPFrames = 12
const DeltaDeadline = 150 * time.Millisecond
const NormalKeyframeBudget = 500 * time.Millisecond
const RecoveryDeadline = 2 * time.Second

// Metadata is repeated on every packet. Independent control/media delivery can
// never relabel a delayed old frame with the current capture generation.
type Metadata struct {
	Generation, Sequence          uint64
	Width, Height                 uint32
	Keyframe, Timed               bool
	Index, Count                  uint16
	FrameID, CaptureNS, EncodedNS uint64
}

func (m Metadata) Marshal() []byte {
	b := make([]byte, 53)
	binary.BigEndian.PutUint64(b, m.Generation)
	binary.BigEndian.PutUint64(b[8:], m.Sequence)
	binary.BigEndian.PutUint32(b[16:], m.Width)
	binary.BigEndian.PutUint32(b[20:], m.Height)
	if m.Keyframe {
		b[24] |= 1
	}
	if m.Timed {
		b[24] |= 2
	}
	binary.BigEndian.PutUint16(b[25:], m.Index)
	binary.BigEndian.PutUint16(b[27:], m.Count)
	binary.BigEndian.PutUint64(b[29:], m.FrameID)
	binary.BigEndian.PutUint64(b[37:], m.CaptureNS)
	binary.BigEndian.PutUint64(b[45:], m.EncodedNS)
	return b
}
func ParseMetadata(b []byte) (Metadata, error) {
	if len(b) != 53 || b[24] > 3 {
		return Metadata{}, ErrChunk
	}
	m := Metadata{Generation: binary.BigEndian.Uint64(b), Sequence: binary.BigEndian.Uint64(b[8:]), Width: binary.BigEndian.Uint32(b[16:]), Height: binary.BigEndian.Uint32(b[20:]), Keyframe: b[24]&1 != 0, Timed: b[24]&2 != 0, Index: binary.BigEndian.Uint16(b[25:]), Count: binary.BigEndian.Uint16(b[27:]), FrameID: binary.BigEndian.Uint64(b[29:]), CaptureNS: binary.BigEndian.Uint64(b[37:]), EncodedNS: binary.BigEndian.Uint64(b[45:])}
	if m.Generation == 0 || m.Sequence == 0 || m.Width < 2 || m.Width > 8192 || m.Height < 2 || m.Height > 8192 || m.Count == 0 || m.Count > 16384 || m.Index >= m.Count {
		return Metadata{}, ErrChunk
	}
	return m, nil
}
func (m Metadata) Budget() time.Duration {
	if m.Keyframe {
		return NormalKeyframeBudget
	}
	return DeltaDeadline
}

func Packetize(data []byte, sequence uint64, timestamp uint32, firstSequence uint16, extensionID uint8) ([]*rtp.Packet, error) {
	if len(data) < 12 || !bytes.Equal(data[:4], []byte("FRS1")) || !ValidFrame(data) {
		return nil, ErrChunk
	}
	body := data[12:]
	h := 25
	timed := bytes.Equal(body[:4], []byte("FRV2"))
	if timed {
		h = 49
	}
	m := Metadata{Generation: binary.BigEndian.Uint64(data[4:12]), Sequence: sequence, Width: binary.BigEndian.Uint32(body[4:8]), Height: binary.BigEndian.Uint32(body[8:12]), Keyframe: body[12] == 1, Timed: timed}
	if timed {
		m.FrameID = binary.BigEndian.Uint64(body[25:])
		m.CaptureNS = binary.BigEndian.Uint64(body[33:])
		m.EncodedNS = binary.BigEndian.Uint64(body[41:])
	}
	s := int(binary.BigEndian.Uint32(body[13:17]))
	p := int(binary.BigEndian.Uint32(body[17:21]))
	nals := body[h+s+p:]
	annex := make([]byte, 0, len(body)+12)
	start := []byte{0, 0, 0, 1}
	annex = append(annex, start...)
	annex = append(annex, body[h:h+s]...)
	annex = append(annex, start...)
	annex = append(annex, body[h+s:h+s+p]...)
	for len(nals) > 0 {
		if len(nals) < 4 {
			return nil, ErrChunk
		}
		n := int(binary.BigEndian.Uint32(nals))
		nals = nals[4:]
		if n < 1 || n > len(nals) {
			return nil, ErrChunk
		}
		annex = append(annex, start...)
		annex = append(annex, nals[:n]...)
		nals = nals[n:]
	}
	payloader := codecs.H264Payloader{DisableStapA: true}
	payloads := payloader.Payload(RTPPayloadSize, annex)
	if len(payloads) < 1 || len(payloads) > 16384 || len(data) > MaxRTPFrameBytes {
		return nil, ErrChunk
	}
	m.Count = uint16(len(payloads))
	packets := make([]*rtp.Packet, 0, len(payloads))
	for i, payload := range payloads {
		m.Index = uint16(i)
		packet := &rtp.Packet{Header: rtp.Header{Version: 2, SequenceNumber: firstSequence + uint16(i), Timestamp: timestamp, Marker: i == len(payloads)-1}, Payload: payload}
		if err := packet.SetExtension(extensionID, m.Marshal()); err != nil {
			return nil, err
		}
		packets = append(packets, packet)
	}
	return packets, nil
}

type rtpPartial struct {
	meta      Metadata
	timestamp uint32
	first     uint16
	created   time.Time
	packets   map[uint16][]byte
	bytes     int
}
type RTPReassembler struct {
	repairRTT              time.Duration
	generation             uint64
	frames                 map[uint64]*rtpPartial
	last                   uint64
	haveLast, needKeyframe bool
	dropped                uint64
	repaired               uint64
}

func NewRTPReassembler() *RTPReassembler {
	return &RTPReassembler{frames: make(map[uint64]*rtpPartial), needKeyframe: true}
}
func (r *RTPReassembler) Reset(generation uint64) {
	rtt := r.repairRTT
	*r = *NewRTPReassembler()
	r.repairRTT = rtt
	r.generation = generation
}
func (r *RTPReassembler) SetRTT(rtt time.Duration) {
	r.repairRTT = max(0, min(rtt, 300*time.Millisecond))
}

// RepairDeadline uses a known incomplete access unit's first-arrival budget.
// A completely absent frame has no metadata yet, so its sequence gaps receive
// the bounded delta budget; the sender independently rejects expired repairs.
func (r *RTPReassembler) RepairDeadline(sequence uint16, now time.Time) time.Time {
	for _, frame := range r.frames {
		if uint16(sequence-frame.first) < frame.meta.Count {
			return frame.created.Add(r.budget(frame.meta))
		}
	}
	return now.Add(r.budget(Metadata{}))
}
func (r *RTPReassembler) budget(m Metadata) time.Duration {
	if m.Keyframe {
		return RecoveryDeadline
	}
	return max(DeltaDeadline, min(350*time.Millisecond, 2*r.repairRTT+100*time.Millisecond))
}
func (r *RTPReassembler) PendingBytes() int {
	n := 0
	for _, f := range r.frames {
		n += f.bytes
	}
	return n
}
func (r *RTPReassembler) Counters() (uint64, uint64) { return r.dropped, r.repaired }
func (r *RTPReassembler) MarkLost()                  { r.needKeyframe = true }
func (r *RTPReassembler) Push(packet *rtp.Packet, extensionID uint8, now time.Time) ([][]byte, bool, error) {
	m, err := ParseMetadata(packet.GetExtension(extensionID))
	if err != nil {
		return nil, false, err
	}
	if m.Generation != r.generation || (r.haveLast && m.Sequence <= r.last) {
		return nil, false, nil
	}
	if len(packet.Payload) > RTPPayloadSize || len(packet.Payload) == 0 || packet.Marker != (m.Index == m.Count-1) {
		return nil, false, ErrChunk
	}
	lost := r.expire(now)
	f := r.frames[m.Sequence]
	if f == nil {
		if len(r.frames) >= MaxRTPFrames {
			oldest := m.Sequence
			for seq := range r.frames {
				if seq < oldest {
					oldest = seq
				}
			}
			if oldest == m.Sequence {
				return nil, true, nil
			}
			delete(r.frames, oldest)
			r.needKeyframe = true
			r.dropped++
			lost = true
		}
		f = &rtpPartial{meta: m, timestamp: packet.Timestamp, first: packet.SequenceNumber - m.Index, created: now, packets: make(map[uint16][]byte)}
		r.frames[m.Sequence] = f
	}
	original := f.meta
	original.Index = m.Index
	if original != m || f.timestamp != packet.Timestamp || f.first+m.Index != packet.SequenceNumber {
		return nil, false, ErrChunk
	}
	if previous, ok := f.packets[m.Index]; ok {
		if !bytes.Equal(previous, packet.Payload) {
			return nil, false, ErrChunk
		}
		return nil, lost, nil
	}
	f.packets[m.Index] = bytes.Clone(packet.Payload)
	f.bytes += len(packet.Payload)
	if f.bytes > MaxRTPFrameBytes || r.PendingBytes() > MaxRTPFrameBytes*2 {
		delete(r.frames, m.Sequence)
		r.needKeyframe = true
		r.dropped++
		return nil, true, nil
	}
	frames, more, err := r.drain(now)
	return frames, lost || more, err
}
func (r *RTPReassembler) expire(now time.Time) bool {
	lost := false
	for seq, f := range r.frames {
		if now.Sub(f.created) > r.budget(f.meta) {
			delete(r.frames, seq)
			r.needKeyframe = true
			r.dropped++
			lost = true
		}
	}
	return lost
}
func (r *RTPReassembler) Tick(now time.Time) ([][]byte, bool, error) {
	lost := r.expire(now)
	frames, more, err := r.drain(now)
	return frames, lost || more, err
}
func (r *RTPReassembler) drain(now time.Time) ([][]byte, bool, error) {
	keys := make([]uint64, 0, len(r.frames))
	for seq := range r.frames {
		keys = append(keys, seq)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })
	var out [][]byte
	lost := false
	for _, seq := range keys {
		f := r.frames[seq]
		if f == nil {
			continue
		}
		complete := len(f.packets) == int(f.meta.Count)
		if !complete {
			continue
		}
		if r.haveLast && seq != r.last+1 && !f.meta.Keyframe {
			// Wait for an earlier frame/packet instead of treating ordinary reordering as loss.
			if now.Sub(f.created) < r.budget(f.meta) {
				break
			}
			r.needKeyframe = true
		}
		if r.needKeyframe && !f.meta.Keyframe {
			if now.Sub(f.created) < r.budget(f.meta) {
				continue
			}
			delete(r.frames, seq)
			r.dropped++
			lost = true
			continue
		}
		data, err := assembleRTP(f)
		if err != nil {
			delete(r.frames, seq)
			r.needKeyframe = true
			r.dropped++
			return out, true, err
		}
		r.last = seq
		r.haveLast = true
		r.needKeyframe = false
		out = append(out, data)
		for old := range r.frames {
			if old <= seq {
				delete(r.frames, old)
			}
		}
	}
	return out, lost, nil
}
func assembleRTP(f *rtpPartial) ([]byte, error) {
	depacketizer := codecs.H264Packet{IsAVC: true}
	var avcc []byte
	for i := uint16(0); i < f.meta.Count; i++ {
		b, err := depacketizer.Unmarshal(f.packets[i])
		if err != nil {
			return nil, err
		}
		avcc = append(avcc, b...)
		if len(avcc) > MaxRTPFrameBytes {
			return nil, ErrChunk
		}
	}
	var sps, pps, payload []byte
	for len(avcc) > 0 {
		if len(avcc) < 4 {
			return nil, ErrChunk
		}
		n := int(binary.BigEndian.Uint32(avcc))
		if n < 1 || n > len(avcc)-4 {
			return nil, ErrChunk
		}
		nal := avcc[4 : 4+n]
		switch nal[0] & 31 {
		case 7:
			sps = bytes.Clone(nal)
		case 8:
			pps = bytes.Clone(nal)
		default:
			payload = append(payload, avcc[:4+n]...)
		}
		avcc = avcc[4+n:]
	}
	if len(sps) == 0 || len(pps) == 0 || len(payload) == 0 {
		return nil, errors.New("RTP frame missing H264 parameters or access unit")
	}
	header := 25
	if f.meta.Timed {
		header = 49
	}
	b := make([]byte, 12+header+len(sps)+len(pps)+len(payload))
	copy(b, "FRS1")
	binary.BigEndian.PutUint64(b[4:], f.meta.Generation)
	body := b[12:]
	copy(body, "FRV1")
	if f.meta.Timed {
		copy(body, "FRV2")
		binary.BigEndian.PutUint64(body[25:], f.meta.FrameID)
		binary.BigEndian.PutUint64(body[33:], f.meta.CaptureNS)
		binary.BigEndian.PutUint64(body[41:], f.meta.EncodedNS)
	}
	binary.BigEndian.PutUint32(body[4:], f.meta.Width)
	binary.BigEndian.PutUint32(body[8:], f.meta.Height)
	if f.meta.Keyframe {
		body[12] = 1
	}
	binary.BigEndian.PutUint32(body[13:], uint32(len(sps)))
	binary.BigEndian.PutUint32(body[17:], uint32(len(pps)))
	binary.BigEndian.PutUint32(body[21:], uint32(len(payload)))
	copy(body[header:], sps)
	copy(body[header+len(sps):], pps)
	copy(body[header+len(sps)+len(pps):], payload)
	return b, nil
}
