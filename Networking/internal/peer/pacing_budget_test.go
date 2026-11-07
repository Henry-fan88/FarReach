package peer

import (
	"testing"
	"time"
)

func TestPacingBudgetAccruesBoundedIdleCapacity(t *testing.T) {
	start := time.Now()
	budget := pacingBudget{last: start, tokens: 0}
	budget.wake(start.Add(100*time.Millisecond), 2_000_000)
	if budget.tokens != 4800 {
		t.Fatalf("idle time lost: got %.0f bytes, want capped 4800", budget.tokens)
	}
	budget.tokens -= 1500
	budget.tick(start.Add(102*time.Millisecond), 2_000_000)
	if budget.tokens != 3800 {
		t.Fatalf("wake interval double-counted or active refill wrong: %.0f", budget.tokens)
	}
	budget.tokens = 0
	budget.wake(start.Add(110*time.Millisecond), 500_000)
	if budget.tokens != 500 {
		t.Fatalf("partial idle refill incorrect: %.0f", budget.tokens)
	}
	budget.wake(start.Add(time.Hour), 12_000_000)
	if budget.tokens != maximumPacingBurstBytes {
		t.Fatal("long idle permits an oversized burst")
	}
	budget.tick(start.Add(time.Hour-time.Millisecond), 12_000_000)
	if budget.tokens != maximumPacingBurstBytes {
		t.Fatal("stale timer changed current token capacity")
	}
}
