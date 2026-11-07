import XCTest
import CoreMedia
import CoreVideo
import VideoToolbox
import RemoteCore
import RemoteMedia

/// Real identity authentication, input IPC, direct WebRTC, native H.264 and native
/// decode. Pixels are generated in memory; this never captures a desktop, opens
/// a viewer window, posts a CGEvent, accesses Keychain, or uses an external STUN.
final class SyntheticLatencyTests: XCTestCase {
    func test720pInputToDecodedSyntheticResponseOverAuthenticatedWebRTC() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = ProcessInfo.processInfo.environment["FARREACH_NETWORK_HELPER"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent(".build/testing/FarReachNetwork")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw XCTSkip("Build the v2 helper at .build/testing/FarReachNetwork or set FARREACH_NETWORK_HELPER.")
        }
        let authenticated = expectation(description: "both synthetic peers authenticated and authorized")
        let harness = try SyntheticLatencyHarness(helper: helper, onReady: { authenticated.fulfill() },
            onFailure: { XCTFail("Synthetic latency session failed: \($0)") })
        defer { harness.close() }
        harness.start()
        await fulfillment(of: [authenticated], timeout: 20)
        guard harness.isAuthenticated else { return }

        var milliseconds: [Double] = []
        // Two warm-up responses exercise the same path, but are excluded from
        // percentiles so decoder/session initialization is not mixed with steady use.
        for sequence in UInt64(1)...22 {
            let decoded = expectation(description: "decoded pixels for input \(sequence)")
            let result = LatencyResultBox()
            try harness.request(sequence: sequence) { value in result.set(value); decoded.fulfill() }
            await fulfillment(of: [decoded], timeout: 5)
            guard let value = result.get() else { return }
            let response = try value.get()
            XCTAssertEqual(response.frameID, sequence, "RTP metadata must identify the triggering input")
            XCTAssertEqual(response.pixelID, sequence, "Decoded pixels must change to the triggering input, not merely repeat an old image")
            XCTAssertEqual(response.width, 1280); XCTAssertEqual(response.height, 720)
            XCTAssertGreaterThanOrEqual(response.milliseconds, 0)
            if sequence > 2 { milliseconds.append(response.milliseconds) }
        }
        XCTAssertEqual(milliseconds.count, 20)
        let sorted = milliseconds.sorted()
        let p50 = sorted[Int(ceil(Double(sorted.count) * 0.50)) - 1]
        let p95 = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
        print(String(format: "SYNTHETIC_LATENCY input-to-decoded response: samples=%d warmup=2 resolution=1280x720 p50=%.2fms p95=%.2fms max=%.2fms; same-Mac direct-UDP loopback, native H.264, generated pixels; excludes physical input, screen capture, display scanout and WAN; no WAN latency target asserted", sorted.count, p50, p95, sorted.last!))
    }
}

private struct SyntheticDecodedResponse {
    let frameID: UInt64
    let pixelID: UInt64
    let width: Int
    let height: Int
    let milliseconds: Double
}

private enum SyntheticLatencyError: Error {
    case notAuthenticated, inputRejected, invalidInput, invalidGeneration, duplicateRequest
    case codec(String, OSStatus)
}

private final class LatencyResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<SyntheticDecodedResponse, Error>?
    func set(_ value: Result<SyntheticDecodedResponse, Error>) { lock.lock(); result = value; lock.unlock() }
    func get() -> Result<SyntheticDecodedResponse, Error>? { lock.lock(); defer { lock.unlock() }; return result }
}

private final class SyntheticLatencyHarness: @unchecked Sendable {
    private let protocolQueue = DispatchQueue(label: "FarReach.test.latency.protocol", qos: .userInteractive)
    private let encodeQueue = DispatchQueue(label: "FarReach.test.latency.encode", qos: .userInteractive)
    private let decodeQueue = DispatchQueue(label: "FarReach.test.latency.decode", qos: .userInteractive)
    private let helper: URL
    private let host: WebRTCPeer
    private var viewer: WebRTCPeer?
    private let hostIdentity = DeviceIdentity(), viewerIdentity = DeviceIdentity()
    private var hostHandshake: PairingHandshake?, viewerHandshake: PairingHandshake?
    private var hostAuthenticated = false, viewerAuthenticated = false, mediaAuthorized = false, closed = false
    private let generation: UInt64 = 731
    private let onReady: () -> Void
    private let onFailure: (Error) -> Void
    typealias Reply = (Result<SyntheticDecodedResponse, Error>) -> Void
    private var pending: [UInt64: (started: UInt64, reply: Reply)] = [:]
    // Encoder state belongs to encodeQueue; decoder state belongs to decodeQueue.
    private let encoder: H264Encoder
    private var encodingSequence: UInt64 = 0
    private let preparer = MediaFramePreparer()
    private var decoder: VTDecompressionSession?
    private var decoderSPS = Data(), decoderPPS = Data()

