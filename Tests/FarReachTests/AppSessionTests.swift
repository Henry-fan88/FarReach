import XCTest
import AppKit
import Combine
@testable import FarReach
import RemoteCore
import RemoteMedia

/// AppModel tests use real TLS and synthetic video with an in-memory pairing
/// store. They do not capture the screen, inject input, or write the Keychain.
final class AppSessionTests: XCTestCase {
    @MainActor
    func testPairOncePauseResumeKeepsIdentityAndHeartbeat() async throws {
        _ = NSApplication.shared
        let store = InMemoryPairingStore()
        let model = AppModel(pairingStore: store)
        let host = try SyntheticSessionHost()
        let firstFrame = expectation(description: "authenticated first frame")
        let resumedFrame = expectation(description: "fresh frame after resume")
        let paused = expectation(description: "host pauses without closing transport")
        let input = expectation(description: "authenticated viewer input")
        let closed = expectation(description: "full disconnect closes transport")
        var frames = 0
        var resuming = false
        var resumedOnce = false
        let oldEnqueue = model.desktop.onFrameEnqueued
        model.desktop.onFrameEnqueued = {
            oldEnqueue?(); frames += 1
            if frames == 1 { firstFrame.fulfill() }
            if resuming, host.resumeCount == 2, !resumedOnce { resumedOnce = true; resumedFrame.fulfill() }
        }
        host.onPause = { paused.fulfill() }
        host.onInput = { event in
            if event.kind == .move {
                XCTAssertEqual(event.x, 0.25); XCTAssertEqual(event.y, 0.75)
                input.fulfill()
            }
        }
        var disconnecting = false
        host.onClose = { error in
            if !disconnecting { XCTFail("Paired transport closed during viewing/standby: \(String(describing: error))") }
            closed.fulfill()
        }
        let listener = try await connectTLS(model, host: host)
        defer { host.onClose = nil; model.shutdown(); host.close(); listener.stop() }
        await fulfillment(of: [firstFrame], timeout: 8)
        XCTAssertTrue(model.isViewing)
        XCTAssertFalse(model.isConnecting)
        XCTAssertTrue(model.canResumeViewing)
        XCTAssertEqual(model.remoteName, host.name, "Display name must come from authenticated identity")
        XCTAssertEqual(model.desktop.frameSize, CGSize(width: 64, height: 64))
        XCTAssertTrue(model.pastedInvitation.isEmpty)
        XCTAssertNil(model.error)
        let saved = try XCTUnwrap(store.listDevices().first)
        XCTAssertEqual(saved.id, host.identity.id)
        XCTAssertEqual(saved.publicKey, host.identity.publicKey)
        XCTAssertEqual(host.authenticationCount, 1)
        let pairingMessages = host.pairingMessageCount

        model.desktop.onInput?(RemoteInput(kind: .move, x: 0.25, y: 0.75))
        await fulfillment(of: [input], timeout: 3)
        model.endViewing()
        await fulfillment(of: [paused], timeout: 3)
        XCTAssertFalse(model.isViewing)
        XCTAssertTrue(model.canResumeViewing)
        XCTAssertEqual(model.connectedDeviceID, saved.id)
        XCTAssertEqual(model.desktop.frameSize, .zero)
        XCTAssertFalse(model.desktop.inputEnabled)
        XCTAssertFalse(host.streaming)
        let initialPings = host.pingCount
        try await Task.sleep(nanoseconds: 2_250_000_000)
        XCTAssertGreaterThanOrEqual(host.pingCount - initialPings, 2)
        XCTAssertNotNil(model.pingMS)
        XCTAssertNil(model.error)

        resuming = true
        model.resumeViewing()
        await fulfillment(of: [resumedFrame], timeout: 5)
        XCTAssertTrue(model.isViewing)
        XCTAssertTrue(model.desktop.inputEnabled)
        XCTAssertEqual(host.resumeCount, 2)
        XCTAssertEqual(host.generation, 3)
        XCTAssertEqual(host.authenticationCount, 1, "Resume must retain authentication")
        XCTAssertEqual(host.pairingMessageCount, pairingMessages, "Resume must not exchange pairing proofs again")
        XCTAssertEqual(try store.listDevices().map(\.id), [saved.id])
        XCTAssertEqual(model.connectedDeviceID, saved.id)

        disconnecting = true
        model.disconnect()
        await fulfillment(of: [closed], timeout: 3)
        XCTAssertFalse(model.isViewing)
        XCTAssertFalse(model.canResumeViewing)
        XCTAssertNil(model.connectedDeviceID)
        XCTAssertEqual(model.desktop.frameSize, .zero)
        XCTAssertNil(model.pingMS)
        XCTAssertEqual(try store.listDevices().map(\.id), [saved.id], "Disconnect retains durable device trust")
    }

