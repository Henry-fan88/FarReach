import XCTest
import Foundation
import Darwin
@testable import RemoteCore

final class WebRTCTransportTests: XCTestCase {
    private var temporaryFolders: [URL] = []
    override func tearDownWithError() throws {
        for folder in temporaryFolders { try? FileManager.default.removeItem(at: folder) }
        temporaryFolders = []
    }

    func testHelperPartialFramingHandshakeAndControlRoundtrip() throws {
        let helper = try makeHelper("""
        assert config['role'] == 'host'
        assert config['stunURLs'] == []
        event('invitation', 'farreach-offer://v2/eyJ2IjoxfQ', fragmented=True)
        kind, data = read_packet()
        assert kind == 241
        assert json.loads(data)['response'] == 'farreach-answer://v2/eyJ2IjoxfQ'
        event('path', 'Direct UDP', fragmented=True)
        event('ready', fragmented=True)
        kind, data = read_packet()
        assert kind == 4 and data == b'hello'
        event('videoDropped', fragmented=True)
        packet(5, data, fragmented=True)
        # The adapter closes its writer during normal shutdown.
        sys.stdin.buffer.read()
        """)
        let callbacks = DispatchQueue(label: "farreach.webrtc.test.callbacks")
        let invitation = expectation(description: "manual offer")
        let answer = expectation(description: "pong from helper")
        let drop = expectation(description: "video drop feedback")
        let closed = expectation(description: "closed once")
        let peer = try WebRTCPeer(role: .host, stunURLs: [], helperURL: helper, mediaFlowControl: false, callbackQueue: callbacks)
        var path: String?
        peer.onInvitation = { [weak peer] value in
            XCTAssertEqual(value, "farreach-offer://v2/eyJ2IjoxfQ")
            do { try peer?.applyResponse("farreach-answer://v2/eyJ2IjoxfQ") }
            catch { XCTFail("Answer rejected: \(error)") }
            invitation.fulfill()
        }
        peer.onPath = { path = $0 }
        peer.onReady = { [weak peer] in
            XCTAssertTrue(peer?.send(WireMessage(kind: .ping, payload: Data("hello".utf8))) == true)
        }
        peer.onVideoDropped = { drop.fulfill() }
        peer.onMessage = { message in
            XCTAssertEqual(message.kind, .pong)
            XCTAssertEqual(message.payload, Data("hello".utf8))
            answer.fulfill()
        }
        peer.onClose = { error in XCTAssertNil(error); closed.fulfill() }
        peer.start()
        wait(for: [invitation, drop, answer], timeout: 6)
        XCTAssertEqual(path, "Direct UDP")
        XCTAssertEqual(peer.channelBinding, Data(repeating: 0x42, count: 32))
        peer.close()
        wait(for: [closed], timeout: 3)
    }

    func testViewerReceivesManualResponseAndRejectsApplyingAnotherAnswer() throws {
        let helper = try makeHelper("""
        assert config['role'] == 'viewer'
        assert config['invitation'] == 'farreach-offer://v2/eyJ2IjoxfQ'
        event('response', 'farreach-answer://v2/eyJ2IjoyfQ')
        event('ready')
        sys.stdin.buffer.read()
        """)
        let response = expectation(description: "manual response")
        let ready = expectation(description: "viewer ready")
        let callbacks = DispatchQueue(label: "farreach.webrtc.test.viewer")
        let peer = try WebRTCPeer(role: .viewer(invitation: "farreach-offer://v2/eyJ2IjoxfQ"), stunURLs: [], helperURL: helper, mediaFlowControl: false, callbackQueue: callbacks)
        peer.onResponse = { value in XCTAssertEqual(value, "farreach-answer://v2/eyJ2IjoyfQ"); response.fulfill() }
        peer.onReady = { ready.fulfill() }
        peer.start()
        defer { peer.close() }
        wait(for: [response, ready], timeout: 5)
        XCTAssertThrowsError(try peer.applyResponse("farreach-answer://v2/eyJ2IjoyfQ"))
    }

