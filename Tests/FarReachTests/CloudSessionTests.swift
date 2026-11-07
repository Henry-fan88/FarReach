import XCTest
import AppKit
import Combine
@testable import FarReach
import RemoteCore

final class CloudSessionTests: XCTestCase {
    /// Uses encrypted signaling only. The deliberately missing helper proves
    /// that a legacy offer is reported before any desktop transport is created.
    @MainActor
    func testLegacyCloudOfferReportsUpdateOnlyForCurrentAttempt() async throws {
        guard let address = ProcessInfo.processInfo.environment["FARREACH_SIGNALING_TEST_URL"],
              let endpoint = URL(string: address) else { throw XCTSkip("Set FARREACH_SIGNALING_TEST_URL to run Worker integration.") }
        _ = NSApplication.shared
        let viewerIdentity = DeviceIdentity(), hostIdentity = DeviceIdentity()
        let host = try PairedDevice(name: "Legacy synthetic host", publicKey: hostIdentity.publicKey)
        let viewer = try PairedDevice(name: "Current synthetic viewer", publicKey: viewerIdentity.publicKey)
        let store = InMemoryPairingStore(identity: viewerIdentity)
        try store.save(host)
        let model = AppModel(networkHelperURL: URL(fileURLWithPath: "/does-not-exist/FarReachNetwork"), pairingStore: store)
        model.signalingURL = address
        let hostSignal = try CloudSignalingClient(identity: hostIdentity, endpoint: endpoint, peers: [viewer])
        let hostReady = expectation(description: "legacy fixture signaling ready")
        let viewerReady = expectation(description: "viewer signaling ready")
        let requested = expectation(description: "current connection attempt received")
        let updateRequired = expectation(description: "matching legacy offer reports explicit required update")
        var attemptID: String?
        var announcedReady = false
        let readySubscription = model.$signalingReady.sink { ready in
            if ready && !announcedReady { announcedReady = true; viewerReady.fulfill() }
        }
        let errorSubscription = model.$error.sink { value in
            if value == WebRTCTransportError.incompatibleVersion.localizedDescription { updateRequired.fulfill() }
        }
        hostSignal.onReady = { hostReady.fulfill() }
        hostSignal.onError = { XCTFail($0) }
        hostSignal.onSignal = { from, message in
            if message.kind == .request {
                XCTAssertEqual(from, viewer.id); attemptID = message.attemptID; requested.fulfill()
            }
        }
        defer { readySubscription.cancel(); errorSubscription.cancel(); model.shutdown(); hostSignal.stop() }
        hostSignal.start(); model.configureSignaling()
        await fulfillment(of: [hostReady, viewerReady], timeout: 15)
        model.connectPairedDevice(host)
        await fulfillment(of: [requested], timeout: 5)
        XCTAssertTrue(hostSignal.send(.init(kind: .offer, attemptID: UUID().uuidString, body: "farreach-offer://v1/Stale_Description"), to: viewer.id))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(model.isConnecting)
        XCTAssertNil(model.error, "A stale legacy description cannot fail the current attempt")
        XCTAssertTrue(hostSignal.send(.init(kind: .offer, attemptID: try XCTUnwrap(attemptID), body: "farreach-offer://v1/Legacy_Description"), to: viewer.id))
        await fulfillment(of: [updateRequired], timeout: 5)
        XCTAssertFalse(model.isConnecting)
        XCTAssertFalse(model.isRecovering)
        XCTAssertFalse(model.isViewing)
        XCTAssertTrue(model.connectionPath.isEmpty)
        XCTAssertEqual(model.pairedDevices.map(\.id), [host.id])
    }

    @MainActor
    func testSignalsCannotEnableSharingOrConnectUnknownDevices() throws {
        _ = NSApplication.shared
        let store = InMemoryPairingStore()
        let trusted = try PairedDevice(name: "Trusted", publicKey: DeviceIdentity().publicKey)
        try store.save(trusted)
        let model = AppModel(pairingStore: store)
        defer { model.shutdown() }
        model.receiveSignal(from: trusted.id, message: .init(kind: .request, attemptID: UUID().uuidString))
        XCTAssertFalse(model.isHosting)
        XCTAssertFalse(model.isConnecting)
        model.cloudHosting = true; model.isHosting = true
        model.receiveSignal(from: DeviceIdentity().id, message: .init(kind: .request, attemptID: UUID().uuidString))
        XCTAssertTrue(model.invitation.isEmpty)
        XCTAssertNil(model.error)
        model.stopHosting()
        model.receiveSignal(from: trusted.id, message: .init(kind: .request, attemptID: UUID().uuidString))
        model.receiveSignal(from: trusted.id, message: .init(kind: .offer, attemptID: UUID().uuidString, body: "farreach-offer://v2/invalid"))
        XCTAssertFalse(model.cloudHosting)
        XCTAssertFalse(model.isHosting)
        XCTAssertFalse(model.isConnecting)
        XCTAssertNil(model.error)
    }