    @MainActor
    func testUnavailableAndOldGenerationFramesCannotRestoreStaleScreen() async throws {
        _ = NSApplication.shared
        let model = AppModel(pairingStore: InMemoryPairingStore())
        let host = try SyntheticSessionHost()
        let initial = expectation(description: "initial current generation")
        let fresh = expectation(description: "fresh replacement generation")
        var frames = 0
        var unexpected: XCTestExpectation?
        var awaitingFresh = false
        var freshOnce = false
        model.desktop.onFrameEnqueued = {
            frames += 1
            if frames == 1 { initial.fulfill() }
            else if let unexpected { unexpected.fulfill() }
            else if awaitingFresh, !freshOnce { freshOnce = true; fresh.fulfill() }
        }
        let listener = try await connectTLS(model, host: host)
        defer { model.shutdown(); host.close(); listener.stop() }
        await fulfillment(of: [initial], timeout: 8)
        // Hold fresh recovery frames until the test explicitly releases one.
        // Availability legitimately requests an IDR; it must not confuse a
        // valid new-generation response with the old frame injected below.
        host.respondsToKeyframeRequests = false
        let unavailable = expectation(description: "unavailable state clears picture")
        var unavailableOnce = false
        let unavailableSubscription = model.$streamUnavailable.sink { value in
            if value, !unavailableOnce { unavailableOnce = true; unavailable.fulfill() }
        }
        host.sendState(.unavailable, generation: 2)
        await fulfillment(of: [unavailable], timeout: 3)
        XCTAssertEqual(model.desktop.frameSize, .zero)
        XCTAssertFalse(model.desktop.inputEnabled)
        let framesBeforeBlank = frames
        let whileBlank = expectation(description: "old frame must not appear while unavailable"); whileBlank.isInverted = true
        unexpected = whileBlank
        host.sendFrame(generation: 1)
        await fulfillment(of: [whileBlank], timeout: 0.3)
        unexpected = nil
        unavailableSubscription.cancel()

        let available = expectation(description: "new generation announced")
        var availableOnce = false
        let availableSubscription = model.$streamUnavailable.sink { value in
            if !value, !availableOnce { availableOnce = true; available.fulfill() }
        }
        host.sendState(.available, generation: 3)
        await fulfillment(of: [available], timeout: 3)
        XCTAssertEqual(model.desktop.frameSize, .zero, "Availability is not itself a fresh picture")
        XCTAssertFalse(model.desktop.inputEnabled)
        let stale = expectation(description: "old generation cannot reappear after new availability"); stale.isInverted = true
        unexpected = stale
        host.sendFrame(generation: 1)
        await fulfillment(of: [stale], timeout: 0.3)
        unexpected = nil
        XCTAssertEqual(frames, framesBeforeBlank)
        awaitingFresh = true
        host.sendFrame(generation: 3)
        await fulfillment(of: [fresh], timeout: 3)
        availableSubscription.cancel()
        XCTAssertEqual(frames, framesBeforeBlank + 1)
        XCTAssertEqual(model.desktop.frameSize, CGSize(width: 64, height: 64))
        XCTAssertTrue(model.desktop.inputEnabled)
        XCTAssertEqual(host.authenticationCount, 1)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testViewerRejectsInvalidHostInfoAfterAuthentication() async throws {
        _ = NSApplication.shared
        let model = AppModel(pairingStore: InMemoryPairingStore())
        let host = try SyntheticSessionHost()
        host.invalidHostInfo = true
        let closed = expectation(description: "invalid authenticated host metadata closes session")
        host.onClose = { _ in closed.fulfill() }
        let listener = try await connectTLS(model, host: host)
        defer { host.onClose = nil; model.shutdown(); host.close(); listener.stop() }
        await fulfillment(of: [closed], timeout: 8)
        XCTAssertEqual(host.authenticationCount, 1)
        XCTAssertFalse(model.isViewing)
        XCTAssertFalse(model.canResumeViewing)
        XCTAssertEqual(model.desktop.frameSize, .zero)
        XCTAssertTrue(model.error?.contains("Invalid remote stream") == true)
    }

    @MainActor
    private func connectTLS(_ model: AppModel, host: SyntheticSessionHost) async throws -> SecureListener {
        let key = try PairingInvitation.generateKey()
        let listening = expectation(description: "loopback TLS listener ready")
        let listener = try SecureListener(key: key, port: 0)
        var port: UInt16 = 0
        listener.onReady = { port = $0; listening.fulfill() }
        listener.onError = { XCTFail("Listener failed: \($0)") }
        listener.onConnection = { peer in
            do { try host.attach(peer) }
            catch { XCTFail("Host handshake setup failed: \(error)"); peer.close() }
        }
        listener.start()
        await fulfillment(of: [listening], timeout: 5)
        model.pastedInvitation = try PairingInvitation(host: "127.0.0.1", port: port, key: key).urlString
        model.connect()
        return listener
    }
}
