package peer

import (
	"encoding/binary"
	"fmt"
	"io"
	"math/rand"
	"net"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"farreach.local/networking/internal/video"
	"farreach.local/networking/internal/wire"
	"github.com/pion/ice/v4"
	"github.com/pion/logging"
	"github.com/pion/transport/v5/vnet"
	"github.com/pion/webrtc/v4"
)

// Test-only reproduction of the previous media algorithm: 16KiB fragments,
// unordered SCTP with zero retransmits, 256KiB admission ceiling, existing
// legacy reassembler and 250ms keyframe-request throttle. It intentionally
// excludes the native encoder/display and should never be shipped as a fallback.
func TestLegacyVirtualWANBaseline(t *testing.T) {
	if os.Getenv("FARREACH_NETWORK_BASELINE") != "1" {
		t.Skip("set FARREACH_NETWORK_BASELINE=1 for historical transport comparison")
	}
	for _, profile := range []struct{ rtt, loss, bandwidth int }{{20, 0, 15_000_000}, {80, 3, 5_000_000}, {150, 3, 2_000_000}} {
		t.Run(fmt.Sprintf("RTT%dms_loss%d_bandwidth%d", profile.rtt, profile.loss, profile.bandwidth), func(t *testing.T) { runLegacyWAN(t, profile.rtt, profile.loss, profile.bandwidth) })
	}
}
func runLegacyWAN(t *testing.T, rttMS, lossPercent, bandwidth int) {
	logger := logging.NewDefaultLoggerFactory()
	logger.DefaultLogLevel = logging.LogLevelDisabled
	logger.Writer = io.Discard
	router, err := vnet.NewRouter(&vnet.RouterConfig{CIDR: "10.91.0.0/24", MinDelay: time.Duration(rttMS) * time.Millisecond / 2, QueueSize: 2048, LoggerFactory: logger})
	if err != nil {
		t.Fatal(err)
	}
	hostNet, _ := vnet.NewNet(&vnet.NetConfig{StaticIPs: []string{"10.91.0.1"}})
	viewerNet, _ := vnet.NewNet(&vnet.NetConfig{StaticIPs: []string{"10.91.0.2"}})
	queue, err := vnet.NewQueue(viewerNet, vnet.NewTBFQueue(bandwidth, 4800, 64*1024))
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
	var active atomic.Bool
	var datagrams, drops atomic.Uint64
	router.AddChunkFilter(func(chunk vnet.Chunk) bool {
		b := chunk.UserData()
		if !active.Load() || len(b) < 200 || b[0] != 23 || chunk.SourceAddr().(*net.UDPAddr).IP.String() != "10.91.0.1" {
			return true
		}
		datagrams.Add(1)
		if rng.Intn(100) < lossPercent {
			drops.Add(1)
			return false
		}
		return true
	})
	if err = router.Start(); err != nil {
		t.Fatal(err)
	}
	defer router.Stop()
	makePC := func(network *vnet.Net) *webrtc.PeerConnection {
		settings := webrtc.SettingEngine{}
		settings.LoggerFactory = logger
		settings.SetNet(network)
		settings.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
		settings.SetICEMulticastDNSMode(ice.MulticastDNSModeDisabled)
		settings.SetSCTPMaxReceiveBufferSize(2 * 1024 * 1024)
		pc, err := webrtc.NewAPI(webrtc.WithSettingEngine(settings)).NewPeerConnection(webrtc.Configuration{})
		if err != nil {
			t.Fatal(err)
		}
		return pc
	}
	host, viewer := makePC(hostNet), makePC(viewerNet)
	defer host.Close()
	defer viewer.Close()
	ordered := true
	control, err := host.CreateDataChannel("baseline-control", &webrtc.DataChannelInit{Ordered: &ordered})
	if err != nil {
		t.Fatal(err)
	}
	ordered = false
	zero := uint16(0)
	media, err := host.CreateDataChannel("baseline-video", &webrtc.DataChannelInit{Ordered: &ordered, MaxRetransmits: &zero})
	if err != nil {
		t.Fatal(err)
	}
	incoming := make(chan wire.Frame, 256)
	var forceKey atomic.Bool
	forceKey.Store(true)
	var viewerControl *webrtc.DataChannel
	var receiverMu sync.Mutex
	assembler := video.NewReassembler()
	lastRequest := time.Time{}
	requestKey := func() {
		if viewerControl != nil && time.Since(lastRequest) >= 250*time.Millisecond {
			lastRequest = time.Now()
			b, _ := wire.Encode(wire.Frame{Kind: wire.RequestKeyframe})
			_ = viewerControl.Send(b)
		}
	}
	control.OnMessage(func(message webrtc.DataChannelMessage) {
		f, err := wire.Decode(message.Data)
		if err != nil {
			return
		}
		if f.Kind == wire.RequestKeyframe {
			forceKey.Store(true)
		} else if f.Kind == wire.Ping {
			b, _ := wire.Encode(wire.Frame{Kind: wire.Pong, Payload: f.Payload})
			_ = control.Send(b)
		}
	})
	opened := make(chan struct{}, 4)
	control.OnOpen(func() { opened <- struct{}{} })
	media.OnOpen(func() { opened <- struct{}{} })
	viewer.OnDataChannel(func(dc *webrtc.DataChannel) {
		dc.OnOpen(func() { opened <- struct{}{} })
		if dc.Label() == "baseline-control" {
			receiverMu.Lock()
			viewerControl = dc
			receiverMu.Unlock()
			dc.OnMessage(func(m webrtc.DataChannelMessage) {
				if f, e := wire.Decode(m.Data); e == nil {
					incoming <- f
				}
			})
		} else {
			dc.OnMessage(func(m webrtc.DataChannelMessage) {
				receiverMu.Lock()
				f, lost, e := assembler.Push(m.Data, time.Now())
				if lost {
					requestKey()
				}
				receiverMu.Unlock()
				if e == nil && f != nil {
					incoming <- wire.Frame{Kind: wire.Video, Payload: f.Data}
				}
			})
		}
	})
	offer, err := host.CreateOffer(nil)
	if err != nil {
		t.Fatal(err)
	}
	gathered := webrtc.GatheringCompletePromise(host)
	if err = host.SetLocalDescription(offer); err != nil {
		t.Fatal(err)
	}
	<-gathered
	if err = viewer.SetRemoteDescription(*host.LocalDescription()); err != nil {
		t.Fatal(err)
	}
	answer, err := viewer.CreateAnswer(nil)
	if err != nil {
		t.Fatal(err)
	}
	gathered = webrtc.GatheringCompletePromise(viewer)
	if err = viewer.SetLocalDescription(answer); err != nil {
		t.Fatal(err)
	}
	<-gathered
	if err = host.SetRemoteDescription(*viewer.LocalDescription()); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 4; i++ {
		select {
		case <-opened:
		case <-time.After(8 * time.Second):
			t.Fatal("legacy negotiation timeout")
		}
	}
	active.Store(true)
	duration := 4 * time.Second
	if os.Getenv("FARREACH_NETWORK_LONG") == "1" {
		duration = 20 * time.Second
	}
	timer := time.NewTimer(duration)
	defer timer.Stop()
	ticker := time.NewTicker(time.Second / 30)
	defer ticker.Stop()
	expiry := time.NewTicker(100 * time.Millisecond)
	defer expiry.Stop()
	var sent, received int
	lastFrame := time.Now()
	maxGap := time.Duration(0)
	var gapExcess time.Duration
	var gapsOver250 int
	var latencies, pings []float64
	maxQueue := uint64(0)
	running := true
	for running {
		select {
		case now := <-ticker.C:
			sent++
			key := forceKey.Swap(false) || sent%30 == 0
			data := virtualFrame(sent, now, key)
			if media.BufferedAmount() > 256*1024 {
				forceKey.Store(true)
				continue
			}
			fragments, e := video.Fragments(uint64(sent), data)
			if e != nil {
				t.Fatal(e)
			}
			for _, fragment := range fragments {
				if e = media.Send(fragment); e != nil {
					t.Fatal(e)
				}
			}
			maxQueue = max(maxQueue, media.BufferedAmount())
			if sent%3 == 0 {
				b := make([]byte, 8)
				binary.BigEndian.PutUint64(b, uint64(now.UnixNano()))
				encoded, _ := wire.Encode(wire.Frame{Kind: wire.Ping, Payload: b})
				receiverMu.Lock()
				e = viewerControl.Send(encoded)
				receiverMu.Unlock()
				if e != nil {
					t.Fatal(e)
				}
			}
		case f := <-incoming:
			if f.Kind == wire.Video {
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
				capture := int64(binary.BigEndian.Uint64(f.Payload[45:]))
				latencies = append(latencies, float64(time.Since(time.Unix(0, capture)).Microseconds())/1000)
			} else if f.Kind == wire.Pong {
				sentAt := int64(binary.BigEndian.Uint64(f.Payload))
				pings = append(pings, float64(time.Since(time.Unix(0, sentAt)).Microseconds())/1000)
			}
		case now := <-expiry.C:
			receiverMu.Lock()
			if assembler.Expire(now) {
				requestKey()
			}
			receiverMu.Unlock()
		case <-timer.C:
			running = false
		}
	}
	if received == 0 || len(pings) == 0 {
		t.Fatal("legacy benchmark produced no measurements")
	}
	sort.Float64s(latencies)
	sort.Float64s(pings)
	p95 := func(v []float64) float64 { return v[min(len(v)-1, int(float64(len(v))*.95))] }
	t.Logf("LEGACY_VNET_RESULT configuredRTT=%dms loss=%d%% bandwidth=%d sentFrames=%d deliveredFrames=%d largeDTLSDatagrams=%d injectedDrops=%d sendToIPC_p95=%.2fms controlRTT_p95=%.2fms maxSCTPBufferedBytes=%d maxFrameGapMS=%.2f gapExcessMS=%.2f gapsOver250ms=%d", rttMS, lossPercent, bandwidth, sent, received, datagrams.Load(), drops.Load(), p95(latencies), p95(pings), maxQueue, float64(maxGap.Microseconds())/1000, float64(gapExcess.Microseconds())/1000, gapsOver250)
}