    func testMalformedHelperOutputFailsClosedBeforeReady() throws {
        let scenarios = [
            "sys.stdout.buffer.write(bytes([255, 0, 0, 0, 0])); sys.stdout.buffer.flush()",
            "sys.stdout.buffer.write(bytes([242, 0, 4, 0, 1])); sys.stdout.buffer.flush()",
            "sys.stdout.buffer.write(bytes([242, 0, 0, 0, 20]) + b'{}'); sys.stdout.buffer.flush()",
            "packet(3, b'{}')",
            "event('invitation', 'farreach-offer://v2/eyJ2IjoxfQ'); packet(242, json.dumps({'type':'ready','value':''}).encode())",
            "event('invitation', 'farreach-offer://v2/eyJ2IjoxfQ'); event('binding', base64.urlsafe_b64encode(bytes(32)).decode().rstrip('='))"
        ]
        for scenario in scenarios {
            let helper = try makeHelper(scenario)
            let closed = expectation(description: "malformed helper closed")
            let peer = try WebRTCPeer(role: .host, stunURLs: [], helperURL: helper, mediaFlowControl: false,
                                      callbackQueue: DispatchQueue(label: "farreach.webrtc.test.invalid"))
            peer.onReady = { XCTFail("Invalid helper reached ready") }
            peer.onMessage = { _ in XCTFail("Unauthenticated message was delivered") }
            peer.onClose = { error in XCTAssertNotNil(error); closed.fulfill() }
            peer.start()
            wait(for: [closed], timeout: 4)
            peer.close()
        }
    }

    func testVideoAdmissionIsBoundedAndCloseReleasesStalledChild() throws {
        let helper = try makeHelper("""
        event('invitation', 'farreach-offer://v2/' + str(os.getpid()))
        kind, data = read_packet()
        assert kind == 241
        event('ready')
        # Deliberately stop consuming stdin; the Swift writer must be cancellable.
        time.sleep(30)
        """)
        let ready = expectation(description: "bounded video writes attempted")
        let closed = expectation(description: "peer closes after caller releases it")
        let callbacks = DispatchQueue(label: "farreach.webrtc.test.backpressure")
        var peer: WebRTCPeer? = try WebRTCPeer(role: .host, stunURLs: [], helperURL: helper, mediaFlowControl: false, callbackQueue: callbacks)
        var childPID: Int32 = 0
        peer?.onInvitation = { [weak peer] value in
            childPID = Int32(value.split(separator: "/").last ?? "0") ?? 0
            try? peer?.applyResponse("farreach-answer://v2/eyJ2IjoxfQ")
        }
        peer?.onReady = { [weak peer] in
            peer?.setMediaAuthorization(true, generation: 1)
            var bytes = Data(repeating: 7, count: 8 * 1024 * 1024)
            bytes.replaceSubrange(0..<12, with: Data([0x46, 0x52, 0x53, 0x31, 0, 0, 0, 0, 0, 0, 0, 1]))
            let message = WireMessage(kind: .video, payload: bytes)
            XCTAssertTrue(peer?.send(message) == true)
            XCTAssertFalse(peer?.send(message) == true, "A second video cannot queue behind a blocked pipe write")
            ready.fulfill()
        }
        peer?.onClose = { error in XCTAssertNil(error); closed.fulfill() }
        peer?.start()
        wait(for: [ready], timeout: 5)
        peer?.close()
        peer = nil
        wait(for: [closed], timeout: 3)
        XCTAssertGreaterThan(childPID, 0)
        let exit = expectation(description: "owned helper exits")
        DispatchQueue.global().async {
            for _ in 0..<40 {
                if Darwin.kill(childPID, 0) != 0 { exit.fulfill(); return }
                Thread.sleep(forTimeInterval: 0.05)
            }
            XCTFail("Owned helper remained running after close")
            exit.fulfill()
        }
        wait(for: [exit], timeout: 3)
    }

