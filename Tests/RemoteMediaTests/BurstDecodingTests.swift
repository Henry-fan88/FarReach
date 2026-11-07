import XCTest
import AppKit
import CoreMedia
import CoreVideo
@testable import RemoteMedia

final class BurstDecodingTests: XCTestCase {
    @MainActor
    func testRepairedReferenceBurstDecodesEveryFrameWhileOnlyLatestPixelsArePresented() async throws {
        let encoder = try H264Encoder(width: 320, height: 180, configuration: .automaticInitial)
        defer { encoder.finish() }
        var frames: [EncodedFrame] = []
        for index in 0..<8 {
            let encoded = expectation(description: "reference frame \(index)")
            let box = EncodedResultBox()
            encoder.onFrame = { box.set(.success($0)); encoded.fulfill() }
            encoder.onError = { box.set(.failure($0)); encoded.fulfill() }
            XCTAssertTrue(encoder.encode(try Self.image(index: index), presentationTime: CMTime(value: Int64(index + 1), timescale: 30)))
            await fulfillment(of: [encoded], timeout: 5)
            frames.append(try XCTUnwrap(box.get()).get())
        }
        XCTAssertTrue(try XCTUnwrap(frames.first).isKeyframe)
        XCTAssertGreaterThanOrEqual(frames.filter { !$0.isKeyframe }.count, 4, "The fixture must exercise compressed references, not only IDRs")
        XCTAssertFalse(try XCTUnwrap(frames.last).isKeyframe)
        let chain = frames
        let decoded: [PreparedMediaFrame] = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                do {
                    let preparer = MediaFramePreparer()
                    var pixels: [PreparedMediaFrame] = []
                    // A repaired network batch can arrive without any display
                    // opportunity between these compressed references.
                    for (index, frame) in chain.enumerated() {
                        let prepared = try preparer.decode(frame)
                        XCTAssertTrue(prepared.isDecoded)
                        let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(prepared.sample))
                        XCTAssertEqual(CVPixelBufferGetWidth(image), 320)
                        XCTAssertEqual(CVPixelBufferGetHeight(image), 180)
                        CVPixelBufferLockBaseAddress(image, .readOnly)
                        let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
                        let stride = CVPixelBufferGetBytesPerRow(image)
                        XCTAssertGreaterThan(bytes[80 * stride + (26 + index * 24) * 4], 180, "The decoded moving marker must match this reference frame")
                        if index > 0 { XCTAssertLessThan(bytes[80 * stride + 26 * 4], 110, "An old marker must disappear as reference updates decode") }
                        CVPixelBufferUnlockBaseAddress(image, .readOnly)
                        pixels.append(prepared)
                    }
                    preparer.reset()
                    XCTAssertThrowsError(try preparer.decode(chain.last!)) { error in
                        guard case MediaError.needsKeyframe = error else { XCTFail("Reset decoder must ask for IDR: \(error)"); return }
                    }
                    XCTAssertTrue(try preparer.decode(chain[0]).isDecoded)
                    continuation.resume(returning: pixels)
                } catch { continuation.resume(throwing: error) }
            }
        }
        XCTAssertEqual(decoded.count, 8)
        _ = NSApplication.shared
        let view = RemoteDesktopView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        view.inputEnabled = false
        var requests = 0, presentations = 0
        view.onNeedsKeyframe = { requests += 1 }
        view.onFrameEnqueued = { presentations += 1 }
        // Deliberately omit every earlier display frame, including the IDR.
        // The final pixel image is independent and can initialize an empty view.
        XCTAssertTrue(try view.display(XCTUnwrap(decoded.last)))
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(view.frameSize, CGSize(width: 320, height: 180))
        view.clear()
    }

    func testDecodeOnMainThreadIsRejectedBeforeBlockingCodecWork() throws {
        let frame = try EncodedFrame(width: 64, height: 64, isKeyframe: true,
            sps: Data([0x67, 1]), pps: Data([0x68, 2]), payload: Data([0, 0, 0, 2, 0x65, 0x88]))
        let check = {
            XCTAssertThrowsError(try MediaFramePreparer().decode(frame)) { error in
                guard case MediaError.invalidFrame(let detail) = error else { XCTFail("Expected off-main precondition"); return }
                XCTAssertTrue(detail.contains("main thread"))
            }
        }
        if Thread.isMainThread { try check() } else { try DispatchQueue.main.sync(execute: check) }
    }

    private static func image(index: Int) throws -> CVPixelBuffer {
        var image: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image)
        guard status == kCVReturnSuccess, let image else { throw MediaError.codec("Creating synthetic reference pixels", status) }
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        let stride = CVPixelBufferGetBytesPerRow(image) / 4
        let pixels = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt32.self)
        pixels.update(repeating: 0xff404040, count: stride * 180)
        for y in 64..<96 { (pixels + y * stride + 16 + index * 24).update(repeating: 0xffe0e0e0, count: 20) }
        return image
    }
}

private final class EncodedResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<EncodedFrame, Error>?
    func set(_ result: Result<EncodedFrame, Error>) { lock.lock(); value = result; lock.unlock() }
    func get() -> Result<EncodedFrame, Error>? { lock.lock(); defer { lock.unlock() }; return value }
}
