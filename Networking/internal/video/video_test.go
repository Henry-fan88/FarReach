package video

import (
	"bytes"
	"encoding/binary"
	"testing"
	"time"
)

func fixture(n int, key bool) []byte {
	b := make([]byte, 27+n)
	copy(b, "FRV1")
	binary.BigEndian.PutUint32(b[4:8], 1920)
	binary.BigEndian.PutUint32(b[8:12], 1080)
	if key {
		b[12] = 1
	}
	binary.BigEndian.PutUint32(b[13:17], 1)
	binary.BigEndian.PutUint32(b[17:21], 1)
	binary.BigEndian.PutUint32(b[21:25], uint32(n))
	b[25] = 0x67
	b[26] = 0x68
	for i := 27; i < len(b); i++ {
		b[i] = byte(i)
	}
	return b
}
func feed(t *testing.T, r *Reassembler, id uint64, b []byte, now time.Time) *Frame {
	t.Helper()
	chunks, e := Fragments(id, b)
	if e != nil {
		t.Fatal(e)
	}
	var result *Frame
	for i := len(chunks) - 1; i >= 0; i-- {
		f, _, e := r.Push(chunks[i], now)
		if e != nil {
			t.Fatal(e)
		}
		if f != nil {
			result = f
		}
	}
	return result
}
func TestReorderedMegabyteFragmentRoundTrip(t *testing.T) {
	r := NewReassembler()
	b := fixture(1024*1024, true)
	f := feed(t, r, 1, b, time.Now())
	if f == nil || !bytes.Equal(f.Data, b) {
		t.Fatal("fragment mismatch")
	}
	if r.PendingBytes() != 0 {
		t.Fatal("retained completed frame")
	}
}
func TestGapSuppressesDeltasUntilIDR(t *testing.T) {
	r := NewReassembler()
	now := time.Now()
	if feed(t, r, 1, fixture(100, true), now) == nil {
		t.Fatal("initial IDR lost")
	}
	if feed(t, r, 3, fixture(100, false), now) != nil {
		t.Fatal("delta survived sequence gap")
	}
	if feed(t, r, 4, fixture(100, false), now) != nil {
		t.Fatal("dependent delta survived")
	}
	if feed(t, r, 5, fixture(100, true), now) == nil {
		t.Fatal("IDR did not recover")
	}
	if feed(t, r, 6, fixture(100, false), now) == nil {
		t.Fatal("next delta lost")
	}
}
func TestReassemblyBoundsExpiryAndMalformedChunks(t *testing.T) {
	r := NewReassembler()
	now := time.Now()
	b := fixture(12*1024*1024, true)
	chunks, _ := Fragments(1, b)
	if _, _, e := r.Push(chunks[0], now); e != nil {
		t.Fatal(e)
	}
	for id := uint64(2); id < 10; id++ {
		chunk := bytes.Clone(chunks[0])
		binary.BigEndian.PutUint64(chunk[4:12], id)
		r.Push(chunk, now)
	}
	if len(r.frames) > 2 || r.PendingBytes() > 32*1024*1024 {
		t.Fatal("unbounded reassembly")
	}
	if !r.Expire(now.Add(KeyframeTimeout+time.Millisecond)) || r.PendingBytes() != 0 {
		t.Fatal("expiry failed")
	}
	for _, bad := range [][]byte{nil, make([]byte, 30), append(bytes.Clone(chunks[0]), 1)} {
		if _, _, e := r.Push(bad, now); e == nil {
			t.Fatal("malformed chunk accepted")
		}
	}
	bad := bytes.Clone(chunks[0])
	binary.BigEndian.PutUint32(bad[12:16], MaxFrame+1)
	if _, _, e := r.Push(bad, now); e == nil {
		t.Fatal("oversized fragment admitted")
	}
}

