import XCTest
import CryptoKit
@testable import RemoteCore

final class CloudSignalingTests: XCTestCase {
    func testAuthenticatedLegacyDescriptionsRetainAttemptForUpdateReporting() throws {
        let alice = try SignalingCryptography(identity: DeviceIdentity()), bob = try SignalingCryptography(identity: DeviceIdentity())
        let sender = try PairedDevice(name: "Legacy host", publicKey: alice.identity.publicKey)
        let recipient = try PairedDevice(name: "Current viewer", publicKey: bob.identity.publicKey)
        for kind in [CloudSignalMessage.Kind.offer, .answer] {
            let scheme = kind == .offer ? "farreach-offer://" : "farreach-answer://"
            let legacy = CloudSignalMessage(kind: kind, attemptID: UUID().uuidString, expiresAt: 180, body: scheme + "v1/Legacy_SDP")
            let sealed = try alice.encrypt(legacy, to: recipient, keys: bob.publicKeys, now: 100)
            let opened = try bob.decrypt(sealed, from: sender, keys: alice.publicKeys, now: 101)
            XCTAssertEqual(opened, legacy)
            XCTAssertTrue(opened.requiresTransportUpdate)
            XCTAssertFalse(CloudSignalMessage(kind: kind, attemptID: legacy.attemptID, body: scheme + "v2/Current_SDP").requiresTransportUpdate)
            XCTAssertThrowsError(try CloudSignalMessage(kind: kind, attemptID: legacy.attemptID, expiresAt: 180, body: scheme + "v1/").validate(now: 100))
            XCTAssertThrowsError(try CloudSignalMessage(kind: kind, attemptID: legacy.attemptID, expiresAt: 180, body: scheme + "v1/invalid=").validate(now: 100))
        }
    }
    func testSessionCloseAndBusyAreAuthenticatedAndSessionScoped() throws {
        let attempt = UUID().uuidString, session = UUID().uuidString
        let close = CloudSignalMessage(kind: .close, attemptID: attempt, expiresAt: 180, sessionID: session)
        try close.validate(now: 100)
        try CloudSignalMessage(kind: .closed, attemptID: attempt, expiresAt: 180, sessionID: session).validate(now: 100)
        try CloudSignalMessage(kind: .busy, attemptID: attempt, expiresAt: 180).validate(now: 100)
        XCTAssertThrowsError(try CloudSignalMessage(kind: .close, attemptID: attempt, expiresAt: 180).validate(now: 100))
        XCTAssertThrowsError(try CloudSignalMessage(kind: .closed, attemptID: attempt, expiresAt: 180, sessionID: "invalid").validate(now: 100))
        let alice = try SignalingCryptography(identity: DeviceIdentity()), bob = try SignalingCryptography(identity: DeviceIdentity())
        let to = try PairedDevice(name: "Bob", publicKey: bob.identity.publicKey)
        let from = try PairedDevice(name: "Alice", publicKey: alice.identity.publicKey)
        let sealed = try alice.encrypt(close, to: to, keys: bob.publicKeys, now: 100)
        XCTAssertEqual(try bob.decrypt(sealed, from: from, keys: alice.publicKeys, now: 100), close)
    }
    @MainActor func testNativeClientExchangeWithRunningWorker() async throws {
        guard let endpointText = ProcessInfo.processInfo.environment["FARREACH_SIGNALING_TEST_URL"],
              let endpoint = URL(string: endpointText) else {
            throw XCTSkip("Set FARREACH_SIGNALING_TEST_URL to a running local or deployed signaling Worker.")
        }
        let aliceIdentity = DeviceIdentity(), bobIdentity = DeviceIdentity()
        let aliceDevice = try PairedDevice(name: "Synthetic Alice", publicKey: aliceIdentity.publicKey)
        let bobDevice = try PairedDevice(name: "Synthetic Bob", publicKey: bobIdentity.publicKey)
        let alice = try CloudSignalingClient(identity: aliceIdentity, endpoint: endpoint, peers: [bobDevice])
        let bob = try CloudSignalingClient(identity: bobIdentity, endpoint: endpoint, peers: [aliceDevice])
        let aliceReady = expectation(description: "Alice authenticated")
        let bobReady = expectation(description: "Bob authenticated")
        alice.onReady = { aliceReady.fulfill() }; bob.onReady = { bobReady.fulfill() }
        alice.onError = { XCTFail($0) }; bob.onError = { XCTFail($0) }
        alice.start(); bob.start()
        defer { alice.stop(); bob.stop() }
        await fulfillment(of: [aliceReady, bobReady], timeout: 15)
        alice.onReady = nil; bob.onReady = nil
        guard alice.isReady && bob.isReady else { return }
        let request = CloudSignalMessage(kind: .request, attemptID: UUID().uuidString)
        let received = expectation(description: "Encrypted request delivered")
        let answered = expectation(description: "Encrypted response delivered")
        bob.onSignal = { from, message in
            XCTAssertEqual(from, aliceIdentity.id); XCTAssertEqual(message, request)
            received.fulfill()
            XCTAssertTrue(bob.send(CloudSignalMessage(kind: .reject, attemptID: message.attemptID), to: from))
        }
        alice.onSignal = { from, message in
            XCTAssertEqual(from, bobIdentity.id); XCTAssertEqual(message.kind, .reject)
            XCTAssertEqual(message.attemptID, request.attemptID); answered.fulfill()
        }
        XCTAssertTrue(alice.send(request, to: bobIdentity.id))
        await fulfillment(of: [received, answered], timeout: 10)
        alice.updatePeers([])
        XCTAssertFalse(alice.send(CloudSignalMessage(kind: .request, attemptID: UUID().uuidString), to: bobIdentity.id))
    }

