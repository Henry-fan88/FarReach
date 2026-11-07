import XCTest
import CoreMedia
import CoreVideo
import VideoToolbox
@testable import RemoteMedia

final class MediaTests: XCTestCase {
    private func fixture() throws -> EncodedFrame {
        try EncodedFrame(width: 640, height: 480, isKeyframe: true, sps: Data([0x67, 1]), pps: Data([0x68, 2]), payload: Data([0, 0, 0, 2, 0x65, 0x88]))
    }
    func testFrameRoundtripAndNonzeroDataIndex() throws {
        let original = try fixture()
        let bytes = try original.serialized()
        let container = Data([9, 9]) + bytes
        let decoded = try EncodedFrame(data: container.dropFirst(2))
        XCTAssertEqual(decoded.width, 640); XCTAssertEqual(decoded.height, 480)
        XCTAssertTrue(decoded.isKeyframe)
        XCTAssertEqual(decoded.sps, original.sps); XCTAssertEqual(decoded.pps, original.pps)
        XCTAssertEqual(decoded.payload, original.payload)
    }
    func testMalformedFrameCannotReachDecoder() throws {
        let good = try fixture().serialized()
        for count in 0..<good.count { XCTAssertThrowsError(try EncodedFrame(data: good.prefix(count))) }
        var huge = good; huge[21] = 0xff
        XCTAssertThrowsError(try EncodedFrame(data: huge))
        var trailing = good; trailing.append(0)
        XCTAssertThrowsError(try EncodedFrame(data: trailing))
        var badDimensions = good; badDimensions[4] = 0xff
        XCTAssertThrowsError(try EncodedFrame(data: badDimensions))
        XCTAssertThrowsError(try EncodedFrame(width: 640, height: 480, isKeyframe: false, sps: Data([1]), pps: Data([1]), payload: Data([0, 0, 0, 30, 1])))
        XCTAssertThrowsError(try EncodedFrame(width: 640, height: 480, isKeyframe: false, sps: Data([1]), pps: Data([1]), payload: Data([0, 0, 0, 0])))
    }
    func testInputValidationAndCodable() throws {
        let move = RemoteInput(kind: .move, x: 0.25, y: 0.75)
        XCTAssertTrue(move.isValid)
        let decoded = try JSONDecoder().decode(RemoteInput.self, from: JSONEncoder().encode(move))
        XCTAssertEqual(decoded.x, 0.25)
        XCTAssertFalse(RemoteInput(kind: .move, x: .nan).isValid)
        XCTAssertFalse(RemoteInput(kind: .move, x: -0.1).isValid)
        XCTAssertFalse(RemoteInput(kind: .move, y: 1.1).isValid)
        XCTAssertFalse(RemoteInput(kind: .scroll, deltaY: .infinity).isValid)
        XCTAssertFalse(RemoteInput(kind: .scroll, deltaY: 2001).isValid)
        XCTAssertFalse(RemoteInput(kind: .keyDown, keyCode: 255).isValid)
        XCTAssertFalse(RemoteInput(kind: .keyDown, modifiers: UInt64.max).isValid)
        XCTAssertFalse(RemoteInput(kind: .mouseDown, button: 4).isValid)
        XCTAssertFalse(RemoteInput(kind: .mouseDown, clickCount: 0).isValid)
    }


    func testIdleKeyframeRecoveryUsesLatestImageAndCoalescesRequests() throws {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let image = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image)!, 128, CVPixelBufferGetBytesPerRow(image) * 64)
        CVPixelBufferUnlockBaseAddress(image, [])
        let first = expectation(description: "initial captured image")
        let recovered = expectation(description: "static image recovered as an IDR")
        let queue = DispatchQueue(label: "farreach.test.idle-recovery")
        let lock = NSLock()
        var frames = 0
        let pipeline = try FrameEncodingPipeline(width: 64, height: 64, configuration: .init(), queue: queue, onFrame: { frame in
            XCTAssertTrue(frame.isKeyframe)
            lock.lock(); frames += 1; let count = frames; lock.unlock()
            if count == 1 { first.fulfill() }
            else if count == 2 { recovered.fulfill() }
            else { XCTFail("Coalesced idle recovery produced duplicate frames") }
        }, onError: { XCTFail("Idle recovery encoder failed: \($0)") })
        defer { queue.sync { pipeline.stop() } }
        queue.sync { pipeline.receive(image, presentationTime: CMTime(value: 1, timescale: 30)) }
        wait(for: [first], timeout: 5)
        // No further captures arrive; all requests must share one delayed resend.
        for _ in 0..<100 { pipeline.requestKeyframe() }
        wait(for: [recovered], timeout: 5)
        let settled = expectation(description: "recovery queue settled")
        queue.asyncAfter(deadline: .now() + .milliseconds(600)) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        lock.lock(); let count = frames; lock.unlock()
        XCTAssertEqual(count, 2)
    }

    /// Exercises Apple's actual encoder and decoder without screen recording or
    /// Accessibility permission. This is a codec test, not a remote latency claim.
    func testRealH264EncodeDecode() throws {
        let dimension = 64
        var buffer: CVPixelBuffer?
        let allocation = CVPixelBufferCreate(kCFAllocatorDefault, dimension, dimension, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        XCTAssertEqual(allocation, kCVReturnSuccess)
        let image = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(image, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(image)
        for y in 0..<dimension {
            for x in 0..<dimension {
                let offset = y * stride + x * 4
                base[offset] = UInt8(x * 3); base[offset + 1] = UInt8(y * 3)
                base[offset + 2] = 128; base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        let encoded = expectation(description: "H.264 encoded")
        let lock = NSLock()
        var produced: EncodedFrame?
        var failed: Error?
        let encoder = try H264Encoder(width: dimension, height: dimension)
        encoder.onFrame = { frame in lock.lock(); produced = frame; lock.unlock(); encoded.fulfill() }
        encoder.onError = { error in lock.lock(); failed = error; lock.unlock(); encoded.fulfill() }
        encoder.encode(image, presentationTime: CMTime(value: 1, timescale: 30))
        encoder.finish()
        wait(for: [encoded], timeout: 5)
        if let failed { throw failed }
        let frame = try XCTUnwrap(produced)
        XCTAssertTrue(frame.isKeyframe)
        let serialized = try frame.serialized()
        let reconstructed = try EncodedFrame(data: serialized)
        let format = try RemoteDesktopView.makeFormat(reconstructed)
        let sample = try RemoteDesktopView.makeSample(reconstructed, format: format)
        var decoder: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary, outputCallback: nil, decompressionSessionOut: &decoder)
        XCTAssertEqual(created, noErr)
        let session = try XCTUnwrap(decoder)
        defer { VTDecompressionSessionInvalidate(session) }
        let decoded = expectation(description: "H.264 decoded")
        let result = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, pixel, _, _ in
            XCTAssertEqual(status, noErr)
            if let pixel {
                XCTAssertEqual(CVPixelBufferGetWidth(pixel), dimension)
                XCTAssertEqual(CVPixelBufferGetHeight(pixel), dimension)
                CVPixelBufferLockBaseAddress(pixel, .readOnly)
                let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
                let center = 32 * CVPixelBufferGetBytesPerRow(pixel) + 32 * 4
                // H.264 is lossy; allow conversion/quantization error while checking content.
                XCTAssertLessThan(abs(Int(bytes[center + 2]) - 128), 30)
                CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
            } else { XCTFail("Decoder returned no image") }
            decoded.fulfill()
        }
        XCTAssertEqual(result, noErr)
        wait(for: [decoded], timeout: 5)
    }
}
