import XCTest
import AppKit
import CoreMedia
import CoreVideo
import RemoteCore
import RemoteMedia

/// A protocol-complete fake screen host: real pairing and transport, synthetic
/// codec output only. It never starts ScreenCaptureKit or an InputInjector.
@MainActor
final class SyntheticSessionHost {
    let identity = DeviceIdentity()
    let name: String
    let frame: EncodedFrame
    private(set) var peer: (any RemotePeer)?
    private var handshake: PairingHandshake?
    private(set) var authenticatedDevice: PairedDevice?
    private(set) var authenticationCount = 0
    private(set) var pairingMessageCount = 0
    private(set) var resumeCount = 0
    private(set) var pauseCount = 0
    private(set) var pingCount = 0
    private(set) var generation: UInt64 = 0
    private(set) var streaming = false
    var invalidHostInfo = false
    var respondsToKeyframeRequests = true
    var onResume: (() -> Void)?
    var onPause: (() -> Void)?
    var onInput: ((RemoteInput) -> Void)?
    var onClose: ((Error?) -> Void)?

    init(name: String = "Synthetic Mac") throws {
        self.name = name
        self.frame = try Self.syntheticFrame()
    }

    func attach(_ peer: any RemotePeer) throws {
        self.peer = peer
        let handshake = try PairingHandshake(identity: identity, localName: name, role: .host, channelBinding: try XCTUnwrap(peer.channelBinding))
        self.handshake = handshake
        handshake.onSend = { [weak peer] message in XCTAssertTrue(peer?.send(message) == true) }
        handshake.onAuthenticated = { [weak self] device in
            self?.authenticatedDevice = device
            self?.authenticationCount += 1
            self?.peer?.setMediaAuthorization(true, generation: 0)
        }
        handshake.onFailure = { error in XCTFail("Synthetic host pairing failed: \(error)"); peer.close() }
        peer.onMessage = { [weak self] message in self?.receive(message) }
        peer.onClose = { [weak self] error in self?.onClose?(error) }
        handshake.start()
    }

    private func receive(_ message: WireMessage) {
        guard let peer else { return }
        do {
            switch message.kind {
            case .pairing:
                pairingMessageCount += 1
                handshake?.receive(message.payload)
            case .ping:
                pingCount += 1
                XCTAssertEqual(message.payload.count, 32)
                XCTAssertTrue(peer.send(WireMessage(kind: .pong, payload: message.payload)))
            case .sessionControl:
                guard authenticatedDevice != nil else { XCTFail("Session control arrived before device authentication"); return }
                let command = try JSONDecoder().decode(SessionControl.self, from: message.payload)
                switch command.action {
                case .wake: break // Never wake or synthesize input on the test Mac.
                case .resume:
                    resumeCount += 1
                    if !streaming { generation += 1 }
                    streaming = true
                    let hello = HostInfo(name: "Unauthenticated display label", width: invalidHostInfo ? 0 : 64, height: 64, fps: 30)
                    XCTAssertTrue(peer.send(WireMessage(kind: .hello, payload: try JSONEncoder().encode(hello))))
                    if !invalidHostInfo {
                        sendState(.available, generation: generation)
                        sendFrame(generation: generation)
                    }
                    onResume?()
                case .pause:
                    pauseCount += 1
                    generation += 1
                    streaming = false
                    sendState(.paused, generation: generation)
                    onPause?()
                }
            case .input, .pointer:
                guard authenticatedDevice != nil else { XCTFail("Input arrived before device authentication"); return }
                let input = try JSONDecoder().decode(RemoteInput.self, from: message.payload)
                XCTAssertTrue(input.isValid)
                onInput?(input)
            case .requestKeyframe:
                if streaming && respondsToKeyframeRequests { sendFrame(generation: generation) }
            case .disconnect: peer.close()
            case .pong: break
            default: XCTFail("Unexpected synthetic-host message: \(message.kind)")
            }
        } catch { XCTFail("Synthetic host protocol error: \(error)") }
    }

    func sendState(_ state: StreamState.State, generation: UInt64) {
        self.generation = generation
        if state == .available { streaming = true }
        else if state == .paused || state == .unavailable { streaming = false }
        peer?.setMediaAuthorization(state == .available, generation: state == .available ? generation : 0)
        do {
            let bytes = try JSONEncoder().encode(StreamState(state, generation: generation))
            XCTAssertTrue(peer?.send(WireMessage(kind: .streamState, payload: bytes)) == true)
        } catch { XCTFail("State encoding failed: \(error)") }
    }
    func sendFrame(generation: UInt64, retries: Int = 10) {
        do {
            let bytes = try StreamFrameEnvelope(generation: generation, frame: frame.serialized()).encoded()
            guard let peer else { return }
            if !peer.send(WireMessage(kind: .video, payload: bytes)) {
                // A request may overtake the fixture's initial IDR while it is
                // still in bounded IPC. Real capture retries a cached image.
                guard retries > 0 else { XCTFail("Synthetic keyframe remained backpressured"); return }
                Task { [weak self, weak peer] in
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    guard let self, let peer, self.peer === peer, self.streaming, self.generation == generation else { return }
                    self.sendFrame(generation: generation, retries: retries - 1)
                }
            }
        } catch { XCTFail("Frame encoding failed: \(error)") }
    }
    func close() {
        handshake?.cancel()
        peer?.onClose = nil
        peer?.close()
        peer = nil
    }

    private static func syntheticFrame() throws -> EncodedFrame {
        var image: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image)
        guard status == kCVReturnSuccess, let image else { throw MediaError.codec("Allocating synthetic desktop", status) }
        CVPixelBufferLockBaseAddress(image, [])
        let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<64 {
            for x in 0..<64 {
                let offset = y * CVPixelBufferGetBytesPerRow(image) + x * 4
                bytes[offset] = UInt8(x * 3); bytes[offset + 1] = UInt8(y * 3)
                bytes[offset + 2] = 160; bytes[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        let encoder = try H264Encoder(width: 64, height: 64)
        let lock = NSLock()
        var result: Result<EncodedFrame, Error>?
        encoder.onFrame = { frame in lock.lock(); result = .success(frame); lock.unlock() }
        encoder.onError = { error in lock.lock(); result = .failure(error); lock.unlock() }
        encoder.encode(image, presentationTime: CMTime(value: 1, timescale: 30))
        encoder.finish()
        lock.lock(); let completed = result; lock.unlock()
        return try XCTUnwrap(completed, "Encoder did not emit a synthetic frame").get()
    }
}
