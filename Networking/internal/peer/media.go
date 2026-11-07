package peer

import (
	"encoding/json"
	"errors"
	"time"

	"farreach.local/networking/internal/video"
	"farreach.local/networking/internal/wire"
	"github.com/pion/rtcp"
	"github.com/pion/webrtc/v4"
)

type MediaAuthorization struct {
	Authorized bool   `json:"authorized"`
	Generation uint64 `json:"generation"`
}

func (p *Connection) AuthorizeMedia(a MediaAuthorization) error {
	p.mu.Lock()
	if !p.ready || p.closed {
		p.mu.Unlock()
		return errors.New("media authorization before ready")
	}
	if !a.Authorized {
		a.Generation = 0
	}
	changed := p.authorized != a.Authorized || p.mediaGeneration != a.Generation
	p.authorized = a.Authorized
	p.mediaGeneration = a.Generation
	if changed {
		p.flowCredit = false
		p.flowNeedsGrant = a.Authorized && a.Generation > 0
		p.flowSequence = 0
	}
	if changed {
		p.needSendKeyframe = true
		p.dropGeneration++
	}
	p.mu.Unlock()
	if changed {
		p.pacer.SetGeneration(a.Generation)
		p.reassemblyMu.Lock()
		p.rtpAssembly.Reset(a.Generation)
		p.repairs.Reset(a.Generation)
		p.loss = packetLossTracker{}
		p.reassemblyMu.Unlock()
		for {
			select {
			case <-p.videoQueue:
			default:
				goto drained
			}
		}
	drained:
		if a.Authorized && a.Generation > 0 {
			if p.cfg.Role == "viewer" {
				p.requestKeyframe()
			} else {
				p.emit("videoDropped", "new capture generation requires keyframe")
			}
		}
	}
	p.maybeGrantMediaCapacity()
	return nil
}
func (p *Connection) receiveTrack(track *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) {
	if p.cfg.Role != "viewer" || track.Codec().MimeType != webrtc.MimeTypeH264 {
		p.fail("unexpected media track")
		return
	}
	id := uint8(0)
	for _, ext := range receiver.GetParameters().HeaderExtensions {
		if ext.URI == video.MetadataURI {
			id = uint8(ext.ID)
		}
	}
	if id == 0 {
		p.fail("missing generation metadata")
		return
	}
	p.mu.Lock()
	if p.remoteSSRC != 0 {
		p.mu.Unlock()
		p.fail("unexpected second media track")
		return
	}
	p.remoteSSRC = uint32(track.SSRC())
	p.receiverExtension = id
	p.mu.Unlock()
	for {
		packet, _, err := track.ReadRTP()
		if err != nil {
			return
		}
		p.mu.Lock()
		allowed := p.ready && !p.closed && p.authorized && p.mediaGeneration > 0
		generation := p.mediaGeneration
		p.mu.Unlock()
		if !allowed {
			continue
		}
		metadata, metaErr := video.ParseMetadata(packet.GetExtension(id))
		if metaErr != nil {
			p.fail("invalid RTP metadata")
			return
		}
		if metadata.Generation != generation {
			continue
		}
		p.receivedPackets.Add(1)
		p.reassemblyMu.Lock()
		if p.repairs.generation != metadata.Generation {
			p.reassemblyMu.Unlock()
			continue
		}
		lost, repaired := p.loss.Push(packet.SequenceNumber)
		p.lostPackets.Add(lost)
		p.repairedPackets.Add(repaired)
		now := time.Now()
		frames, loss, err := p.rtpAssembly.Push(packet, id, now)
		if err == nil {
			p.repairs.Observe(metadata.Generation, packet.SequenceNumber, metadata.Index, now, func(seq uint16) time.Time { return p.rtpAssembly.RepairDeadline(seq, now) })
		}
		p.reassemblyMu.Unlock()
		p.deliverMedia(frames, loss, err)
	}
}
func (p *Connection) deliverMedia(frames [][]byte, lost bool, err error) {
	if err != nil {
		p.fail("invalid RTP media")
		return
	}
	p.mu.Lock()
	allowed := p.ready && !p.closed && p.authorized && p.mediaGeneration > 0
	p.mu.Unlock()
	if !allowed {
		return
	}
	if lost {
		p.droppedFrames.Add(1)
		p.requestKeyframe()
	}
	for _, frame := range frames {
		if !p.output(wire.Frame{Kind: wire.Video, Payload: frame}) {
			p.reassemblyMu.Lock()
			p.rtpAssembly.MarkLost()
			p.reassemblyMu.Unlock()
			p.droppedFrames.Add(1)
			p.requestKeyframe()
		}
	}
}
func (p *Connection) readRTCP() {
	for {
		packets, _, err := p.sender.ReadRTCP()
		if err != nil {
			return
		}
		for _, packet := range packets {
			switch packet.(type) {
			case *rtcp.PictureLossIndication, *rtcp.FullIntraRequest:
				p.forwardKeyframeRequest()
			}
		}
	}
}
func (p *Connection) emitStatistics() {
	p.mu.Lock()
	active := p.ready && !p.closed
	p.mu.Unlock()
	if !active {
		return
	}
	now := time.Since(p.mediaStart).Nanoseconds()
	previous := p.lastStatsNS.Load()
	if now-previous < int64(250*time.Millisecond) || !p.lastStatsNS.CompareAndSwap(previous, now) {
		return
	}
	estimate := 2_000_000
	if p.estimator != nil {
		estimate = p.estimator.GetTargetBitrate()
	}
	target := max(minimumMediaBitrate, min(12_000_000, estimate))
	queued, age := p.pacer.Stats()
	rtt := 0.0
	if pair, ok := p.pc.SCTP().Transport().ICETransport().GetSelectedCandidatePairStats(); ok {
		rtt = pair.CurrentRoundTripTime * 1000
	}
	if rtt == 0 {
		rtt = p.pc.SCTP().Stats().SmoothedRoundTripTime * 1000
	}
	p.pacer.SetRTT(time.Duration(rtt * float64(time.Millisecond)))
	p.reassemblyMu.Lock()
	p.rtpAssembly.SetRTT(time.Duration(rtt * float64(time.Millisecond)))
	p.repairRTT = time.Duration(rtt * float64(time.Millisecond))
	p.reassemblyMu.Unlock()
	p.mu.Lock()
	ready := p.authorized && p.mediaGeneration > 0 && p.connected
	p.mu.Unlock()
	stats := struct {
		TargetBitrate              int     `json:"targetBitrate"`
		RTTMS                      float64 `json:"rttMS"`
		QueuedBytes                int     `json:"queuedBytes"`
		QueueMS                    float64 `json:"queueMS"`
		PacketsSent                uint64  `json:"packetsSent"`
		PacketsReceived            uint64  `json:"packetsReceived"`
		PacketsLost                uint64  `json:"packetsLost"`
		PacketsRepaired            uint64  `json:"packetsRepaired"`
		FramesDropped              uint64  `json:"framesDropped"`
		Keyframes                  uint64  `json:"keyframes"`
		MediaReady                 bool    `json:"mediaReady"`
		KeyframeRequests           uint64  `json:"keyframeRequests"`
		AdmissionDroppedFrames     uint64  `json:"admissionDroppedFrames"`
		DependencySuppressedFrames uint64  `json:"dependencySuppressedFrames"`
		PacingDroppedEvents        uint64  `json:"pacingDroppedEvents"`
		PacketizationFailures      uint64  `json:"packetizationFailures"`
		EstimatedBitrate           int     `json:"estimatedBitrate"`
	}{target, rtt, queued, age, p.sentPackets.Load(), p.receivedPackets.Load(), p.lostPackets.Load(), p.repairedPackets.Load(), p.droppedFrames.Load(), p.keyframes.Load(), ready, p.keyframeRequests.Load(), p.admissionDroppedFrames.Load(), p.dependencySuppressedFrames.Load(), p.pacingDroppedEvents.Load(), p.packetizationFailures.Load(), estimate}
	b, _ := json.Marshal(stats)
	p.emit("statistics", string(b))
}

