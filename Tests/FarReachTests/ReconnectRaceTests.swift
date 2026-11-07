import XCTest
import AppKit
import Combine
@testable import FarReach
import RemoteCore

/// Opt-in diagnosis only. Uses fresh in-memory identities, the local Worker,
/// and real UDP helpers, without screen capture, wake requests or input.
final class ReconnectRaceTests: XCTestCase {
    @MainActor
    func testImmediateReconnectOrderingWithRealSignaling() async throws {
        let fixture = try ReconnectRaceFixture()
        defer { fixture.close() }
        try await fixture.start()
        fixture.begin()
        try await fixture.waitForAuthenticatedConnection()

        let cycles = 8
        var immediateRejects = 0
        var immediateSuccesses = 0
        var cleanupMilliseconds: [Int] = []
        for _ in 0..<cycles {
            let oldHostCount = fixture.hostAuthenticationCount
            let oldControllerCount = fixture.controllerAuthenticationCount
            let oldRejects = fixture.rejectionCount
            fixture.markCloseStart()
            fixture.closeControllerTransport()
            fixture.begin()
            try await waitUntil("immediate attempt returns a result") {
                fixture.rejectionCount > oldRejects
                    || (fixture.hostAuthenticationCount > oldHostCount
                        && fixture.controllerAuthenticationCount > oldControllerCount)
            }
            if fixture.rejectionCount > oldRejects {
                immediateRejects += 1
                try await waitUntil("old host connection closes") { fixture.model.connectedDeviceID == nil }
                fixture.begin()
                try await fixture.waitForAuthenticatedConnection()
            } else {
                immediateSuccesses += 1
            }
            if let elapsed = fixture.lastCleanupMilliseconds { cleanupMilliseconds.append(elapsed) }
            XCTAssertEqual(fixture.model.connectedDeviceID, fixture.controllerIdentity.id)
            XCTAssertFalse(fixture.model.hasViewer)
        }
        print("RECONNECT_DIAGNOSTIC real_local_signaling cycles=\(cycles) immediate_rejects=\(immediateRejects) immediate_successes=\(immediateSuccesses) eventual_successes=\(cycles) host_cleanup_ms=\(cleanupMilliseconds)")
    }

    @MainActor
    func testSignalingArrivingBeforeOldTransportCloseIsRejectedThenRetryWorks() async throws {
        let fixture = try ReconnectRaceFixture()
        defer { fixture.close() }
        try await fixture.start()
        fixture.begin()
        try await fixture.waitForAuthenticatedConnection()
        let oldRejects = fixture.rejectionCount
        let oldOffers = fixture.offersReceived
        fixture.markCloseStart()
        fixture.closeControllerTransport()

        // Deterministically choose a permitted event ordering: a validated new
        // signaling request reaches the main actor before the asynchronous UDP
        // teardown callback. This is an ordering simulation, not WAN evidence.
        XCTAssertEqual(fixture.model.connectedDeviceID, fixture.controllerIdentity.id)
        fixture.deliverFreshValidatedRequestBeforeTeardown()
        XCTAssertEqual(fixture.model.connectedDeviceID, fixture.controllerIdentity.id)
        try await waitUntil("encrypted rejection delivered") { fixture.rejectionCount == oldRejects + 1 }
        XCTAssertEqual(fixture.offersReceived, oldOffers)
        try await waitUntil("old host transport cleanup") { fixture.model.connectedDeviceID == nil }
        XCTAssertTrue(fixture.model.cloudHosting)
        XCTAssertTrue(fixture.model.isHosting)
        fixture.begin()
        try await fixture.waitForAuthenticatedConnection()
        XCTAssertEqual(fixture.offersReceived, oldOffers + 1)
        XCTAssertEqual(fixture.model.connectedDeviceID, fixture.controllerIdentity.id)
        XCTAssertFalse(fixture.model.hasViewer)
        print("RECONNECT_DIAGNOSTIC simulated_signaling_before_udp_teardown first_attempt=rejected retry_after_cleanup=authenticated host_cleanup_ms=\(fixture.lastCleanupMilliseconds ?? -1)")
    }
}

