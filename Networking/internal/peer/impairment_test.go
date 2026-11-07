package peer

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"os"
	"sort"
	"sync/atomic"
	"testing"
	"time"

	"farreach.local/networking/internal/wire"
	"github.com/pion/logging"
	"github.com/pion/rtp"
	"github.com/pion/transport/v5/vnet"
)

// Runs the actual ICE/DTLS/SRTP/SCTP/GCC/NACK implementation over virtual UDP,
// with seeded media loss, fixed path delay and a bounded bandwidth queue. The
// timing is send-to-complete-IPC delivery, not native capture-to-display latency.
func TestVirtualWANImpairments(t *testing.T) {
	if os.Getenv("FARREACH_NETWORK_IMPAIRMENT") != "1" {
		t.Skip("set FARREACH_NETWORK_IMPAIRMENT=1 for controlled virtual-WAN benchmark")
	}
	for _, profile := range []struct{ rtt, loss, bandwidth int }{{20, 0, 15_000_000}, {80, 1, 5_000_000}, {80, 3, 5_000_000}, {150, 3, 2_000_000}, {80, 5, 2_000_000}} {
		t.Run(fmt.Sprintf("RTT%dms_loss%d_bandwidth%d", profile.rtt, profile.loss, profile.bandwidth), func(t *testing.T) { runVirtualWAN(t, profile.rtt, profile.loss, profile.bandwidth) })
	}
}

type virtualOptions struct{ firstRepairLost, dynamic bool }

