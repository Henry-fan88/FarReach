import XCTest
import CryptoKit
@testable import RemoteCore

final class DevicePairingTests: XCTestCase {
    func testIdentityRoundtripAndMemoryStoreRevocation() throws {
        let raw = Data(repeating: 7, count: 32)
        let original = try DeviceIdentity(rawRepresentation: raw)
        let restored = try DeviceIdentity(rawRepresentation: raw)
        XCTAssertEqual(original.id, restored.id)
        XCTAssertEqual(original.publicKey, restored.publicKey)
        XCTAssertEqual(original.publicKey.count, 32)
        XCTAssertEqual(original.id.count, 43)
        XCTAssertThrowsError(try DeviceIdentity(rawRepresentation: Data(repeating: 0, count: 31)))
        let store = InMemoryPairingStore(identity: original)
        XCTAssertEqual(try store.loadOrCreateIdentity().id, original.id)
        XCTAssertEqual(try store.loadOrCreateIdentity().id, original.id)
        XCTAssertTrue(try store.listDevices().isEmpty)
        let other = DeviceIdentity()
        let device = try PairedDevice(name: "Other Mac", publicKey: other.publicKey, lastSeen: Date(timeIntervalSince1970: 100))
        try store.save(device)
        XCTAssertEqual(try store.listDevices(), [device])
        var updated = device
        updated.name = "Renamed Mac"
        updated.lastSeen = Date(timeIntervalSince1970: 200)
        try store.save(updated)
        XCTAssertEqual(try store.listDevices(), [updated])
        try store.forget(id: device.id)
        try store.forget(id: device.id) // Revoking an already absent entry is idempotent.
        XCTAssertTrue(try store.listDevices().isEmpty)
        XCTAssertEqual(try store.loadOrCreateIdentity().id, original.id, "Forgetting a peer must not reset local identity")
        XCTAssertThrowsError(try store.forget(id: "not-an-identity"))
    }

    func testDeviceRecordsValidateNamesKeysAndIdentifiers() throws {
        let identity = DeviceIdentity()
        for name in ["", "   ", "Mac\nInjected", String(repeating: "x", count: 129)] {
            XCTAssertThrowsError(try PairedDevice(name: name, publicKey: identity.publicKey))
        }
        XCTAssertThrowsError(try PairedDevice(name: "Mac", publicKey: Data(repeating: 1, count: 31)))
        let device = try PairedDevice(name: "Example Mac", publicKey: identity.publicKey)
        let encoded = try JSONEncoder().encode(device)
        XCTAssertEqual(try JSONDecoder().decode(PairedDevice.self, from: encoded), device)
        var object = try json(encoded)
        object["id"] = DeviceIdentity().id
        XCTAssertThrowsError(try JSONDecoder().decode(PairedDevice.self, from: JSONSerialization.data(withJSONObject: object)))
        let store = InMemoryPairingStore()
        var invalid = device
        invalid.name = String(repeating: "x", count: 129)
        XCTAssertThrowsError(try store.save(invalid))
    }

    func testMutualHandshakeAuthenticatesBothRolesAndSavedKeys() throws {
        let hostIdentity = DeviceIdentity(), viewerIdentity = DeviceIdentity()
        let link = try Link(hostIdentity: hostIdentity, viewerIdentity: viewerIdentity,
                            expectedHost: viewerIdentity.id, expectedViewer: hostIdentity.id)
        link.start()
        link.flush()
        XCTAssertEqual(link.hostDevice?.id, viewerIdentity.id)
        XCTAssertEqual(link.viewerDevice?.id, hostIdentity.id)
        XCTAssertEqual(link.hostDevice?.name, "Viewer Mac")
        XCTAssertEqual(link.viewerDevice?.name, "Host Mac")
        XCTAssertTrue(link.host.isAuthenticated)
        XCTAssertTrue(link.viewer.isAuthenticated)
        XCTAssertEqual(link.hostAuthCount, 1)
        XCTAssertEqual(link.viewerAuthCount, 1)
        XCTAssertTrue(link.errors.isEmpty)
        XCTAssertTrue(link.sent.allSatisfy { $0.1.kind == .pairing && $0.1.payload.count <= 4096 })
    }

    func testSynchronousReentrantDeliveryAndEarlyHelloAreSafe() throws {
        let host = try PairingHandshake(identity: DeviceIdentity(), localName: "Host", role: .host, channelBinding: Data(repeating: 0x42, count: 32))
        let viewer = try PairingHandshake(identity: DeviceIdentity(), localName: "Viewer", role: .viewer, channelBinding: Data(repeating: 0x42, count: 32))
        var authenticated = 0
        host.onSend = { viewer.receive($0.payload) }
        viewer.onSend = { host.receive($0.payload) }
        host.onAuthenticated = { _ in authenticated += 1 }
        viewer.onAuthenticated = { _ in authenticated += 1 }
        host.onFailure = { XCTFail("Host failed: \($0)") }
        viewer.onFailure = { XCTFail("Viewer failed: \($0)") }
        host.start() // Viewer receives and stores this hello before it starts.
        XCTAssertFalse(viewer.isAuthenticated)
        viewer.start()
        XCTAssertEqual(authenticated, 2)
        XCTAssertTrue(host.isAuthenticated)
        XCTAssertTrue(viewer.isAuthenticated)
        host.start(); viewer.start()
        XCTAssertEqual(authenticated, 2, "start() must not resend handshake or authentication callbacks")
    }