// Sequence gaps and late arrivals are reported separately, never labelled as
// physical link loss. A bounded window handles RTP uint16 wrap and duplicates.
type packetLossTracker struct {
	initialized bool
	highest     uint16
	missing     map[uint16]bool
}

func (t *packetLossTracker) Push(seq uint16) (uint64, uint64) {
	if !t.initialized {
		t.initialized = true
		t.highest = seq
		t.missing = make(map[uint16]bool)
		return 0, 0
	}
	delta := int16(seq - t.highest)
	if delta > 0 {
		count := uint64(delta - 1)
		if delta > 2048 {
			t.missing = make(map[uint16]bool)
		} else {
			for i := uint16(1); i < uint16(delta); i++ {
				t.missing[t.highest+i] = true
			}
		}
		t.highest = seq
		for key := range t.missing {
			if uint16(seq-key) > 2048 {
				delete(t.missing, key)
			}
		}
		return count, 0
	}
	if t.missing[seq] {
		delete(t.missing, seq)
		return 0, 1
	}
	return 0, 0
}

func (p *Connection) sendRepairFeedback(now time.Time) {
	p.mu.Lock()
	allowed := p.cfg.Role == "viewer" && p.ready && !p.closed && p.authorized && p.mediaGeneration > 0
	generation := p.mediaGeneration
	ssrc := p.remoteSSRC
	p.mu.Unlock()
	if !allowed || ssrc == 0 {
		return
	}
	p.reassemblyMu.Lock()
	if p.repairs.generation != generation {
		p.reassemblyMu.Unlock()
		return
	}
	ids := p.repairs.Due(now, p.repairRTT)
	p.reassemblyMu.Unlock()
	if len(ids) == 0 {
		return
	}
	p.mu.Lock()
	stillAllowed := p.authorized && p.mediaGeneration == generation && !p.closed
	p.mu.Unlock()
	if stillAllowed {
		_ = p.pc.WriteRTCP([]rtcp.Packet{&rtcp.TransportLayerNack{MediaSSRC: ssrc, Nacks: rtcp.NackPairsFromSequenceNumbers(ids)}})
	}
}