@MainActor private func waitUntil(_ description: String, timeout: TimeInterval = 15,
                                 predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() {
        guard Date() < deadline else {
            throw NSError(domain: "ReconnectRaceTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(description)"])
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

@MainActor private final class ReconnectRaceFixture {
    let hostIdentity = DeviceIdentity()
    let controllerIdentity = DeviceIdentity()
    let model: AppModel
    let signaling: CloudSignalingClient
    let helper: URL
    private var attemptID: String?
    private var peer: WebRTCPeer?
    private var handshake: PairingHandshake?
    private var subscription: AnyCancellable?
    private var closeStart: Date?
    private(set) var rejectionCount = 0
    private(set) var hostAuthenticationCount = 0
    private(set) var controllerAuthenticationCount = 0
    private(set) var offersReceived = 0
    private(set) var lastCleanupMilliseconds: Int?

    init() throws {
        guard let address = ProcessInfo.processInfo.environment["FARREACH_SIGNALING_TEST_URL"],
              let endpoint = URL(string: address), ["127.0.0.1", "localhost", "::1"].contains(endpoint.host ?? "") else {
            throw XCTSkip("Set FARREACH_SIGNALING_TEST_URL to a local Worker for reconnect diagnostics.")
        }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        helper = ProcessInfo.processInfo.environment["FARREACH_NETWORK_HELPER"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("Networking/bin/FarReachNetwork")
        let store = InMemoryPairingStore(identity: hostIdentity)
        try store.save(PairedDevice(name: "Temporary Controller", publicKey: controllerIdentity.publicKey))
        let host = try PairedDevice(name: "Temporary Host", publicKey: hostIdentity.publicKey)
        signaling = try CloudSignalingClient(identity: controllerIdentity, endpoint: endpoint, peers: [host])
        model = AppModel(networkHelperURL: helper, pairingStore: store)
        model.stunServer = ""; model.signalingURL = address
        signaling.onError = { XCTFail("Temporary signaling failed: \($0)") }
        signaling.onSignal = { [weak self] from, message in self?.receive(from: from, message: message) }
        subscription = model.$connectedDeviceID.sink { [weak self] value in
            guard let self else { return }
            if value == self.controllerIdentity.id { self.hostAuthenticationCount += 1 }
            else if value == nil, let start = self.closeStart {
                self.lastCleanupMilliseconds = Int(Date().timeIntervalSince(start) * 1000)
                self.closeStart = nil
            }
        }
    }

    func start() async throws {
        signaling.start(); model.configureSignaling()
        try await waitUntil("temporary cloud clients ready", timeout: 20) { signaling.isReady && model.signalingReady }
        model.cloudHosting = true; model.isHosting = true
    }

    func begin() {
        attemptID = UUID().uuidString
        XCTAssertTrue(signaling.send(.init(kind: .request, attemptID: attemptID!), to: hostIdentity.id))
    }

    func deliverFreshValidatedRequestBeforeTeardown() {
        attemptID = UUID().uuidString
        model.receiveSignal(from: controllerIdentity.id, message: .init(kind: .request, attemptID: attemptID!))
    }

    func markCloseStart() { closeStart = Date(); lastCleanupMilliseconds = nil }

    func waitForAuthenticatedConnection() async throws {
        try await waitUntil("both temporary direct peers authenticated", timeout: 25) {
            model.connectedDeviceID == controllerIdentity.id && handshake?.isAuthenticated == true
        }
    }

    private func receive(from: String, message: CloudSignalMessage) {
        XCTAssertEqual(from, hostIdentity.id)
        guard message.attemptID == attemptID else { return }
        switch message.kind {
        case .offer:
            do {
                offersReceived += 1
                let invitation = try XCTUnwrap(message.body)
                let transport = try WebRTCPeer(role: .viewer(invitation: invitation), stunURLs: [], helperURL: helper)
                peer = transport
                transport.onResponse = { [weak self] answer in
                    guard let self else { return }
                    XCTAssertTrue(self.signaling.send(.init(kind: .answer, attemptID: message.attemptID, body: answer), to: from))
                }
                transport.onReady = { [weak self, weak transport] in
                    guard let self, let transport else { return }
                    do {
                        let proof = try PairingHandshake(identity: self.controllerIdentity, localName: "Temporary Controller", role: .viewer,
                            channelBinding: XCTUnwrap(transport.channelBinding), expectedPeerID: self.hostIdentity.id)
                        self.handshake = proof
                        proof.onSend = { [weak transport] value in _ = transport?.send(value) }
                        proof.onAuthenticated = { [weak self, weak transport] _ in self?.controllerAuthenticationCount += 1; transport?.setMediaAuthorization(true, generation: 0) }
                        proof.onFailure = { [weak transport] _ in transport?.close() }
                        proof.start()
                    } catch { XCTFail("Temporary controller authentication failed: \(error)") }
                }
                transport.onMessage = { [weak self, weak transport] message in
                    if message.kind == .pairing { self?.handshake?.receive(message.payload) }
                    else if message.kind == .ping { _ = transport?.send(WireMessage(kind: .pong, payload: message.payload)) }
                }
                transport.start()
            } catch { XCTFail("Temporary transport setup failed: \(error)") }
        case .reject, .busy: rejectionCount += 1
        case .request, .answer, .cancel, .close, .closed: break
        }
    }

    func closeControllerTransport() {
        peer?.onClose = nil; peer?.close(); peer = nil
        handshake?.cancel(); handshake = nil
    }

    func close() {
        subscription?.cancel(); subscription = nil
        closeControllerTransport(); signaling.stop(); model.shutdown()
    }
}
