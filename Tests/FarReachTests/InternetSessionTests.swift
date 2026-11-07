import XCTest
import AppKit
import Combine
@testable import FarReach
import RemoteCore
import RemoteMedia

/// Real two-helper direct WebRTC plus device identity and standby. Synthetic
/// screen only; an in-memory pairing store prevents any test Keychain writes.
final class InternetSessionTests: XCTestCase {
    @MainActor
    func testManualPairingStandbyResumeKeepsHelperAndTrustWithoutSTUN() async throws {
        _ = NSApplication.shared
        let helper = try helperURL()
        let store = InMemoryPairingStore()
        let model = AppModel(networkHelperURL: helper, pairingStore: store)
        model.stunServer = ""
        let peer = try WebRTCPeer(role: .host, stunURLs: [], helperURL: helper)
        let host = try SyntheticSessionHost(name: "Direct Synthetic Mac")
        let responsePrepared = expectation(description: "manual response prepared once")
        let firstFrame = expectation(description: "authenticated first wrapped frame")
        let resumedFrame = expectation(description: "resume sends another wrapped frame")
        let shortRecoveryFrame = expectation(description: "short interruption reauthorizes the existing media generation")
        let paused = expectation(description: "host sees pause and retains direct channel")
        let inputReceived = expectation(description: "direct authenticated input reaches dummy host")
        let hostClosed = expectation(description: "full disconnect terminates helper session")
        var responseCount = 0
        var receivedFrames = 0
        var resuming = false
        var resumedOnce = false
        var pathReceived = false
        var readyCount = 0
        var disconnecting = false
        var shortRecovery = false
        let oldEnqueue = model.desktop.onFrameEnqueued
        model.desktop.onFrameEnqueued = {
            oldEnqueue?(); receivedFrames += 1
            if receivedFrames == 1 { firstFrame.fulfill() }
            if shortRecovery { shortRecovery = false; shortRecoveryFrame.fulfill() }
            if resuming, host.resumeCount == 3, !resumedOnce { resumedOnce = true; resumedFrame.fulfill() }
        }
        let responseSubscription = model.$connectionResponse.sink { response in
            guard !response.isEmpty else { return }
            responseCount += 1
            XCTAssertEqual(responseCount, 1)
            XCTAssertTrue(response.hasPrefix("farreach-answer://v2/"))
            XCTAssertTrue(model.isConnecting)
            XCTAssertFalse(model.isViewing)
            do { try peer.applyResponse(response) }
            catch { XCTFail("Could not apply local response: \(error)") }
            responsePrepared.fulfill()
        }
        peer.onInvitation = { invitation in model.pastedInvitation = invitation; model.connect() }
        peer.onPath = { path in
            guard let data = path.data(using: .utf8),
                  let fields = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                XCTFail("Missing direct path metadata"); return
            }
            XCTAssertEqual(fields["protocol"], "udp")
            XCTAssertNotEqual(fields["localType"], "relay")
            XCTAssertNotEqual(fields["remoteType"], "relay")
            pathReceived = true
        }
        host.onPause = { paused.fulfill() }
        host.onInput = { event in
            if event.kind == .move {
                XCTAssertEqual(event.x, 0.25); XCTAssertEqual(event.y, 0.75)
                inputReceived.fulfill()
            }
        }
        host.onClose = { error in
            if !disconnecting { XCTFail("Direct standby session ended early: \(String(describing: error))") }
            hostClosed.fulfill()
        }
        peer.onReady = {
            readyCount += 1
            XCTAssertTrue(pathReceived)
            do { try host.attach(peer) }
            catch { XCTFail("Could not start identity authentication: \(error)") }
        }
        // Report failures before attach() has installed the host fixture callback.
        peer.onClose = { error in XCTFail("Direct setup failed: \(String(describing: error))") }
        defer {
            responseSubscription.cancel()
            host.onClose = nil; peer.onClose = nil
            model.shutdown(); host.close(); peer.close()
        }
        peer.start()
        await fulfillment(of: [responsePrepared, firstFrame], timeout: 20)
        XCTAssertTrue(model.isViewing)
        XCTAssertFalse(model.isConnecting)
        XCTAssertTrue(model.canResumeViewing)
        XCTAssertEqual(model.remoteName, host.name)
        XCTAssertEqual(model.desktop.frameSize, CGSize(width: 64, height: 64))
        XCTAssertTrue(model.pastedInvitation.isEmpty)
        XCTAssertTrue(model.connectionResponse.isEmpty)
        XCTAssertTrue(model.connectionPath.contains("UDP"))
        XCTAssertNil(model.error)
        let saved = try XCTUnwrap(store.listDevices().first)
        XCTAssertEqual(saved.id, host.identity.id)
        XCTAssertEqual(saved.publicKey, host.identity.publicKey)
        let pairingMessages = host.pairingMessageCount
        let originalPath = model.connectionPath
        XCTAssertEqual(host.authenticationCount, 1)

