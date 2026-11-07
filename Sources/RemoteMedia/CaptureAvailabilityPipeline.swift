import Foundation
import CoreVideo
import CoreMedia
import ScreenCaptureKit

/// A random-seeded, process-wide clock keeps epochs distinct across streamer
/// instances as well as across suspensions of one streamer. These values are
/// ordering tags, not credentials.
enum CaptureGenerationClock {
    private static let lock = NSLock()
    private static var value = UInt64.random(in: 1...(UInt64.max - 1_000_000))
    static func next() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        value &+= 1
        if value == 0 { value = 1 }
        return value
    }
}

struct CaptureAvailabilityState {
    private(set) var generation = CaptureGenerationClock.next()
    private(set) var isAvailable = false

    mutating func begin() -> UInt64 {
        generation = CaptureGenerationClock.next()
        isAvailable = false
        return generation
    }
    mutating func resume() -> UInt64 {
        generation = CaptureGenerationClock.next()
        isAvailable = true
        return generation
    }
    mutating func invalidate(force: Bool = false) -> UInt64? {
        guard isAvailable || force else { return nil }
        generation = CaptureGenerationClock.next()
        isAvailable = false
        return generation
    }
}

/// Owns the disposable encoding pipeline for one capture stream. All methods
/// and callbacks execute on queue. `.idle` preserves a valid static image;
/// unavailable states destroy the old encoder/cache so late outputs cannot be
/// mistaken for the resumed display.
final class CaptureAvailabilityPipeline {
    private let queue: DispatchQueue
    private var configuration: StreamConfiguration
    private var width: Int
    private var height: Int
    private let onFrame: (EncodedFrame, UInt64) -> Void
    private let onAvailability: (Bool, UInt64) -> Void
    private let onError: (Error) -> Void
    private let canEncode: () -> Bool
    private let onStatistics: (MediaPipelineStatistics) -> Void
    private var state = CaptureAvailabilityState()
    private var pipeline: FrameEncodingPipeline?
    private var active = true

    init(width: Int, height: Int, configuration: StreamConfiguration, queue: DispatchQueue,
         onFrame: @escaping (EncodedFrame, UInt64) -> Void,
         onAvailability: @escaping (Bool, UInt64) -> Void,
         onError: @escaping (Error) -> Void, canEncode: @escaping () -> Bool = { true },
         onStatistics: @escaping (MediaPipelineStatistics) -> Void = { _ in }) {
        self.width = width; self.height = height; self.configuration = configuration
        self.queue = queue; self.onFrame = onFrame
        self.onAvailability = onAvailability; self.onError = onError
        self.canEncode = canEncode; self.onStatistics = onStatistics
        dispatchPrecondition(condition: .onQueue(queue))
        onAvailability(false, state.begin())
    }

    func receive(status: SCFrameStatus?, image: CVPixelBuffer?, presentationTime: CMTime) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard active else { return }
        switch status {
        case .idle, .started:
            // Neither status establishes a new pixel buffer. In particular,
            // an idle buffer without an image is normal for a static desktop.
            return
        case .blank, .suspended, .stopped, nil:
            invalidate()
            return
        case .complete:
            guard image != nil else { invalidate(); return }
        @unknown default:
            invalidate()
            return
        }
        guard let image, CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height else { return }
        do {
            if pipeline == nil {
                let epoch = state.resume()
                pipeline = try FrameEncodingPipeline(width: width, height: height, configuration: configuration, queue: queue,
                    onFrame: { [weak self] frame in
                        guard let self, self.active, self.state.isAvailable, self.state.generation == epoch else { return }
                        self.onFrame(frame, epoch)
                    },
                    onError: { [weak self] error in
                        guard let self, self.active, self.state.generation == epoch else { return }
                        self.invalidate()
                        self.onError(error)
                    }, canEncode: canEncode, onStatistics: onStatistics)
                onAvailability(true, epoch)
            }
            pipeline?.receive(image, presentationTime: presentationTime)
        } catch {
            invalidate()
            onError(error)
        }
    }

    func requestKeyframe() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard active, state.isAvailable else { return }
        pipeline?.requestKeyframe()
    }

    func updateConfiguration(_ configuration: StreamConfiguration, width: Int, height: Int) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard active else { return }
        if self.width != width || self.height != height {
            invalidate()
            self.width = width; self.height = height
        } else {
            try pipeline?.updateConfiguration(configuration)
        }
        self.configuration = configuration
    }

    func invalidate() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard active else { return }
        // Mark the old pipeline inactive before draining VideoToolbox. Any
        // callbacks it already queued will fail its active/epoch checks.
        pipeline?.stop()
        pipeline = nil
        if let epoch = state.invalidate() { onAvailability(false, epoch) }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard active else { return }
        pipeline?.stop(); pipeline = nil
        active = false
        if let epoch = state.invalidate(force: true) { onAvailability(false, epoch) }
    }
}
