package video

import (
	"bytes"
	"encoding/binary"
	"github.com/pion/rtp"
	"math/rand"
	"sort"
	"testing"
	"time"
)

func rtpFixture(size int, key, timed bool, generation uint64) []byte {
	header := 25
	if timed {
		header = 49
	}
	b := make([]byte, 12+header+2+4+size)
	copy(b, "FRS1")
	binary.BigEndian.PutUint64(b[4:], generation)
	body := b[12:]
	copy(body, "FRV1")
	if timed {
		copy(body, "FRV2")
		binary.BigEndian.PutUint64(body[25:], 12)
		binary.BigEndian.PutUint64(body[33:], 123456)
		binary.BigEndian.PutUint64(body[41:], 234567)
	}
	binary.BigEndian.PutUint32(body[4:], 1280)
	binary.BigEndian.PutUint32(body[8:], 720)
	if key {
		body[12] = 1
	}
	binary.BigEndian.PutUint32(body[13:], 1)
	binary.BigEndian.PutUint32(body[17:], 1)
	binary.BigEndian.PutUint32(body[21:], uint32(4+size))
	body[header] = 0x67
	body[header+1] = 0x68
	binary.BigEndian.PutUint32(body[header+2:], uint32(size))
	for i := header + 6; i < len(body); i++ {
		body[i] = 0x55
	}
	if key {
		body[header+6] = 0x65
	} else {
		body[header+6] = 0x41
	}
	return b
}
func rtpPackets(t *testing.T, seq uint64, key, timed bool) []*rtp.Packet {
	t.Helper()
	p, err := Packetize(rtpFixture(12_000, key, timed, 42), seq, uint32(seq)*3000, 65530+uint16(seq)*20, 1)
	if err != nil {
		t.Fatal(err)
	}
	return p
}
func TestRTPAVCCRoundTripReorderWrapAndTiming(t *testing.T) {
	for _, timed := range []bool{false, true} {
		r := NewRTPReassembler()
		r.Reset(42)
		packets := rtpPackets(t, 1, true, timed)
		now := time.Now()
		var frames [][]byte
		for i := len(packets) - 1; i >= 0; i-- {
			out, _, err := r.Push(packets[i], 1, now)
			if err != nil {
				t.Fatal(err)
			}
			frames = append(frames, out...)
		}
		if len(frames) != 1 || !bytes.Equal(frames[0], rtpFixture(12_000, true, timed, 42)) {
			t.Fatal("H264/timing/generation roundtrip changed")
		}
		if r.PendingBytes() != 0 {
			t.Fatal("completed packets retained")
		}
	}
}
func TestRTPCompleteFrameReorderingDoesNotDemandIDR(t *testing.T) {
	r := NewRTPReassembler()
	r.Reset(42)
	now := time.Now()
	deliver := func(packets []*rtp.Packet) [][]byte {
		var result [][]byte
		for _, p := range packets {
			frames, lost, err := r.Push(p, 1, now)
			if err != nil || lost {
				t.Fatalf("ordinary reorder declared lost: %v", err)
			}
			result = append(result, frames...)
		}
		return result
	}
	if len(deliver(rtpPackets(t, 1, true, false))) != 1 {
		t.Fatal("IDR missing")
	}
	if len(deliver(rtpPackets(t, 3, false, false))) != 0 {
		t.Fatal("dependent future frame emitted")
	}
	if len(deliver(rtpPackets(t, 2, false, false))) != 2 {
		t.Fatal("reordered frames were not released in sequence")
	}
}
func TestRTPExpiryGenerationAndBoundedRecovery(t *testing.T) {
	r := NewRTPReassembler()
	r.Reset(42)
	now := time.Now()
	packets := rtpPackets(t, 1, true, true)
	r.Push(packets[0], 1, now)
	if _, lost, err := r.Tick(now.Add(RecoveryDeadline + time.Millisecond)); err != nil || !lost || r.PendingBytes() != 0 {
		t.Fatal("silent incomplete keyframe did not expire")
	}
	r.Reset(43)
	for _, p := range packets {
		frames, _, err := r.Push(p, 1, now)
		if err != nil || len(frames) != 0 {
			t.Fatal("old generation admitted")
		}
	}
	r.Reset(42)
	for seq := uint64(1); seq < 100; seq++ {
		p := rtpPackets(t, seq, true, false)
		r.Push(p[0], 1, now)
	}
	if len(r.frames) > MaxRTPFrames || r.PendingBytes() > 2*MaxRTPFrameBytes {
		t.Fatal("unbounded receiver")
	}
}
func TestRTPMalformedMetadataAndFragmentConflicts(t *testing.T) {
	r := NewRTPReassembler()
	r.Reset(42)
	p := rtpPackets(t, 1, true, false)
	now := time.Now()
	r.Push(p[0], 1, now)
	bad := p[0].Clone()
	bad.Payload[0] ^= 1
	if _, _, err := r.Push(bad, 1, now); err == nil {
		t.Fatal("conflicting duplicate accepted")
	}
	bad = p[1].Clone()
	m, _ := ParseMetadata(bad.GetExtension(1))
	m.Width = 9000
	bad.SetExtension(1, m.Marshal())
	if _, _, err := r.Push(bad, 1, now); err == nil {
		t.Fatal("invalid dimensions accepted")
	}
}
func TestDeterministicRTPImpairmentProfiles(t *testing.T) {
	// Packet-level impairment harness: finite jitter/reordering and one simulated
	// NACK repair. It validates reassembly bounds, not a measured real WAN SLA.
	for _, lossPercent := range []int{0, 1, 3, 5} {
		t.Run(string(rune('0'+lossPercent))+"percent", func(t *testing.T) {
			rng := rand.New(rand.NewSource(42))
			r := NewRTPReassembler()
			r.Reset(42)
			now := time.Now()
			packets, err := Packetize(rtpFixture(90_000, true, true, 42), 1, 10, 65000, 1)
			if err != nil {
				t.Fatal(err)
			}
			type delivery struct {
				at time.Duration
				p  *rtp.Packet
			}
			events := make([]delivery, 0, len(packets))
			for i, p := range packets {
				at := time.Duration(i)*time.Millisecond + time.Duration(rng.Intn(20))*time.Millisecond
				if rng.Intn(100) < lossPercent {
					at += 80 * time.Millisecond
				}
				events = append(events, delivery{at, p})
			}
			sort.SliceStable(events, func(i, j int) bool { return events[i].at < events[j].at })
			var result [][]byte
			for _, event := range events {
				frames, _, err := r.Push(event.p, 1, now.Add(event.at))
				if err != nil {
					t.Fatal(err)
				}
				result = append(result, frames...)
				if r.PendingBytes() > 2*MaxRTPFrameBytes {
					t.Fatal("receiver exceeded memory cap")
				}
			}
			if len(result) != 1 || !bytes.Equal(result[0], rtpFixture(90_000, true, true, 42)) {
				t.Fatal("repaired/reordered frame failed")
			}
		})
	}
}