        shortRecovery = true
        model.noteConnectionState(.recovering)
        XCTAssertFalse(model.desktop.inputEnabled)
        XCTAssertTrue(model.isRecovering)
        model.noteConnectionState(.connected)
        await fulfillment(of: [shortRecoveryFrame], timeout: 8)
        XCTAssertFalse(model.isRecovering)
        XCTAssertTrue(model.desktop.inputEnabled)
        XCTAssertEqual(readyCount, 1)
        XCTAssertEqual(host.generation, 1, "A transient outage must not require capture restart")

        model.desktop.onInput?(RemoteInput(kind: .move, x: 0.25, y: 0.75))
        await fulfillment(of: [inputReceived], timeout: 3)
        model.endViewing()
        await fulfillment(of: [paused], timeout: 3)
        XCTAssertFalse(model.isViewing)
        XCTAssertTrue(model.canResumeViewing)
        XCTAssertEqual(model.connectedDeviceID, saved.id)
        XCTAssertEqual(model.connectionPath, originalPath)
        XCTAssertFalse(host.streaming)
        XCTAssertEqual(model.desktop.frameSize, .zero)
        XCTAssertFalse(model.desktop.inputEnabled)
        let baselinePings = host.pingCount
        try await Task.sleep(nanoseconds: 2_250_000_000)
        XCTAssertGreaterThanOrEqual(host.pingCount - baselinePings, 2)
        XCTAssertNotNil(model.pingMS)
        XCTAssertNil(model.error)

        resuming = true
        model.resumeViewing()
        await fulfillment(of: [resumedFrame], timeout: 8)
        XCTAssertTrue(model.isViewing)
        XCTAssertTrue(model.desktop.inputEnabled)
        XCTAssertEqual(model.connectionPath, originalPath)
        XCTAssertEqual(host.resumeCount, 3)
        XCTAssertEqual(host.generation, 3)
        XCTAssertEqual(readyCount, 1, "Resume must reuse the same helper connection")
        XCTAssertEqual(responseCount, 1, "Resume must not require another SDP exchange")
        XCTAssertEqual(host.authenticationCount, 1)
        XCTAssertEqual(host.pairingMessageCount, pairingMessages)
        XCTAssertEqual(try store.listDevices().map(\.id), [saved.id])

        disconnecting = true
        model.disconnect()
        await fulfillment(of: [hostClosed], timeout: 12)
        XCTAssertFalse(model.isViewing)
        XCTAssertFalse(model.canResumeViewing)
        XCTAssertNil(model.connectedDeviceID)
        XCTAssertTrue(model.connectionPath.isEmpty)
        XCTAssertTrue(model.connectionResponse.isEmpty)
        XCTAssertNil(model.pingMS)
        XCTAssertEqual(try store.listDevices().map(\.id), [saved.id])
    }

    private func helperURL() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = ProcessInfo.processInfo.environment["FARREACH_NETWORK_HELPER"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("Networking/bin/FarReachNetwork")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw XCTSkip("Build the real networking helper with scripts/build-network.sh or set FARREACH_NETWORK_HELPER.")
        }
        return helper
    }
}