    func testReleasingOwnerWithoutStartOrWhileWaitingDoesNotLeakHelper() throws {
        let helper = try makeHelper("""
        event('invitation', 'farreach-offer://v2/' + str(os.getpid()))
        time.sleep(30)
        """)
        let offered = expectation(description: "helper offer")
        var childPID: Int32 = 0
        var peer: WebRTCPeer? = try WebRTCPeer(role: .host, stunURLs: [], helperURL: helper, mediaFlowControl: false,
                                             callbackQueue: DispatchQueue(label: "farreach.webrtc.test.release"))
        peer?.onInvitation = { value in
            childPID = Int32(value.split(separator: "/").last ?? "0") ?? 0
            offered.fulfill()
        }
        peer?.start()
        wait(for: [offered], timeout: 4)
        peer = nil
        let exit = expectation(description: "deinit cancels the owned child")
        DispatchQueue.global().async {
            for _ in 0..<40 {
                if childPID > 0 && Darwin.kill(childPID, 0) != 0 { exit.fulfill(); return }
                Thread.sleep(forTimeInterval: 0.05)
            }
            XCTFail("Dropping the peer leaked its helper process")
            exit.fulfill()
        }
        wait(for: [exit], timeout: 3)
    }

    func testConfigurationDoesNotAcceptRelayURLsOrArbitraryInvitationSchemes() throws {
        let helper = try makeHelper("pass")
        for value in ["turn:relay.example:3478", "turns:relay.example:5349", "https://example.com", "stun:user:secret@example.com:3478", "stun:example.com:3478/path", "stun:example.com:3478?transport=tcp", "stun:example.com:0", "stun:example.com\n"] {
            XCTAssertThrowsError(try WebRTCPeer(role: .host, stunURLs: [value], helperURL: helper, mediaFlowControl: false), value)
        }
        XCTAssertThrowsError(try WebRTCPeer(role: .host, stunURLs: Array(repeating: "stun:example.com:3478", count: 4), helperURL: helper, mediaFlowControl: false))
        XCTAssertThrowsError(try WebRTCPeer(role: .viewer(invitation: "https://example.com"), helperURL: helper, mediaFlowControl: false))
        XCTAssertThrowsError(try WebRTCPeer(role: .viewer(invitation: "farreach-offer://v2/contains whitespace"), helperURL: helper, mediaFlowControl: false))
        XCTAssertThrowsError(try WebRTCPeer(role: .host, helperURL: URL(fileURLWithPath: "/does/not/exist")))
        XCTAssertNoThrow(try WebRTCPeer(role: .host, stunURLs: ["stun:stun.cloudflare.com:3478", "stun:[::1]:3478"], helperURL: helper, mediaFlowControl: false))
    }

    func testLegacyInternetInvitationReportsRequiredUpdate() throws {
        let helper = try makeHelper("pass")
        XCTAssertThrowsError(try WebRTCPeer(role: .viewer(invitation: "farreach-offer://v1/eyJ2IjoxfQ"), helperURL: helper, mediaFlowControl: false)) {
            XCTAssertEqual($0 as? WebRTCTransportError, .incompatibleVersion)
        }
    }

