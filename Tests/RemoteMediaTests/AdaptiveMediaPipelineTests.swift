import XCTest
import CoreMedia
import CoreVideo
import ScreenCaptureKit
@testable import RemoteMedia

final class AdaptiveMediaPipelineTests: XCTestCase {
    func testOneEncoderSubmissionUntilFrameForwardingConsumesTransportCredit() throws {
        let queue = DispatchQueue(label: "farreach.test.one-frame-credit")
        let captures = try (1...25).map { _ in try image(width: 64, height: 64) }
        let first = expectation(description: "first encoded frame consumes credit")
        let latest = expectation(description: "only latest raw capture follows returned credit")
        var credit = true
        var frames: [EncodedFrame] = []
        var statistics = MediaPipelineStatistics()
        let pipeline = try FrameEncodingPipeline(width: 64, height: 64, configuration: .automaticInitial, queue: queue,
            onFrame: { frame in
                frames.append(frame)
                if frames.count == 1 { credit = false; first.fulfill() }
                else if frames.count == 2 { latest.fulfill() }
                else { XCTFail("More than one encoded reference escaped the closed credit") }
            }, onError: { XCTFail("Encoding failed: \($0)") }, canEncode: { credit }, onStatistics: { statistics = $0 })
        defer { queue.sync { pipeline.stop() } }
        queue.sync {
            // Codec callbacks may finish while this queue is occupied. None may
            // free admission until onFrame is actually delivered on this queue.
            for (index, capture) in captures.enumerated() {
                pipeline.receive(capture, presentationTime: CMTime(value: Int64(index + 1), timescale: 1000))
            }
        }
        wait(for: [first], timeout: 5)
        let checked = expectation(description: "credit remains closed without extra encoded frames")
        queue.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(frames.count, 1)
            XCTAssertEqual(statistics.encodedFrames, 1)
            XCTAssertEqual(statistics.capturedFrames, 25)
            XCTAssertGreaterThanOrEqual(statistics.skippedBeforeEncoding, 24)
            XCTAssertNotNil(statistics.dataRateLimitSupported)
            credit = true
            checked.fulfill()
        }
        wait(for: [checked, latest], timeout: 3)
        queue.sync {
            XCTAssertEqual(frames.count, 2)
            XCTAssertEqual(frames[0].captureTimeNanoseconds, 1_000_000)
            XCTAssertEqual(frames[1].captureTimeNanoseconds, 25_000_000)
        }
    }

    func testFinalStaticCaptureRetriesWithoutKeyframeRequestAndKeepsCaptureTime() throws {
        let queue = DispatchQueue(label: "farreach.test.latest-raw-retry")
        let image = try image(width: 64, height: 64)
        let delivered = expectation(description: "static final capture delivered without another capture")
        var capacity = false
        let pipeline = try FrameEncodingPipeline(width: 64, height: 64, configuration: .automaticInitial, queue: queue,
            onFrame: { frame in
                XCTAssertEqual(frame.captureTimeNanoseconds, 777_000_000)
                delivered.fulfill()
            }, onError: { XCTFail("Encoding failed: \($0)") }, canEncode: { capacity })
        defer { queue.sync { pipeline.stop() } }
        queue.sync { pipeline.receive(image, presentationTime: CMTime(value: 777, timescale: 1000)) }
        queue.asyncAfter(deadline: .now() + 0.1) { capacity = true }
        wait(for: [delivered], timeout: 2)
    }

    func testFRV2MetadataRoundtripAndLegacyFRV1Compatibility() throws {
        let original = try EncodedFrame(width: 64, height: 64, isKeyframe: true, sps: Data([0x67, 1]), pps: Data([0x68, 2]),
                                        payload: Data([0, 0, 0, 2, 0x65, 0x88]), frameID: 42, captureTimeNanoseconds: 123456789, encodedTimeNanoseconds: 123499999)
        let bytes = try original.serialized()
        XCTAssertEqual(bytes.prefix(4), Data("FRV2".utf8))
        let decoded = try EncodedFrame(data: (Data([1, 2, 3]) + bytes).dropFirst(3))
        XCTAssertEqual(decoded.frameID, 42)
        XCTAssertEqual(decoded.captureTimeNanoseconds, 123456789)
        XCTAssertEqual(decoded.encodedTimeNanoseconds, 123499999)
        XCTAssertEqual(decoded.payload, original.payload)
        var legacy = bytes
        legacy.replaceSubrange(0..<4, with: Data("FRV1".utf8)); legacy.removeSubrange(25..<49)
        let old = try EncodedFrame(data: legacy)
        XCTAssertEqual(old.frameID, 0); XCTAssertEqual(old.captureTimeNanoseconds, 0)
        XCTAssertEqual(old.payload, original.payload)
    }

    func testBackpressureSkipsBeforeEncodingAndStaticImageRecoversWhenCapacityReturns() throws {
        let queue = DispatchQueue(label: "farreach.test.preencode-capacity")
        let image = try image(width: 64, height: 64)
        let recovered = expectation(description: "latest static image encoded after capacity returns")
        var capacity = false, frames = 0
        var stats = MediaPipelineStatistics()
        let pipeline = try FrameEncodingPipeline(width: 64, height: 64, configuration: .automaticInitial, queue: queue,
            onFrame: { frame in
                frames += 1
                XCTAssertTrue(frame.isKeyframe)
                XCTAssertGreaterThan(frame.frameID, 0)
                XCTAssertGreaterThan(frame.encodedTimeNanoseconds, 0)
                if frames == 1 { recovered.fulfill() }
            }, onError: { XCTFail("Encoding failed: \($0)") }, canEncode: { capacity }, onStatistics: { stats = $0 })
        defer { queue.sync { pipeline.stop() } }
        queue.sync {
            for index in 1...5 { pipeline.receive(image, presentationTime: CMTime(value: Int64(index), timescale: 30)) }
            pipeline.requestKeyframe()
        }
        let blocked = expectation(description: "no encoding under backpressure")
        queue.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(frames, 0)
            XCTAssertGreaterThanOrEqual(stats.skippedBeforeEncoding, 5)
            capacity = true; blocked.fulfill()
        }
        wait(for: [blocked, recovered], timeout: 2)
        let settled = expectation(description: "recovery retries stop after success")
        queue.asyncAfter(deadline: .now() + 0.5) { XCTAssertEqual(frames, 1); settled.fulfill() }
        wait(for: [settled], timeout: 2)
    }

    func testRateUpdatePreservesGenerationAndResizeRequiresFreshMatchingImage() throws {
        let queue = DispatchQueue(label: "farreach.test.adaptive-resize")
        let small = try image(width: 64, height: 64), large = try image(width: 128, height: 96)
        let first = expectation(description: "first image"), rateUpdated = expectation(description: "updated rate image")
        let resized = expectation(description: "new resolution IDR")
        var frames: [(EncodedFrame, UInt64)] = []
        var states: [(Bool, UInt64)] = []
        var pipeline: CaptureAvailabilityPipeline!
        queue.sync {
            pipeline = CaptureAvailabilityPipeline(width: 64, height: 64, configuration: .automaticInitial, queue: queue,
                onFrame: { frame, generation in
                    frames.append((frame, generation))
                    switch frames.count { case 1: first.fulfill(); case 2: rateUpdated.fulfill(); case 3: resized.fulfill(); default: XCTFail("Unexpected extra frame") }
                }, onAvailability: { states.append(($0, $1)) }, onError: { XCTFail("Capture pipeline failed: \($0)") })
            pipeline.receive(status: .complete, image: small, presentationTime: CMTime(value: 1, timescale: 30))
        }
        defer { queue.sync { pipeline.stop() } }
        wait(for: [first], timeout: 5)
        try queue.sync {
            try pipeline.updateConfiguration(.init(maxDimension: 1280, framesPerSecond: 60, bitrate: 1_000_000), width: 64, height: 64)
            pipeline.receive(status: .complete, image: small, presentationTime: CMTime(value: 2, timescale: 30))
        }
        wait(for: [rateUpdated], timeout: 5)
        try queue.sync {
            XCTAssertEqual(frames[0].1, frames[1].1)
            try pipeline.updateConfiguration(.automaticMaximum, width: 128, height: 96)
            pipeline.receive(status: .complete, image: small, presentationTime: CMTime(value: 3, timescale: 30))
            pipeline.requestKeyframe()
            XCTAssertEqual(frames.count, 2, "An old-size buffer cannot restore a resized generation")
            XCTAssertEqual(states.last?.0, false)
            pipeline.receive(status: .complete, image: large, presentationTime: CMTime(value: 4, timescale: 30))
        }
        wait(for: [resized], timeout: 5)
        queue.sync {
            XCTAssertTrue(frames[2].0.isKeyframe)
            XCTAssertEqual(frames[2].0.width, 128); XCTAssertEqual(frames[2].0.height, 96)
            XCTAssertNotEqual(frames[2].1, frames[1].1)
        }
    }

    func testFramePreparationRunsOffMainAndRejectsMismatchedCachedDimensions() throws {
        let image = try image(width: 64, height: 64)
        let encoder = try H264Encoder(width: 64, height: 64)
        let encoded = expectation(description: "encoded fixture")
        let prepared = expectation(description: "prepared away from main")
        let preparer = MediaFramePreparer()
        encoder.onFrame = { frame in
            encoded.fulfill()
            DispatchQueue.global(qos: .userInteractive).async {
                XCTAssertFalse(Thread.isMainThread)
                do {
                    let result = try preparer.prepare(frame)
                    XCTAssertEqual(CMSampleBufferGetNumSamples(result.sample), 1)
                    XCTAssertEqual(result.frame.frameID, frame.frameID)
                    let bad = try EncodedFrame(width: 128, height: 64, isKeyframe: true, sps: frame.sps, pps: frame.pps, payload: frame.payload)
                    XCTAssertThrowsError(try preparer.prepare(bad))
                    preparer.reset()
                    XCTAssertNoThrow(try preparer.prepare(frame))
                } catch { XCTFail("Preparing video failed: \(error)") }
                prepared.fulfill()
            }
        }
        encoder.onError = { XCTFail("Encoding failed: \($0)") }
        encoder.encode(image, presentationTime: CMClockGetTime(CMClockGetHostTimeClock()))
        encoder.finish()
        wait(for: [encoded, prepared], timeout: 5)
    }

    private func image(width: Int, height: Int) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
        let image = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image)!, 128, CVPixelBufferGetBytesPerRow(image) * height)
        CVPixelBufferUnlockBaseAddress(image, [])
        return image
    }
}
