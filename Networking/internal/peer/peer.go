package peer

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"github.com/pion/interceptor"
	"github.com/pion/interceptor/pkg/cc"
	"github.com/pion/interceptor/pkg/gcc"
	"github.com/pion/interceptor/pkg/nack"
	"github.com/pion/rtcp"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"farreach.local/networking/internal/invitation"
	"farreach.local/networking/internal/video"
	"farreach.local/networking/internal/wire"
	"github.com/pion/ice/v4"
	"github.com/pion/logging"
	"github.com/pion/transport/v5"
	"github.com/pion/webrtc/v4"
)

const controlLabel = "farreach-control-v2"
const pointerLabel = "farreach-pointer-v2"

type Config struct {
	MediaFlowControl bool     `json:"mediaFlowControl,omitempty"`
	ProtocolVersion  int      `json:"protocolVersion"`
	Role             string   `json:"role"`
	Invitation       string   `json:"invitation,omitempty"`
	STUNURLs         []string `json:"stunURLs"`
}
type Event struct {
	Type  string `json:"type"`
	Value string `json:"value"`
}
type Path struct {
	LocalType  string `json:"localType"`
	RemoteType string `json:"remoteType"`
	Protocol   string `json:"protocol"`
}

// Connection has no signaling connection: descriptions are exported/imported by
// the operator. ICE servers are restricted to STUN; TURN/relay candidates fail closed.
type queuedVideo struct {
	sequence uint64
	data     []byte
}

type Connection struct {
	cfg                                                                                                              Config
	output                                                                                                           func(wire.Frame) bool
	pc                                                                                                               *webrtc.PeerConnection
	mu                                                                                                               sync.Mutex
	control, video                                                                                                   *webrtc.DataChannel
	controlOpen, videoOpen, connected, ready, closed, answerApplied                                                  bool
	offer                                                                                                            invitation.Offer
	answerSDP                                                                                                        string
	pendingControls                                                                                                  []wire.Frame
	preReadyVideo                                                                                                    bool
	done                                                                                                             chan struct{}
	closeOnce                                                                                                        sync.Once
	videoQueue                                                                                                       chan queuedVideo
	sequence                                                                                                         uint64
	needSendKeyframe                                                                                                 bool
	dropGeneration                                                                                                   uint64
	lastDrop, lastRequest                                                                                            time.Time
	reassemblyMu                                                                                                     sync.Mutex
	controlSendMu                                                                                                    sync.Mutex
	track                                                                                                            *webrtc.TrackLocalStaticRTP
	sender                                                                                                           *webrtc.RTPSender
	pacer                                                                                                            *boundedPacer
	estimator                                                                                                        cc.BandwidthEstimator
	authorized                                                                                                       bool
	mediaGeneration                                                                                                  uint64
	rtpSequence                                                                                                      uint16
	mediaStart                                                                                                       time.Time
	rtpAssembly                                                                                                      *video.RTPReassembler
	recoveringSince                                                                                                  time.Time
	receivedPackets, sentPackets, lostPackets, repairedPackets, droppedFrames, keyframes                             atomic.Uint64
	keyframeRequests, admissionDroppedFrames, dependencySuppressedFrames, pacingDroppedEvents, packetizationFailures atomic.Uint64
	flowCredit                                                                                                       bool
	flowNeedsGrant                                                                                                   bool
	flowSequence                                                                                                     uint64
	lastStatsNS                                                                                                      atomic.Int64
	remoteSSRC                                                                                                       uint32
	receiverExtension                                                                                                uint8
	loss                                                                                                             packetLossTracker
	repairs                                                                                                          repairScheduler
	repairRTT                                                                                                        time.Duration
}