    init(helper: URL, onReady: @escaping () -> Void, onFailure: @escaping (Error) -> Void) throws {
        self.helper = helper; self.onReady = onReady; self.onFailure = onFailure
        host = try WebRTCPeer(role: .host, stunURLs: [], helperURL: helper, callbackQueue: protocolQueue)
        encoder = try H264Encoder(width: 1280, height: 720, configuration: .automaticInitial)
        encoder.onFrame = { [weak self] frame in
            self?.encodeQueue.async { [weak self] in self?.sendEncoded(frame) }
        }
        encoder.onError = { [weak self] error in self?.fail(error) }
        host.onInvitation = { [weak self] invitation in self?.makeViewer(invitation) }
        host.onReady = { [weak self] in self?.beginHandshake(hostSide: true) }
        host.onMessage = { [weak self] message in self?.receiveHost(message) }
        host.onVideoDropped = { [weak self] in self?.encoder.requestKeyframe() }
        host.onClose = { [weak self] error in
            guard let self, !self.closed else { return }
            self.onFailure(error ?? SyntheticLatencyError.notAuthenticated)
        }
    }

    var isAuthenticated: Bool { protocolQueue.sync { mediaAuthorized && !closed } }
    func start() { host.start() }

    private func makeViewer(_ invitation: String) {
        do {
            let viewer = try WebRTCPeer(role: .viewer(invitation: invitation), stunURLs: [], helperURL: helper, callbackQueue: protocolQueue)
            self.viewer = viewer
            viewer.onResponse = { [weak self] answer in
                do { try self?.host.applyResponse(answer) } catch { self?.onFailure(error) }
            }
            viewer.onReady = { [weak self] in self?.beginHandshake(hostSide: false) }
            viewer.onMessage = { [weak self] message in
                if message.kind == .pairing { self?.viewerHandshake?.receive(message.payload) }
            }
            viewer.onMediaMessage = { [weak self] message in
                guard message.kind == .video else { return }
                self?.decodeQueue.async { [weak self] in self?.decode(message.payload) }
            }
            viewer.onClose = { [weak self] error in
                guard let self, !self.closed else { return }
                self.onFailure(error ?? SyntheticLatencyError.notAuthenticated)
            }
            viewer.start()
        } catch { onFailure(error) }
    }

    private func beginHandshake(hostSide: Bool) {
        do {
            let peer: WebRTCPeer = hostSide ? host : try XCTUnwrap(viewer)
            let handshake = try PairingHandshake(identity: hostSide ? hostIdentity : viewerIdentity,
                localName: hostSide ? "Synthetic latency host" : "Synthetic latency viewer", role: hostSide ? .host : .viewer,
                channelBinding: try XCTUnwrap(peer.channelBinding), expectedPeerID: hostSide ? viewerIdentity.id : hostIdentity.id)
            if hostSide { hostHandshake = handshake } else { viewerHandshake = handshake }
            handshake.onSend = { [weak peer] message in XCTAssertTrue(peer?.send(message) == true) }
            handshake.onFailure = { [weak self] error in self?.onFailure(error) }
            handshake.onAuthenticated = { [weak self] _ in
                guard let self else { return }
                if hostSide { self.hostAuthenticated = true } else { self.viewerAuthenticated = true }
                if self.hostAuthenticated && self.viewerAuthenticated && !self.mediaAuthorized {
                    self.host.setMediaAuthorization(true, generation: self.generation)
                    self.viewer?.setMediaAuthorization(true, generation: self.generation)
                    self.mediaAuthorized = true
                    self.onReady()
                }
            }
            handshake.start()
        } catch { onFailure(error) }
    }

    func request(sequence: UInt64, completion: @escaping Reply) throws {
        try protocolQueue.sync {
            guard mediaAuthorized, !closed, let viewer else { throw SyntheticLatencyError.notAuthenticated }
            guard pending.isEmpty else { throw SyntheticLatencyError.duplicateRequest }
            let started = DispatchTime.now().uptimeNanoseconds
            let input = RemoteInput(kind: .keyDown, keyCode: 0, sequence: sequence, interaction: sequence + 1)
            let bytes = try JSONEncoder().encode(input)
            pending[sequence] = (started, completion)
            guard viewer.send(WireMessage(kind: .input, payload: bytes)) else {
                pending.removeValue(forKey: sequence); throw SyntheticLatencyError.inputRejected
            }
        }
    }

    private func receiveHost(_ message: WireMessage) {
        if message.kind == .pairing { hostHandshake?.receive(message.payload); return }
        if message.kind == .requestKeyframe { encoder.requestKeyframe(); return }
        guard message.kind == .input else { return }
        do {
            guard hostAuthenticated && mediaAuthorized else { throw SyntheticLatencyError.notAuthenticated }
            let input = try JSONDecoder().decode(RemoteInput.self, from: message.payload)
            guard input.isValid, input.kind == .keyDown, input.sequence > 0, input.sequence < 256 else { throw SyntheticLatencyError.invalidInput }
            encodeQueue.async { [weak self] in
                guard let self else { return }
                do {
                    self.encodingSequence = input.sequence
                    let image = try Self.makeImage(sequence: input.sequence)
                    guard self.encoder.encode(image, presentationTime: CMClockGetTime(CMClockGetHostTimeClock())) else {
                        throw SyntheticLatencyError.inputRejected
                    }
                } catch { self.fail(error) }
            }
        } catch { onFailure(error) }
    }