func runVirtualWAN(t *testing.T, rttMS, lossPercent, bandwidth int, options ...virtualOptions) {
	forceLoss := len(options) > 0 && options[0].firstRepairLost
	dynamic := len(options) > 0 && options[0].dynamic
	jitter := time.Duration(0)
	if dynamic {
		jitter = 20 * time.Millisecond
	}
	var repairSequence uint16
	var watchedSequence atomic.Uint32
	var watched atomic.Bool
	lastAttempt := -1
	repairDrops := 0
	repairChosen := false
	log := logging.NewDefaultLoggerFactory()
	log.DefaultLogLevel = logging.LogLevelDisabled
	log.Writer = io.Discard
	router, err := vnet.NewRouter(&vnet.RouterConfig{CIDR: "10.90.0.0/24", MinDelay: time.Duration(rttMS) * time.Millisecond / 2, QueueSize: 2048, MaxJitter: jitter, LoggerFactory: log})
	if err != nil {
		t.Fatal(err)
	}
	hostNet, err := vnet.NewNet(&vnet.NetConfig{StaticIPs: []string{"10.90.0.1"}})
	if err != nil {
		t.Fatal(err)
	}
	viewerNet, err := vnet.NewNet(&vnet.NetConfig{StaticIPs: []string{"10.90.0.2"}})
	if err != nil {
		t.Fatal(err)
	}
	shaper := vnet.NewTBFQueue(bandwidth, 4800, 64*1024)
	queue, err := vnet.NewQueue(viewerNet, shaper)
	if err != nil {
		t.Fatal(err)
	}
	defer queue.Close()
	if err = router.AddNet(hostNet); err != nil {
		t.Fatal(err)
	}
	if err = router.AddNet(queue); err != nil {
		t.Fatal(err)
	}
	rng := rand.New(rand.NewSource(20261105))
	var packets, discarded atomic.Uint64
	router.AddChunkFilter(func(chunk vnet.Chunk) bool {
		h := rtp.Header{}
		if _, err := h.Unmarshal(chunk.UserData()); err != nil || h.PayloadType != 96 {
			return true
		}
		count := packets.Add(1)
		if forceLoss {
			if count == 100 && !repairChosen {
				repairSequence = h.SequenceNumber
				repairChosen = true
				watchedSequence.Store(uint32(repairSequence))
				watched.Store(true)
				t.Logf("repair probe sequence=%d version=%d extensions=%v", repairSequence, h.Version, h.GetExtensionIDs())
			}
			if repairChosen && h.SequenceNumber == repairSequence && repairDrops < 2 {
				repairDrops++
				t.Logf("repair probe drop=%d at=%s", repairDrops, time.Now().Format("15:04:05.000"))
				discarded.Add(1)
				return false
			}
		}
		if (dynamic && count%250 >= 240 && count%250 < 245) || rng.Intn(100) < lossPercent {
			discarded.Add(1)
			return false
		}
		return true
	})
	if err = router.Start(); err != nil {
		t.Fatal(err)
	}
	defer router.Stop()
	hostFrames, viewerFrames := make(chan wire.Frame, 256), make(chan wire.Frame, 256)
	output := func(ch chan wire.Frame) func(wire.Frame) bool {
		return func(f wire.Frame) bool {
			select {
			case ch <- f:
				return true
			default:
				return false
			}
		}
	}
	host, err := newConnection(Config{ProtocolVersion: 2, Role: "host"}, output(hostFrames), hostNet)
	if err != nil {
		t.Fatal(err)
	}
	defer host.Close()
	if err = host.Start(); err != nil {
		t.Fatal(err)
	}
	offer := awaitVirtualEvent(t, hostFrames, "invitation")
	viewer, err := newConnection(Config{ProtocolVersion: 2, Role: "viewer", Invitation: offer}, output(viewerFrames), viewerNet)
	if err != nil {
		t.Fatal(err)
	}
	defer viewer.Close()
	if err = viewer.Start(); err != nil {
		t.Fatal(err)
	}
	answer := awaitVirtualEvent(t, viewerFrames, "response")
	if err = host.ApplyAnswer(answer); err != nil {
		t.Fatal(err)
	}
	awaitVirtualEvent(t, hostFrames, "ready")
	awaitVirtualEvent(t, viewerFrames, "ready")
	if err = host.AuthorizeMedia(MediaAuthorization{true, 42}); err != nil {
		t.Fatal(err)
	}
	if err = viewer.AuthorizeMedia(MediaAuthorization{true, 42}); err != nil {
		t.Fatal(err)
	}
	ticker := time.NewTicker(time.Second / 30)
	defer ticker.Stop()
	duration := 4 * time.Second
	if dynamic {
		duration = 10 * time.Second
	}
	if os.Getenv("FARREACH_NETWORK_LONG") == "1" {
		duration = 20 * time.Second
	}
	timer := time.NewTimer(duration)
	defer timer.Stop()
	var sent, received, pongs int
	forceKey := true
	targetBitrate := 2_000_000
	lastFrame := time.Now()
	maxGap := time.Duration(0)
	var gapExcess time.Duration
	var gapsOver250 int
	maxQueueMS := 0.0
	var latencies, pings []float64
	maxQueue := 0
	phase := 0
	startedAt := time.Now()
	windowStart := startedAt
	windowBytes := 0
	maxOfferedBitrate := 0
	running := true
	for running {
		select {
		case now := <-ticker.C:
			sent++
			if forceLoss && watched.Load() {
				viewer.reassemblyMu.Lock()
				gap, exists := viewer.repairs.pending[uint16(watchedSequence.Load())]
				rtt := viewer.repairRTT
				viewer.reassemblyMu.Unlock()
				if exists && int(gap.attempts) != lastAttempt {
					lastAttempt = int(gap.attempts)
					t.Logf("repair probe attempt=%d rtt=%s remaining=%s next=%s", gap.attempts, rtt, time.Until(gap.deadline), time.Until(gap.next))
				}
			}
			key := forceKey || sent%30 == 0
			forceKey = false
			capBytes := 4096
			if dynamic {
				capBytes = 32000
			}
			size := min(capBytes, max(512, int(float64(targetBitrate)*0.85/8/33)))
			data := virtualSizedFrame(sent, now, key, size)
			windowBytes += len(data)
			if now.Sub(windowStart) >= time.Second {
				maxOfferedBitrate = max(maxOfferedBitrate, int(float64(windowBytes)*8/now.Sub(windowStart).Seconds()))
				windowBytes = 0
				windowStart = now
			}
			if dynamic && phase == 0 && now.Sub(startedAt) >= 4*time.Second {
				shaper.SetRate(2_000_000)
				phase = 1
			}
			if dynamic && phase == 1 && now.Sub(startedAt) >= 7*time.Second {
				shaper.SetRate(15_000_000)
				phase = 2
			}
			if err = host.Send(wire.Frame{Kind: wire.Video, Payload: data}); err != nil {
				t.Fatal(err)
			}
			if sent%3 == 0 {
				b := make([]byte, 8)
				binary.BigEndian.PutUint64(b, uint64(now.UnixNano()))
				if err = viewer.Send(wire.Frame{Kind: wire.Ping, Payload: b}); err != nil {
					t.Fatal(err)
				}
			}
			n, age := host.pacer.Stats()
			maxQueueMS = max(maxQueueMS, age)
			maxQueue = max(maxQueue, n)
		case f := <-hostFrames:
			switch f.Kind {
			case wire.Ping:
				if err = host.Send(wire.Frame{Kind: wire.Pong, Payload: f.Payload}); err != nil {
					t.Fatal(err)
				}
			case wire.RequestKeyframe:
				forceKey = true
			case wire.Event:
				var e Event
				json.Unmarshal(f.Payload, &e)
				if e.Type == "statistics" {
					var stats struct {
						TargetBitrate int `json:"targetBitrate"`
					}
					if json.Unmarshal([]byte(e.Value), &stats) == nil && stats.TargetBitrate > 0 {
						targetBitrate = stats.TargetBitrate
					}
				}
				if e.Type == "videoDropped" {
					forceKey = true
				}
				if e.Type == "error" {
					t.Fatal(e.Value)
				}
			}
		case f := <-viewerFrames:
			switch f.Kind {
			case wire.Video:
				received++
				gap := time.Since(lastFrame)
				if received > 1 {
					maxGap = max(maxGap, gap)
					gapExcess += max(time.Duration(0), gap-time.Second/30)
					if gap > 250*time.Millisecond {
						gapsOver250++
					}
				}
				lastFrame = time.Now()
				capture := int64(binary.BigEndian.Uint64(f.Payload[12+33:]))
				latencies = append(latencies, float64(time.Since(time.Unix(0, capture)).Microseconds())/1000)
			case wire.Pong:
				pongs++
				sentAt := int64(binary.BigEndian.Uint64(f.Payload))
				pings = append(pings, float64(time.Since(time.Unix(0, sentAt)).Microseconds())/1000)
			case wire.Event:
				var e Event
				json.Unmarshal(f.Payload, &e)
				if e.Type == "error" {
					t.Fatal(e.Value)
				}
			}
		case <-timer.C:
			running = false
		}
	}
	if dynamic && (phase != 2 || maxOfferedBitrate <= 2_000_000) {
		t.Fatalf("capacity collapse was not exercised: phase=%d maxOffered=%d", phase, maxOfferedBitrate)
	}
	if forceLoss && (discarded.Load() != 2 || viewer.repairedPackets.Load() < 1) {
		t.Fatalf("second repair not verified: injected=%d recovered=%d", discarded.Load(), viewer.repairedPackets.Load())
	}
	if received < 5 || pongs < 10 {
		t.Fatalf("media/control stalled: admitted=%d delivered=%d pongs=%d", sent, received, pongs)
	}
	if maxQueue > 512*1024 {
		t.Fatal("unbounded pacing queue")
	}
	sort.Float64s(latencies)
	sort.Float64s(pings)
	p95 := func(values []float64) float64 { return values[min(len(values)-1, int(float64(len(values))*.95))] }
	t.Logf("VNET_RESULT configuredRTT=%dms loss=%d%% bandwidth=%d sentFrames=%d deliveredFrames=%d mediaPackets=%d injectedDrops=%d sequenceGaps=%d lateRecovered=%d sendToIPC_p95=%.2fms controlRTT_p95=%.2fms maxQueuedBytes=%d targetBitrate=%d maxQueueMS=%.2f maxFrameGapMS=%.2f gapExcessMS=%.2f gapsOver250ms=%d maxOfferedBitrate=%d dynamic=%t jitterMaxMS=%d", rttMS, lossPercent, bandwidth, sent, received, packets.Load(), discarded.Load(), viewer.lostPackets.Load(), viewer.repairedPackets.Load(), p95(latencies), p95(pings), maxQueue, host.estimator.GetTargetBitrate(), maxQueueMS, float64(maxGap.Microseconds())/1000, float64(gapExcess.Microseconds())/1000, gapsOver250, maxOfferedBitrate, dynamic, jitter.Milliseconds())
}
func awaitVirtualEvent(t *testing.T, ch <-chan wire.Frame, want string) string {
	t.Helper()
	timer := time.NewTimer(8 * time.Second)
	defer timer.Stop()
	for {
		select {
		case f := <-ch:
			if f.Kind != wire.Event {
				continue
			}
			var e Event
			json.Unmarshal(f.Payload, &e)
			if e.Type == want {
				return e.Value
			}
			if e.Type == "error" {
				t.Fatal(e.Value)
			}
		case <-timer.C:
			t.Fatalf("virtual network awaiting %s", want)
		}
	}
}
func virtualFrame(id int, now time.Time, key bool) []byte {
	return virtualSizedFrame(id, now, key, 4096)
}
func virtualSizedFrame(id int, now time.Time, key bool, size int) []byte {
	if key {
		size *= 4
	}
	b := make([]byte, 12+49+2+4+size)
	copy(b, "FRS1")
	binary.BigEndian.PutUint64(b[4:], 42)
	body := b[12:]
	copy(body, "FRV2")
	binary.BigEndian.PutUint32(body[4:], 1280)
	binary.BigEndian.PutUint32(body[8:], 720)
	if key {
		body[12] = 1
	}
	binary.BigEndian.PutUint32(body[13:], 1)
	binary.BigEndian.PutUint32(body[17:], 1)
	binary.BigEndian.PutUint32(body[21:], uint32(4+size))
	binary.BigEndian.PutUint64(body[25:], uint64(id))
	binary.BigEndian.PutUint64(body[33:], uint64(now.UnixNano()))
	binary.BigEndian.PutUint64(body[41:], uint64(now.UnixNano()))
	body[49] = 0x67
	body[50] = 0x68
	binary.BigEndian.PutUint32(body[51:], uint32(size))
	for i := 55; i < len(body); i++ {
		body[i] = 0x55
	}
	if key {
		body[55] = 0x65
	} else {
		body[55] = 0x41
	}
	return b
}

func TestVirtualWANRecoversWhenFirstRepairIsLost(t *testing.T) {
	if os.Getenv("FARREACH_NETWORK_IMPAIRMENT") != "1" {
		t.Skip("opt-in virtual-WAN repair test")
	}
	runVirtualWAN(t, 80, 0, 5_000_000, virtualOptions{firstRepairLost: true})
}

func TestVirtualWANJitterBurstAndCapacityCollapse(t *testing.T) {
	if os.Getenv("FARREACH_NETWORK_IMPAIRMENT") != "1" {
		t.Skip("opt-in virtual-WAN dynamic-capacity test")
	}
	runVirtualWAN(t, 80, 1, 15_000_000, virtualOptions{dynamic: true})
}
