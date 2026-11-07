import XCTest
@testable import RemoteCore

final class TransportTests: XCTestCase {
    func testTLSChannelBindingMatchesBothPeersAndChangesPerConnection() throws {
        let key = try PairingInvitation.generateKey()
        let first = try channelBindings(key: key)
        let second = try channelBindings(key: key)
        XCTAssertEqual(first.0, first.1)
        XCTAssertEqual(second.0, second.1)
        XCTAssertEqual(first.0.count, 32)
        XCTAssertTrue(first.0.contains(where: { $0 != 0 }))
        XCTAssertNotEqual(first.0, second.0, "Separate TLS sessions must not share an identity-proof binding")
    }

    private func channelBindings(key: Data) throws -> (Data, Data) {
        let callbacks = DispatchQueue(label: "farreach.test.channel-binding")
        let listening = expectation(description: "binding listener ready")
        let exchanged = expectation(description: "both TLS peers ready and bound")
        let listener = try SecureListener(key: key, port: 0, callbackQueue: callbacks)
        var port: UInt16 = 0
        var accepted: SecurePeer?
        var serverBinding: Data?
        var clientBinding: Data?
        listener.onReady = { port = $0; listening.fulfill() }
        listener.onError = { XCTFail("Binding listener failed: \($0)") }
        listener.onConnection = { peer in
            accepted = peer
            serverBinding = peer.channelBinding
            peer.onMessage = { message in
                XCTAssertEqual(message.kind, .ping)
                XCTAssertTrue(peer.send(WireMessage(kind: .pong, payload: message.payload)))
            }
        }
        listener.start()
        defer { accepted?.close(); listener.stop() }
        wait(for: [listening], timeout: 5)
        let client = try SecurePeer(host: "127.0.0.1", port: port, key: key, callbackQueue: callbacks)
        client.onReady = {
            clientBinding = client.channelBinding
            XCTAssertTrue(client.send(WireMessage(kind: .ping)))
        }
        client.onMessage = { message in
            XCTAssertEqual(message.kind, .pong)
            exchanged.fulfill()
        }
        client.start()
        defer { client.close() }
        wait(for: [exchanged], timeout: 5)
        return (try XCTUnwrap(serverBinding), try XCTUnwrap(clientBinding))
    }
    func testCloseStillCancelsAfterOwnerImmediatelyReleasesPeer() throws {
        let key = try PairingInvitation.generateKey()
        let callbacks = DispatchQueue(label: "farreach.test.close-release")
        let listening = expectation(description: "listening")
        let accepted = expectation(description: "accepted")
        let connected = expectation(description: "connected")
        let remoteClosed = expectation(description: "remote observes close after local owner releases peer")
        let listener = try SecureListener(key: key, port: 0, callbackQueue: callbacks)
        var port: UInt16 = 0
        listener.onReady = { port = $0; listening.fulfill() }
        listener.onConnection = { peer in
            peer.onClose = { _ in remoteClosed.fulfill() }
            accepted.fulfill()
        }
        listener.start()
        defer { listener.stop() }
        wait(for: [listening], timeout: 5)
        var client: SecurePeer? = try SecurePeer(host: "127.0.0.1", port: port, key: key, callbackQueue: callbacks)
        client?.onReady = { connected.fulfill() }
        client?.start()
        wait(for: [accepted, connected], timeout: 5)
        client?.close()
        client = nil
        wait(for: [remoteClosed], timeout: 3)
    }

    func testStoppingAndReleasingListenerClosesItsAcceptedPeer() throws {
        let key = try PairingInvitation.generateKey()
        let callbacks = DispatchQueue(label: "farreach.test.listener-release")
        let listening = expectation(description: "listening")
        let accepted = expectation(description: "accepted")
        let connected = expectation(description: "connected")
        let remoteClosed = expectation(description: "viewer observes host stop")
        var listener: SecureListener? = try SecureListener(key: key, port: 0, callbackQueue: callbacks)
        var port: UInt16 = 0
        listener?.onReady = { port = $0; listening.fulfill() }
        listener?.onConnection = { _ in accepted.fulfill() }
        listener?.start()
        wait(for: [listening], timeout: 5)
        let client = try SecurePeer(host: "127.0.0.1", port: port, key: key, callbackQueue: callbacks)
        client.onReady = { connected.fulfill() }
        client.onClose = { _ in remoteClosed.fulfill() }
        client.start()
        defer { client.close() }
        wait(for: [accepted, connected], timeout: 5)
        listener?.stop()
        listener = nil
        wait(for: [remoteClosed], timeout: 3)
    }

