import XCTest
import CoreMedia
import CoreVideo
import CoreGraphics
import CoreText
import VideoToolbox
@testable import RemoteMedia

/// Synthetic text editor/scroll workload, not a screen capture and not random
/// noise. Optional fixtures let the Go transport test actual VideoToolbox NALs.
final class NativeContinuousEncodingTests: XCTestCase {
    func testNativeDataRateLimitsExperiment() async throws {
        guard ProcessInfo.processInfo.environment["FARREACH_RATE_LIMIT_EXPERIMENT"] == "1" else {
            throw XCTSkip("Opt-in platform experiment: set FARREACH_RATE_LIMIT_EXPERIMENT=1.")
        }
        for (width, height, bitrate, window) in [(1280, 800, 2_000_000, 0.4), (1280, 800, 2_000_000, 0.5),
                                                 (1280, 800, 500_000, 0.4), (1280, 800, 500_000, 0.5),
                                                 (640, 400, 500_000, 0.4)] {
            try await hardLimitProfile(width: width, height: height, bitrate: bitrate, window: window)
        }
    }

    func testDesktopLikeContinuousNativeFramesAndLowRateRecoverySizes() async throws {
        let high = try await captureProfile(width: 1280, height: 800, bitrate: 2_000_000, count: 60)
        let low = try await captureProfile(width: 1280, height: 800, bitrate: 500_000, count: 60)
        let small = try await captureProfile(width: 640, height: 400, bitrate: 500_000, count: 6)
        for frames in [high, low] {
            XCTAssertEqual(frames.count, 60)
            XCTAssertGreaterThanOrEqual(frames.filter(\.isKeyframe).count, 2)
            XCTAssertGreaterThanOrEqual(frames.filter { !$0.isKeyframe }.count, 45)
            let decoded = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                DispatchQueue.global(qos: .userInteractive).async {
                    do {
                        let decoder = MediaFramePreparer()
                        for frame in frames {
                            let pixels = try decoder.decode(frame)
                            XCTAssertTrue(pixels.isDecoded)
                            XCTAssertNotNil(CMSampleBufferGetImageBuffer(pixels.sample))
                        }
                        continuation.resume(returning: frames.count)
                    } catch { continuation.resume(throwing: error) }
                }
            }
            XCTAssertEqual(decoded, frames.count)
        }
        if let destination = ProcessInfo.processInfo.environment["FARREACH_NATIVE_FRAME_FIXTURE"] {
            let url = URL(fileURLWithPath: destination)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.fixture(high).write(to: url, options: .atomic)
            let lowURL = url.deletingPathExtension().appendingPathExtension("500kbps.bin")
            let smallURL = url.deletingPathExtension().appendingPathExtension("640px-500kbps.bin")
            try Self.fixture(low).write(to: lowURL, options: .atomic)
            try Self.fixture(small).write(to: smallURL, options: .atomic)
            print("NATIVE_H264_FIXTURES format=UInt32BE-length+FRS1 generation=731 high=\(url.path) low=\(lowURL.path) small=\(smallURL.path)")
        }
    }

    private func captureProfile(width: Int, height: Int, bitrate: Int, count: Int) async throws -> [EncodedFrame] {
        let encoder = try H264Encoder(width: width, height: height,
            configuration: .init(maxDimension: width, framesPerSecond: 30, bitrate: bitrate))
        defer { encoder.finish() }
        var frames: [EncodedFrame] = []
        let started = DispatchTime.now().uptimeNanoseconds
        for index in 0..<count {
            let deadline = started + UInt64(index) * 1_000_000_000 / 30
            let now = DispatchTime.now().uptimeNanoseconds
            if now < deadline { try await Task.sleep(nanoseconds: deadline - now) }
            let complete = expectation(description: "native desktop frame \(index) at \(bitrate)")
            let box = NativeEncodingResult()
            encoder.onFrame = { box.set(.success($0)); complete.fulfill() }
            encoder.onError = { box.set(.failure($0)); complete.fulfill() }
            if index == 30 { encoder.requestKeyframe() }
            let image = try Self.desktopImage(width: width, height: height, scroll: index)
            XCTAssertTrue(encoder.encode(image, presentationTime: CMClockGetTime(CMClockGetHostTimeClock())))
            await fulfillment(of: [complete], timeout: 5)
            frames.append(try XCTUnwrap(box.get()).get())
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        let keySizes = try frames.filter(\.isKeyframe).map { try $0.serialized().count }
        let deltaSizes = try frames.filter { !$0.isKeyframe }.map { try $0.serialized().count }
        let nalTypes = Set(frames.flatMap { Self.nalTypes($0.payload) }).sorted()
        if encoder.dataRateLimitSupported {
            // This real text workload used to exceed the transport's normal
            // 500 ms recovery budget. Verify actual output, not merely that the
            // property setter succeeded. Go tests account for RTP wire overhead.
            XCTAssertLessThanOrEqual(keySizes.max() ?? 0, Int(Double(bitrate) * 0.5 * 0.85 / 8) + 128)
            XCTAssertLessThanOrEqual(deltaSizes.max() ?? 0, Int(Double(bitrate) * 0.150 / 8))
        }
        print(String(format: "NATIVE_H264_PROFILE desktop-text-scroll dims=%dx%d bitrate=%d captured=%d encoded=%d elapsed=%.3fs effective=%.2ffps keyframes=%d keyBytes=%@ deltaBytesMin=%d deltaBytesMax=%d sps=%d pps=%d nalTypes=%@ rateLimitSupported=%@", width, height, bitrate, count, frames.count, elapsed, Double(frames.count) / elapsed, keySizes.count, String(describing: keySizes), deltaSizes.min() ?? 0, deltaSizes.max() ?? 0, frames.first?.sps.count ?? 0, frames.first?.pps.count ?? 0, String(describing: nalTypes), String(encoder.dataRateLimitSupported)))
        return frames
    }

    private func hardLimitProfile(width: Int, height: Int, bitrate: Int, window: Double) async throws {
        var created: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        XCTAssertEqual(createStatus, noErr)
        let session = try XCTUnwrap(created)
        defer { VTCompressionSessionInvalidate(session) }
        for (key, value): (CFString, CFTypeRef) in [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel),
            (kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber),
            (kVTCompressionPropertyKey_ExpectedFrameRate, 30 as CFNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, 60 as CFNumber)
        ] { XCTAssertEqual(VTSessionSetProperty(session, key: key, value: value), noErr) }
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFNumber)
        let hardBytes = Int(Double(bitrate) * window * 0.85 / 8)
        let setStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
            value: [NSNumber(value: hardBytes), NSNumber(value: window)] as CFArray)
        var rawReadback: UnsafeRawPointer?
        let readStatus = VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, allocator: kCFAllocatorDefault, valueOut: &rawReadback)
        let readback = rawReadback.map { Unmanaged<AnyObject>.fromOpaque($0).takeRetainedValue() }
        print("NATIVE_HARD_LIMIT_CONFIG dims=\(width)x\(height) bitrate=\(bitrate) window=\(window) hardBytes=\(hardBytes) setStatus=\(setStatus) readStatus=\(readStatus) readback=\(String(describing: readback))")
        guard setStatus == noErr else { return }
        XCTAssertEqual(VTCompressionSessionPrepareToEncodeFrames(session), noErr)
        var frames: [EncodedFrame] = []
        var dropped = 0, encodingErrors = 0
        let started = DispatchTime.now().uptimeNanoseconds
        for index in 0..<36 {
            let deadline = started + UInt64(index) * 1_000_000_000 / 30
            let now = DispatchTime.now().uptimeNanoseconds
            if now < deadline { try await Task.sleep(nanoseconds: deadline - now) }
            let complete = expectation(description: "hard-limited frame \(index)")
            let box = NativeCompressionResult()
            let image = try Self.desktopImage(width: width, height: height, scroll: index)
            let options = index == 0 || index == 18 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            let status = VTCompressionSessionEncodeFrame(session, imageBuffer: image,
                presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), duration: .invalid,
                frameProperties: options, infoFlagsOut: nil) { status, flags, sample in
                box.set(status: status, flags: flags, sample: sample); complete.fulfill()
            }
            guard status == noErr else { encodingErrors += 1; continue }
            await fulfillment(of: [complete], timeout: 5)
            let result = try XCTUnwrap(box.get())
            if result.status != noErr { encodingErrors += 1; continue }
            if result.flags.contains(.frameDropped) || result.sample == nil { dropped += 1; continue }
            frames.append(try Self.frame(from: result.sample!, width: width, height: height))
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        let generated = frames
        let decodeCounts = await withCheckedContinuation { (continuation: CheckedContinuation<(Int, Int), Never>) in
            DispatchQueue.global(qos: .userInteractive).async {
                let decoder = MediaFramePreparer()
                var decoded = 0, failures = 0
                for frame in generated {
                    do { _ = try decoder.decode(frame); decoded += 1 }
                    catch { failures += 1; decoder.reset() }
                }
                continuation.resume(returning: (decoded, failures))
            }
        }
        let keySizes = frames.filter(\.isKeyframe).map { $0.payload.count }
        let largestDelta = frames.filter { !$0.isKeyframe }.map { $0.payload.count }.max() ?? 0
        let largest = frames.map { $0.payload.count }.max() ?? 0
        print("NATIVE_HARD_LIMIT_RESULT dims=\(width)x\(height) bitrate=\(bitrate) window=\(window) hardBytes=\(hardBytes) submitted=36 encoded=\(frames.count) encoderDropped=\(dropped) encodeErrors=\(encodingErrors) decoded=\(decodeCounts.0) decodeErrors=\(decodeCounts.1) keyBytes=\(keySizes) largestDelta=\(largestDelta) largestPayload=\(largest) exceedsHardBytes=\(largest > hardBytes)")
        XCTAssertEqual(encodingErrors, 0)
        XCTAssertEqual(decodeCounts.1, 0)
        XCTAssertGreaterThan(frames.count, 0)
    }

    private static func frame(from sample: CMSampleBuffer, width: Int, height: Int) throws -> EncodedFrame {
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        let payloadCount = CMBlockBufferGetDataLength(block)
        var payload = Data(count: payloadCount)
        let copied = payload.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: payloadCount, destination: $0.baseAddress!) }
        XCTAssertEqual(copied, noErr)
        var sets: [Data] = []
        for index in 0..<2 {
            var bytes: UnsafePointer<UInt8>?, count = 0, total = 0
            var header: Int32 = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &bytes, parameterSetSizeOut: &count, parameterSetCountOut: &total, nalUnitHeaderLengthOut: &header)
            XCTAssertEqual(status, noErr); XCTAssertEqual(header, 4)
            sets.append(Data(bytes: try XCTUnwrap(bytes), count: count))
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        return try EncodedFrame(width: UInt32(width), height: UInt32(height),
            isKeyframe: (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true,
            sps: sets[0], pps: sets[1], payload: payload)
    }

    private static func desktopImage(width: Int, height: Int, scroll: Int) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result)
        guard status == kCVReturnSuccess, let image = result else { throw MediaError.codec("Allocating synthetic desktop", status) }
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        let bitmap = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(image), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(image), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap) else {
            throw MediaError.invalidFrame("Could not create synthetic desktop drawing context")
        }
        context.scaleBy(x: CGFloat(width) / 1280, y: CGFloat(height) / 800)
        context.setFillColor(CGColor(gray: 0.98, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1280, height: 800))
        context.setFillColor(CGColor(red: 0.12, green: 0.15, blue: 0.20, alpha: 1)); context.fill(CGRect(x: 0, y: 760, width: 1280, height: 40))
        context.setFillColor(CGColor(gray: 0.91, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 220, height: 760))
        let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
        func text(_ value: String, x: CGFloat, y: CGFloat, color: CGColor) {
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
            context.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, context)
        }
        text("Synthetic project / editor / local fixture — no captured user content", x: 18, y: 773, color: CGColor(gray: 1, alpha: 1))
        for row in 0..<37 {
            text(String(format: "%02d  source_%02d.swift", row, row), x: 14, y: CGFloat(738 - row * 19), color: CGColor(gray: 0.20, alpha: 1))
        }
        for row in 0..<52 {
            let number = row + scroll
            let value = String(format: "%04d  let sample_%03d = items.filter { $0.enabled && $0.rank > %d }.map { record in record.value + %d }", number, number % 997, number % 17, number * 7)
            text(value, x: 236, y: CGFloat(742 - row * 14), color: row % 5 == 0 ? CGColor(red: 0.08, green: 0.28, blue: 0.60, alpha: 1) : CGColor(gray: 0.16, alpha: 1))
        }
        context.setFillColor(CGColor(red: 0.95, green: 0.62, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 650 + scroll * 3 % 420, y: 390, width: 3, height: 22))
        return image
    }

    private static func nalTypes(_ payload: Data) -> [UInt8] {
        var offset = 0, types: [UInt8] = []
        while offset + 4 < payload.count {
            let size = payload.dropFirst(offset).prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard size > 0, offset + size <= payload.count else { break }
            types.append(payload[payload.startIndex + offset] & 31)
            offset += size
        }
        return types
    }

    private static func fixture(_ frames: [EncodedFrame]) throws -> Data {
        var fixture = Data()
        for frame in frames {
            var envelope = Data("FRS1".utf8)
            for shift in stride(from: 56, through: 0, by: -8) { envelope.append(UInt8(truncatingIfNeeded: UInt64(731) >> shift)) }
            envelope.append(try frame.serialized())
            let size = UInt32(envelope.count)
            for shift in stride(from: 24, through: 0, by: -8) { fixture.append(UInt8(truncatingIfNeeded: size >> shift)) }
            fixture.append(envelope)
        }
        return fixture
    }
}

private final class NativeEncodingResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<EncodedFrame, Error>?
    func set(_ result: Result<EncodedFrame, Error>) { lock.lock(); value = result; lock.unlock() }
    func get() -> Result<EncodedFrame, Error>? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class NativeCompressionResult: @unchecked Sendable {
    struct Value { let status: OSStatus; let flags: VTEncodeInfoFlags; let sample: CMSampleBuffer? }
    private let lock = NSLock()
    private var value: Value?
    func set(status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) { lock.lock(); value = Value(status: status, flags: flags, sample: sample); lock.unlock() }
    func get() -> Value? { lock.lock(); defer { lock.unlock() }; return value }
}