    /// Optional integration against wrangler dev or the deployed service. Uses
    /// temporary in-memory identities, real UDP helpers and synthetic pixels.
    /// No desktop capture, Keychain, login password or remote input is involved.
    @MainActor
    func testCloudReconnectNegotiatesRealDirectTransportAndSurvivesSignalingLoss() async throws {
        guard let address = ProcessInfo.processInfo.environment["FARREACH_SIGNALING_TEST_URL"],
              let endpoint = URL(string: address) else { throw XCTSkip("Set FARREACH_SIGNALING_TEST_URL to run Worker integration.") }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = ProcessInfo.processInfo.environment["FARREACH_NETWORK_HELPER"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("Networking/bin/FarReachNetwork")
        let viewerIdentity = DeviceIdentity()
        let store = InMemoryPairingStore(identity: viewerIdentity)
        let host = try SyntheticSessionHost(name: "Cloud Synthetic Mac")
        let savedHost = try PairedDevice(name: host.name, publicKey: host.identity.publicKey)
        let savedViewer = try PairedDevice(name: "Cloud Viewer", publicKey: viewerIdentity.publicKey)
        try store.save(savedHost)
        let hostSignal = try CloudSignalingClient(identity: host.identity, endpoint: endpoint, peers: [savedViewer])
        let model = AppModel(networkHelperURL: helper, pairingStore: store)
        model.stunServer = ""; model.signalingURL = address
        let hostReady = expectation(description: "host signaling authenticated")
        let viewerReady = expectation(description: "viewer signaling authenticated")
        let firstFrame = expectation(description: "first synthetic frame over direct UDP")
        let secondFrame = expectation(description: "fresh transport after prior connection closes")
        let paused = expectation(description: "pause reaches host without signaling")
        let recoveredFrame = expectation(description: "fresh frame after paused transport recovery and explicit resume")
        var rtc: WebRTCPeer?
        var attempt: String?
        var connectionCount = 0
        var frames = Set<Int>()
        var viewerWasReady = false
        var busyNextRequest = false
        var busyResponses = 0
        let readySubscription = model.$signalingReady.sink { ready in
            if ready && !viewerWasReady { viewerWasReady = true; viewerReady.fulfill() }
        }
        model.desktop.onFrameEnqueued = {
            guard !frames.contains(connectionCount) else { return }
            frames.insert(connectionCount)
            if connectionCount == 1 { firstFrame.fulfill() }
            if connectionCount == 2 { secondFrame.fulfill() }
            if connectionCount == 3 { recoveredFrame.fulfill() }
        }
        hostSignal.onReady = { hostReady.fulfill() }
        hostSignal.onError = { message in XCTFail(message) }
        hostSignal.onSignal = { from, message in
            XCTAssertEqual(from, viewerIdentity.id)
            do {
                switch message.kind {
                case .request:
                    if busyNextRequest {
                        busyNextRequest = false; busyResponses += 1
                        XCTAssertTrue(hostSignal.send(.init(kind: .busy, attemptID: message.attemptID), to: from))
                        return
                    }
                    connectionCount += 1; attempt = message.attemptID
                    let peer = try WebRTCPeer(role: .host, stunURLs: [], helperURL: helper)
                    rtc = peer
                    peer.onInvitation = { invitation in
                        XCTAssertTrue(hostSignal.send(.init(kind: .offer, attemptID: message.attemptID, body: invitation), to: from))
                    }
                    peer.onReady = { do { try host.attach(peer) } catch { XCTFail("Host attach failed: \(error)") } }
                    peer.start()
                case .answer:
                    XCTAssertEqual(message.attemptID, attempt)
                    try rtc?.applyResponse(XCTUnwrap(message.body))
                case .cancel, .reject, .offer, .close, .closed, .busy: break
                }
            } catch { XCTFail("Cloud host negotiation failed: \(error)") }
        }
        defer {
            readySubscription.cancel(); host.onClose = nil
            model.shutdown(); hostSignal.stop(); host.close(); rtc?.close()
        }
        hostSignal.start(); model.configureSignaling()
        await fulfillment(of: [hostReady, viewerReady], timeout: 20)
        model.connectPairedDevice(savedHost)
        await fulfillment(of: [firstFrame], timeout: 25)
        XCTAssertTrue(model.isViewing)
        XCTAssertEqual(model.connectedDeviceID, host.identity.id)
        XCTAssertTrue(model.connectionResponse.isEmpty, "Cloud answer must not require manual copy")
        XCTAssertTrue(model.invitation.isEmpty)
        XCTAssertTrue(model.connectionPath.contains("UDP"))
        model.disconnect(); host.close(); rtc = nil
        busyNextRequest = true
        model.connectPairedDevice(savedHost)
        await fulfillment(of: [secondFrame], timeout: 25)
        XCTAssertEqual(connectionCount, 2)
        XCTAssertEqual(busyResponses, 1, "The viewer retries a closing host without another user action")
        XCTAssertTrue(model.isViewing)
        host.onPause = { paused.fulfill() }
        model.endViewing()
        await fulfillment(of: [paused], timeout: 5)
        host.onPause = nil
        host.close(); rtc = nil
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while connectionCount < 3 || model.isRecovering || !model.canResumeViewing {
            guard ProcessInfo.processInfo.systemUptime < deadline else { XCTFail("Paused direct connection did not recover"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(model.isViewing, "Recovery must preserve the user's paused intent")
        XCTAssertFalse(host.streaming)
        XCTAssertEqual(model.connectedDeviceID, host.identity.id)
        model.resumeViewing()
        await fulfillment(of: [recoveredFrame], timeout: 10)
        hostSignal.stop()
        let independentPause = expectation(description: "healthy desktop remains usable after signaling loss")
        host.onPause = { independentPause.fulfill() }
        model.endViewing()
        await fulfillment(of: [independentPause], timeout: 5)
        XCTAssertTrue(model.canResumeViewing, "Signaling loss must not close an authenticated direct channel")
        XCTAssertNil(model.error)
    }
}