    func testProofMayArriveBeforeHelloButCannotAuthenticateAlone() throws {
        let link = try Link()
        link.start()
        let hostHello = try link.take(from: .host, type: "hello")
        let viewerHello = try link.take(from: .viewer, type: "hello")
        link.host.receive(viewerHello.payload)
        let hostProof = try link.take(from: .host, type: "proof")
        link.viewer.receive(hostProof.payload)
        XCTAssertFalse(link.viewer.isAuthenticated)
        link.viewer.receive(hostHello.payload)
        link.flush()
        XCTAssertTrue(link.host.isAuthenticated)
        XCTAssertTrue(link.viewer.isAuthenticated)
        XCTAssertTrue(link.errors.isEmpty)
    }

    func testTamperedProofFailsBeforeAuthentication() throws {
        let link = try Link()
        link.transform = { role, message in
            guard role == .host, try self.json(message.payload)["type"] as? String == "proof" else { return message }
            var object = try self.json(message.payload)
            let signature = try XCTUnwrap(object["signature"] as? String)
            object["signature"] = (signature.first == "A" ? "B" : "A") + signature.dropFirst()
            return WireMessage(kind: .pairing, payload: try JSONSerialization.data(withJSONObject: object))
        }
        link.start(); link.flush()
        XCTAssertFalse(link.viewer.isAuthenticated)
        XCTAssertNil(link.viewerDevice)
        XCTAssertEqual(link.errors[.viewer] as? DevicePairingError, .invalidSignature)
    }

    func testFreshNoncesRejectReplayWithTheSamePersistentKeys() throws {
        let hostIdentity = DeviceIdentity(), viewerIdentity = DeviceIdentity()
        let old = try Link(hostIdentity: hostIdentity, viewerIdentity: viewerIdentity)
        old.start(); old.flush()
        let oldProof = old.sent.first { $0.0 == .host && (try? self.json($0.1.payload)["type"] as? String) == "proof" }.map { $0.1 }
        let captured = try XCTUnwrap(oldProof)
        let oldNonce = try XCTUnwrap(old.sent.first { $0.0 == .host }.map { try self.json($0.1.payload)["nonce"] as? String })
        let fresh = try Link(hostIdentity: hostIdentity, viewerIdentity: viewerIdentity)
        fresh.transform = { role, message in
            if role == .host, try self.json(message.payload)["type"] as? String == "proof" { return captured }
            return message
        }
        fresh.start()
        let freshNonce = try XCTUnwrap(fresh.sent.first { $0.0 == .host }.map { try self.json($0.1.payload)["nonce"] as? String })
        XCTAssertNotEqual(oldNonce, freshNonce)
        fresh.flush()
        XCTAssertFalse(fresh.viewer.isAuthenticated)
        XCTAssertEqual(fresh.errors[.viewer] as? DevicePairingError, .invalidSignature)
    }

    func testReflectionSelfPairingAndUnexpectedSavedDeviceAreRejected() throws {
        let host = try PairingHandshake(identity: DeviceIdentity(), localName: "Host", role: .host, channelBinding: Data(repeating: 0x42, count: 32))
        var hello: Data?
        var error: Error?
        host.onSend = { hello = $0.payload }
        host.onFailure = { error = $0 }
        host.start(); host.receive(try XCTUnwrap(hello))
        XCTAssertEqual(error as? DevicePairingError, .wrongRole)

        let identity = DeviceIdentity()
        let reflected = try Link(hostIdentity: identity, viewerIdentity: identity)
        reflected.start(); reflected.flush()
        XCTAssertFalse(reflected.host.isAuthenticated)
        XCTAssertFalse(reflected.viewer.isAuthenticated)
        XCTAssertEqual(reflected.errors[.host] as? DevicePairingError, .selfPairing)
        XCTAssertEqual(reflected.errors[.viewer] as? DevicePairingError, .selfPairing)

        let mismatch = try Link(expectedHost: DeviceIdentity().id)
        mismatch.start(); mismatch.flush()
        XCTAssertFalse(mismatch.host.isAuthenticated)
        XCTAssertEqual(mismatch.errors[.host] as? DevicePairingError, .unexpectedPeer)
        XCTAssertFalse(mismatch.sent.contains { $0.0 == .host && (try? self.json($0.1.payload)["type"] as? String) == "proof" }, "Do not sign a proof for a peer whose saved identity does not match")
    }