    private func sendEncoded(_ encoded: EncodedFrame) {
        do {
            // The synthetic response uses the triggering input's ID. All codec
            // bytes and original monotonic timing still come from VideoToolbox.
            let frame = try EncodedFrame(width: encoded.width, height: encoded.height, isKeyframe: encoded.isKeyframe,
                sps: encoded.sps, pps: encoded.pps, payload: encoded.payload, frameID: encodingSequence,
                captureTimeNanoseconds: encoded.captureTimeNanoseconds, encodedTimeNanoseconds: encoded.encodedTimeNanoseconds)
            let envelope = try StreamFrameEnvelope(generation: generation, frame: frame.serialized()).encoded()
            guard host.send(WireMessage(kind: .video, payload: envelope)) else { throw SyntheticLatencyError.inputRejected }
        } catch { fail(error) }
    }

    private func decode(_ bytes: Data) {
        do {
            let envelope = try StreamFrameEnvelope(data: bytes)
            guard envelope.generation == generation else { throw SyntheticLatencyError.invalidGeneration }
            let frame = try EncodedFrame(data: envelope.frame)
            let prepared = try preparer.prepare(frame)
            if decoder == nil || decoderSPS != frame.sps || decoderPPS != frame.pps {
                if let decoder { VTDecompressionSessionWaitForAsynchronousFrames(decoder); VTDecompressionSessionInvalidate(decoder) }
                decoder = nil
                let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: prepared.format,
                    decoderSpecification: nil, imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
                    outputCallback: nil, decompressionSessionOut: &decoder)
                guard status == noErr else { throw SyntheticLatencyError.codec("Creating synthetic decoder", status) }
                decoderSPS = frame.sps; decoderPPS = frame.pps
            }
            guard let decoder else { throw SyntheticLatencyError.codec("Missing synthetic decoder", -1) }
            let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: prepared.sample,
                flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
                let decodedAt = DispatchTime.now().uptimeNanoseconds
                guard status == noErr, let image else { self?.fail(SyntheticLatencyError.codec("Decoding synthetic response", status)); return }
                let pixelID = Self.readPixelID(image)
                let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
                self?.protocolQueue.async { [weak self] in
                    guard let self, !self.closed, let request = self.pending.removeValue(forKey: frame.frameID) else { return }
                    request.reply(.success(.init(frameID: frame.frameID, pixelID: pixelID, width: width, height: height,
                        milliseconds: Double(decodedAt - request.started) / 1_000_000)))
                }
            }
            guard status == noErr else { throw SyntheticLatencyError.codec("Submitting synthetic decode", status) }
        } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        protocolQueue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.onFailure(error)
            let requests = self.pending.values; self.pending.removeAll()
            for request in requests { request.reply(.failure(error)) }
        }
    }

    func close() {
        protocolQueue.sync {
            closed = true; pending.removeAll()
            hostHandshake?.cancel(); viewerHandshake?.cancel()
            host.onClose = nil; viewer?.onClose = nil
            host.setMediaAuthorization(false, generation: 0); viewer?.setMediaAuthorization(false, generation: 0)
            host.close(); viewer?.close()
        }
        encodeQueue.sync { encoder.finish() }
        decodeQueue.sync {
            if let decoder { VTDecompressionSessionWaitForAsynchronousFrames(decoder); VTDecompressionSessionInvalidate(decoder) }
            decoder = nil
        }
    }

    private static func makeImage(sequence: UInt64) throws -> CVPixelBuffer {
        var image: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image)
        guard status == kCVReturnSuccess, let image else { throw SyntheticLatencyError.codec("Allocating synthetic pixels", status) }
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        let stride = CVPixelBufferGetBytesPerRow(image) / 4
        let pixels = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt32.self)
        pixels.update(repeating: 0xff808080, count: stride * 720)
        // Eight broad gray tiles encode the input ID robustly through lossy H.264.
        // Each response changes real pixel content instead of trusting metadata alone.
        for bit in 0..<8 {
            let color: UInt32 = sequence & (1 << bit) == 0 ? 0xff202020 : 0xffe0e0e0
            for y in 64..<128 { (pixels + y * stride + 64 + bit * 80).update(repeating: color, count: 64) }
        }
        return image
    }

    private static func readPixelID(_ image: CVPixelBuffer) -> UInt64 {
        guard CVPixelBufferGetWidth(image) == 1280, CVPixelBufferGetHeight(image) == 720,
              CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA else { return .max }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(image)
        var result: UInt64 = 0
        for bit in 0..<8 {
            let gray = bytes[96 * stride + (96 + bit * 80) * 4]
            if gray > 128 { result |= 1 << bit }
        }
        return result
    }
}