    func testSlowMediaConsumerDoesNotBlockControlReader() throws {
        let helper = try makeHelper("""
        event('invitation', 'farreach-offer://v2/eyJ2IjoyfQ')
        assert read_packet()[0] == 241
        event('ready')
        kind, payload = read_packet()
        assert kind == 244 and json.loads(payload)['generation'] == 1
        frame = b'FRS1' + struct.pack('>Q', 1) + b'FRV1' + bytes(8) + bytes([1]) + bytes(12)
        packet(243, struct.pack('>QII', 1, len(frame), 0) + frame)
        time.sleep(.1)
        packet(5, b'control-alive')
        sys.stdin.buffer.read()
        """)
        let mediaStarted = expectation(description: "media callback occupied")
        let pong = expectation(description: "control proceeds independently")
        let gate = DispatchSemaphore(value: 0)
        let peer = try WebRTCPeer(role: .host, stunURLs: [], helperURL: helper, mediaFlowControl: false,
                                  callbackQueue: DispatchQueue(label: "farreach.control.independent"))
        peer.onInvitation = { [weak peer] _ in try? peer?.applyResponse("farreach-answer://v2/eyJ2IjoyfQ") }
        peer.onReady = { [weak peer] in peer?.setMediaAuthorization(true, generation: 1) }
        peer.onMediaMessage = { _ in mediaStarted.fulfill(); _ = gate.wait(timeout: .now() + 5) }
        peer.onMessage = { message in
            if message.kind == .pong { XCTAssertEqual(message.payload, Data("control-alive".utf8)); pong.fulfill() }
        }
        peer.start()
        defer { gate.signal(); peer.close() }
        wait(for: [mediaStarted, pong], timeout: 4)
    }

    func testLargeMediaWriteAllowsControlBetweenChunks() throws {
        let helper = try makeHelper("""
        event('invitation', 'farreach-offer://v2/eyJ2IjoyfQ')
        assert read_packet()[0] == 241
        event('ready')
        assert read_packet()[0] == 244
        kind, payload = read_packet()
        assert kind == 243
        total = struct.unpack('>I', payload[8:12])[0]
        received = len(payload) - 16
        packet(4, b'priority')
        while True:
            time.sleep(.002)
            kind, payload = read_packet()
            if kind == 5:
                assert received < total
                packet(5, b'priority-ok')
                break
            assert kind == 243
            received += len(payload) - 16
        sys.stdin.buffer.read()
        """)
        let completed = expectation(description: "control preempts large frame")
        let peer = try WebRTCPeer(role: .host, stunURLs: [], helperURL: helper, mediaFlowControl: false,
                                  callbackQueue: DispatchQueue(label: "farreach.chunk.priority"))
        peer.onInvitation = { [weak peer] _ in try? peer?.applyResponse("farreach-answer://v2/eyJ2IjoyfQ") }
        peer.onReady = { [weak peer] in
            peer?.setMediaAuthorization(true, generation: 1)
            var data = Data(repeating: 0, count: 2 * 1024 * 1024)
            data.replaceSubrange(0..<12, with: Data([0x46, 0x52, 0x53, 0x31, 0, 0, 0, 0, 0, 0, 0, 1]))
            XCTAssertTrue(peer?.send(WireMessage(kind: .video, payload: data)) == true)
        }
        peer.onMessage = { [weak peer] message in
            if message.kind == .ping { _ = peer?.send(WireMessage(kind: .pong, payload: message.payload)) }
            if message.kind == .pong { XCTAssertEqual(message.payload, Data("priority-ok".utf8)); completed.fulfill() }
        }
        peer.start()
        defer { peer.close() }
        wait(for: [completed], timeout: 5)
    }

