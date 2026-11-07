import Foundation
import CoreVideo
import CoreMedia

/// Serial capture/encoder coordinator. Retains only the newest capture buffer so
/// an IDR request can recover a static desktop without waiting for screen motion.
/// receive/stop run on queue; requestKeyframe is safe from any queue.
final class FrameEncodingPipeline {
    private let queue: DispatchQueue
    private let encoder: H264Encoder
    private let onFrame: (EncodedFrame) -> Void
    private let onError: (Error) -> Void
    private let canEncode: () -> Bool
    private let onStatistics: (MediaPipelineStatistics) -> Void
    private var latestImage: CVPixelBuffer?
    private var latestCaptureTime: UInt64 = 0
    private var latestNeedsEncoding = false
    private var lastPresentationTime = CMTime.invalid
    private var recoveryWork: DispatchWorkItem?
    private var rawRetryWork: DispatchWorkItem?
    private var recoveryPending = false
    private var lastRecoveryAttempt: TimeInterval?
    private var statistics = MediaPipelineStatistics()
    private var encoding = false
    private var active = true

    init(width: Int, height: Int, configuration: StreamConfiguration, queue: DispatchQueue,
         onFrame: @escaping (EncodedFrame) -> Void, onError: @escaping (Error) -> Void,
         canEncode: @escaping () -> Bool = { true }, onStatistics: @escaping (MediaPipelineStatistics) -> Void = { _ in }) throws {
        self.queue = queue
        self.encoder = try H264Encoder(width: width, height: height, configuration: configuration)
        self.statistics.dataRateLimitSupported = encoder.dataRateLimitSupported
        self.onFrame = onFrame
        self.onError = onError
        self.canEncode = canEncode; self.onStatistics = onStatistics
        encoder.onFrame = { [weak self] frame in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, self.active else { return }
                // An encoder callback may complete before this capture-queue
                // handoff runs. Keep one submission reserved until onFrame has
                // actually forwarded it and consumed the transport's credit.
                defer {
                    self.encoding = false
                    self.scheduleRawRetry()
                }
                self.statistics.encodedFrames += 1
                if frame.isKeyframe {
                    self.statistics.keyframes += 1
                    self.recoveryPending = false
                    self.recoveryWork?.cancel(); self.recoveryWork = nil
                }
                self.onStatistics(self.statistics)
                self.onFrame(frame)
            }
        }
        encoder.onEncodingCompleted = { [weak self] duration, dropped in
            self?.queue.async { [weak self] in
                guard let self, self.active else { return }
                self.statistics.lastEncodeMilliseconds = duration
                if dropped {
                    self.encoder.requestKeyframe()
                    self.encoding = false
                    self.statistics.encoderDroppedFrames += 1; self.onStatistics(self.statistics)
                    self.requestKeyframe()
                }
            }
        }
        encoder.onError = { [weak self] error in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, self.active else { return }
                self.encoding = false
                self.onError(error)
            }
        }
    }

    func receive(_ image: CVPixelBuffer, presentationTime: CMTime) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard active else { return }
        statistics.capturedFrames += 1
        latestImage = image
        let time = CMTimeConvertScale(presentationTime, timescale: 1_000_000_000, method: .default)
        latestCaptureTime = time.isNumeric && time.value > 0 ? UInt64(time.value) : DispatchTime.now().uptimeNanoseconds
        latestNeedsEncoding = true
        encode(image, presentationTime: presentationTime)
        scheduleRawRetry()
    }

    func requestKeyframe() {
        queue.async { [weak self] in
            guard let self, self.active else { return }
            self.statistics.recoveryRequests += 1
            guard !self.recoveryPending else { return }
            self.recoveryPending = true
            self.rawRetryWork?.cancel(); self.rawRetryWork = nil
            self.encoder.requestKeyframe()
            self.scheduleRecovery()
        }
    }

    private func scheduleRawRetry() {
        guard active, latestNeedsEncoding, !recoveryPending, rawRetryWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active else { return }
            self.rawRetryWork = nil
            guard self.latestNeedsEncoding, let image = self.latestImage else { return }
            // No reference was discarded: retry the newest raw capture as a
            // normal frame. A static final change must not wait for more motion.
            self.encode(image, presentationTime: CMClockGetTime(CMClockGetHostTimeClock()))
            self.scheduleRawRetry()
        }
        rawRetryWork = work
        queue.asyncAfter(deadline: .now() + .milliseconds(50), execute: work)
    }

    private func scheduleRecovery() {
        guard active, recoveryPending, recoveryWork == nil, latestImage != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // The first request is immediate. Retry attempts remain at most four
        // per second, including while there is no capacity to encode/send.
        let delay = max(0, (lastRecoveryAttempt ?? (now - 0.25)) + 0.25 - now)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.recoveryPending else { return }
            self.recoveryWork = nil
            self.lastRecoveryAttempt = ProcessInfo.processInfo.systemUptime
            guard let image = self.latestImage else { return }
            self.encoder.requestKeyframe()
            _ = self.encode(image, presentationTime: CMClockGetTime(CMClockGetHostTimeClock()))
            self.scheduleRecovery()
        }
        recoveryWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func updateConfiguration(_ configuration: StreamConfiguration) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard active else { return }
        try encoder.updateConfiguration(configuration)
        statistics.dataRateLimitSupported = encoder.dataRateLimitSupported
        onStatistics(statistics)
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard active else { return }
        active = false
        recoveryPending = false
        recoveryWork?.cancel(); recoveryWork = nil
        rawRetryWork?.cancel(); rawRetryWork = nil
        latestNeedsEncoding = false
        encoding = false
        latestImage = nil
        encoder.finish()
    }

    @discardableResult private func encode(_ image: CVPixelBuffer, presentationTime: CMTime) -> Bool {
        guard !encoding, canEncode() else {
            statistics.skippedBeforeEncoding += 1; onStatistics(statistics)
            return false
        }
        var time = presentationTime
        if !time.isNumeric { time = CMClockGetTime(CMClockGetHostTimeClock()) }
        if lastPresentationTime.isNumeric, CMTimeCompare(time, lastPresentationTime) <= 0 {
            time = CMTimeAdd(lastPresentationTime, CMTime(value: 1, timescale: 1_000_000))
        }
        lastPresentationTime = time
        encoding = true
        let admitted = encoder.encode(image, presentationTime: time, captureTimeNanoseconds: latestCaptureTime)
        if admitted {
            latestNeedsEncoding = false
            rawRetryWork?.cancel(); rawRetryWork = nil
        }
        if !admitted {
            encoding = false
            statistics.skippedBeforeEncoding += 1; onStatistics(statistics)
        }
        if recoveryPending { scheduleRecovery() }
        return admitted
    }
}
