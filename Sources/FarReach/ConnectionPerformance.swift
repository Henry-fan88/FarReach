import Foundation
import RemoteCore
import RemoteMedia

/// Monotonic deadlines are unaffected by wall-clock synchronization or travel.
struct RecoveryPolicy {
    static let grace: TimeInterval = 2
    static let budget: TimeInterval = 60
    static func retryDelay(attempt: Int) -> TimeInterval { min(8, pow(2, Double(max(0, attempt)))) }
    static func permitsRetry(started: TimeInterval, now: TimeInterval) -> Bool { now - started < budget }
}

/// Dependency suppression and a request for an IDR are recovery signals, not
/// additional evidence that the network queue is congested.
enum TransportPressure {
    static func feedbackQueueMS(_ current: TransportStatistics, previous: TransportStatistics?, usesMediaCredits: Bool) -> Double {
        // A credit-controlled sender has at most one original frame in flight.
        // Its IDR pacing time is intentional, not an accumulating frame backlog.
        let backlog = usesMediaCredits ? 0 : current.queueMS
        return max(backlog, hasNewAdmissionOrPacingDrop(current, after: previous) ? 160 : 0)
    }
    static func hasNewAdmissionOrPacingDrop(_ current: TransportStatistics, after previous: TransportStatistics?) -> Bool {
        func increased(_ value: UInt64?, _ old: UInt64?) -> Bool {
            guard let value else { return false }
            return value > (old ?? 0)
        }
        return increased(current.admissionDroppedFrames, previous?.admissionDroppedFrames) ||
            increased(current.pacingDroppedEvents, previous?.pacingDroppedEvents)
    }
}

/// The UI and media queue share only this small authorization/counter mailbox.
/// No encoded frame is retained, and generations are checked again at display.
final class MediaSessionMailbox {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var needsKeyframe = true
    private var keyframeRevision: UInt64 = 0
    private var frames = 0
    private var bytes = 0
    private var drops = 0
    private var encodeMilliseconds: Double?
    private var lastFrameID: UInt64?
    private var pipeline: MediaPipelineStatistics?
    func recordPipeline(_ statistics: MediaPipelineStatistics) { lock.lock(); pipeline = statistics; lock.unlock() }
    func authorize(_ generation: UInt64) {
        lock.lock(); self.generation = generation; needsKeyframe = true; keyframeRevision &+= 1; lock.unlock()
    }
    func permits(_ generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation != 0 && self.generation == generation
    }
    func requireKeyframe() { lock.lock(); needsKeyframe = true; keyframeRevision &+= 1; lock.unlock() }
    func send(_ frame: EncodedFrame, generation: UInt64, peer: any RemotePeer) throws -> Bool {
        lock.lock()
        let admitted = generation != 0 && self.generation == generation && (!needsKeyframe || frame.isKeyframe)
        let revision = keyframeRevision
        lock.unlock()
        guard admitted else { return false }
        let payload = try StreamFrameEnvelope(generation: generation, frame: frame.serialized()).encoded()
        guard permits(generation) else { return false }
        let sent = peer.send(WireMessage(kind: .video, payload: payload))
        lock.lock()
        if self.generation == generation {
            if sent {
                frames += 1; bytes += payload.count
                if revision == keyframeRevision { needsKeyframe = false }
                encodeMilliseconds = Self.encodeDuration(frame)
                lastFrameID = frame.frameID
            }
            else { drops += 1; needsKeyframe = true; keyframeRevision &+= 1 }
        }
        lock.unlock()
        return sent
    }
    static func encodeDuration(_ frame: EncodedFrame) -> Double? {
        guard frame.captureTimeNanoseconds > 0, frame.encodedTimeNanoseconds >= frame.captureTimeNanoseconds else { return nil }
        let value = Double(frame.encodedTimeNanoseconds - frame.captureTimeNanoseconds) / 1_000_000
        return value <= 60_000 ? value : nil
    }
    func drain() -> (frames: Int, bytes: Int, drops: Int, encodeMilliseconds: Double?, frameID: UInt64?, pipeline: MediaPipelineStatistics?) {
        lock.lock(); defer { lock.unlock() }
        let result = (frames, bytes, drops, encodeMilliseconds, lastFrameID, pipeline)
        frames = 0; bytes = 0; drops = 0
        return result
    }
}

struct DecodedFrameDelivery {
    let generation: UInt64
    let epoch: UInt64
    let prepared: PreparedMediaFrame
    let preparationMilliseconds: Double
    let preparedAt: TimeInterval
    var payloadBytes: Int
}