    func testPointerFloodIsCoalescedWhileControlQueueIsStalled() throws {
        let helper = try makeHelper("""
        event('invitation', 'farreach-offer://v2/eyJ2IjoyfQ')
        assert read_packet()[0] == 241
        event('ready')
        assert read_packet()[0] == 244
        for index in range(1000):
            packet(11, str(index).encode())
        packet(5, b'after-pointer-flood')
        sys.stdin.buffer.read()
        """)
        let pong = expectation(description: "critical control survives pointer pressure")
        let callbackQueue = DispatchQueue(label: "farreach.pointer.coalescing")
        let peer = try WebRTCPeer(role: .host, stunURLs: [], helperURL: helper, mediaFlowControl: false, callbackQueue: callbackQueue)
        var pointerCallbacks = 0
        var newest: String?
        peer.onInvitation = { [weak peer] _ in try? peer?.applyResponse("farreach-answer://v2/eyJ2IjoyfQ") }
        peer.onReady = { [weak peer] in
            peer?.setMediaAuthorization(true, generation: 1)
            // Deliberately occupy only the UI-equivalent callback queue. The
            // helper reader must keep draining/coalescing rather than disconnect.
            Thread.sleep(forTimeInterval: 0.4)
        }
        peer.onMessage = { message in
            if message.kind == .pointer { pointerCallbacks += 1; newest = String(data: message.payload, encoding: .utf8) }
            if message.kind == .pong { pong.fulfill() }
        }
        peer.onClose = { error in if let error { XCTFail("Pointer overload closed connection: \(error)") } }
        peer.start()
        defer { peer.onClose = nil; peer.close() }
        wait(for: [pong], timeout: 5)
        callbackQueue.sync {
            XCTAssertEqual(newest, "999")
            XCTAssertLessThan(pointerCallbacks, 10)
        }
    }

    func testOldStatisticsCannotRevokeNewCaptureAuthorization() throws {
        let helper = try makeHelper("""
        event('invitation', 'farreach-offer://v2/eyJ2IjoyfQ')
        assert read_packet()[0] == 241
        event('ready')
        assert read_packet()[0] == 244
        stats = dict(targetBitrate=2000000,rttMS=1,queuedBytes=0,queueMS=0,
                     packetsSent=0,packetsReceived=0,packetsLost=0,packetsRepaired=0,
                     framesDropped=0,keyframes=0,mediaReady=False)
        event('statistics', json.dumps(stats))
        sys.stdin.buffer.read()
        """)
        let sampled = expectation(description: "stale periodic status does not gate current generation")
        let peer = try WebRTCPeer(role: .host, stunURLs: [], helperURL: helper, mediaFlowControl: false,
                                  callbackQueue: DispatchQueue(label: "farreach.stats.epoch"))
        peer.onInvitation = { [weak peer] _ in try? peer?.applyResponse("farreach-answer://v2/eyJ2IjoyfQ") }
        peer.onReady = { [weak peer] in peer?.setMediaAuthorization(true, generation: 2) }
        peer.onStatistics = { [weak peer] stats in
            XCTAssertFalse(stats.mediaReady)
            XCTAssertTrue(peer?.mediaCapacityAvailable == true)
            sampled.fulfill()
        }
        peer.start()
        defer { peer.close() }
        wait(for: [sampled], timeout: 5)
    }

    func testRepairedReferenceBurstIsPreservedWhileControlRemainsResponsive() throws {
        let helper = try makeHelper("""
        event('invitation', 'farreach-offer://v2/eyJ2IjoyfQ')
        assert read_packet()[0] == 241
        event('ready')
        assert read_packet()[0] == 244
        for number in range(1, 13):
            frame = b'FRS1' + struct.pack('>Q', 1) + b'FRV1' + bytes(8) + bytes([number == 1]) + bytes(12) + bytes([number])
            packet(243, struct.pack('>QII', number, len(frame), 0) + frame)
        time.sleep(.1)
        packet(5, b'control-during-burst')
        sys.stdin.buffer.read()
        """)
        let control = expectation(description: "control passes blocked decode")
        let frames = expectation(description: "all references delivered in sequence"); frames.expectedFulfillmentCount = 12
        let gate = DispatchSemaphore(value: 0)
        let lock = NSLock(); var received: [UInt8] = []
        let peer = try WebRTCPeer(role: .host, stunURLs: [], helperURL: helper, mediaFlowControl: false,
                                  callbackQueue: DispatchQueue(label: "farreach.reference.burst"))
        peer.onInvitation = { [weak peer] _ in try? peer?.applyResponse("farreach-answer://v2/eyJ2IjoyfQ") }
        peer.onReady = { [weak peer] in peer?.setMediaAuthorization(true, generation: 1) }
        peer.onMediaMessage = { message in
            if message.payload.last == 1 { _ = gate.wait(timeout: .now() + 5) }
            lock.lock(); received.append(message.payload.last!); lock.unlock()
            frames.fulfill()
        }
        peer.onMessage = { message in if message.kind == .pong { control.fulfill() } }
        peer.start(); defer { gate.signal(); peer.close() }
        wait(for: [control], timeout: 4)
        gate.signal()
        wait(for: [frames], timeout: 3)
        lock.lock(); let values = received; lock.unlock()
        XCTAssertEqual(values, Array(UInt8(1)...UInt8(12)))
    }

