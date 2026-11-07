import AppKit
import CoreMedia
import VideoToolbox
import CoreImage
import RemoteCore
import RemoteMedia

/// A user-triggered live test. It exercises the real host session and a loopback
/// viewer, and sends one A key only while our dedicated test view owns focus.
@MainActor
final class LocalDiagnostic: NSObject, NSWindowDelegate {
    private weak var model: AppModel?
    private var peer: (any RemotePeer)?
    private var decoder: VTDecompressionSession?
    private var handshake: PairingHandshake?
    private var expectedGeneration: UInt64 = 0
    private var window: NSWindow?
    private let inputView = DiagnosticInputView(frame: NSRect(x: 0, y: 0, width: 580, height: 260))
    private var finished = false
    private var decoding = false
    private var sentInput = false
    private var originalAddress = ""
    private var originalMode: AppModel.ConnectionMode = .local
    private let internet: Bool
    private let lockProbe: Bool
    private var timeout: DispatchWorkItem?

    init(model: AppModel, internet: Bool = false, lockProbe: Bool = false) { self.model = model; self.internet = internet; self.lockProbe = lockProbe; super.init() }

    var ownsFocus: Bool {
        NSApp.isActive && NSApp.keyWindow === window && window?.firstResponder === inputView
    }

    func run() {
        guard let model else { return }
        originalAddress = model.address
        originalMode = model.connectionMode
        model.connectionMode = internet ? .internet : .local
        let window = NSWindow(contentRect: inputView.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = lockProbe ? "FarReach · Lock-screen capture check" : "FarReach · Local live test"
        inputView.lockProbe = lockProbe
        window.contentView = inputView
        window.delegate = self
        window.isReleasedWhenClosed = false
        self.window = window
        inputView.onKey = { [weak self] key, down in
            guard let self, self.sentInput, key == 0, !down else { return }
            self.finish(self.internet ? "Passed: live screen and keyboard input crossed a direct encrypted UDP connection between two local engines. No STUN or relay was used for this local check." : "Passed: live screen captured, encrypted, decoded, and keyboard input received in this test window.")
        }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(inputView)
        model.address = "127.0.0.1"
        model.startHosting()
        guard model.isHosting else { finish(nil, error: model.error ?? "Hosting could not start."); return }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.finish(nil, error: self.lockProbe ? "No fresh screen was captured during the locked-screen check. Unlock locally; this build cannot claim lock-screen access from this result." : "The live check timed out. Check Screen Recording and Accessibility, then quit and reopen FarReach.")
        }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + (lockProbe ? 27 : 20), execute: timeout)
        Task {
            for _ in 0..<50 {
                if finished { return }
                if !model.invitation.isEmpty { connect(model.invitation); return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            finish(nil, error: "The local listener did not become ready.")
        }
    }

    private func connect(_ string: String) {
        do {
            let peer: any RemotePeer
            if internet {
                let rtc = try WebRTCPeer(role: .viewer(invitation: string), stunURLs: [])
                rtc.onResponse = { [weak self] response in
                    guard let self, !self.finished, let model = self.model else { return }
                    model.pastedResponse = response
                    model.finishInternetPairing()
                }
                peer = rtc
            } else {
                let invite = try PairingInvitation(string: string)
                peer = try SecurePeer(host: invite.host, port: invite.port, key: invite.key)
            }
            self.peer = peer
            peer.onReady = { [weak self, weak peer] in
                guard let self, let peer else { return }
                do {
                    guard let binding = peer.channelBinding else { throw RemoteProtocolError.securityNegotiationFailed }
                    let handshake = try PairingHandshake(identity: DeviceIdentity(), localName: "FarReach local test", role: .viewer, channelBinding: binding)
                    self.handshake = handshake
                    handshake.onSend = { [weak peer] message in _ = peer?.send(message) }
                    handshake.onAuthenticated = { [weak self, weak peer] _ in
                        guard let self else { return }
                        peer?.setMediaAuthorization(true, generation: 0)
                        if self.lockProbe {
                            // The owner locks the Mac manually. No lock/unlock command
                            // or password is generated by this diagnostic.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self, weak peer] in
                                guard let self, !self.finished else { return }
                                for action in [SessionControl.Action.wake, .resume] {
                                    if let data = try? JSONEncoder().encode(SessionControl(action)) { _ = peer?.send(WireMessage(kind: .sessionControl, payload: data)) }
                                }
                            }
                        } else if let data = try? JSONEncoder().encode(SessionControl(.resume)) { _ = peer?.send(WireMessage(kind: .sessionControl, payload: data)) }
                    }
                    handshake.onFailure = { [weak self] error in self?.finish(nil, error: error.localizedDescription) }
                    handshake.start()
                } catch { self.finish(nil, error: error.localizedDescription) }
            }
            peer.onMessage = { [weak self, weak peer] message in
                guard let self, !self.finished, let peer else { return }
                switch message.kind {
                case .pairing: self.handshake?.receive(message.payload)
                case .streamState:
                    if let state = try? JSONDecoder().decode(StreamState.self, from: message.payload), state.state == .available {
                        self.expectedGeneration = state.generation
                        peer.setMediaAuthorization(true, generation: state.generation)
                        _ = peer.send(WireMessage(kind: .requestKeyframe, payload: Data()))
                    }
                case .video:
                    if let envelope = try? StreamFrameEnvelope(data: message.payload), envelope.generation == self.expectedGeneration, !self.decoding { self.decode(envelope.frame) }
                case .ping: _ = peer.send(WireMessage(kind: .pong, payload: message.payload))
                default: break
                }
            }
            peer.onClose = { [weak self] error in
                guard let self, !self.finished else { return }
                self.finish(nil, error: error?.localizedDescription ?? "The local connection closed before the check finished.")
            }
            peer.start()
        } catch { finish(nil, error: error.localizedDescription) }
    }

