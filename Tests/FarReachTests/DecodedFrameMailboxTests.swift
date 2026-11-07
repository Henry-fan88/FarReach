import XCTest
import CoreMedia
import CoreVideo
@testable import FarReach
import RemoteMedia

final class DecodedFrameMailboxTests: XCTestCase {
    /// Simulates a stalled presentation queue while a repaired H.264 chain is
    /// delivered in a burst. No desktop capture, window, or input is involved.
    func testBurstDecodesEveryReferenceAndQueuesOnlyLatestPixels() {
        let finished = expectation(description: "native reference chain decoded")
        DispatchQueue(label: "FarReach.test.decoded-burst").async {
            defer { finished.fulfill() }
            do {
                let frames = try Self.encodeFrames(count: 24)
                XCTAssertTrue(frames[0].isKeyframe)
                XCTAssertGreaterThan(frames.dropFirst().filter { !$0.isKeyframe }.count, 8,
                                     "The regression must exercise a dependent H.264 chain")
                let decoder = MediaFramePreparer(), mailbox = LatestDecodedFrameMailbox()
                mailbox.authorize(17)
                let epoch = try XCTUnwrap(mailbox.token(for: 17))
                var scheduledCallbacks = 0
                var totalPayload = 0
                for frame in frames {
                    let decoded = try decoder.decode(frame)
                    XCTAssertTrue(decoded.isDecoded)
                    XCTAssertNotNil(CMSampleBufferGetImageBuffer(decoded.sample))
                    let bytes = try frame.serialized().count
                    totalPayload += bytes
                    if mailbox.publish(.init(generation: 17, epoch: epoch, prepared: decoded,
                        preparationMilliseconds: 0, preparedAt: ProcessInfo.processInfo.systemUptime, payloadBytes: bytes)) {
                        scheduledCallbacks += 1
                    }
                    // Intentionally do not consume the main-queue mailbox here.
                }
                XCTAssertEqual(scheduledCallbacks, 1)
                let displayed = try XCTUnwrap(mailbox.take())
                XCTAssertEqual(displayed.prepared.frame.frameID, frames.last?.frameID)
                XCTAssertEqual(displayed.payloadBytes, totalPayload)
                XCTAssertNil(mailbox.take(), "Only one decoded image may wait for the UI")
            } catch { XCTFail("Native decoded burst failed: \(error)") }
        }
        wait(for: [finished], timeout: 20)
    }

    func testRevocationRejectsQueuedPixelsAndNeverCoalescesCompressedSamples() {
        let finished = expectation(description: "generation admission checked")
        DispatchQueue(label: "FarReach.test.decoded-generation").async {
            defer { finished.fulfill() }
            do {
                let frame = try XCTUnwrap(Self.encodeFrames(count: 1).first)
                let decoder = MediaFramePreparer(), mailbox = LatestDecodedFrameMailbox()
                mailbox.authorize(9)
                let oldEpoch = try XCTUnwrap(mailbox.token(for: 9))
                let compressed = try decoder.prepare(frame)
                XCTAssertFalse(mailbox.publish(.init(generation: 9, epoch: oldEpoch, prepared: compressed,
                    preparationMilliseconds: 0, preparedAt: 0, payloadBytes: 1)))
                let decoded = try decoder.decode(frame)
                let old = DecodedFrameDelivery(generation: 9, epoch: oldEpoch, prepared: decoded,
                    preparationMilliseconds: 0, preparedAt: 0, payloadBytes: 1)
                XCTAssertTrue(mailbox.publish(old))
                mailbox.authorize(0)
                XCTAssertNil(mailbox.take())
                XCTAssertNil(mailbox.token(for: 9))
                mailbox.authorize(9)
                XCTAssertNotEqual(mailbox.token(for: 9), oldEpoch, "Reusing a capture generation cannot revive an earlier decode")
                XCTAssertFalse(mailbox.publish(old))
                XCTAssertNil(mailbox.take())
            } catch { XCTFail("Decoded generation check failed: \(error)") }
        }
        wait(for: [finished], timeout: 10)
    }

    private static func encodeFrames(count: Int) throws -> [EncodedFrame] {
        let encoder = try H264Encoder(width: 128, height: 128,
            configuration: .init(maxDimension: 1280, framesPerSecond: 30, bitrate: 2_000_000))
        defer { encoder.finish() }
        let callback = DispatchSemaphore(value: 0), lock = NSLock()
        var output: EncodedFrame?, failure: Error?
        encoder.onFrame = { frame in lock.lock(); output = frame; lock.unlock(); callback.signal() }
        encoder.onError = { error in lock.lock(); failure = error; lock.unlock(); callback.signal() }
        var frames: [EncodedFrame] = []
        for index in 0..<count {
            var allocated: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, 128, 128, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &allocated)
            guard status == kCVReturnSuccess, let pixels = allocated else { throw MediaError.codec("Allocating test pixels", status) }
            CVPixelBufferLockBaseAddress(pixels, [])
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            memset(base, 128, stride * 128)
            for y in 48..<56 {
                for x in (index * 4)..<(index * 4 + 8) {
                    let offset = y * stride + x * 4
                    base[offset] = 240; base[offset + 1] = 240; base[offset + 2] = 240; base[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            guard encoder.encode(pixels, presentationTime: CMTime(value: Int64(index + 1), timescale: 30)) else {
                throw MediaError.invalidFrame("Test encoder refused a sequential frame")
            }
            guard callback.wait(timeout: .now() + 3) == .success else { throw MediaError.invalidFrame("Test encoder callback timed out") }
            lock.lock(); let next = output, error = failure; output = nil; failure = nil; lock.unlock()
            if let error { throw error }
            frames.append(try XCTUnwrap(next))
        }
        return frames
    }
}