    func testEncryptedOfferAnswerRoundtripAndStableDerivedKey() throws {
        let aliceIdentity = try DeviceIdentity(rawRepresentation: Data(repeating: 7, count: 32))
        let alice = try SignalingCryptography(identity: aliceIdentity)
        let restored = try SignalingCryptography(identity: DeviceIdentity(rawRepresentation: Data(repeating: 7, count: 32)))
        XCTAssertEqual(alice.publicKeys.publicKey, restored.publicKeys.publicKey)
        XCTAssertEqual(alice.publicKeys.agreementKey, restored.publicKeys.agreementKey)
        XCTAssertNotEqual(alice.publicKeys.agreementKey, alice.publicKeys.publicKey)
        let bob = try SignalingCryptography(identity: DeviceIdentity())
        let aliceDevice = try PairedDevice(name: "Alice", publicKey: aliceIdentity.publicKey)
        let bobDevice = try PairedDevice(name: "Bob", publicKey: bob.identity.publicKey)
        let offer = CloudSignalMessage(kind: .offer, attemptID: UUID().uuidString,
            expiresAt: 180, body: "farreach-offer://v2/Private_Offer_123")
        let payload = try alice.encrypt(offer, to: bobDevice, keys: bob.publicKeys, now: 100)
        XCTAssertFalse(payload.contains("Private_Offer"))
        XCTAssertEqual(try bob.decrypt(payload, from: aliceDevice, keys: alice.publicKeys, now: 101), offer)
        let second = try alice.encrypt(offer, to: bobDevice, keys: bob.publicKeys, now: 100)
        XCTAssertNotEqual(payload, second, "AES-GCM must use a new random nonce for every transmission")
        let answer = CloudSignalMessage(kind: .answer, attemptID: offer.attemptID,
            expiresAt: 180, body: "farreach-answer://v2/Private_Answer_123")
        let response = try bob.encrypt(answer, to: aliceDevice, keys: alice.publicKeys, now: 100)
        XCTAssertEqual(try alice.decrypt(response, from: bobDevice, keys: bob.publicKeys, now: 101), answer)
    }

    func testUntrustedKeySubstitutionTamperingAndReflectionFail() throws {
        let alice = try SignalingCryptography(identity: DeviceIdentity())
        let bob = try SignalingCryptography(identity: DeviceIdentity())
        let mallory = try SignalingCryptography(identity: DeviceIdentity())
        let aliceDevice = try PairedDevice(name: "Alice", publicKey: alice.identity.publicKey)
        let bobDevice = try PairedDevice(name: "Bob", publicKey: bob.identity.publicKey)
        let request = CloudSignalMessage(kind: .request, attemptID: UUID().uuidString, expiresAt: 180)
        let substitute = SignalingPublicKeys(publicKey: bob.publicKeys.publicKey,
            agreementKey: mallory.publicKeys.agreementKey, keySignature: mallory.publicKeys.keySignature)
        XCTAssertThrowsError(try alice.encrypt(request, to: bobDevice, keys: substitute, now: 100))
        XCTAssertThrowsError(try alice.encrypt(request, to: bobDevice, keys: mallory.publicKeys, now: 100))
        let payload = try alice.encrypt(request, to: bobDevice, keys: bob.publicKeys, now: 100)
        var changed = Data(signalingBase64URL: payload)!
        changed[changed.count - 1] ^= 1
        XCTAssertThrowsError(try bob.decrypt(changed.signalingBase64URL, from: aliceDevice, keys: alice.publicKeys, now: 100))
        XCTAssertThrowsError(try alice.decrypt(payload, from: bobDevice, keys: bob.publicKeys, now: 100), "Directional AAD prevents reflection")
        XCTAssertThrowsError(try mallory.decrypt(payload, from: aliceDevice, keys: alice.publicKeys, now: 100))
        XCTAssertThrowsError(try bob.decrypt(payload + "=", from: aliceDevice, keys: alice.publicKeys, now: 100))
    }

