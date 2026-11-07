import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreGraphics
import CoreMedia
import CoreVideo

public struct StreamConfiguration: Sendable, Equatable {
    public var maxDimension: Int
    public var framesPerSecond: Int
    public var bitrate: Int
    public init(maxDimension: Int = 1920, framesPerSecond: Int = 30, bitrate: Int = 8_000_000) {
        self.maxDimension = min(3840, max(320, maxDimension))
        self.framesPerSecond = min(60, max(10, framesPerSecond))
        self.bitrate = min(40_000_000, max(500_000, bitrate))
    }
    public static let automaticInitial = StreamConfiguration(maxDimension: 1280, framesPerSecond: 30, bitrate: 2_000_000)
    public static let automaticMaximum = StreamConfiguration(maxDimension: 1920, framesPerSecond: 60, bitrate: 12_000_000)
}

/// Hardware-preferred, low-delay H.264 encoder. Captured frames are discarded before
/// encoding if the encoder is already busy; network drops require requestKeyframe().
public final class H264Encoder {
    public var onFrame: ((EncodedFrame) -> Void)?
    public var onError: ((Error) -> Void)?
    public var onEncodingCompleted: ((Double, Bool) -> Void)?
    /// Acceptance by the selected encoder, not an absolute per-frame guarantee.
    /// The transport still enforces its own bounded admission and pacing policy.
    public private(set) var dataRateLimitSupported = false
    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var forceKeyframe = true
    private var inFlight = 0
    private let width: Int
    private let height: Int

    public init(width: Int, height: Int, configuration: StreamConfiguration = .init()) throws {
        guard (2...8192).contains(width), (2...8192).contains(height), width % 2 == 0, height % 2 == 0 else {
            throw MediaError.invalidFrame("encoder dimensions must be even and between 2 and 8192")
        }
        self.width = width; self.height = height
        let specification = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264, encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw MediaError.codec("Creating H.264 encoder", status) }
        let required: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel),
            (kVTCompressionPropertyKey_AverageBitRate, configuration.bitrate as CFNumber),
            (kVTCompressionPropertyKey_ExpectedFrameRate, configuration.framesPerSecond as CFNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, configuration.framesPerSecond * 2 as CFNumber)
        ]
        for (key, value) in required {
            let code = VTSessionSetProperty(session, key: key, value: value)
            guard code == noErr else { VTCompressionSessionInvalidate(session); throw MediaError.codec("Configuring H.264 encoder", code) }
        }
        dataRateLimitSupported = try Self.configureDataRateLimit(session, bitrate: configuration.bitrate)
        // Some hardware does not expose this optional queue control.
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFNumber)
        let ready = VTCompressionSessionPrepareToEncodeFrames(session)
        guard ready == noErr else { throw MediaError.codec("Preparing H.264 encoder", ready) }
    }

    public func requestKeyframe() { lock.lock(); forceKeyframe = true; lock.unlock() }

    /// Called on the same serial queue as encode. Rate changes do not discard
    /// reference frames or reset the current capture generation.
    public func updateConfiguration(_ configuration: StreamConfiguration) throws {
        guard let session else { throw MediaError.stopped }
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_AverageBitRate, configuration.bitrate as CFNumber),
            (kVTCompressionPropertyKey_ExpectedFrameRate, configuration.framesPerSecond as CFNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, configuration.framesPerSecond * 2 as CFNumber)
        ]
        for (key, value) in properties {
            let status = VTSessionSetProperty(session, key: key, value: value)
            guard status == noErr else { throw MediaError.codec("Updating H.264 encoder", status) }
        }
        dataRateLimitSupported = try Self.configureDataRateLimit(session, bitrate: configuration.bitrate)
    }

    private static func configureDataRateLimit(_ session: VTCompressionSession, bitrate: Int) throws -> Bool {
        // AverageBitRate alone allows desktop IDRs several times larger than a
        // pacing window. Bound half-second bursts and reserve 15% for RTP/SRTP
        // overhead. Actual output is still checked by the transport: hardware
        // can exceed this requested limit, especially during bootstrap.
        let bytes = max(1, Int(Double(bitrate) * 0.5 * 0.85 / 8))
        let status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
            value: [NSNumber(value: bytes), NSNumber(value: 0.5)] as CFArray)
        if status == kVTPropertyNotSupportedErr { return false }
        guard status == noErr else { throw MediaError.codec("Configuring video burst rate", status) }
        return true
    }

    /// Call encode and finish from a single serial queue. The callbacks may use a
    /// VideoToolbox queue. The pixel buffer must remain immutable after submission.
    @discardableResult public func encode(_ image: CVPixelBuffer, presentationTime: CMTime, captureTimeNanoseconds: UInt64? = nil) -> Bool {
        guard let session else { return false }
        lock.lock()
        guard inFlight < 2 else { lock.unlock(); return false }
        inFlight += 1
        let keyframe = forceKeyframe
        forceKeyframe = false
        lock.unlock()
        let submittedAt = DispatchTime.now().uptimeNanoseconds
        let scaled = CMTimeConvertScale(presentationTime, timescale: 1_000_000_000, method: .default)
        let capturedAt = captureTimeNanoseconds ?? (scaled.isNumeric && scaled.value > 0 ? UInt64(scaled.value) : submittedAt)
        let frameID = MediaFrameClock.next()
        let properties = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: presentationTime, duration: .invalid, frameProperties: properties, infoFlagsOut: nil) { [weak self] status, flags, buffer in
            guard let self else { return }
            self.lock.lock(); self.inFlight = max(0, self.inFlight - 1); self.lock.unlock()
            let completedAt = DispatchTime.now().uptimeNanoseconds
            self.onEncodingCompleted?(Double(completedAt - submittedAt) / 1_000_000, flags.contains(.frameDropped) || buffer == nil)
            guard status == noErr else { self.onError?(MediaError.codec("Encoding video", status)); return }
            guard !flags.contains(.frameDropped), let buffer else { self.requestKeyframe(); return }
            do { self.onFrame?(try self.frame(from: buffer, frameID: frameID, capturedAt: capturedAt, encodedAt: completedAt)) }
            catch { self.onError?(error) }
        }
        if status != noErr {
            lock.lock(); inFlight = max(0, inFlight - 1); forceKeyframe = true; lock.unlock()
            onError?(MediaError.codec("Submitting video frame", status))
            return false
        }
        return true
    }

    public func finish() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }
    deinit { finish() }

    private func frame(from sample: CMSampleBuffer, frameID: UInt64, capturedAt: UInt64, encodedAt: UInt64) throws -> EncodedFrame {
        guard let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else { throw MediaError.invalidFrame("encoder returned no data") }
        let count = CMBlockBufferGetDataLength(block)
        guard count > 0, count <= EncodedFrame.maximumPayload else { throw MediaError.invalidFrame("encoder frame exceeds limit") }
        var payload = Data(count: count)
        let code = payload.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!) }
        guard code == noErr else { throw MediaError.codec("Copying compressed video", code) }
        var sets: [Data] = []
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            var total = 0
            var nalHeader: Int32 = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &total, nalUnitHeaderLengthOut: &nalHeader)
            guard status == noErr, let pointer, size > 0, size <= 65536, nalHeader == 4 else { throw MediaError.codec("Reading H.264 configuration", status) }
            sets.append(Data(bytes: pointer, count: size))
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        return try EncodedFrame(width: UInt32(width), height: UInt32(height), isKeyframe: isKeyframe, sps: sets[0], pps: sets[1], payload: payload,
                                frameID: frameID, captureTimeNanoseconds: capturedAt, encodedTimeNanoseconds: encodedAt)
    }
}

