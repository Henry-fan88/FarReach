package peer

import (
	"testing"
	"time"
)

func TestRepairWaitsForRTTBeforeSecondAttempt(t *testing.T) {
	now := time.Now()
	var s repairScheduler
	s.Reset(42)
	deadline := func(uint16) time.Time { return now.Add(250 * time.Millisecond) }
	s.Observe(42, 100, 0, now, deadline)
	s.Observe(42, 102, 2, now, deadline)
	if len(s.Due(now.Add(9*time.Millisecond), 80*time.Millisecond)) != 0 {
		t.Fatal("reordering grace ignored")
	}
	first := s.Due(now.Add(20*time.Millisecond), 80*time.Millisecond)
	if len(first) != 1 || first[0] != 101 {
		t.Fatal("missing packet not requested")
	}
	// Simulate loss of the first repair. The second NACK must not be consumed
	// while Pion's responder is still suppressing repeats for one RTT.
	if len(s.Due(now.Add(40*time.Millisecond), 80*time.Millisecond)) != 0 {
		t.Fatal("second request spent while repair in flight")
	}
	second := s.Due(now.Add(110*time.Millisecond), 80*time.Millisecond)
	if len(second) != 1 || second[0] != 101 {
		t.Fatal("second repair not scheduled after RTT")
	}
	if len(s.Due(now.Add(200*time.Millisecond), 20*time.Millisecond)) != 0 {
		t.Fatal("more than two repair attempts")
	}
}
func TestRepairReorderWrapGenerationAndDeadline(t *testing.T) {
	now := time.Now()
	var s repairScheduler
	s.Reset(7)
	deadline := func(uint16) time.Time { return now.Add(210 * time.Millisecond) }
	s.Observe(7, 65534, 0, now, deadline)
	s.Observe(7, 1, 3, now, deadline)
	s.Observe(7, 65535, 1, now.Add(5*time.Millisecond), deadline)
	due := s.Due(now.Add(20*time.Millisecond), 80*time.Millisecond)
	if len(due) != 1 || due[0] != 0 {
		t.Fatal("reordered packet/wrap repair wrong")
	}
	s.Reset(8)
	s.Observe(7, 5, 0, now, deadline)
	if len(s.Due(now.Add(20*time.Millisecond), time.Millisecond)) != 0 {
		t.Fatal("old generation requested")
	}
	s.Observe(8, 10, 0, now, deadline)
	s.Observe(8, 12, 2, now, deadline)
	if len(s.Due(now.Add(150*time.Millisecond), 80*time.Millisecond)) != 0 {
		t.Fatal("repair cannot arrive before deadline")
	}
}
func TestRepairInitialMissingFragmentAndMemoryBound(t *testing.T) {
	now := time.Now()
	var s repairScheduler
	s.Reset(1)
	deadline := func(uint16) time.Time { return now.Add(500 * time.Millisecond) }
	s.Observe(1, 100, 2, now, deadline)
	due := s.Due(now.Add(20*time.Millisecond), 80*time.Millisecond)
	if len(due) != 2 || due[0] != 98 || due[1] != 99 {
		t.Fatal("first fragments cannot be repaired")
	}
	s.Observe(1, 20000, 0, now, deadline)
	if len(s.pending) > 2048 {
		t.Fatal("unbounded sequence gaps")
	}
	if len(s.Due(now.Add(time.Second), time.Millisecond)) != 0 || len(s.pending) != 0 {
		t.Fatal("expired gaps retained")
	}
}
