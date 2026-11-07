package peer

import (
	"errors"
	"sync"
	"time"

	"farreach.local/networking/internal/video"
	"github.com/pion/interceptor"
	"github.com/pion/rtp"
)

const minimumMediaBitrate = 500_000

const maximumPacingBurstBytes = 4800

type pacingBudget struct {
	tokens float64
	last   time.Time
}

// Idle time is real available link capacity. Preserve it across one-frame
// grants, while keeping the same small burst ceiling as active pacing.
func (b *pacingBudget) wake(now time.Time, rate int) { b.tick(now, rate) }
func (b *pacingBudget) tick(now time.Time, rate int) {
	if now.Before(b.last) {
		return
	}
	b.tokens = min(maximumPacingBurstBytes, b.tokens+now.Sub(b.last).Seconds()*float64(rate)/8)
	b.last = now
}

var errMediaExpired = errors.New("media packet expired or pacing queue full")

type resendCompletion interface {
	Retain()
	Release(bool)
}

type pacedPacket struct {
	completions       []resendCompletion
	header            rtp.Header
	payload           []byte
	attributes        interceptor.Attributes
	created, deadline time.Time
	writer            interceptor.RTPWriter
}

// boundedPacer implements gcc.Pacer. Every original and repaired packet consumes
// the same rate budget. The default GCC pacer is intentionally not used: its
// unbounded linked list can turn congestion into many seconds of remote lag.
type boundedPacer struct {
	repairRTT   time.Duration
	mu          sync.Mutex
	rate        int
	streams     map[uint32]interceptor.RTPWriter
	queue       []pacedPacket
	bytes       int
	closed      bool
	deadlines   map[[2]uint64]time.Time
	generation  uint64
	extensionID uint8
	done        chan struct{}
	onDrop      func()
	onSent      func()
	onPressure  func()
	onDrained   func()
	inFlight    int
	wake        chan struct{}
}

