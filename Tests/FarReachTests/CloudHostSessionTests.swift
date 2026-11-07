import XCTest
import AppKit
import Combine
@testable import FarReach
import RemoteCore

final class CloudHostSessionTests: XCTestCase {
    /// These tests deliberately never send resume, wake, or input commands.
    /// The host authenticates a real direct UDP connection without capture.
    @MainActor func testCloudHostAcceptsReconnectAndStopSharingRejectsNewRequests() async throws {
        let fixture = try HostFixture()
        defer { fixture.close() }
        try await fixture.start(in: self)

        let firstAuth = expectation(description: "host authenticated first controller")
        let secondAuth = expectation(description: "host authenticated reconnected controller")
        let firstClosed = expectation(description: "host returned to available state")
        var phase = 1
        let subscription = fixture.model.$connectedDeviceID.sink { value in
            if value == fixture.controllerIdentity.id {
                if phase == 1 { phase = 2; firstAuth.fulfill() }
                else if phase == 3 { phase = 4; secondAuth.fulfill() }
            } else if phase == 2 { phase = 3; firstClosed.fulfill() }
        }
        defer { subscription.cancel() }
        fixture.begin(identity: fixture.controllerIdentity)
        await fulfillment(of: [firstAuth], timeout: 25)
        XCTAssertEqual(fixture.model.connectedDeviceID, fixture.controllerIdentity.id)
        XCTAssertFalse(fixture.model.hasViewer, "Authentication alone must not start capture")
        XCTAssertFalse(fixture.model.isViewing)
        XCTAssertTrue(fixture.model.invitation.isEmpty)
        XCTAssertTrue(fixture.model.connectionPath.contains("UDP"))
        let oldSession = try XCTUnwrap(fixture.sessionID)
        let acknowledged = expectation(description: "authenticated session-scoped close is acknowledged")
        fixture.onClosed = { acknowledged.fulfill() }
        fixture.requestSessionClose(UUID().uuidString)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fixture.model.connectedDeviceID, fixture.controllerIdentity.id, "A different session token cannot close the active transport")
        fixture.requestSessionClose(oldSession)
        await fulfillment(of: [firstClosed, acknowledged], timeout: 10)
        fixture.onClosed = nil
        fixture.closeControllerTransport()
        XCTAssertTrue(fixture.model.isHosting)
        XCTAssertTrue(fixture.model.cloudHosting)
        XCTAssertNil(fixture.model.connectedDeviceID)
        fixture.begin(identity: fixture.controllerIdentity)
        await fulfillment(of: [secondAuth], timeout: 25)
        XCTAssertEqual(fixture.model.connectedDeviceID, fixture.controllerIdentity.id)
        XCTAssertFalse(fixture.model.hasViewer)
        XCTAssertEqual(fixture.offersReceived, 2)
        fixture.requestSessionClose(oldSession)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fixture.model.connectedDeviceID, fixture.controllerIdentity.id, "Delayed close for a previous session cannot close its replacement")

        let controllerClosed = expectation(description: "Stop Sharing closes authenticated controller")
        fixture.onTransportClosed = { controllerClosed.fulfill() }
        fixture.model.stopHosting()
        await fulfillment(of: [controllerClosed], timeout: 10)
        XCTAssertFalse(fixture.model.isHosting)
        XCTAssertFalse(fixture.model.cloudHosting)
        XCTAssertNil(fixture.model.connectedDeviceID)
        let refused = expectation(description: "trusted new request rejected after Stop Sharing")
        fixture.onRejected = { refused.fulfill() }
        fixture.begin(identity: fixture.controllerIdentity)
        await fulfillment(of: [refused], timeout: 10)
        XCTAssertEqual(fixture.offersReceived, 2, "A request must not silently restart sharing")
        XCTAssertFalse(fixture.model.isHosting)
        XCTAssertFalse(fixture.model.hasViewer)
        XCTAssertEqual(fixture.model.pairedDevices.map(\.id), [fixture.controllerIdentity.id])
    }

    @MainActor func testCloudHostRejectsDifferentIdentityOnAuthenticatedSignalingAttempt() async throws {
        let fixture = try HostFixture()
        defer { fixture.close() }
        try await fixture.start(in: self)
        let rejected = expectation(description: "host rejects unpinned desktop identity")
        let closed = expectation(description: "rejected direct connection closes")
        var reported = false
        let subscription = fixture.model.$error.sink { value in
            if value == DevicePairingError.unexpectedPeer.localizedDescription, !reported {
                reported = true; rejected.fulfill()
            }
        }
        defer { subscription.cancel() }
        fixture.onTransportClosed = { closed.fulfill() }
        let impostor = DeviceIdentity()
        fixture.begin(identity: impostor)
        await fulfillment(of: [rejected, closed], timeout: 25)
        XCTAssertNil(fixture.model.connectedDeviceID)
        XCTAssertFalse(fixture.model.hasViewer)
        XCTAssertTrue(fixture.model.isHosting)
        XCTAssertTrue(fixture.model.cloudHosting)
        XCTAssertEqual(fixture.model.pairedDevices.map(\.id), [fixture.controllerIdentity.id])
        XCTAssertFalse(fixture.model.pairedDevices.contains(where: { $0.id == impostor.id }))
    }
}