func ValidateConfig(c Config) error {
	if c.ProtocolVersion != 2 {
		return errors.New("incompatible protocol version; update both Macs")
	}
	if c.Role != "host" && c.Role != "viewer" {
		return errors.New("role must be host or viewer")
	}
	if c.Role == "host" && c.Invitation != "" {
		return errors.New("host cannot import an offer")
	}
	if c.Role == "viewer" && c.Invitation == "" {
		return errors.New("viewer requires an offer invitation")
	}
	if len(c.STUNURLs) > 3 {
		return errors.New("at most three STUN servers are allowed")
	}
	for _, s := range c.STUNURLs {
		if len(s) > 512 || !strings.HasPrefix(s, "stun:") || strings.ContainsAny(s, "/?#@ \t\n\r") {
			return errors.New("only STUN discovery URLs are allowed; TURN is forbidden")
		}
		host := strings.TrimPrefix(s, "stun:")
		if host == "" {
			return errors.New("STUN hostname is missing")
		}
		if strings.Contains(host, ":") {
			h, p, e := net.SplitHostPort(host)
			if e != nil || h == "" {
				return errors.New("invalid STUN address")
			}
			n, e := strconv.Atoi(p)
			if e != nil || n < 1 || n > 65535 {
				return errors.New("invalid STUN port")
			}
		}
	}
	return nil
}
func New(c Config, out func(wire.Frame) bool) (*Connection, error) { return newConnection(c, out, nil) }