func TestKeyframeRecoveryBudgetAndShortDeltaExpiry(t *testing.T) {
	now := time.Now()
	// A1MiB IDR arriving over1s remains useful, even if fragment zero is delayed.
	r := NewReassembler()
	original := fixture(1024*1024, true)
	chunks, err := Fragments(1, original)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err = r.Push(chunks[1], now); err != nil {
		t.Fatal(err)
	}
	if r.Expire(now.Add(500 * time.Millisecond)) {
		t.Fatal("unknown frame expired before IDR classification")
	}
	var complete *Frame
	for i, chunk := range chunks {
		if i == 1 {
			continue
		}
		frame, _, err := r.Push(chunk, now.Add(time.Second))
		if err != nil {
			t.Fatal(err)
		}
		if frame != nil {
			complete = frame
		}
	}
	if complete == nil || !bytes.Equal(complete.Data, original) {
		t.Fatal("slow IDR did not reassemble")
	}

	// A known delta retains the original250ms low-delay deadline.
	delta, _ := Fragments(2, fixture(100000, false))
	if _, _, err = r.Push(delta[0], now); err != nil {
		t.Fatal(err)
	}
	if !r.Expire(now.Add(Timeout+time.Millisecond)) || r.PendingBytes() != 0 {
		t.Fatal("known delta exceeded short deadline")
	}

	// Classifying an unknown old frame as delta immediately expires it.
	r = NewReassembler()
	r.Push(delta[1], now)
	if frame, dropped, err := r.Push(delta[0], now.Add(500*time.Millisecond)); err != nil || frame != nil || !dropped || r.PendingBytes() != 0 {
		t.Fatal("late delta classification was given IDR lifetime")
	}

	// Known IDRs and unknown first fragments both expire after the bounded2s.
	for _, first := range []int{0, 1} {
		r = NewReassembler()
		r.Push(chunks[first], now)
		if r.Expire(now.Add(time.Second)) {
			t.Fatal("IDR expired too early")
		}
		if !r.Expire(now.Add(KeyframeTimeout+time.Millisecond)) || r.PendingBytes() != 0 {
			t.Fatal("IDR/unknown frame outlived bound")
		}
	}
}

func wrapped(generation uint64, frame []byte) []byte {
	b := make([]byte, 12+len(frame))
	copy(b, "FRS1")
	binary.BigEndian.PutUint64(b[4:12], generation)
	copy(b[12:], frame)
	return b
}
func TestGenerationEnvelopeRoundTripAndValidation(t *testing.T) {
	original := wrapped(0x0102030405060708, fixture(1024*1024, true))
	if !ValidFrame(original) || !IsKeyframe(original) {
		t.Fatal("valid wrapped IDR rejected")
	}
	if IsKeyframe(wrapped(9, fixture(100, false))) {
		t.Fatal("wrapped delta classified as IDR")
	}
	r := NewReassembler()
	result := feed(t, r, 1, original, time.Now())
	if result == nil || !bytes.Equal(result.Data, original) || binary.BigEndian.Uint64(result.Data[4:12]) != 0x0102030405060708 {
		t.Fatal("generation envelope changed during fragmentation")
	}
	for _, invalid := range [][]byte{[]byte("FRS1"), original[:12], original[:36], wrapped(1, []byte("FRV1")), wrapped(1, original), append(bytes.Clone(original), 0)} {
		if ValidFrame(invalid) {
			t.Fatal("invalid wrapped frame admitted")
		}
	}
	bad := bytes.Clone(original)
	bad[24] = 2
	if ValidFrame(bad) {
		t.Fatal("invalid inner keyframe flag admitted")
	}
	bad = bytes.Clone(original)
	binary.BigEndian.PutUint32(bad[12+21:12+25], 12*1024*1024+1)
	if ValidFrame(bad) {
		t.Fatal("oversized wrapped payload admitted")
	}
	if ValidFrame(append(bytes.Clone(original), make([]byte, MaxFrame)...)) {
		t.Fatal("wrapper bypassed outer frame limit")
	}
}
func TestWrappedKeyframeClassificationAndExpiry(t *testing.T) {
	now := time.Now()
	for _, key := range []bool{false, true} {
		data := wrapped(42, fixture(100000, key))
		chunks, err := Fragments(1, data)
		if err != nil {
			t.Fatal(err)
		}
		r := NewReassembler()
		if _, _, err = r.Push(chunks[0], now); err != nil {
			t.Fatal(err)
		}
		if key {
			if r.Expire(now.Add(500 * time.Millisecond)) {
				t.Fatal("wrapped IDR used delta expiry")
			}
			var complete *Frame
			for _, chunk := range chunks[1:] {
				frame, _, err := r.Push(chunk, now.Add(time.Second))
				if err != nil {
					t.Fatal(err)
				}
				if frame != nil {
					complete = frame
				}
			}
			if complete == nil || !bytes.Equal(complete.Data, data) {
				t.Fatal("slow wrapped IDR did not reassemble")
			}
		} else if !r.Expire(now.Add(Timeout+time.Millisecond)) || r.PendingBytes() != 0 {
			t.Fatal("wrapped delta used IDR expiry")
		}
	}
	// Missing fragment zero has the bounded unknown/IDR deadline, then releases memory.
	data := wrapped(43, fixture(100000, true))
	chunks, _ := Fragments(2, data)
	r := NewReassembler()
	r.Push(chunks[1], now)
	if !r.Expire(now.Add(KeyframeTimeout+time.Millisecond)) || r.PendingBytes() != 0 {
		t.Fatal("wrapped unknown frame exceeded bound")
	}
}