    func testOversizedMalformedAndDuplicateMessagesFailClosed() throws {
        for bytes in [Data(repeating: 0, count: 4097), Data("{}".utf8), Data(#"{"version":2,"type":"hello"}"#.utf8)] {
            let handshake = try PairingHandshake(identity: DeviceIdentity(), localName: "Mac", role: .host, channelBinding: Data(repeating: 0x42, count: 32))
            var failed = false
            handshake.onFailure = { _ in failed = true }
            handshake.receive(bytes)
            XCTAssertTrue(failed)
            XCTAssertFalse(handshake.isAuthenticated)
        }
        let link = try Link()
        link.start()
        let hello = try link.take(from: .host, type: "hello")
        link.viewer.receive(hello.payload)
        link.viewer.receive(hello.payload)
        XCTAssertEqual(link.errors[.viewer] as? DevicePairingError, .duplicateMessage)
        XCTAssertFalse(link.viewer.isAuthenticated)
    }

    func testCancelSuppressesBufferedAuthenticationAndCallbacks() throws {
        let link = try Link()
        link.start()
        link.viewer.cancel()
        link.flush()
        XCTAssertFalse(link.viewer.isAuthenticated)
        XCTAssertNil(link.viewer.authenticatedPeer)
        XCTAssertNil(link.viewerDevice)
        XCTAssertNil(link.errors[.viewer])
    }

    func testDifferentTransportBindingsRejectRelayedIdentityProofs() throws {
        let link = try Link(hostBinding: Data(repeating: 0x11, count: 32), viewerBinding: Data(repeating: 0x22, count: 32))
        link.start(); link.flush()
        XCTAssertFalse(link.host.isAuthenticated)
        XCTAssertFalse(link.viewer.isAuthenticated)
        XCTAssertEqual(link.errors[.host] as? DevicePairingError, .invalidSignature)
        XCTAssertEqual(link.errors[.viewer] as? DevicePairingError, .invalidSignature)
        XCTAssertThrowsError(try PairingHandshake(identity: DeviceIdentity(), localName: "Mac", role: .host, channelBinding: Data()))
        XCTAssertThrowsError(try PairingHandshake(identity: DeviceIdentity(), localName: "Mac", role: .host, channelBinding: Data(repeating: 0, count: 32)))
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private final class Link {
        let host: PairingHandshake
        let viewer: PairingHandshake
        var hostDevice: PairedDevice?
        var viewerDevice: PairedDevice?
        var hostAuthCount = 0
        var viewerAuthCount = 0
        var errors: [PairingRole: Error] = [:]
        var pending: [(PairingRole, WireMessage)] = []
        var sent: [(PairingRole, WireMessage)] = []
        var transform: ((PairingRole, WireMessage) throws -> WireMessage)?
        init(hostIdentity: DeviceIdentity = DeviceIdentity(), viewerIdentity: DeviceIdentity = DeviceIdentity(),
             expectedHost: String? = nil, expectedViewer: String? = nil,
             hostBinding: Data = Data(repeating: 0x42, count: 32), viewerBinding: Data = Data(repeating: 0x42, count: 32)) throws {
            host = try PairingHandshake(identity: hostIdentity, localName: "Host Mac", role: .host, channelBinding: hostBinding, expectedPeerID: expectedHost)
            viewer = try PairingHandshake(identity: viewerIdentity, localName: "Viewer Mac", role: .viewer, channelBinding: viewerBinding, expectedPeerID: expectedViewer)
            host.onSend = { [weak self] in self?.enqueue(.host, $0) }
            viewer.onSend = { [weak self] in self?.enqueue(.viewer, $0) }
            host.onAuthenticated = { [weak self] in self?.hostDevice = $0; self?.hostAuthCount += 1 }
            viewer.onAuthenticated = { [weak self] in self?.viewerDevice = $0; self?.viewerAuthCount += 1 }
            host.onFailure = { [weak self] in self?.errors[.host] = $0 }
            viewer.onFailure = { [weak self] in self?.errors[.viewer] = $0 }
        }
        func start() { host.start(); viewer.start() }
        private func enqueue(_ role: PairingRole, _ message: WireMessage) {
            sent.append((role, message)); pending.append((role, message))
        }
        func take(from role: PairingRole, type: String) throws -> WireMessage {
            let index = try XCTUnwrap(pending.firstIndex { item in
                item.0 == role && (try? (JSONSerialization.jsonObject(with: item.1.payload) as? [String: Any])?["type"] as? String) == type
            })
            return pending.remove(at: index).1
        }
        func flush() {
            var count = 0
            while !pending.isEmpty && count < 32 {
                let item = pending.removeFirst(); count += 1
                do {
                    let message = try transform?(item.0, item.1) ?? item.1
                    (item.0 == .host ? viewer : host).receive(message.payload)
                } catch { XCTFail("Test message transform failed: \(error)") }
            }
            XCTAssertLessThan(count, 32, "Handshake generated a message loop")
        }
    }
}