    private func decode(_ bytes: Data) {
        do {
            let frame = try EncodedFrame(data: bytes)
            guard frame.isKeyframe else { return }
            let format = try RemoteDesktopView.makeFormat(frame)
            let sample = try RemoteDesktopView.makeSample(frame, format: format)
            let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &decoder)
            guard status == noErr, let decoder else { throw MediaError.codec("Creating local decoder", status) }
            decoding = true
            let code = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
                let success = status == noErr && image != nil
                let preview: CGImage?
                if let self, self.lockProbe, let image {
                    let ci = CIImage(cvPixelBuffer: image)
                    preview = CIContext().createCGImage(ci, from: ci.extent)
                } else { preview = nil }
                DispatchQueue.main.async {
                    guard let self, !self.finished else { return }
                    if success && self.lockProbe {
                        if let preview { self.model?.lockProbeImage = NSImage(cgImage: preview, size: .zero) }
                        self.finish("A fresh screen was captured after the delayed wake/resume request. Inspect the preview to confirm whether macOS exposed its lock screen. No password or test key was entered.")
                    } else if success { self.testInput() }
                    else { self.finish(nil, error: "The captured screen could not be decoded (\(status)).") }
                }
            }
            guard code == noErr else { throw MediaError.codec("Decoding local screen", code) }
        } catch { finish(nil, error: error.localizedDescription) }
    }

    private func testInput() {
        guard !sentInput, !finished else { return }
        guard ownsFocus else { finish(nil, error: "The test window lost focus. No keyboard test was sent; run it again with that window active."); return }
        sentInput = true
        do {
            for kind in [RemoteInput.Kind.keyDown, .keyUp] {
                let bytes = try JSONEncoder().encode(RemoteInput(kind: kind, keyCode: 0))
                guard peer?.send(WireMessage(kind: .input, payload: bytes)) == true else { throw RemoteProtocolError.connectionClosed }
            }
        } catch { finish(nil, error: error.localizedDescription) }
    }

    func cancel() { finish(nil, error: "Local check cancelled.") }
    func windowWillClose(_ notification: Notification) { if !finished { cancel() } }

    private func finish(_ result: String?, error: String? = nil) {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        handshake?.cancel(); handshake = nil
        peer?.onClose = nil
        peer?.close(); peer = nil
        if let decoder { VTDecompressionSessionInvalidate(decoder) }; decoder = nil
        model?.stopHosting()
        model?.address = originalAddress
        model?.connectionMode = originalMode
        model?.diagnosticResult = result ?? error
        model?.diagnosticRunning = false
        if result == nil { model?.error = error }
        window?.delegate = nil
        window?.close(); window = nil
    }
}

private final class DiagnosticInputView: NSView {
    var lockProbe = false
    var onKey: ((UInt16, Bool) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event.keyCode, true) }
    override func keyUp(with event: NSEvent) { onKey?(event.keyCode, false) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let title = lockProbe ? "Lock this Mac now" : "Testing your local connection…"
        title.draw(in: NSRect(x: 30, y: 145, width: bounds.width - 60, height: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 23, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
        let detail = lockProbe ? "Press Control–Command–Q. Leave the Mac locked for 30 seconds,\nthen unlock it locally. FarReach will attempt a fresh capture\nafter 12 seconds. It will not type or save your password." : "Keep this window active. FarReach will capture a frame,\nsend it through an encrypted local connection,\nand send one test key to this window."
        detail.draw(in: NSRect(x: 30, y: 55, width: bounds.width - 60, height: 80), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
    }
}
