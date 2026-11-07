import Foundation

public enum PeerConnectionState: String, Codable, Sendable {
    case connected, recovering, closed
}

/// Transport counters, not displayed-frame or physical-network measurements.
/// Packet loss is observed missing RTP; repaired packets are counted separately.
public struct TransportStatistics: Codable, Equatable, Sendable {
    public var targetBitrate: Int
    public var rttMS: Double
    public var queuedBytes: Int
    public var queueMS: Double
    public var packetsSent: UInt64
    public var packetsReceived: UInt64
    public var packetsLost: UInt64
    public var packetsRepaired: UInt64
    public var framesDropped: UInt64
    public var keyframes: UInt64
    public var mediaReady: Bool
    public var keyframeRequests: UInt64?
    public var admissionDroppedFrames: UInt64?
    public var dependencySuppressedFrames: UInt64?
    public var pacingDroppedEvents: UInt64?
    public var packetizationFailures: UInt64?
    public var estimatedBitrate: Int?

    public init(targetBitrate: Int = 2_000_000, rttMS: Double = 0, queuedBytes: Int = 0,
                queueMS: Double = 0, packetsSent: UInt64 = 0, packetsReceived: UInt64 = 0,
                packetsLost: UInt64 = 0, packetsRepaired: UInt64 = 0, framesDropped: UInt64 = 0,
                keyframes: UInt64 = 0, mediaReady: Bool = true,
                keyframeRequests: UInt64? = nil, admissionDroppedFrames: UInt64? = nil,
                dependencySuppressedFrames: UInt64? = nil, pacingDroppedEvents: UInt64? = nil,
                packetizationFailures: UInt64? = nil, estimatedBitrate: Int? = nil) {
        self.targetBitrate = targetBitrate; self.rttMS = rttMS; self.queuedBytes = queuedBytes
        self.queueMS = queueMS; self.packetsSent = packetsSent; self.packetsReceived = packetsReceived
        self.packetsLost = packetsLost; self.packetsRepaired = packetsRepaired
        self.framesDropped = framesDropped; self.keyframes = keyframes; self.mediaReady = mediaReady
        self.keyframeRequests = keyframeRequests; self.admissionDroppedFrames = admissionDroppedFrames
        self.dependencySuppressedFrames = dependencySuppressedFrames; self.pacingDroppedEvents = pacingDroppedEvents
        self.packetizationFailures = packetizationFailures
        self.estimatedBitrate = estimatedBitrate
    }

    var isValid: Bool {
        (0...40_000_000).contains(targetBitrate) && (0...64 * 1024 * 1024).contains(queuedBytes) &&
        rttMS.isFinite && (0...120_000).contains(rttMS) &&
        queueMS.isFinite && (0...120_000).contains(queueMS) &&
        (estimatedBitrate.map { (0...40_000_000).contains($0) } ?? true)
    }
}

/// A message transport authenticated by its own connection protocol. Session
/// owners can use direct TLS or the bundled WebRTC engine through the same API.
public protocol RemotePeer: AnyObject {
    /// Connection-specific authenticated binding for persistent device proofs.
    var channelBinding: Data? { get }
    var onReady: (() -> Void)? { get set }
    var onMessage: ((WireMessage) -> Void)? { get set }
    var onClose: ((Error?) -> Void)? { get set }
    var onStatistics: ((TransportStatistics) -> Void)? { get set }
    var onConnectionState: ((PeerConnectionState) -> Void)? { get set }
    /// WebRTC delivers media on a dedicated serial queue. Install before start;
    /// the receiver must validate the capture generation before presentation.
    var onMediaMessage: ((WireMessage) -> Void)? { get set }
    var mediaCapacityAvailable: Bool { get }
    /// True when encoding is gated by one local helper/pacer credit per frame.
    var usesMediaCredits: Bool { get }
    func setMediaAuthorization(_ authorized: Bool, generation: UInt64)
    func start()
    @discardableResult func send(_ message: WireMessage) -> Bool
    func close()
}

public extension RemotePeer {
    // The legacy LAN transport continues to deliver media through onMessage.
    var onStatistics: ((TransportStatistics) -> Void)? { get { nil } set {} }
    var onConnectionState: ((PeerConnectionState) -> Void)? { get { nil } set {} }
    var onMediaMessage: ((WireMessage) -> Void)? { get { nil } set {} }
    var mediaCapacityAvailable: Bool { true }
    var usesMediaCredits: Bool { false }
    func setMediaAuthorization(_ authorized: Bool, generation: UInt64) {}
}

extension SecurePeer: RemotePeer {}