    func testCompressedOverflowDiscardsBrokenChainUntilFreshKeyframe() throws {
        let helper = try makeHelper("""
        event('invitation', 'farreach-offer://v2/eyJ2IjoyfQ')
        assert read_packet()[0] == 241
        event('ready')
        assert read_packet()[0] == 244
        def video(number, key):
            frame = b'FRS1' + struct.pack('>Q', 1) + b'FRV1' + bytes(8) + bytes([key]) + bytes(12) + bytes([number])
            packet(243, struct.pack('>QII', number, len(frame), 0) + frame)
        video(1, True)
        assert read_packet()[0] == 4
        for number in range(2, 21): video(number, False)
        video(21, True)
        packet(5, b'overflow-finished')
        sys.stdin.buffer.read()
        """)
        let control = expectation(description: "overflow remained bounded")
        let frames = expectation(description: "only valid reference chain survives"); frames.expectedFulfillmentCount = 2
        let gate = DispatchSemaphore(value: 0)
        let lock = NSLock(); var received: [UInt8] = []
        let peer = try WebRTCPeer(role: .host, stunURLs: [], helperURL: helper, mediaFlowControl: false,
                                  callbackQueue: DispatchQueue(label: "farreach.reference.overflow"))
        peer.onInvitation = { [weak peer] _ in try? peer?.applyResponse("farreach-answer://v2/eyJ2IjoyfQ") }
        peer.onReady = { [weak peer] in peer?.setMediaAuthorization(true, generation: 1) }
        peer.onMediaMessage = { [weak peer] message in
            if message.payload.last == 1 {
                _ = peer?.send(WireMessage(kind: .ping))
                _ = gate.wait(timeout: .now() + 5)
            }
            lock.lock(); received.append(message.payload.last!); lock.unlock()
            frames.fulfill()
        }
        peer.onMessage = { message in if message.kind == .pong { control.fulfill() } }
        peer.start(); defer { gate.signal(); peer.close() }
        wait(for: [control], timeout: 4)
        gate.signal()
        wait(for: [frames], timeout: 3)
        lock.lock(); let values = received; lock.unlock()
        XCTAssertEqual(values, [1, 21])
    }