// network is injectable only in package tests, never through helper configuration.
func newConnection(c Config, out func(wire.Frame) bool, network transport.Net) (*Connection, error) {
	if err := ValidateConfig(c); err != nil {
		return nil, err
	}
	var offer invitation.Offer
	if c.Role == "viewer" {
		var err error
		offer, err = invitation.ParseOffer(c.Invitation, time.Now())
		if err != nil {
			return nil, err
		}
	}
	settings := webrtc.SettingEngine{}
	if network != nil {
		settings.SetNet(network)
	}
	logger := logging.NewDefaultLoggerFactory()
	logger.DefaultLogLevel = logging.LogLevelDisabled
	logger.Writer = io.Discard
	settings.LoggerFactory = logger
	settings.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4, webrtc.NetworkTypeUDP6})
	settings.SetIncludeLoopbackCandidate(true)
	settings.SetICEMulticastDNSMode(ice.MulticastDNSModeDisabled)
	settings.SetSCTPMaxReceiveBufferSize(2 * 1024 * 1024)
	settings.SetICETimeouts(8*time.Second, invitation.Lifetime, 2*time.Second)
	pacer := newPacer()
	registry := &interceptor.Registry{}
	mediaEngine := &webrtc.MediaEngine{}
	codec := webrtc.RTPCodecParameters{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeH264, ClockRate: 90000, SDPFmtpLine: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=4d0033"}, PayloadType: 96}
	if err := mediaEngine.RegisterCodec(codec, webrtc.RTPCodecTypeVideo); err != nil {
		pacer.Close()
		return nil, err
	}
	if err := mediaEngine.RegisterHeaderExtension(webrtc.RTPHeaderExtensionCapability{URI: video.MetadataURI}, webrtc.RTPCodecTypeVideo); err != nil {
		pacer.Close()
		return nil, err
	}
	var estimator cc.BandwidthEstimator
	controller, err := cc.NewInterceptor(func() (cc.BandwidthEstimator, error) {
		return gcc.NewSendSideBWE(gcc.SendSideBWEInitialBitrate(2_000_000), gcc.SendSideBWEMinBitrate(minimumMediaBitrate), gcc.SendSideBWEMaxBitrate(12_000_000), gcc.SendSideBWEPacer(pacer), gcc.WithLoggerFactory(logger))
	})
	if err != nil {
		pacer.Close()
		return nil, err
	}
	controller.OnNewPeerConnection(func(_ string, e cc.BandwidthEstimator) { estimator = e })
	registry.Add(controller)
	if err = webrtc.ConfigureTWCCHeaderExtensionSender(mediaEngine, registry); err != nil {
		pacer.Close()
		return nil, err
	}
	if err = webrtc.ConfigureNackWithOptions(mediaEngine, registry, []nack.GeneratorOption{nack.GeneratorStreamsFilter(func(*interceptor.StreamInfo) bool { return false }), nack.GeneratorSize(2048), nack.GeneratorMaxNacksPerPacket(2), nack.GeneratorInterval(10 * time.Millisecond), nack.GeneratorSkipLastN(1), nack.WithGeneratorLoggerFactory(logger)}, nack.ResponderSize(2048), nack.WithResponderLoggerFactory(logger)); err != nil {
		pacer.Close()
		return nil, err
	}
	if err = webrtc.ConfigureRTCPReports(registry); err != nil {
		pacer.Close()
		return nil, err
	}
	if err = webrtc.ConfigureStatsInterceptor(registry); err != nil {
		pacer.Close()
		return nil, err
	}
	if err = webrtc.ConfigureTWCCSender(mediaEngine, registry); err != nil {
		pacer.Close()
		return nil, err
	}
	api := webrtc.NewAPI(webrtc.WithSettingEngine(settings), webrtc.WithMediaEngine(mediaEngine), webrtc.WithInterceptorRegistry(registry))
	servers := []webrtc.ICEServer{}
	if len(c.STUNURLs) > 0 {
		servers = append(servers, webrtc.ICEServer{URLs: c.STUNURLs})
	}
	pc, err := api.NewPeerConnection(webrtc.Configuration{ICEServers: servers, ICETransportPolicy: webrtc.ICETransportPolicyAll})
	if err != nil {
		pacer.Close()
		return nil, errors.New("could not create direct networking engine")
	}
	p := &Connection{cfg: c, output: out, pc: pc, done: make(chan struct{}), videoQueue: make(chan queuedVideo, 1), needSendKeyframe: true, offer: offer, pacer: pacer, estimator: estimator, rtpAssembly: video.NewRTPReassembler(), mediaStart: time.Now()}
	pacer.mu.Lock()
	pacer.onDrop = func() { p.pacingDroppedEvents.Add(1); p.videoDropped() }
	pacer.onSent = func() { p.sentPackets.Add(1) }
	pacer.onPressure = p.emitStatistics
	pacer.onDrained = p.maybeGrantMediaCapacity
	pacer.mu.Unlock()
	if p.estimator != nil {
		p.estimator.OnTargetBitrateChange(func(_ int) { p.emitStatistics() })
	}
	pc.OnTrack(p.receiveTrack)
	if c.Role == "host" {
		track, e := webrtc.NewTrackLocalStaticRTP(webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeH264, ClockRate: 90000, SDPFmtpLine: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=4d0033"}, "desktop", "farreach")
		if e != nil {
			pc.Close()
			return nil, e
		}
		p.track = track
		sender, e := pc.AddTrack(track)
		if e != nil {
			pc.Close()
			return nil, e
		}
		p.sender = sender
		go p.readRTCP()
	}
	pc.OnICECandidate(func(candidate *webrtc.ICECandidate) {
		if candidate != nil && candidate.Typ == webrtc.ICECandidateTypeRelay {
			p.fail("relay candidate forbidden")
		}
	})
	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		switch state {
		case webrtc.PeerConnectionStateConnected:
			p.mu.Lock()
			p.connected = true
			p.recoveringSince = time.Time{}
			p.mu.Unlock()
			p.emit("connectionState", "connected")
			p.maybeReady()
			p.maybeGrantMediaCapacity()
		case webrtc.PeerConnectionStateDisconnected:
			p.mu.Lock()
			p.connected = false
			p.recoveringSince = time.Now()
			p.mu.Unlock()
			p.emit("connectionState", "recovering")
		case webrtc.PeerConnectionStateFailed:
			p.fail("direct connection unavailable or interrupted; no relay fallback is enabled")
		case webrtc.PeerConnectionStateClosed:
			go p.Close()
		}
	})
	pc.OnDataChannel(func(dc *webrtc.DataChannel) {
		if c.Role != "viewer" {
			p.fail("unexpected data channel")
			return
		}
		p.attach(dc)
	})
	if c.Role == "host" {
		ordered := true
		control, err := pc.CreateDataChannel(controlLabel, &webrtc.DataChannelInit{Ordered: &ordered})
		if err != nil {
			pc.Close()
			return nil, errors.New("control channel creation failed")
		}
		p.attach(control)
		ordered = false
		zero := uint16(0)
		vid, err := pc.CreateDataChannel(pointerLabel, &webrtc.DataChannelInit{Ordered: &ordered, MaxRetransmits: &zero})
		if err != nil {
			pc.Close()
			return nil, errors.New("video channel creation failed")
		}
		p.attach(vid)
	}
	go p.videoLoop()
	go p.expiryLoop()
	return p, nil
}
func (p *Connection) Done() <-chan struct{} { return p.done }
func (p *Connection) Start() error {
	if p.cfg.Role == "viewer" {
		if err := p.pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: p.offer.SDP}); err != nil {
			return errors.New("offer could not be applied")
		}
	}
	var description webrtc.SessionDescription
	var err error
	if p.cfg.Role == "host" {
		description, err = p.pc.CreateOffer(nil)
	} else {
		description, err = p.pc.CreateAnswer(nil)
	}
	if err != nil {
		return errors.New("could not create connection description")
	}
	gathered := webrtc.GatheringCompletePromise(p.pc)
	if err = p.pc.SetLocalDescription(description); err != nil {
		return errors.New("local description could not be applied")
	}
	select {
	case <-gathered:
	case <-p.done:
		return errors.New("connection cancelled")
	case <-time.After(15 * time.Second):
		return errors.New("address discovery timed out; check the STUN settings")
	}
	local := p.pc.LocalDescription()
	if local == nil {
		return errors.New("no local connection description")
	}
	if err = invitation.ValidateSDP(local.SDP); err != nil {
		return err
	}
	if p.cfg.Role == "host" {
		offer, err := invitation.NewOffer(local.SDP, time.Now())
		if err != nil {
			return err
		}
		p.mu.Lock()
		p.offer = offer
		p.mu.Unlock()
		s, _ := offer.String()
		p.emit("invitation", s)
	} else {
		answer, err := invitation.NewAnswer(p.offer, local.SDP, time.Now())
		if err != nil {
			return err
		}
		p.mu.Lock()
		p.answerSDP = answer.SDP
		p.mu.Unlock()
		s, _ := answer.String()
		p.emit("response", s)
	}
	return nil
}
func (p *Connection) ApplyAnswer(s string) error {
	p.mu.Lock()
	if p.cfg.Role != "host" || p.answerApplied || p.offer.SessionID == "" || p.closed {
		p.mu.Unlock()
		return errors.New("no unused host invitation is waiting for an answer")
	}
	offer := p.offer
	p.mu.Unlock()
	answer, err := invitation.ParseAnswer(s, offer, time.Now())
	if err != nil {
		return err
	}
	p.mu.Lock()
	if p.answerApplied || p.closed {
		p.mu.Unlock()
		return errors.New("answer already consumed")
	}
	p.answerSDP = answer.SDP
	p.answerApplied = true
	p.mu.Unlock()
	if err = p.pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: answer.SDP}); err != nil {
		return errors.New("authenticated answer could not be applied")
	}
	return nil
}
func (p *Connection) attach(dc *webrtc.DataChannel) {
	p.mu.Lock()
	switch dc.Label() {
	case controlLabel:
		if p.control != nil || !dc.Ordered() || dc.MaxRetransmits() != nil || dc.MaxPacketLifeTime() != nil {
			p.mu.Unlock()
			p.fail("invalid control channel")
			return
		}
		p.control = dc
	case pointerLabel:
		if p.video != nil || dc.Ordered() || dc.MaxRetransmits() == nil || *dc.MaxRetransmits() != 0 || dc.MaxPacketLifeTime() != nil {
			p.mu.Unlock()
			p.fail("invalid video channel")
			return
		}
		p.video = dc
	default:
		p.mu.Unlock()
		p.fail("unknown data channel")
		return
	}
	p.mu.Unlock()
	dc.OnOpen(func() {
		p.mu.Lock()
		if dc.Label() == controlLabel {
			p.controlOpen = true
		} else {
			p.videoOpen = true
		}
		p.mu.Unlock()
		p.maybeReady()
	})
	dc.OnClose(func() { p.fail("remote channel closed") })
	dc.OnError(func(error) { p.fail("remote channel failed") })
	dc.OnMessage(func(message webrtc.DataChannelMessage) {
		if message.IsString {
			p.fail("text data-channel messages are forbidden")
			return
		}
		if dc.Label() == controlLabel {
			f, err := wire.Decode(message.Data)
			if err != nil || !wire.IsControlKind(f.Kind) {
				p.fail("invalid control message")
				return
			}
			p.mu.Lock()
			if p.closed {
				p.mu.Unlock()
				return
			}
			if !p.ready {
				if len(p.pendingControls) >= 16 {
					p.mu.Unlock()
					p.fail("pre-ready message bound exceeded")
					return
				}
				f.Payload = append([]byte(nil), f.Payload...)
				p.pendingControls = append(p.pendingControls, f)
				p.mu.Unlock()
				return
			}
			p.mu.Unlock()
			if !p.output(f) {
				p.fail("application control output exceeded its bound")
			}
		} else {
			f, err := wire.Decode(message.Data)
			if err != nil || f.Kind != wire.Pointer || p.cfg.Role != "host" {
				p.fail("invalid pointer message")
				return
			}
			p.mu.Lock()
			admitted := p.ready && !p.closed && p.authorized && p.mediaGeneration > 0
			p.mu.Unlock()
			if admitted {
				p.output(f)
			} // Pointer snapshots are replaceable, never fatal under pressure.

		}
	})
}
func (p *Connection) maybeReady() {
	p.mu.Lock()
	eligible := p.controlOpen && p.videoOpen && p.connected && !p.closed && !p.ready && (p.cfg.Role == "viewer" || p.answerApplied) && p.answerSDP != ""
	p.mu.Unlock()
	if !eligible {
		return
	}
	pair, err := p.pc.SCTP().Transport().ICETransport().GetSelectedCandidatePair()
	if err != nil || !ValidPair(pair) {
		p.fail("a direct non-relay candidate pair was not selected")
		return
	}
	p.mu.Lock()
	if p.ready || p.closed {
		p.mu.Unlock()
		return
	}
	// Both channels are open, DTLS fingerprints are checked, and host's answer was
	// authenticated before its remote fingerprint was accepted.
	path, _ := json.Marshal(Path{pair.Local.Typ.String(), pair.Remote.Typ.String(), pair.Local.Protocol.String()})
	p.emit("path", string(path))
	binding := connectionBinding(p.offer.SDP, p.answerSDP)
	p.emit("binding", base64.RawURLEncoding.EncodeToString(binding[:]))
	p.emit("ready", "direct")
	for _, frame := range p.pendingControls {
		if !p.output(frame) {
			p.mu.Unlock()
			p.fail("application output congested at connection start")
			return
		}
	}
	p.pendingControls = nil
	requestFrame := p.preReadyVideo
	p.preReadyVideo = false
	p.ready = true
	p.mu.Unlock()
	if requestFrame {
		p.requestKeyframe()
	}
	p.pc.SCTP().Transport().ICETransport().OnSelectedCandidatePairChange(func(pair *webrtc.ICECandidatePair) {
		if !ValidPair(pair) {
			p.fail("relay path forbidden")
			return
		}
		b, _ := json.Marshal(Path{pair.Local.Typ.String(), pair.Remote.Typ.String(), pair.Local.Protocol.String()})
		p.emit("path", string(b))
	})
}