func newPacer() *boundedPacer {
	p := &boundedPacer{rate: 2_000_000, streams: make(map[uint32]interceptor.RTPWriter), deadlines: make(map[[2]uint64]time.Time), done: make(chan struct{}), wake: make(chan struct{}, 1)}
	go p.run()
	return p
}
func (p *boundedPacer) AddStream(ssrc uint32, w interceptor.RTPWriter) {
	p.mu.Lock()
	p.streams[ssrc] = w
	p.mu.Unlock()
}
func (p *boundedPacer) SetRTT(rtt time.Duration) {
	p.mu.Lock()
	p.repairRTT = max(0, min(rtt, 300*time.Millisecond))
	p.mu.Unlock()
}
func (p *boundedPacer) SetTargetBitrate(rate int) {
	p.mu.Lock()
	p.rate = max(minimumMediaBitrate, min(rate, 12_000_000))
	p.mu.Unlock()
}
func (p *boundedPacer) SetGeneration(generation uint64) {
	p.mu.Lock()
	p.generation = generation
	for _, packet := range p.queue {
		for _, completion := range packet.completions {
			completion.Release(false)
		}
	}
	p.queue = nil
	p.bytes = 0
	p.deadlines = make(map[[2]uint64]time.Time)
	p.mu.Unlock()
}
func (p *boundedPacer) BeginFrame(m video.Metadata, size int, id uint8) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	for key, deadline := range p.deadlines {
		if !deadline.After(now) {
			delete(p.deadlines, key)
		}
	}
	budget := m.Budget()
	limit := min(512*1024, int(float64(p.rate)*budget.Seconds()/8))
	if m.Keyframe && size+p.bytes > limit {
		budget = video.RecoveryDeadline
		limit = min(512*1024, int(float64(p.rate)*budget.Seconds()/8))
	}
	if p.closed || m.Generation != p.generation || size+p.bytes > limit || len(p.deadlines) >= 128 {
		return false
	}
	p.extensionID = id
	repairBudget := budget
	if !m.Keyframe {
		repairBudget = max(budget, min(350*time.Millisecond, 2*p.repairRTT+100*time.Millisecond))
	}
	p.deadlines[[2]uint64{m.Generation, m.Sequence}] = now.Add(repairBudget)
	return true
}
func (p *boundedPacer) Write(header *rtp.Header, payload []byte, attributes interceptor.Attributes) (int, error) {
	p.mu.Lock()
	m, err := video.ParseMetadata(header.GetExtension(p.extensionID))
	key := [2]uint64{m.Generation, m.Sequence}
	deadline := p.deadlines[key]
	size := header.MarshalSize() + len(payload)
	now := time.Now()
	if err != nil || p.closed || m.Generation != p.generation || !deadline.After(now) || p.bytes+size > 512*1024 || len(p.queue) >= 2048 || p.streams[header.SSRC] == nil {
		p.mu.Unlock()
		return 0, errMediaExpired
	}
	// Clone because NACK's retained buffers may be released when Write returns.
	cloned := header.Clone()
	data := append([]byte(nil), payload...)
	attrs := make(interceptor.Attributes, len(attributes))
	var completions []resendCompletion
	for k, v := range attributes {
		attrs[k] = v
		if completion, ok := v.(resendCompletion); ok {
			completion.Retain()
			completions = append(completions, completion)
		}
	}
	p.queue = append(p.queue, pacedPacket{header: cloned, payload: data, attributes: attrs, created: now, deadline: deadline, writer: p.streams[header.SSRC], completions: completions})
	p.bytes += size
	select {
	case p.wake <- struct{}{}:
	default:
	}
	p.mu.Unlock()
	return size, nil
}
func (p *boundedPacer) Drained() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.queue) == 0 && p.inFlight == 0
}
func (p *boundedPacer) Stats() (int, float64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	age := float64(0)
	if len(p.queue) > 0 {
		age = float64(time.Since(p.queue[0].created).Microseconds()) / 1000
	}
	return p.bytes, age
}
func (p *boundedPacer) Close() error {
	p.mu.Lock()
	if !p.closed {
		p.closed = true
		close(p.done)
		for _, packet := range p.queue {
			for _, completion := range packet.completions {
				completion.Release(false)
			}
		}
		p.queue = nil
		p.bytes = 0
	}
	p.mu.Unlock()
	return nil
}
func (p *boundedPacer) run() {
	ticker := time.NewTicker(2 * time.Millisecond)
	defer ticker.Stop()
	budget := pacingBudget{last: time.Now(), tokens: 2400}
	for {
		p.mu.Lock()
		empty := len(p.queue) == 0
		p.mu.Unlock()
		if empty {
			ticker.Stop()
			select {
			case <-p.done:
				return
			case <-p.wake:
			}
			p.mu.Lock()
			budget.wake(time.Now(), p.rate)
			p.mu.Unlock()
			ticker.Reset(2 * time.Millisecond)
		}
		select {
		case <-p.done:
			return
		case now := <-ticker.C:
			p.mu.Lock()
			budget.tick(now, p.rate)
			dropped := false
			didWork := false
			for len(p.queue) > 0 {
				item := p.queue[0]
				size := item.header.MarshalSize() + len(item.payload)
				if item.deadline.Before(now) {
					for _, completion := range item.completions {
						completion.Release(false)
					}
					p.queue[0] = pacedPacket{}
					p.queue = p.queue[1:]
					p.bytes -= size
					dropped = true
					didWork = true
					continue
				}
				if budget.tokens < float64(size) {
					break
				}
				budget.tokens -= float64(size)
				didWork = true
				p.inFlight++
				p.queue[0] = pacedPacket{}
				p.queue = p.queue[1:]
				p.bytes -= size
				// Never hold queue state across an external socket write. A generation
				// change may overlap this one in-flight packet; its authenticated generation
				// remains attached and the receiver rejects it after a transition.
				p.mu.Unlock()
				_, err := item.writer.Write(&item.header, item.payload, item.attributes)
				for _, completion := range item.completions {
					completion.Release(err == nil)
				}
				p.mu.Lock()
				p.inFlight--
				if err != nil {
					dropped = true
				} else if p.onSent != nil {
					p.onSent()
				}
			}
			drained := didWork && len(p.queue) == 0 && p.inFlight == 0
			onDrained := p.onDrained
			notify := p.onDrop
			pressure := p.onPressure
			pressured := len(p.queue) > 0 && (now.Sub(p.queue[0].created) > 50*time.Millisecond || float64(p.bytes)*8/float64(p.rate) > 0.05)
			p.mu.Unlock()
			if pressured && pressure != nil {
				pressure()
			}
			if dropped && notify != nil {
				notify()
			}
			if drained && onDrained != nil {
				onDrained()
			}
		}
	}
}
