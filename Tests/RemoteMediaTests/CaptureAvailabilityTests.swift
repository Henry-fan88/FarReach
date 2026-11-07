import XCTest
import CoreMedia
import CoreVideo
import ScreenCaptureKit
@testable import RemoteMedia

final class CaptureAvailabilityTests: XCTestCase {
    func testEpochsAreDistinctAcrossAvailabilityAndStreamerInstances() {
        var first = CaptureAvailabilityState(), second = CaptureAvailabilityState()
        let started = first.begin()
        XCTAssertFalse(first.isAvailable)
        let live = first.resume()
        XCTAssertTrue(first.isAvailable)
        let unavailable = first.invalidate()
        XCTAssertFalse(first.isAvailable)
        XCTAssertNil(first.invalidate(), "Repeated unavailable samples must not churn epochs")
        let resumed = first.resume()
        let stopped = first.invalidate(force: true)
        let other = second.begin()
        XCTAssertEqual(Set([started, live, unavailable!, resumed, stopped!, other]).count, 6)
    }

    func testIdleRecoveryPreservedButBlankClearsCacheAndResumesWithFreshIDR() throws {
        let queue = DispatchQueue(label: "farreach.test.capture-availability")
        let image = try syntheticImage()
        let initial = expectation(description: "initial frame")
        let idle = expectation(description: "idle cached keyframe")
        let resumed = expectation(description: "fresh frame after blank")
        var frames: [(EncodedFrame, UInt64)] = []
        var events: [(Bool, UInt64)] = []
        var pipeline: CaptureAvailabilityPipeline!
        queue.sync {
            pipeline = CaptureAvailabilityPipeline(width: 64, height: 64, configuration: .init(), queue: queue,
                onFrame: { frame, epoch in
                    frames.append((frame, epoch))
                    switch frames.count {
                    case 1: initial.fulfill()
                    case 2: idle.fulfill()
                    case 3: resumed.fulfill()
                    default: XCTFail("Unexpected cached/late frame after availability change")
                    }
                }, onAvailability: { events.append(($0, $1)) }, onError: { XCTFail("Encoder failed: \($0)") })
            pipeline.receive(status: .complete, image: image, presentationTime: CMTime(value: 1, timescale: 30))
        }
        defer { queue.sync { pipeline.stop() } }
        wait(for: [initial], timeout: 5)
        queue.sync {
            pipeline.receive(status: .idle, image: nil, presentationTime: .invalid)
            pipeline.requestKeyframe()
        }
        wait(for: [idle], timeout: 5)
        queue.sync {
            XCTAssertEqual(frames[0].1, frames[1].1, "Idle recovery remains in the same available epoch")
            pipeline.receive(status: .blank, image: nil, presentationTime: .invalid)
            pipeline.receive(status: .suspended, image: nil, presentationTime: .invalid)
            pipeline.requestKeyframe()
        }
        let pause = expectation(description: "no stale cached output")
        queue.asyncAfter(deadline: .now() + .milliseconds(400)) {
            XCTAssertEqual(frames.count, 2)
            XCTAssertEqual(events.map(\.0), [false, true, false])
            XCTAssertNotEqual(events[1].1, events[2].1)
            pause.fulfill()
        }
        wait(for: [pause], timeout: 2)
        queue.sync { pipeline.receive(status: .complete, image: image, presentationTime: CMTime(value: 2, timescale: 30)) }
        wait(for: [resumed], timeout: 5)
        queue.sync {
            XCTAssertTrue(frames[2].0.isKeyframe)
            XCTAssertNotEqual(frames[2].1, frames[0].1)
            XCTAssertEqual(events.map(\.0), [false, true, false, true])
            XCTAssertEqual(events.last?.1, frames[2].1)
            pipeline.stop()
            pipeline.requestKeyframe()
            pipeline.receive(status: .complete, image: image, presentationTime: CMTime(value: 3, timescale: 30))
            XCTAssertEqual(events.map(\.0), [false, true, false, true, false])
        }
    }

    func testInvalidationSuppressesInFlightEncoderOutputBeforeResume() throws {
        let queue = DispatchQueue(label: "farreach.test.capture-generation")
        let image = try syntheticImage()
        let resumed = expectation(description: "resumed generation produced a fresh frame")
        var frames: [UInt64] = []
        var liveEpochs: [UInt64] = []
        var pipeline: CaptureAvailabilityPipeline!
        queue.sync {
            pipeline = CaptureAvailabilityPipeline(width: 64, height: 64, configuration: .init(), queue: queue,
                onFrame: { frame, epoch in
                    XCTAssertTrue(frame.isKeyframe)
                    frames.append(epoch)
                    resumed.fulfill()
                }, onAvailability: { available, epoch in if available { liveEpochs.append(epoch) } },
                onError: { XCTFail("Encoder failed: \($0)") })
            pipeline.receive(status: .complete, image: image, presentationTime: CMTime(value: 1, timescale: 30))
            // Both calls share the capture queue: even an already-completed VT
            // callback cannot deliver until the invalidation finishes.
            pipeline.receive(status: .suspended, image: nil, presentationTime: .invalid)
        }
        defer { queue.sync { pipeline.stop() } }
        let discarded = expectation(description: "old callbacks drained")
        queue.asyncAfter(deadline: .now() + .milliseconds(350)) {
            XCTAssertTrue(frames.isEmpty, "Old encoder callbacks must not leak past invalidation")
            pipeline.receive(status: .complete, image: image, presentationTime: CMTime(value: 2, timescale: 30))
            discarded.fulfill()
        }
        wait(for: [discarded, resumed], timeout: 5)
        queue.sync {
            XCTAssertEqual(frames.count, 1)
            XCTAssertEqual(liveEpochs.count, 2)
            XCTAssertNotEqual(liveEpochs[0], liveEpochs[1])
            XCTAssertEqual(frames.first, liveEpochs.last)
            pipeline.receive(status: .complete, image: nil, presentationTime: .invalid)
            pipeline.requestKeyframe()
        }
        let noMissingImageRetry = expectation(description: "missing complete image invalidates cache")
        queue.asyncAfter(deadline: .now() + .milliseconds(350)) {
            XCTAssertEqual(frames.count, 1)
            noMissingImageRetry.fulfill()
        }
        wait(for: [noMissingImageRetry], timeout: 2)
    }

    private func syntheticImage() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let image = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image)!, 128, CVPixelBufferGetBytesPerRow(image) * 64)
        CVPixelBufferUnlockBaseAddress(image, [])
        return image
    }
}
