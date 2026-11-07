import XCTest
import AppKit
import Combine
import CoreMedia
import CoreVideo
import CoreText
import ScreenCaptureKit
@testable import FarReach
import RemoteCore
@testable import RemoteMedia

/// Continuous generated capture buffers exercise the production encode/admission,
/// IPC, RTP, decode and AppModel presentation paths. No real screen is captured
/// and no input, display wake, Keychain, STUN or cloud connection is used.
final class ContinuousStreamTests: XCTestCase {
    @MainActor
    func testContinuous720p30PredictiveStreamThroughProductionMailboxes() async throws {
        try await runStream(detailed: false)
    }

    @MainActor
    func testContinuousDetailedTextWithAutomaticQualityAndLocalMediaCredits() async throws {
        try await runStream(detailed: true)
    }

    @MainActor private func runStream(detailed: Bool) async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = ProcessInfo.processInfo.environment["FARREACH_NETWORK_HELPER"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent(".build/testing/FarReachNetwork")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw XCTSkip("Build a v2 networking helper or set FARREACH_NETWORK_HELPER.") }
        let model = AppModel(networkHelperURL: helper, pairingStore: InMemoryPairingStore())
        model.stunServer = ""
        let finished = expectation(description: "180 continuous captures submitted and drained")
        let source = try ContinuousNativeSource(helper: helper, frames: 180, detailed: detailed, completed: { finished.fulfill() })
        var displayed = 0
        let oldEnqueue = model.desktop.onFrameEnqueued
        model.desktop.onFrameEnqueued = { oldEnqueue?(); displayed += 1 }
        source.host.onInvitation = { invitation in model.pastedInvitation = invitation; model.connect() }
        let response = model.$connectionResponse.sink { value in
            guard !value.isEmpty else { return }
            do { try source.host.applyResponse(value) } catch { XCTFail("Continuous response failed: \(error)") }
        }
        defer { response.cancel(); source.close(); model.shutdown() }
        source.host.start()
        await fulfillment(of: [finished], timeout: 25)
        let counts = source.snapshot()
        XCTAssertNil(counts.failure)
        XCTAssertNil(model.error)
        XCTAssertEqual(counts.captured, 180)
        XCTAssertGreaterThanOrEqual(counts.encoded, detailed ? 90 : 160, "The native capture/encoder path must make sustained progress")
        XCTAssertGreaterThanOrEqual(counts.delta, detailed ? 75 : 145, "This must exercise a continuous reference chain, not isolated IDRs")
        XCTAssertGreaterThanOrEqual(displayed, detailed ? 90 : 145, "A healthy loopback path must not collapse into repeated recovery frames")
        XCTAssertGreaterThan(model.desktop.frameSize.width, 0)
        if detailed { XCTAssertGreaterThan(counts.adaptiveUpdates, 0) }
        XCTAssertEqual(counts.sendRejected, 0, "Local credits and the encoder callback latch must prevent reference drops")
        print("CONTINUOUS_NATIVE workload=\(detailed ? "text-scroll-auto" : "simple-motion") adaptiveUpdates=\(counts.adaptiveUpdates) finalConfig=\(counts.configuration) captured=\(counts.captured) encoded=\(counts.encoded) delta=\(counts.delta) keyframes=\(counts.keyframes) sent=\(counts.sent) sendRejected=\(counts.sendRejected) helperDrops=\(counts.helperDrops) IDRrequests=\(counts.requests) presented=\(displayed) sourceFPS=30 initialResolution=\(detailed ? "1280x800" : "1280x720") duration=6s; generated buffers, actual FrameEncodingPipeline/Swift IPC/Go RTP/AppModel native decode; no real capture, WAN or physical scanout")
    }
}

private final class ContinuousNativeSource {
    struct Counts {
        var captured = 0, encoded = 0, delta = 0, keyframes = 0, sent = 0, sendRejected = 0, helperDrops = 0, requests = 0
        var adaptiveUpdates = 0
        var configuration = "1280px/30fps/2000000bps"
        var failure: String?
    }
    let host: WebRTCPeer
    private let identity = DeviceIdentity()
    private var handshake: PairingHandshake?
    private var authenticated = false
    private var started = false
    private var closed = false
    private var generation: UInt64 = 0
    private let detailed: Bool
    private var adaptive = AdaptiveStreamController()
    private var previousTransport: TransportStatistics?
    private let frameLimit: Int
    private let completed: () -> Void
    private let lock = NSLock()
    private var counts = Counts()
    private let mailbox = MediaSessionMailbox()
    private let captureQueue = DispatchQueue(label: "FarReach.test.continuous.capture", qos: .userInteractive)
    // Queue-owned generated capture state.
    private var pipeline: CaptureAvailabilityPipeline?
    private var configuration = StreamConfiguration.automaticInitial
    private var width = 1280, height = 720
    private var timer: DispatchSourceTimer?
    private var index = 0

