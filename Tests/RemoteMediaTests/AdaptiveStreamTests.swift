import XCTest
@testable import RemoteMedia

final class AdaptiveStreamTests: XCTestCase {
    func testStableRTTStepDoesNotRepeatedlyCutAnUnchangedHealthyBandwidthBudget() {
        var controller = AdaptiveStreamController()
        for second in 0...10 { _ = controller.update(.init(availableBitrate: 2_000_000, rttMilliseconds: 10), now: Double(second)) }
        let settled = controller.configuration
        XCTAssertEqual(settled.bitrate, 1_700_000)
        for second in 11...30 {
            _ = controller.update(.init(availableBitrate: 2_000_000, rttMilliseconds: 80), now: Double(second))
            XCTAssertEqual(controller.configuration, settled, "A cached higher RTT with no queue/loss is not a new congestion event")
        }
        _ = controller.update(.init(availableBitrate: 2_000_000, rttMilliseconds: 80, sendQueueMilliseconds: 80), now: 31)
        XCTAssertLessThan(controller.configuration.bitrate, settled.bitrate, "Actual queue pressure must still reduce the rate")
        let queued = controller.configuration.bitrate
        _ = controller.update(.init(availableBitrate: 2_000_000, rttMilliseconds: 80, lossFraction: 0.12), now: 32)
        XCTAssertLessThan(controller.configuration.bitrate, queued, "Actual loss must still reduce the rate")
    }

    func testAutoStartsConservativelyAndRecoversToCeilingWithHealthyFeedback() {
        var controller = AdaptiveStreamController()
        XCTAssertEqual(controller.configuration, .automaticInitial)
        let feedback = StreamFeedback(availableBitrate: 20_000_000, rttMilliseconds: 25)
        for second in 0...40 { _ = controller.update(feedback, now: Double(second)) }
        XCTAssertEqual(controller.configuration, .automaticMaximum)
        for second in 41...70 { XCTAssertNil(controller.update(feedback, now: Double(second))) }
    }

    func testCongestionCutsRateImmediatelyAndGeometryOnlyAfterSustainedPressure() {
        var controller = AdaptiveStreamController(automatic: false)
        _ = controller.update(.init(availableBitrate: 20_000_000, rttMilliseconds: 20), now: 0)
        let before = controller.configuration
        let pressure = StreamFeedback(availableBitrate: 1_000_000, rttMilliseconds: 120, lossFraction: 0.12, sendQueueMilliseconds: 180)
        let first = controller.update(pressure, now: 1)
        XCTAssertLessThan(first!.bitrate, before.bitrate)
        XCTAssertEqual(first!.maxDimension, before.maxDimension)
        for second in 2...5 { _ = controller.update(pressure, now: Double(second)) }
        XCTAssertLessThanOrEqual(controller.configuration.maxDimension, 960)
        XCTAssertLessThanOrEqual(controller.configuration.framesPerSecond, 30)
        XCTAssertGreaterThanOrEqual(controller.configuration.bitrate, 500_000)
        let low = controller.configuration
        _ = controller.update(.init(availableBitrate: 20_000_000, rttMilliseconds: 20), now: 6)
        XCTAssertEqual(controller.configuration, low, "A single good report must not undo congestion response")
    }

    func testPresetCeilingsAndInvalidOrDuplicatedClockReports() {
        let ceiling = StreamConfiguration(maxDimension: 1280, framesPerSecond: 30, bitrate: 4_000_000)
        var controller = AdaptiveStreamController(maximum: ceiling)
        for second in 0...50 { _ = controller.update(.init(availableBitrate: 100_000_000), now: Double(second)) }
        XCTAssertEqual(controller.configuration, ceiling)
        XCTAssertNil(controller.update(.init(lossFraction: 1), now: 50))
        XCTAssertNil(controller.update(.init(lossFraction: 1), now: 49))
        XCTAssertNil(controller.update(.init(lossFraction: 1), now: .nan))
        _ = controller.update(.init(lossFraction: .nan, sendQueueMilliseconds: .infinity), now: 51)
        XCTAssertLessThan(controller.configuration.bitrate, ceiling.bitrate)
    }

    func testHighStableRTTAloneDoesNotMisidentifyCongestion() {
        var controller = AdaptiveStreamController()
        for second in 0...35 { _ = controller.update(.init(availableBitrate: 20_000_000, rttMilliseconds: 220), now: Double(second)) }
        XCTAssertEqual(controller.configuration, .automaticMaximum)
    }
}