// Bind identity proofs above this transport to the exact descriptions whose
// DTLS certificate fingerprints Pion authenticates, with unambiguous lengths.
func connectionBinding(offerSDP, answerSDP string) [32]byte {
	hash := sha256.New()
	hash.Write([]byte("FarReach-channel-v1\x00"))
	var length [4]byte
	for _, description := range []string{offerSDP, answerSDP} {
		binary.BigEndian.PutUint32(length[:], uint32(len(description)))
		hash.Write(length[:])
		hash.Write([]byte(description))
	}
	var result [32]byte
	copy(result[:], hash.Sum(nil))
	return result
}

func ValidPair(pair *webrtc.ICECandidatePair) bool {
	if pair == nil || pair.Local == nil || pair.Remote == nil {
		return false
	}
	for _, c := range []*webrtc.ICECandidate{pair.Local, pair.Remote} {
		if c.Typ != webrtc.ICECandidateTypeHost && c.Typ != webrtc.ICECandidateTypeSrflx && c.Typ != webrtc.ICECandidateTypePrflx {
			return false
		}
		if c.Protocol != webrtc.ICEProtocolUDP {
			return false
		}
	}
	return true
}
func (p *Connection) Send(f wire.Frame) error {
	if !wire.IsApplicationKind(f.Kind) {
		return errors.New("unknown application message")
	}
	limit, _ := wire.Limit(f.Kind)
	if len(f.Payload) > limit {
		return errors.New("application message exceeds its limit")
	}
	p.mu.Lock()
	ready := p.ready && !p.closed
	p.mu.Unlock()
	if !ready {
		return errors.New("connection is not ready")
	}
	if f.Kind == wire.Pointer {
		p.mu.Lock()
		dc := p.video
		allowed := p.cfg.Role == "viewer" && p.authorized && p.mediaGeneration > 0
		p.mu.Unlock()
		if !allowed {
			return nil
		}
		if dc == nil || dc.BufferedAmount() > 4096 {
			return nil
		}
		b, e := wire.Encode(f)
		if e != nil {
			return e
		}
		return dc.Send(b)
	}
	if f.Kind == wire.Video {
		p.mu.Lock()
		allowed := p.cfg.Role == "host" && p.authorized && p.mediaGeneration > 0
		generation := p.mediaGeneration
		p.mu.Unlock()
		if !allowed {
			return nil
		}
		if len(f.Payload) < 12 || string(f.Payload[:4]) != "FRS1" || binary.BigEndian.Uint64(f.Payload[4:12]) != generation {
			return nil
		}
		if !video.ValidFrame(f.Payload) {
			return errors.New("invalid H.264 frame")
		}
		p.mu.Lock()
		if p.cfg.MediaFlowControl && !p.flowCredit {
			p.mu.Unlock()
			return errors.New("video sent without a local capacity grant")
		}
		p.sequence++
		seq := p.sequence
		if p.cfg.MediaFlowControl {
			p.flowCredit = false
			p.flowNeedsGrant = false
			p.flowSequence = seq
			p.emitMediaCapacityLocked(false)
		}
		p.mu.Unlock()
		select {
		case p.videoQueue <- queuedVideo{seq, f.Payload}:
		default:
			p.admissionDroppedFrames.Add(1)
			p.videoDropped()
			p.completeMediaFlow(generation, seq)
		}
		return nil
	}
	return p.sendControl(f)
}
func (p *Connection) sendControl(f wire.Frame) error {
	p.controlSendMu.Lock()
	defer p.controlSendMu.Unlock()
	p.mu.Lock()
	dc := p.control
	ready := p.ready && !p.closed
	p.mu.Unlock()
	if !ready || dc == nil {
		return errors.New("control channel unavailable")
	}
	if dc.BufferedAmount() > 64*1024 {
		return errors.New("control channel congested")
	}
	b, err := wire.Encode(f)
	if err != nil {
		return err
	}
	if err = dc.Send(b); err != nil {
		return errors.New("control send failed")
	}
	return nil
}
func (p *Connection) videoLoop() {
	for {
		select {
		case <-p.done:
			return
		case queued := <-p.videoQueue:
			p.processVideo(queued)
		}
	}
}
func (p *Connection) processVideo(queued queuedVideo) {
	generationOfFrame := uint64(0)
	if len(queued.data) >= 12 {
		generationOfFrame = binary.BigEndian.Uint64(queued.data[4:12])
	}
	defer p.completeMediaFlow(generationOfFrame, queued.sequence)
	p.mu.Lock()
	generation := p.dropGeneration
	admitted := p.ready && !p.closed && p.authorized && p.connected
	needsKey := p.needSendKeyframe
	captureGeneration := p.mediaGeneration
	p.mu.Unlock()
	if !admitted || len(queued.data) < 12 || binary.BigEndian.Uint64(queued.data[4:12]) != captureGeneration {
		return
	}
	if needsKey && !video.IsKeyframe(queued.data) {
		p.suppressDependentVideo()
		return
	}
	id := uint8(0)
	for _, ext := range p.sender.GetParameters().HeaderExtensions {
		if ext.URI == video.MetadataURI {
			id = uint8(ext.ID)
		}
	}
	if id == 0 {
		p.fail("required media extension missing")
		return
	}
	packets, err := video.Packetize(queued.data, queued.sequence, uint32(time.Since(p.mediaStart).Seconds()*90000), p.rtpSequence, id)
	if err != nil {
		p.packetizationFailures.Add(1)
		p.videoDropped()
		return
	}
	m, _ := video.ParseMetadata(packets[0].GetExtension(id))
	size := 0
	for _, packet := range packets {
		size += packet.MarshalSize() + 8
	}
	if !p.pacer.BeginFrame(m, size, id) {
		p.admissionDroppedFrames.Add(1)
		p.videoDropped()
		return
	}
	p.rtpSequence += uint16(len(packets))
	dropped := false
	for _, packet := range packets {
		if err = p.track.WriteRTP(packet); err != nil {
			dropped = true
			break
		}
	}
	if dropped {
		p.pacingDroppedEvents.Add(1)
		p.videoDropped()
	} else {
		if m.Keyframe {
			p.keyframes.Add(1)
		}
		p.completeVideo(generation)
	}
}
func (p *Connection) completeVideo(generation uint64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.dropGeneration == generation {
		p.needSendKeyframe = false
	}
}
func (p *Connection) videoDropped() { p.requireOutgoingKeyframe(true) }
func (p *Connection) forwardKeyframeRequest() {
	p.keyframeRequests.Add(1)
	p.requireOutgoingKeyframe(false)
}
func (p *Connection) requireOutgoingKeyframe(actualDrop bool) {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return
	}
	if actualDrop {
		p.droppedFrames.Add(1)
	}
	p.needSendKeyframe = true
	p.dropGeneration++
	notify := time.Since(p.lastDrop) >= 250*time.Millisecond
	if notify {
		p.lastDrop = time.Now()
	}
	p.mu.Unlock()
	if notify {
		p.emit("videoDropped", "send a fresh keyframe")
	}
}

