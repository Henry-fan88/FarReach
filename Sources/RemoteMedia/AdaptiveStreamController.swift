import Foundation

public struct StreamFeedback: Sendable {
    public var availableBitrate: Int?
    public var rttMilliseconds: Double?
    public var lossFraction: Double
    public var sendQueueMilliseconds: Double
    public var decodeQueueMilliseconds: Double
    public init(availableBitrate: Int? = nil, rttMilliseconds: Double? = nil, lossFraction: Double = 0,
                sendQueueMilliseconds: Double = 0, decodeQueueMilliseconds: Double = 0) {
        self.availableBitrate = availableBitrate; self.rttMilliseconds = rttMilliseconds
        self.lossFraction = lossFraction; self.sendQueueMilliseconds = sendQueueMilliseconds
        self.decodeQueueMilliseconds = decodeQueueMilliseconds
    }
}

/// Quality ceilings express user intent. Network pressure can always lower the
/// current configuration; recovery requires sustained healthy feedback.
public struct AdaptiveStreamController: Sendable {
    public let maximum: StreamConfiguration
    public private(set) var configuration: StreamConfiguration
    private var lastUpdate: TimeInterval?
    private var healthySince: TimeInterval?
    private var constrainedSince: TimeInterval?
    private var lastGeometryChange: TimeInterval?

    public init(maximum: StreamConfiguration = .automaticMaximum, automatic: Bool = true) {
        self.maximum = StreamConfiguration(maxDimension: maximum.maxDimension, framesPerSecond: maximum.framesPerSecond, bitrate: maximum.bitrate)
        configuration = automatic
            ? .init(maxDimension: min(maximum.maxDimension, 1280), framesPerSecond: min(maximum.framesPerSecond, 30), bitrate: min(maximum.bitrate, 2_000_000))
            : self.maximum
    }

    public mutating func update(_ feedback: StreamFeedback, now: TimeInterval) -> StreamConfiguration? {
        guard now.isFinite, lastUpdate.map({ now >= $0 + 0.2 }) ?? true else { return nil }
        let elapsed = min(2, max(0.2, now - (lastUpdate ?? (now - 1))))
        lastUpdate = now
        let loss = feedback.lossFraction.isFinite ? max(0, min(1, feedback.lossFraction)) : 1
        let queue = max(feedback.sendQueueMilliseconds.isFinite ? feedback.sendQueueMilliseconds : 1000,
                        feedback.decodeQueueMilliseconds.isFinite ? feedback.decodeQueueMilliseconds : 1000)
        // Go's congestion controller owns network-delay estimation. An RTT
        // sample can remain elevated after a route or scheduling change even
        // when capacity is healthy; repeatedly comparing it to a lifetime low
        // would incorrectly drive this independent controller to its floor.
        let pressure = loss >= 0.03 || queue > 60
        let severe = loss >= 0.10 || queue > 150
        let budget = feedback.availableBitrate.map { max(500_000, min(maximum.bitrate, Int(Double(max(0, $0)) * 0.85))) }
        var next = configuration
        if pressure || budget.map({ $0 < configuration.bitrate }) == true {
            healthySince = nil
            constrainedSince = constrainedSince ?? now
            let reduced = pressure ? Int(Double(configuration.bitrate) * (severe ? 0.65 : 0.80)) : configuration.bitrate
            next.bitrate = max(500_000, min(reduced, budget ?? maximum.bitrate))
        } else {
            constrainedSince = nil
            healthySince = healthySince ?? now
            if now - (healthySince ?? now) >= 3 {
                let increment = max(100_000, Int(Double(configuration.bitrate) * 0.15 * elapsed))
                next.bitrate = min(maximum.bitrate, budget ?? maximum.bitrate, configuration.bitrate + increment)
            }
        }
        // Reconfiguration is more expensive than a rate update. Downshift after
        // persistent pressure; grow only after healthy feedback and a cooldown.
        let canResize = lastGeometryChange.map { now - $0 >= 5 } ?? true
        let constrained = constrainedSince.map { now - $0 >= 2 } ?? false
        let healthy = healthySince.map { now - $0 >= 5 } ?? false
        if canResize && (constrained || healthy) {
            let dimension = next.bitrate >= 6_000_000 ? 1920 : next.bitrate >= 1_800_000 ? 1280 : next.bitrate >= 900_000 ? 960 : 640
            let fps = next.bitrate >= 8_000_000 && !pressure ? 60 : next.bitrate >= 1_200_000 ? 30 : 20
            let desiredDimension = min(maximum.maxDimension, dimension)
            let desiredFPS = min(maximum.framesPerSecond, fps)
            if constrained {
                next.maxDimension = min(configuration.maxDimension, desiredDimension)
                next.framesPerSecond = min(configuration.framesPerSecond, desiredFPS)
            } else {
                next.maxDimension = desiredDimension; next.framesPerSecond = desiredFPS
            }
            if next.maxDimension != configuration.maxDimension || next.framesPerSecond != configuration.framesPerSecond {
                lastGeometryChange = now
            }
        }
        guard next != configuration else { return nil }
        configuration = next
        return next
    }
}

public struct MediaPipelineStatistics: Sendable {
    public var capturedFrames: UInt64 = 0
    public var encodedFrames: UInt64 = 0
    /// Skipped encoding attempts, including retries of a cached capture. This
    /// can exceed capturedFrames and is not a frame-loss or packet-loss count.
    public var skippedBeforeEncoding: UInt64 = 0
    public var encoderDroppedFrames: UInt64 = 0
    public var recoveryRequests: UInt64 = 0
    public var keyframes: UInt64 = 0
    public var lastEncodeMilliseconds: Double = 0
    public var dataRateLimitSupported: Bool?
    public init() {}
}