public final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Set callbacks before start. All callbacks execute on the serial capture
    /// queue; UI/session owners must dispatch to their actor/queue as needed.
    public var onFrame: ((EncodedFrame) -> Void)?
    public var onFrameEvent: ((EncodedFrame, UInt64) -> Void)?
    public var onAvailability: ((Bool, UInt64) -> Void)?
    public var onError: ((Error) -> Void)?
    /// Set before start. Invoked on the capture queue; return false to discard
    /// raw pixels before encoding rather than break compressed dependencies.
    public var canEncodeFrame: (() -> Bool)?
    public var onStatistics: ((MediaPipelineStatistics) -> Void)?
    public private(set) var captureDisplayID: CGDirectDisplayID = CGMainDisplayID()
    public private(set) var frameSize = CGSize.zero
    private var configuration: StreamConfiguration
    private let queue = DispatchQueue(label: "FarReach.capture", qos: .userInteractive)
    // Lifecycle properties are accessed only by the main-actor methods.
    private var stream: SCStream?
    private var starting = false
    private var lifecycle = UUID()
    private var sourceSize = CGSize.zero
    private var updatingConfiguration = false
    private var pendingConfiguration: StreamConfiguration?
    // These two properties belong exclusively to queue.
    private var captureStream: SCStream?
    private var pipeline: CaptureAvailabilityPipeline?

    public init(config: StreamConfiguration = .init()) { self.configuration = config; super.init() }

    @MainActor public func start() async throws {
        guard stream == nil, !starting else { return }
        starting = true
        let attempt = UUID(); lifecycle = attempt
        defer { if lifecycle == attempt { starting = false } }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard lifecycle == attempt else { throw MediaError.stopped }
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { throw MediaError.noDisplay }
        captureDisplayID = display.displayID
        sourceSize = CGSize(width: display.width, height: display.height)
        let (width, height) = Self.dimensions(source: sourceSize, configuration: configuration)
        frameSize = CGSize(width: width, height: height)
        let settings = Self.settings(width: width, height: height, configuration: configuration)
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let newStream = SCStream(filter: filter, configuration: settings, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = newStream
        queue.sync {
            self.pipeline?.stop()
            self.captureStream = newStream
            self.pipeline = CaptureAvailabilityPipeline(width: width, height: height, configuration: configuration, queue: queue,
                onFrame: { [weak self] frame, epoch in
                    self?.onFrameEvent?(frame, epoch)
                    self?.onFrame?(frame)
                },
                onAvailability: { [weak self] available, epoch in self?.onAvailability?(available, epoch) },
                onError: { [weak self] error in self?.onError?(error) },
                canEncode: { [weak self] in self?.canEncodeFrame?() ?? true },
                onStatistics: { [weak self] stats in self?.onStatistics?(stats) })
        }
        do {
            try await newStream.startCapture()
            guard lifecycle == attempt else { try? await newStream.stopCapture(); throw MediaError.stopped }
        } catch {
            if stream === newStream { stream = nil }
            queue.sync {
                // A newer start can already be in progress after cancellation.
                guard self.captureStream === newStream else { return }
                self.captureStream = nil
                self.pipeline?.stop(); self.pipeline = nil
            }
            throw error
        }
    }

    @MainActor public func stop() async {
        lifecycle = UUID()
        starting = false
        pendingConfiguration = nil
        let old = stream; stream = nil
        // Invalidate immediately, before awaiting the asynchronous OS stop.
        queue.sync {
            self.captureStream = nil
            if let pipeline = self.pipeline { pipeline.stop() }
            else { self.onAvailability?(false, CaptureGenerationClock.next()) }
            self.pipeline = nil
        }
        try? await old?.stopCapture()
    }

    /// Updates a running stream without replacing its authenticated connection.
    /// Concurrent requests coalesce to the latest configuration. Resizing first
    /// invalidates cached pixels; only a matching new-size capture can resume.
    @MainActor public func updateConfiguration(_ requested: StreamConfiguration) async throws {
        pendingConfiguration = StreamConfiguration(maxDimension: requested.maxDimension, framesPerSecond: requested.framesPerSecond, bitrate: requested.bitrate)
        guard !updatingConfiguration else { return }
        updatingConfiguration = true
        defer { updatingConfiguration = false }
        while let next = pendingConfiguration {
            pendingConfiguration = nil
            guard next != configuration else { continue }
            guard let stream else { configuration = next; continue }
            let attempt = lifecycle
            let previous = configuration
            let (width, height) = Self.dimensions(source: sourceSize, configuration: next)
            let (oldWidth, oldHeight) = Self.dimensions(source: sourceSize, configuration: previous)
            let resized = width != oldWidth || height != oldHeight
            if resized {
                try queue.sync { try pipeline?.updateConfiguration(next, width: width, height: height) }
            }
            do {
                if resized || next.framesPerSecond != previous.framesPerSecond {
                    try await stream.updateConfiguration(Self.settings(width: width, height: height, configuration: next))
                }
                guard lifecycle == attempt, self.stream === stream else { throw MediaError.stopped }
                if !resized { try queue.sync { try pipeline?.updateConfiguration(next, width: width, height: height) } }
                configuration = next; frameSize = CGSize(width: width, height: height)
            } catch {
                if lifecycle == attempt, self.stream === stream {
                    try? queue.sync { try pipeline?.updateConfiguration(previous, width: oldWidth, height: oldHeight) }
                }
                throw error
            }
        }
    }

    private static func dimensions(source: CGSize, configuration: StreamConfiguration) -> (Int, Int) {
        let scale = min(1, Double(configuration.maxDimension) / max(1, max(source.width, source.height)))
        return (max(2, Int(source.width * scale) / 2 * 2), max(2, Int(source.height * scale) / 2 * 2))
    }
    private static func settings(width: Int, height: Int, configuration: StreamConfiguration) -> SCStreamConfiguration {
        let result = SCStreamConfiguration()
        result.width = width; result.height = height
        result.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.framesPerSecond))
        result.pixelFormat = kCVPixelFormatType_32BGRA
        result.queueDepth = 3; result.showsCursor = true; result.capturesAudio = false
        result.colorSpaceName = CGColorSpace.sRGB
        return result
    }

    public func requestKeyframe() { queue.async { [weak self] in self?.pipeline?.requestKeyframe() } }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, self.captureStream === stream else { return }
            self.captureStream = nil
            self.pipeline?.stop(); self.pipeline = nil
            self.onError?(error)
            Task { @MainActor [weak self] in
                guard let self, self.stream === stream else { return }
                self.stream = nil
            }
        }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard captureStream === stream, type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let rawStatus = attachments?.first?[.status] as? Int
        let status = rawStatus.flatMap(SCFrameStatus.init(rawValue:))
        // Status must be read before asking for an image: blank/suspended
        // notifications need not carry pixels, but must invalidate cached pixels.
        pipeline?.receive(status: status, image: CMSampleBufferGetImageBuffer(sampleBuffer),
                          presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}

private enum MediaFrameClock {
    private static let lock = NSLock()
    private static var value: UInt64 = 0
    static func next() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        value &+= 1; if value == 0 { value = 1 }; return value
    }
}