    init(helper: URL, frames: Int, detailed: Bool, completed: @escaping () -> Void) throws {
        self.frameLimit = frames; self.completed = completed; self.detailed = detailed
        if detailed { height = 800 }
        host = try WebRTCPeer(role: .host, stunURLs: [], helperURL: helper)
        host.onStatistics = { [weak self] statistics in self?.adapt(statistics) }
        host.onReady = { [weak self] in self?.authenticate() }
        host.onMessage = { [weak self] message in self?.receive(message) }
        host.onVideoDropped = { [weak self] in
            guard let self else { return }
            self.record { $0.helperDrops += 1 }
            self.mailbox.requireKeyframe()
            self.requestKeyframe()
        }
        host.onClose = { [weak self] error in
            guard let self, !self.closed else { return }
            self.record { $0.failure = error?.localizedDescription ?? "Transport closed during stream" }
        }
    }
    func snapshot() -> Counts { lock.lock(); defer { lock.unlock() }; return counts }
    private func record(_ change: (inout Counts) -> Void) { lock.lock(); change(&counts); lock.unlock() }
    private func authenticate() {
        do {
            let handshake = try PairingHandshake(identity: identity, localName: "Continuous synthetic host", role: .host,
                channelBinding: XCTUnwrap(host.channelBinding))
            self.handshake = handshake
            handshake.onSend = { [weak self] message in _ = self?.host.send(message) }
            handshake.onAuthenticated = { [weak self] _ in
                self?.authenticated = true
                self?.host.setMediaAuthorization(true, generation: 0)
            }
            handshake.onFailure = { [weak self] error in self?.record { $0.failure = error.localizedDescription } }
            handshake.start()
        } catch { record { $0.failure = error.localizedDescription } }
    }
    private func receive(_ message: WireMessage) {
        if message.kind == .pairing { handshake?.receive(message.payload); return }
        if message.kind == .ping { _ = host.send(WireMessage(kind: .pong, payload: message.payload)); return }
        if message.kind == .requestKeyframe { requestKeyframe(); return }
        guard authenticated, message.kind == .sessionControl,
              let command = try? JSONDecoder().decode(SessionControl.self, from: message.payload) else { return }
        if command.action == .resume {
            guard !started else { requestKeyframe(); return }
            started = true
            captureQueue.async { [weak self] in self?.beginCaptures() }
        }
        // Wake and input are deliberately never applied by this synthetic host.
    }
    private func requestKeyframe() {
        record { $0.requests += 1 }
        captureQueue.async { [weak self] in self?.pipeline?.requestKeyframe() }
    }
    private func adapt(_ statistics: TransportStatistics) {
        defer { previousTransport = statistics }
        guard detailed, started else { return }
        let feedback = StreamFeedback(availableBitrate: statistics.targetBitrate,
            rttMilliseconds: statistics.rttMS, sendQueueMilliseconds: TransportPressure.feedbackQueueMS(statistics,
                previous: previousTransport, usesMediaCredits: host.usesMediaCredits))
        guard let next = adaptive.update(feedback, now: ProcessInfo.processInfo.systemUptime) else { return }
        captureQueue.async { [weak self] in
            guard let self, let pipeline = self.pipeline, self.index < self.frameLimit else { return }
            let width = next.maxDimension / 2 * 2
            let height = Int(Double(width) * 800 / 1280) / 2 * 2
            do {
                try pipeline.updateConfiguration(next, width: width, height: height)
                self.configuration = next; self.width = width; self.height = height
                self.record { $0.adaptiveUpdates += 1; $0.configuration = "\(next.maxDimension)px/\(next.framesPerSecond)fps/\(next.bitrate)bps" }
            } catch { self.record { $0.failure = error.localizedDescription } }
        }
    }
    private func beginCaptures() {
        pipeline = CaptureAvailabilityPipeline(width: width, height: height, configuration: configuration, queue: captureQueue,
            onFrame: { [weak self] frame, generation in
                guard let self else { return }
                self.record { $0.encoded += 1; if frame.isKeyframe { $0.keyframes += 1 } else { $0.delta += 1 } }
                do {
                    if try self.mailbox.send(frame, generation: generation, peer: self.host) { self.record { $0.sent += 1 } }
                    else { self.record { $0.sendRejected += 1 }; self.pipeline?.requestKeyframe() }
                } catch { self.record { $0.failure = error.localizedDescription } }
            }, onAvailability: { [weak self] available, generation in
                guard let self else { return }
                self.generation = generation
                self.mailbox.authorize(available ? generation : 0)
                self.host.setMediaAuthorization(available, generation: available ? generation : 0)
                if let bytes = try? JSONEncoder().encode(StreamState(available ? .available : .unavailable, generation: generation)) {
                    _ = self.host.send(WireMessage(kind: .streamState, payload: bytes))
                }
            }, onError: { [weak self] error in self?.record { $0.failure = error.localizedDescription } },
            canEncode: { [weak self] in self?.host.mediaCapacityAvailable == true })
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        self.timer = timer
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.captureNext() }
        timer.resume()
    }
    private func captureNext() {
        do {
            let pixels = try detailed ? Self.desktopImage(width: width, height: height, scroll: index) : Self.image(index: index)
            record { $0.captured += 1 }
            pipeline?.receive(status: .complete, image: pixels, presentationTime: CMClockGetTime(CMClockGetHostTimeClock()))
            index += 1
            if index == frameLimit {
                timer?.cancel(); timer = nil
                captureQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self else { return }
                    DispatchQueue.main.async(execute: self.completed)
                }
            }
        } catch { record { $0.failure = error.localizedDescription }; timer?.cancel(); timer = nil; DispatchQueue.main.async(execute: completed) }
    }
    func close() {
        closed = true
        captureQueue.sync { timer?.cancel(); timer = nil; pipeline?.stop(); pipeline = nil }
        handshake?.cancel(); host.onClose = nil; host.close()
    }
    private static func image(index: Int) throws -> CVPixelBuffer {
        var allocated: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &allocated)
        guard result == kCVReturnSuccess, let image = allocated else { throw MediaError.codec("Allocating generated capture", result) }
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        let stride = CVPixelBufferGetBytesPerRow(image)
        let pixels = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        memset(pixels, 80, stride * 720)
        for row in 0..<18 {
            for y in (20 + row * 34)..<(30 + row * 34) {
                memset(pixels.advanced(by: y * stride + 40 * 4), 180, (240 + (row % 4) * 80) * 4)
            }
        }
        let x = 600 + (index * 7 % 500), y = 50 + (index * 3 % 500)
        for line in y..<(y + 80) { memset(pixels.advanced(by: line * stride + x * 4), 240, 80 * 4) }
        return image
    }
    private static func desktopImage(width: Int, height: Int, scroll: Int) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result)
        guard status == kCVReturnSuccess, let image = result else { throw MediaError.codec("Allocating synthetic desktop", status) }
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        let bitmap = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(image), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(image), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap) else {
            throw MediaError.invalidFrame("Could not create synthetic desktop drawing context")
        }
        context.scaleBy(x: CGFloat(width) / 1280, y: CGFloat(height) / 800)
        context.setFillColor(CGColor(gray: 0.98, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1280, height: 800))
        context.setFillColor(CGColor(red: 0.12, green: 0.15, blue: 0.20, alpha: 1)); context.fill(CGRect(x: 0, y: 760, width: 1280, height: 40))
        context.setFillColor(CGColor(gray: 0.91, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 220, height: 760))
        let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
        func text(_ value: String, x: CGFloat, y: CGFloat, color: CGColor) {
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
            context.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, context)
        }
        text("Synthetic project / editor / local fixture — no captured user content", x: 18, y: 773, color: CGColor(gray: 1, alpha: 1))
        for row in 0..<37 {
            text(String(format: "%02d  source_%02d.swift", row, row), x: 14, y: CGFloat(738 - row * 19), color: CGColor(gray: 0.20, alpha: 1))
        }
        for row in 0..<52 {
            let number = row + scroll
            let value = String(format: "%04d  let sample_%03d = items.filter { $0.enabled && $0.rank > %d }.map { record in record.value + %d }", number, number % 997, number % 17, number * 7)
            text(value, x: 236, y: CGFloat(742 - row * 14), color: row % 5 == 0 ? CGColor(red: 0.08, green: 0.28, blue: 0.60, alpha: 1) : CGColor(gray: 0.16, alpha: 1))
        }
        context.setFillColor(CGColor(red: 0.95, green: 0.62, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 650 + scroll * 3 % 420, y: 390, width: 3, height: 22))
        return image
    }


}
