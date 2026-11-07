package peer

import (
	"sort"
	"time"
)

type missingPacket struct {
	next, deadline time.Time
	attempts       uint8
}

// repairScheduler is protected by Connection.reassemblyMu. A second request
// waits for an actual round trip, rather than spending both allowed NACKs while
// the first repair is still in flight. The receiver never requests expired media.
type repairScheduler struct {
	generation  uint64
	initialized bool
	highest     uint16
	pending     map[uint16]missingPacket
}

func (s *repairScheduler) Reset(generation uint64) {
	*s = repairScheduler{generation: generation, pending: make(map[uint16]missingPacket)}
}
func (s *repairScheduler) Observe(generation uint64, seq, index uint16, now time.Time, deadline func(uint16) time.Time) {
	if generation == 0 || generation != s.generation {
		return
	}
	if !s.initialized {
		s.initialized = true
		s.highest = seq - index - 1
	}
	delta := int16(seq - s.highest)
	if delta > 0 {
		start := uint16(1)
		if delta > 2048 {
			s.pending = make(map[uint16]missingPacket)
			start = uint16(delta) - 2048
		}
		for step := start; step < uint16(delta); step++ {
			id := s.highest + step
			if len(s.pending) >= 2048 {
				break
			}
			if _, exists := s.pending[id]; !exists {
				s.pending[id] = missingPacket{next: now.Add(10 * time.Millisecond), deadline: deadline(id)}
			}
		}
		s.highest = seq
	}
	delete(s.pending, seq)
	for id, gap := range s.pending {
		if uint16(s.highest-id) > 2048 || !gap.deadline.After(now) {
			delete(s.pending, id)
		}
	}
}
func (s *repairScheduler) Due(now time.Time, rtt time.Duration) []uint16 {
	if rtt <= 0 {
		rtt = 100 * time.Millisecond
	}
	rtt = max(10*time.Millisecond, min(rtt, 300*time.Millisecond))
	ids := make([]uint16, 0, len(s.pending))
	for id := range s.pending {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return uint16(s.highest-ids[i]) > uint16(s.highest-ids[j]) })
	out := make([]uint16, 0, 32)
	for _, id := range ids {
		gap := s.pending[id]
		if gap.attempts >= 2 || !gap.deadline.After(now.Add(rtt)) {
			delete(s.pending, id)
			continue
		}
		if gap.next.After(now) {
			continue
		}
		if len(out) >= 256 {
			break
		}
		out = append(out, id)
		gap.attempts++
		gap.next = now.Add(rtt + 10*time.Millisecond)
		s.pending[id] = gap
	}
	return out
}