@MainActor private final class HostFixture {
    let hostIdentity = DeviceIdentity()
    let controllerIdentity = DeviceIdentity()
    let model: AppModel
    let signaling: CloudSignalingClient
    let helper: URL
    var onRejected: (() -> Void)?
    var onTransportClosed: (() -> Void)?
    var onClosed: (() -> Void)?
    var sessionID: String? { attemptID }
    private(set) var offersReceived = 0
    private var attemptID: String?
    private var closeAttemptID: String?
    private var handshakeIdentity: DeviceIdentity?
    private var peer: WebRTCPeer?
    private var handshake: PairingHandshake?

    init() throws {
        guard let address = ProcessInfo.processInfo.environment["FARREACH_SIGNALING_TEST_URL"],
              let endpoint = URL(string: address) else { throw XCTSkip("Set FARREACH_SIGNALING_TEST_URL to run Worker integration.") }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        helper = ProcessInfo.processInfo.environment["FARREACH_NETWORK_HELPER"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("Networking/bin/FarReachNetwork")
        let store = InMemoryPairingStore(identity: hostIdentity)
        try store.save(PairedDevice(name: "Synthetic Controller", publicKey: controllerIdentity.publicKey))
        let host = try PairedDevice(name: "Synthetic Host", publicKey: hostIdentity.publicKey)
        signaling = try CloudSignalingClient(identity: controllerIdentity, endpoint: endpoint, peers: [host])
        model = AppModel(networkHelperURL: helper, pairingStore: store)
        model.stunServer = ""; model.signalingURL = address
        signaling.onError = { XCTFail($0) }
        signaling.onSignal = { [weak self] from, message in self?.receive(from: from, message: message) }
    }

    func start(in test: XCTestCase) async throws {
        let controllerReady = test.expectation(description: "controller signaling authenticated")
        let hostReady = test.expectation(description: "host signaling authenticated")
        var didReady = false
        let subscription = model.$signalingReady.sink { ready in
            if ready && !didReady { didReady = true; hostReady.fulfill() }
        }
        signaling.onReady = { controllerReady.fulfill() }
        signaling.start(); model.configureSignaling()
        await test.fulfillment(of: [controllerReady, hostReady], timeout: 20)
        subscription.cancel(); signaling.onReady = nil
        guard signaling.isReady, model.signalingReady else {
            throw NSError(domain: "CloudHostSessionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Local Worker authentication did not complete."])
        }
        // Emulates the explicit Share action while avoiding system permissions
        // and screen capture entirely. Pairing never starts capture by itself.
        model.cloudHosting = true; model.isHosting = true
    }

    func begin(identity: DeviceIdentity) {
        handshakeIdentity = identity; attemptID = UUID().uuidString
        XCTAssertTrue(signaling.send(.init(kind: .request, attemptID: attemptID!), to: hostIdentity.id))
    }

    func requestSessionClose(_ sessionID: String) {
        let id = UUID().uuidString
        closeAttemptID = id
        XCTAssertTrue(signaling.send(.init(kind: .close, attemptID: id, sessionID: sessionID), to: hostIdentity.id))
    }

    private func receive(from: String, message: CloudSignalMessage) {
        XCTAssertEqual(from, hostIdentity.id)
        if message.kind == .closed, message.attemptID == closeAttemptID { onClosed?(); return }
        guard message.attemptID == attemptID else { return }
        switch message.kind {
        case .offer:
            do {
                offersReceived += 1
                let invitation = try XCTUnwrap(message.body)
                let identity = try XCTUnwrap(handshakeIdentity)
                let transport = try WebRTCPeer(role: .viewer(invitation: invitation), stunURLs: [], helperURL: helper)
                peer = transport
                transport.onResponse = { [weak self] answer in
                    guard let self else { return }
                    XCTAssertTrue(self.signaling.send(.init(kind: .answer, attemptID: message.attemptID, body: answer), to: from))
                }
                transport.onReady = { [weak self, weak transport] in
                    guard let self, let transport else { return }
                    do {
                        let proof = try PairingHandshake(identity: identity, localName: "Synthetic Controller", role: .viewer,
                            channelBinding: XCTUnwrap(transport.channelBinding), expectedPeerID: self.hostIdentity.id)
                        self.handshake = proof
                        proof.onSend = { [weak transport] message in _ = transport?.send(message) }
                        proof.onAuthenticated = { [weak transport] _ in transport?.setMediaAuthorization(true, generation: 0) }
                        proof.onFailure = { [weak transport] _ in transport?.close() }
                        proof.start()
                    } catch { XCTFail("Controller authentication setup failed: \(error)") }
                }
                transport.onMessage = { [weak self, weak transport] message in
                    if message.kind == .pairing { self?.handshake?.receive(message.payload) }
                    else if message.kind == .ping { _ = transport?.send(WireMessage(kind: .pong, payload: message.payload)) }
                }
                transport.onClose = { [weak self] _ in self?.onTransportClosed?() }
                transport.start()
            } catch { XCTFail("Controller transport setup failed: \(error)") }
        case .reject: onRejected?()
        case .request, .answer, .cancel, .close, .closed, .busy: break
        }
    }

    func closeControllerTransport() {
        peer?.onClose = nil; peer?.close(); peer = nil
        handshake?.cancel(); handshake = nil
    }

    func close() {
        onTransportClosed = nil; onRejected = nil
        closeControllerTransport(); signaling.stop(); model.shutdown()
    }
}