/// Every compressed reference is decoded on the media queue. Only independent
/// pixels may be replaced while the UI is busy; retain one latest pixel frame
/// and schedule at most one pending presentation callback per transport.
final class LatestDecodedFrameMailbox {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var epoch: UInt64 = 0
    private var latest: DecodedFrameDelivery?
    private var scheduled = false

    func authorize(_ generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        self.generation = generation
        epoch &+= 1
        latest = nil
        // Keep an already queued callback: it can consume the newest authorized
        // pixels, or become a harmless no-op. Never queue a second callback.
    }
    func token(for generation: UInt64) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return generation != 0 && self.generation == generation ? epoch : nil
    }
    func permits(generation: UInt64, epoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation != 0 && self.generation == generation && self.epoch == epoch
    }
    /// Returns true only when the caller must schedule a presentation callback.
    func publish(_ delivery: DecodedFrameDelivery) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard delivery.prepared.isDecoded, delivery.generation != 0,
              delivery.generation == generation, delivery.epoch == epoch else { return false }
        var newest = delivery
        newest.payloadBytes += latest?.payloadBytes ?? 0
        latest = newest
        guard !scheduled else { return false }
        scheduled = true
        return true
    }
    func take() -> DecodedFrameDelivery? {
        lock.lock(); defer { lock.unlock() }
        let result = latest
        latest = nil; scheduled = false
        return result
    }
}

struct PerformanceSample: Codable {
    let elapsedSeconds: Double
    let applicationRTTMilliseconds: Double?
    let transportRTTMilliseconds: Double?
    let sendQueueMilliseconds: Double?
    let targetBitrate: Int?
    let encodedMegabitsPerSecond: Double
    let admittedFramesPerSecond: Int
    let packetsReceived: UInt64?
    let packetsLost: UInt64?
    let packetsRepaired: UInt64?
    let framesDropped: UInt64?
    let captureToEncodeMilliseconds: Double?
    let localPreparationMilliseconds: Double?
    let localMainHandoffMilliseconds: Double?
    let frameID: UInt64?
    let capturedFrames: UInt64?
    let skippedBeforeEncoding: UInt64?
    let encoderDroppedFrames: UInt64?
    let recoveryRequests: UInt64?
    let enqueueGapEvents: UInt64
    let longestEnqueueGapMilliseconds: Double
    var remoteHostPerformance: HostPerformanceSnapshot? = nil
}

struct PerformanceReport: Codable {
    let formatVersion: Int
    let transport: String
    let quality: String
    let samples: [PerformanceSample]
    let measurementNotes: [String]
    let summary: PerformanceSummary
    let remoteHostPerformance: HostPerformanceSnapshot?

    init(formatVersion: Int, transport: String, quality: String, samples: [PerformanceSample], measurementNotes: [String],
         remoteHostPerformance: HostPerformanceSnapshot? = nil) {
        self.formatVersion = formatVersion; self.transport = transport; self.quality = quality
        self.samples = samples; self.measurementNotes = measurementNotes
        summary = PerformanceSummary(samples: samples)
        self.remoteHostPerformance = remoteHostPerformance
    }
}

struct PerformanceDistribution: Codable {
    let count: Int
    let p50: Double?
    let p95: Double?
    let maximum: Double?

    init(_ values: [Double]) {
        let valid = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        count = valid.count
        func percentile(_ fraction: Double) -> Double? {
            guard !valid.isEmpty else { return nil }
            return valid[max(0, Int(ceil(Double(valid.count) * fraction)) - 1)]
        }
        p50 = percentile(0.5); p95 = percentile(0.95); maximum = valid.last
    }
}

struct PerformanceSummary: Codable {
    let applicationRTTMilliseconds: PerformanceDistribution
    let captureToEncodeMilliseconds: PerformanceDistribution
    let localPreparationMilliseconds: PerformanceDistribution
    let localMainHandoffMilliseconds: PerformanceDistribution
    let sendQueueMilliseconds: PerformanceDistribution

    init(samples: [PerformanceSample]) {
        applicationRTTMilliseconds = .init(samples.compactMap(\.applicationRTTMilliseconds))
        captureToEncodeMilliseconds = .init(samples.compactMap(\.captureToEncodeMilliseconds))
        localPreparationMilliseconds = .init(samples.compactMap(\.localPreparationMilliseconds))
        localMainHandoffMilliseconds = .init(samples.compactMap(\.localMainHandoffMilliseconds))
        sendQueueMilliseconds = .init(samples.compactMap(\.sendQueueMilliseconds))
    }
}