    func testAuthenticationProofUsesFreshChallengeAndAgreementKey() throws {
        let identity = DeviceIdentity()
        let crypto = try SignalingCryptography(identity: identity)
        let nonce = Data(repeating: 0x42, count: 32)
        let data = try crypto.authentication(nonce: nonce.signalingBase64URL, peers: [])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "authenticate")
        XCTAssertEqual(object["publicKey"] as? String, identity.publicKey.signalingBase64URL)
        let signature = try XCTUnwrap(Data(signalingBase64URL: object["signature"] as! String, count: 64))
        var transcript = Data("FarReach-signaling-auth-v1\0".utf8)
        transcript.append(nonce)
        transcript.append(Data(signalingBase64URL: crypto.publicKeys.agreementKey)!)
        let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: identity.publicKey)
        XCTAssertTrue(verifier.isValidSignature(signature, for: transcript))
        transcript[transcript.count - 1] ^= 1
        XCTAssertFalse(verifier.isValidSignature(signature, for: transcript))
        XCTAssertThrowsError(try crypto.authentication(nonce: "bad", peers: []))
    }

    func testExpiryReplayAndMessageShapesAreValidated() throws {
        let attempt = UUID().uuidString
        let request = CloudSignalMessage(kind: .request, attemptID: attempt, expiresAt: 180)
        var replay = SignalingReplayWindow()
        try replay.accept(request, from: "alice", now: 100)
        XCTAssertThrowsError(try replay.accept(request, from: "alice", now: 101))
        try replay.accept(request, from: "bob", now: 101)
        try replay.accept(CloudSignalMessage(kind: .cancel, attemptID: attempt, expiresAt: 180), from: "alice", now: 101)
        XCTAssertThrowsError(try request.validate(now: 180))
        XCTAssertThrowsError(try request.validate(now: 59))
        for message in [
            CloudSignalMessage(kind: .request, attemptID: "not-a-uuid", expiresAt: 180),
            CloudSignalMessage(kind: .request, attemptID: attempt, expiresAt: .nan),
            CloudSignalMessage(kind: .request, attemptID: attempt, expiresAt: 180, body: "unexpected"),
            CloudSignalMessage(kind: .offer, attemptID: attempt, expiresAt: 180),
            CloudSignalMessage(kind: .offer, attemptID: attempt, expiresAt: 180, body: "farreach-answer://v2/a"),
            CloudSignalMessage(kind: .answer, attemptID: attempt, expiresAt: 180, body: "farreach-answer://v2/"),
            CloudSignalMessage(kind: .offer, attemptID: attempt, expiresAt: 180, body: "farreach-offer://v2/invalid=")
        ] { XCTAssertThrowsError(try message.validate(now: 100)) }
    }

    @MainActor func testEndpointValidationRejectsCredentialsAndInsecureNonlocalConnections() throws {
        let id = DeviceIdentity().id
        XCTAssertEqual(try CloudSignalingClient.webSocketURL(endpoint: URL(string: "https://signal.example.com")!, deviceID: id).absoluteString,
                       "wss://signal.example.com/v1/devices/" + id)
        XCTAssertEqual(try CloudSignalingClient.webSocketURL(endpoint: URL(string: "http://127.0.0.1:8787/")!, deviceID: id).scheme, "ws")
        for value in ["http://example.com", "ws://example.com", "https://user:pass@example.com", "https://example.com/?secret=value", "https://example.com/#secret", "https://example.com/extra", "file:///tmp/socket"] {
            XCTAssertThrowsError(try CloudSignalingClient.webSocketURL(endpoint: URL(string: value)!, deviceID: id), value)
        }
        XCTAssertThrowsError(try CloudSignalingClient.webSocketURL(endpoint: URL(string: "https://example.com")!, deviceID: "invalid"))
    }
}
