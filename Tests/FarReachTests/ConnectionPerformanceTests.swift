import XCTest
import AppKit
@testable import FarReach
import RemoteCore
import RemoteMedia

final class ConnectionPerformanceTests: XCTestCase {
    func testDiagnosticPercentilesDiscardInvalidSamplesAndKeepTailLatency() {
        let distribution = PerformanceDistribution([1, 2, 3, 4, 100, .nan, .infinity, -1])
        XCTAssertEqual(distribution.count, 5)
        XCTAssertEqual(distribution.p50, 3)
        XCTAssertEqual(distribution.p95, 100)
        XCTAssertEqual(distribution.maximum, 100)
        XCTAssertNil(PerformanceDistribution([]).p95)
    }
    func testRecoveryBudgetAndRetryCapUseElapsedTime() {
        XCTAssertEqual((0...7).map { RecoveryPolicy.retryDelay(attempt: $0) }, [1, 2, 4, 8, 8, 8, 8, 8])
        XCTAssertTrue(RecoveryPolicy.permitsRetry(started: 100, now: 159.99))
        XCTAssertFalse(RecoveryPolicy.permitsRetry(started: 100, now: 160))
    }

    func testMediaAdmissionRejectsPausedOldGenerationAndDependentFrames() throws {
        let mailbox = MediaSessionMailbox(), peer = RecordingPeer()
        let key = try frame(key: true), delta = try frame(key: false)
        XCTAssertFalse(try mailbox.send(key, generation: 1, peer: peer))
        mailbox.authorize(1)
        XCTAssertFalse(try mailbox.send(delta, generation: 1, peer: peer))
        XCTAssertTrue(try mailbox.send(key, generation: 1, peer: peer))
        XCTAssertTrue(try mailbox.send(delta, generation: 1, peer: peer))
        mailbox.authorize(2)
        XCTAssertFalse(try mailbox.send(key, generation: 1, peer: peer))
        XCTAssertFalse(try mailbox.send(delta, generation: 2, peer: peer))
        XCTAssertTrue(try mailbox.send(key, generation: 2, peer: peer))
        mailbox.authorize(0)
        XCTAssertFalse(try mailbox.send(key, generation: 2, peer: peer))
        XCTAssertEqual(peer.sent.count, 3)
    }

    func testConcurrentDropCannotClearRecoveryKeyframeRequirement() throws {
        let mailbox = MediaSessionMailbox(), peer = RecordingPeer()
        mailbox.authorize(7)
        peer.duringSend = { mailbox.requireKeyframe() }
        XCTAssertTrue(try mailbox.send(frame(key: true), generation: 7, peer: peer))
        peer.duringSend = nil
        XCTAssertFalse(try mailbox.send(frame(key: false), generation: 7, peer: peer))
        XCTAssertTrue(try mailbox.send(frame(key: true), generation: 7, peer: peer))
        XCTAssertTrue(try mailbox.send(frame(key: false), generation: 7, peer: peer))
    }

    func testCaptureDurationUsesOnlyTwoHostTimestamps() throws {
        let frame = try EncodedFrame(width: 64, height: 64, isKeyframe: true,
            sps: Data([0x67]), pps: Data([0x68]), payload: Data([0, 0, 0, 1, 0x65]),
            frameID: 91, captureTimeNanoseconds: 8_000_000_000, encodedTimeNanoseconds: 8_012_000_000)
        XCTAssertEqual(MediaSessionMailbox.encodeDuration(frame), 12)
    }

    @MainActor func testDiagnosticsExcludePrivateSessionFields() throws {
        _ = NSApplication.shared
        let model = AppModel(pairingStore: InMemoryPairingStore())
        defer { model.shutdown() }
        model.pastedInvitation = "private-invitation"
        model.remoteName = "private-device-name"
        model.signalingURL = "https://private-signaling.example"
        let data = try model.diagnosticsData()
        let report = try JSONDecoder().decode(PerformanceReport.self, from: data)
        XCTAssertEqual(report.formatVersion, 1)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("private-"))
        XCTAssertTrue(report.measurementNotes.contains { $0.contains("not glass-to-glass") })
    }

    private func frame(key: Bool) throws -> EncodedFrame {
        try EncodedFrame(width: 64, height: 64, isKeyframe: key,
            sps: Data([0x67]), pps: Data([0x68]), payload: Data([0, 0, 0, 1, key ? 0x65 : 0x41]))
    }
}

private final class RecordingPeer: RemotePeer {
    var channelBinding: Data? = Data(repeating: 1, count: 32)
    var onReady: (() -> Void)?
    var onMessage: ((WireMessage) -> Void)?
    var onClose: ((Error?) -> Void)?
    var sent: [WireMessage] = []
    var duringSend: (() -> Void)?
    func start() {}
    func close() {}
    func send(_ message: WireMessage) -> Bool { sent.append(message); duringSend?(); return true }
}