    func testMediaCreditWaitsForHelperAndRejectsStaleGeneration() throws {
        let helper = try makeHelper("""
        assert config['mediaFlowControl'] is True
        event('invitation', 'farreach-offer://v2/eyJ2IjoyfQ')
        assert read_packet()[0] == 241
        event('ready')
        kind, raw = read_packet()
        assert kind == 244 and json.loads(raw)['generation'] == 1
        assert read_packet()[0] == 4
        event('mediaCapacity', json.dumps(dict(generation=1, available=True)))
        packet(5, b'first-credit')
        kind, raw = read_packet()
        assert kind == 243
        packet(5, b'frame-draining')
        kind, raw = read_packet()
        assert kind == 244 and json.loads(raw)['generation'] == 2
        event('mediaCapacity', json.dumps(dict(generation=1, available=True)))
        packet(5, b'stale-credit')
        assert read_packet()[0] == 4
        event('mediaCapacity', json.dumps(dict(generation=2, available=True)))
        packet(5, b'fresh-credit')
        kind, raw = read_packet()
        assert kind == 243
        packet(5, b'complete')
        sys.stdin.buffer.read()
        """)
        let done = expectation(description: "generation-scoped media grants")
        let peer = try WebRTCPeer(role: .host, stunURLs: [], helperURL: helper,
                                  callbackQueue: DispatchQueue(label: "farreach.media.credit"))
        func video(_ generation: UInt8) -> WireMessage {
            var data = Data("FRS1".utf8)
            data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, generation])
            data.append(Data("FRV1".utf8)); data.append(Data(repeating: 0, count: 21))
            data[24] = 1
            return WireMessage(kind: .video, payload: data)
        }
        peer.onInvitation = { [weak peer] _ in try? peer?.applyResponse("farreach-answer://v2/eyJ2IjoyfQ") }
        peer.onReady = { [weak peer] in
            peer?.setMediaAuthorization(true, generation: 1)
            XCTAssertFalse(peer?.mediaCapacityAvailable ?? true)
            XCTAssertFalse(peer?.send(video(1)) ?? true)
            XCTAssertTrue(peer?.send(WireMessage(kind: .ping)) ?? false)
        }
        peer.onMessage = { [weak peer] message in
            guard let peer, message.kind == .pong else { return }
            switch String(decoding: message.payload, as: UTF8.self) {
            case "first-credit":
                XCTAssertTrue(peer.mediaCapacityAvailable)
                XCTAssertTrue(peer.send(video(1)))
                XCTAssertFalse(peer.mediaCapacityAvailable)
            case "frame-draining":
                XCTAssertFalse(peer.mediaCapacityAvailable, "Writing bytes is not a new capacity grant")
                XCTAssertFalse(peer.send(video(1)))
                peer.setMediaAuthorization(true, generation: 2)
            case "stale-credit":
                XCTAssertFalse(peer.mediaCapacityAvailable)
                XCTAssertTrue(peer.send(WireMessage(kind: .ping)))
            case "fresh-credit":
                XCTAssertTrue(peer.mediaCapacityAvailable)
                XCTAssertTrue(peer.send(video(2)))
            case "complete": done.fulfill()
            default: XCTFail("Unexpected test message")
            }
        }
        peer.onClose = { error in if let error { XCTFail(error.localizedDescription) } }
        peer.start(); defer { peer.onClose = nil; peer.close() }
        wait(for: [done], timeout: 6)
    }

    private func makeHelper(_ scenario: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("farreach-fake-helper-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        temporaryFolders.append(folder)
        let helper = folder.appendingPathComponent("helper.py")
        let preamble = """
        #!/usr/bin/python3
        import sys, struct, json, os, time, base64
        def exact(count):
            value = b''
            while len(value) < count:
                part = sys.stdin.buffer.read(count-len(value))
                if not part: raise EOFError()
                value += part
            return value
        def read_packet():
            header = exact(5)
            return header[0], exact(struct.unpack('>I', header[1:])[0])
        def packet(kind, payload, fragmented=False):
            value = bytes([kind]) + struct.pack('>I', len(payload)) + payload
            if fragmented:
                for index in range(0, len(value), 3):
                    sys.stdout.buffer.write(value[index:index+3]); sys.stdout.buffer.flush(); time.sleep(.001)
            else:
                sys.stdout.buffer.write(value); sys.stdout.buffer.flush()
        def event(kind, value='', fragmented=False):
            if kind == 'ready':
                binding = base64.urlsafe_b64encode(bytes([0x42])*32).decode().rstrip('=')
                packet(242, json.dumps({'type': 'binding', 'value': binding}).encode(), fragmented)
            packet(242, json.dumps({'type': kind, 'value': value}).encode(), fragmented)
        kind, raw = read_packet()
        assert kind == 240
        config = json.loads(raw)
        assert len(sys.argv) == 1
        assert config['protocolVersion'] == 2
        """
        try (preamble + "\n" + scenario + "\n").write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return helper
    }
}