    func testTLSPSKLoopbackExchangesBidirectionalFramedMessages() throws {
        let key = try PairingInvitation.generateKey()
        let callbacks = DispatchQueue(label: "farreach.test.callbacks")
        let listening = expectation(description: "listening")
        let serverReceived = expectation(description: "server receives authenticated ping and input")
        serverReceived.expectedFulfillmentCount = 2
        let clientReceived = expectation(description: "client receives authenticated hello, video, and pong")
        clientReceived.expectedFulfillmentCount = 3
        let serverClosed = expectation(description: "server close")
        let listener = try SecureListener(key: key, port: 0, callbackQueue: callbacks)
        var port: UInt16 = 0
        var accepted: SecurePeer?
        listener.onReady = { port = $0; listening.fulfill() }
        listener.onError = { XCTFail("Listener failed: \($0)") }
        let video = Data((0..<(2 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        let hello = try JSONEncoder().encode(HostInfo(name: "Test Mac", width: 1920, height: 1080))
        let input = Data(#"{"kind":"move","x":0.5,"y":0.5}"#.utf8)
        listener.onConnection = { peer in
            accepted = peer
            peer.onClose = { _ in serverClosed.fulfill() }
            peer.onMessage = { message in
                switch message.kind {
                case .ping:
                    XCTAssertEqual(message.payload, Data("probe".utf8))
                    XCTAssertTrue(peer.send(WireMessage(kind: .video, payload: video)))
                    XCTAssertTrue(peer.send(WireMessage(kind: .pong, payload: message.payload)))
                case .input: XCTAssertEqual(message.payload, input)
                default: XCTFail("Unexpected upstream message")
                }
                serverReceived.fulfill()
            }
            XCTAssertTrue(peer.send(WireMessage(kind: .hello, payload: hello)))
        }
        listener.start()
        defer { listener.stop(); accepted?.close() }
        wait(for: [listening], timeout: 5)
        XCTAssertNotEqual(port, 0)
        let client = try SecurePeer(host: "127.0.0.1", port: port, key: key, callbackQueue: callbacks)
        client.onReady = {
            XCTAssertTrue(client.send(WireMessage(kind: .ping, payload: Data("probe".utf8))))
            XCTAssertTrue(client.send(WireMessage(kind: .input, payload: input)))
        }
        client.onMessage = { message in
            switch message.kind {
            case .hello: XCTAssertEqual(message.payload, hello)
            case .video: XCTAssertEqual(message.payload, video)
            case .pong: XCTAssertEqual(message.payload, Data("probe".utf8))
            default: XCTFail("Unexpected downstream message")
            }
            clientReceived.fulfill()
        }
        client.start()
        wait(for: [serverReceived, clientReceived], timeout: 10)
        client.close()
        wait(for: [serverClosed], timeout: 5)
    }

    func testWrongKeyNeverBecomesAuthenticated() throws {
        let key = try PairingInvitation.generateKey()
        let callbacks = DispatchQueue(label: "farreach.test.wrong-key")
        let listening = expectation(description: "listening")
        let rejected = expectation(description: "wrong key rejected")
        let listener = try SecureListener(key: key, port: 0, callbackQueue: callbacks)
        var port: UInt16 = 0
        listener.onReady = { port = $0; listening.fulfill() }
        listener.onConnection = { _ in XCTFail("Wrong-key client authenticated") }
        listener.start()
        defer { listener.stop() }
        wait(for: [listening], timeout: 5)
        let client = try SecurePeer(host: "127.0.0.1", port: port, key: PairingInvitation.generateKey(), callbackQueue: callbacks)
        client.onReady = { XCTFail("Wrong key reached ready") }
        client.onClose = { error in XCTAssertNotNil(error); rejected.fulfill() }
        client.start()
        wait(for: [rejected], timeout: 12)
        client.close()
    }
}
