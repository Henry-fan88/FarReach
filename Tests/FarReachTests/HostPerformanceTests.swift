import XCTest
import AppKit
import Combine
@testable import FarReach
import RemoteCore
import RemoteMedia

final class HostPerformanceTests: XCTestCase {
    func testIntentionalPacedKeyframeDoesNotReduceCreditControlledQuality() {
        let initial = TransportStatistics(targetBitrate: 4_000_000, queueMS: 0,
            admissionDroppedFrames: 0, pacingDroppedEvents: 0)
        var pacedKeyframe = initial
        pacedKeyframe.queueMS = 300
        let creditedQueue = TransportPressure.feedbackQueueMS(pacedKeyframe, previous: initial, usesMediaCredits: true)
        XCTAssertEqual(creditedQueue, 0)
        XCTAssertEqual(TransportPressure.feedbackQueueMS(pacedKeyframe, previous: initial, usesMediaCredits: false), 300)
        var controller = AdaptiveStreamController()
        let startingRate = controller.configuration.bitrate
        _ = controller.update(.init(availableBitrate: pacedKeyframe.targetBitrate, sendQueueMilliseconds: creditedQueue), now: 1)
        XCTAssertEqual(controller.configuration.bitrate, startingRate)
        pacedKeyframe.admissionDroppedFrames = 1
        let actualPressure = TransportPressure.feedbackQueueMS(pacedKeyframe, previous: initial, usesMediaCredits: true)
        XCTAssertEqual(actualPressure, 160)
        _ = controller.update(.init(availableBitrate: pacedKeyframe.targetBitrate, sendQueueMilliseconds: actualPressure), now: 2)
        XCTAssertLessThan(controller.configuration.bitrate, startingRate, "Actual admission loss must still lower the encoder rate")
    }
    func testPerformanceIsOptionalBoundedAndIgnoredByLegacyHostInfoReaders() throws {
        let old = HostInfo(name: "old host", width: 1280, height: 800)
        let oldData = try JSONEncoder().encode(old)
        XCTAssertNil(try JSONDecoder().decode(HostInfo.self, from: oldData).performance)
        let snapshot = Self.snapshot(counter: .max)
        let current = HostInfo(name: String(repeating: "x", count: 256), width: 1280, height: 800, performance: snapshot)
        XCTAssertTrue(current.isValid)
        let bytes = try JSONEncoder().encode(current)
        XCTAssertLessThanOrEqual(bytes.count, MessageKind.hello.maximumPayloadSize)
        XCTAssertEqual(try JSONDecoder().decode(HostInfo.self, from: bytes).performance, snapshot)
        struct LegacyInfo: Decodable { let protocolVersion: Int; let name: String; let width: Int; let height: Int; let fps: Int }
        XCTAssertEqual(try JSONDecoder().decode(LegacyInfo.self, from: bytes).width, 1280)
        var malformed = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var performance = try XCTUnwrap(malformed["performance"] as? [String: Any])
        performance["queueMS"] = -1
        malformed["performance"] = performance
        XCTAssertFalse(try JSONDecoder().decode(HostInfo.self, from: JSONSerialization.data(withJSONObject: malformed)).isValid)
        performance["queueMS"] = 1; performance["softwareVersion"] = String(repeating: "x", count: 65)
        malformed["performance"] = performance
        XCTAssertFalse(try JSONDecoder().decode(HostInfo.self, from: JSONSerialization.data(withJSONObject: malformed)).isValid)
    }

    func testKeyframeRequestsAndDependencySuppressionDoNotCreateCongestionPressure() {
        let initial = TransportStatistics(framesDropped: 0, keyframeRequests: 0, admissionDroppedFrames: 0,
            dependencySuppressedFrames: 0, pacingDroppedEvents: 0)
        var recovery = initial
        recovery.framesDropped = 90; recovery.keyframeRequests = 10; recovery.dependencySuppressedFrames = 90
        XCTAssertFalse(TransportPressure.hasNewAdmissionOrPacingDrop(recovery, after: initial))
        recovery.admissionDroppedFrames = 1
        XCTAssertTrue(TransportPressure.hasNewAdmissionOrPacingDrop(recovery, after: initial))
        recovery.admissionDroppedFrames = 0; recovery.pacingDroppedEvents = 1
        XCTAssertTrue(TransportPressure.hasNewAdmissionOrPacingDrop(recovery, after: initial))
        XCTAssertFalse(TransportPressure.hasNewAdmissionOrPacingDrop(TransportStatistics(framesDropped: 100), after: nil),
                       "Legacy aggregate counters cannot distinguish recovery from congestion")
    }

    @MainActor
    func testAuthenticatedViewerStoresAndExportsHostPerformanceWithoutIdentity() async throws {
        _ = NSApplication.shared
        let model = AppModel(pairingStore: InMemoryPairingStore())
        let host = try SyntheticSessionHost(name: "Private host identity")
        let snapshot = Self.snapshot(counter: 120)
        let received = expectation(description: "host-side counters received over authenticated session")
        let subscription = model.$remoteHostPerformance.sink { value in if value == snapshot { received.fulfill() } }
        host.onResume = {
            let info = HostInfo(name: "Private display name", width: 64, height: 64, performance: snapshot)
            if let bytes = try? JSONEncoder().encode(info) { _ = host.peer?.send(WireMessage(kind: .hello, payload: bytes)) }
        }
        let key = try PairingInvitation.generateKey()
        let listener = try SecureListener(key: key, port: 0)
        let listening = expectation(description: "synthetic listener ready")
        var port: UInt16 = 0
        listener.onReady = { port = $0; listening.fulfill() }
        listener.onError = { XCTFail($0.localizedDescription) }
        listener.onConnection = { peer in do { try host.attach(peer) } catch { XCTFail(error.localizedDescription) } }
        defer { subscription.cancel(); model.shutdown(); host.close(); listener.stop() }
        listener.start()
        await fulfillment(of: [listening], timeout: 5)
        model.pastedInvitation = try PairingInvitation(host: "127.0.0.1", port: port, key: key).urlString
        model.connect()
        await fulfillment(of: [received], timeout: 8)
        let data = try model.diagnosticsData()
        let report = try JSONDecoder().decode(PerformanceReport.self, from: data)
        XCTAssertEqual(report.remoteHostPerformance, snapshot)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Private"))
        XCTAssertEqual(report.remoteHostPerformance?.softwareVersion, "0.5.1")
        XCTAssertEqual(report.remoteHostPerformance?.softwareBuild, "8")
    }

    private static func snapshot(counter: UInt64) -> HostPerformanceSnapshot {
        HostPerformanceSnapshot(elapsedSeconds: 12, captureGeneration: 5, captureAvailable: true,
            captureWidth: 1280, captureHeight: 800, configuredMaxDimension: 1280, configuredFPS: 30,
            encoderBitrate: 2_000_000, capturedFrames: counter, encodedFrames: counter, encodedKeyframes: counter,
            skippedBeforeEncoding: counter, encoderDroppedFrames: counter, recoveryRequests: counter,
            dataRateLimitSupported: true,
            transport: TransportStatistics(targetBitrate: 2_000_000, rttMS: 80, queuedBytes: 500, queueMS: 2,
                packetsSent: counter, framesDropped: counter, keyframes: counter,
                keyframeRequests: counter, admissionDroppedFrames: counter, dependencySuppressedFrames: counter,
                pacingDroppedEvents: counter, packetizationFailures: counter),
            softwareVersion: "0.5.1", softwareBuild: "8")
    }
}