// Waiting for a requested IDR is dependency suppression, not new evidence of
// queue congestion. Repeated deltas must not repeatedly downshift the encoder.
func (p *Connection) suppressDependentVideo() {
	p.dependencySuppressedFrames.Add(1)
	p.mu.Lock()
	notify := !p.closed && time.Since(p.lastDrop) >= 250*time.Millisecond
	if notify {
		p.lastDrop = time.Now()
	}
	p.mu.Unlock()
	if notify {
		p.emit("videoDropped", "waiting for requested keyframe")
	}
}
func (p *Connection) requestKeyframe() {
	p.mu.Lock()
	notify := time.Since(p.lastRequest) >= 250*time.Millisecond
	if notify {
		p.lastRequest = time.Now()
	}
	p.mu.Unlock()
	if notify {
		p.mu.Lock()
		ssrc := p.remoteSSRC
		authorized := p.authorized
		p.mu.Unlock()
		if ssrc != 0 && authorized {
			if p.pc.WriteRTCP([]rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: ssrc}}) == nil {
				return
			}
		}
		if err := p.sendControl(wire.Frame{Kind: wire.RequestKeyframe}); err != nil {
			p.fail("keyframe request failed")
		}
	}
}
func (p *Connection) expiryLoop() {
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()
	lastStats := time.Now()
	for {
		select {
		case <-p.done:
			return
		case now := <-ticker.C:
			p.reassemblyMu.Lock()
			frames, lost, err := p.rtpAssembly.Tick(now)
			p.reassemblyMu.Unlock()
			p.deliverMedia(frames, lost, err)
			p.sendRepairFeedback(now)
			p.mu.Lock()
			waiting := !p.ready
			expiry := p.offer.Expires
			recovering := p.recoveringSince
			ready := p.ready
			p.mu.Unlock()
			if waiting && expiry > 0 && now.Unix() >= expiry {
				p.fail("pairing invitation expired")
				return
			}
			if !recovering.IsZero() && now.Sub(recovering) > 10*time.Second {
				p.fail("direct path recovery timed out")
				return
			}
			if ready && now.Sub(lastStats) >= time.Second {
				p.emitStatistics()
				lastStats = now
			}
		}
	}
}
func (p *Connection) emit(kind, value string) {
	b, _ := json.Marshal(Event{kind, value})
	if !p.output(wire.Frame{Kind: wire.Event, Payload: b}) {
		go p.Close()
	}
}
func (p *Connection) fail(message string) {
	p.mu.Lock()
	closed := p.closed
	p.mu.Unlock()
	if closed {
		return
	}
	p.emit("error", message)
	go p.Close()
}
func (p *Connection) Close() {
	p.closeOnce.Do(func() {
		p.mu.Lock()
		p.closed = true
		p.mu.Unlock()
		close(p.done)
		if p.pacer != nil {
			p.pacer.Close()
		}
		p.pc.Close()
		p.emit("closed", "connection closed")
	})
}
