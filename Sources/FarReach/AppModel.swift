import AppKit
import SwiftUI
import CoreGraphics
import IOKit.pwr_mgt
import ServiceManagement
import RemoteCore
import RemoteMedia
import Network
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    enum Page: String, CaseIterable { case share = "Share this Mac", connect = "Connect to Mac", devices = "Paired Macs", setup = "Setup" }
    enum ConnectionMode: String, CaseIterable { case internet = "Direct Internet", local = "Local network" }
    enum Quality: String, CaseIterable {
        case automatic = "Auto · adapt to connection", efficient = "Efficient · 720p / 30 fps", balanced = "Balanced · 1080p / 30 fps", smooth = "Smooth · 1080p / 60 fps"
        var configuration: StreamConfiguration {
            switch self {
            case .automatic: return .automaticInitial
            case .efficient: return .init(maxDimension: 1280, framesPerSecond: 30, bitrate: 4_000_000)
            case .balanced: return .init()
            case .smooth: return .init(maxDimension: 1920, framesPerSecond: 60, bitrate: 12_000_000)
            }
        }
        var fps: Int { self == .smooth ? 60 : 30 }
    }
    @Published var connectionMode: ConnectionMode = .internet
    @Published var pastedResponse = ""
    @Published var connectionResponse = ""
    @Published var responseCopied = false
    @Published var connectionPath = ""
    @Published var stunServer = "stun:stun.cloudflare.com:3478"
    @Published var signalingURL = ""
    @Published var signalingStatus = "Cloud signaling is not configured"
    @Published var signalingReady = false
    @Published var cloudHosting = false
    private var signaling: CloudSignalingClient?
    private var signalAttempt: SignalAttempt?
    private var signalDeadline: DispatchWorkItem?
    private var hostExpectedPeerID: String?
    private var activeSignalSessionID: String?
    private var connectionIntent: (deviceID: String, viewing: Bool)?
    private var recoveryStarted: TimeInterval?
    private var recoveryAttempt = 0
    private var recoveryWork: DispatchWorkItem?
    private var recoveryDeadline: DispatchWorkItem?
    private var lossGrace: DispatchWorkItem?
    private var networkMonitor: NWPathMonitor?
    private var networkAvailable = true
    @Published private(set) var isRecovering = false
    private struct SignalAttempt {
        enum Phase { case waitingOffer, creatingOffer, waitingAnswer, connecting }
        let id: String
        let peerID: String
        var phase: Phase
    }
    @Published var networkCheckRunning = false
    @Published var networkCheckResult: String?
    private var routerInspector: RouterMapping?
    private var internetHost: WebRTCPeer?
    private let networkHelperURL: URL?
    private let pairingStore: any PairingStore
    private var localIdentity: DeviceIdentity?
    private var hostHandshake: PairingHandshake?
    private var viewerHandshake: PairingHandshake?
    private var hostDevice: PairedDevice?
    private var viewerDevice: PairedDevice?
    private var hostAuthDeadline: DispatchWorkItem?
    private var viewerAuthDeadline: DispatchWorkItem?
    private var captureGeneration: UInt64 = 1
    private var expectedGeneration: UInt64 = 0
    private var remoteStreamAvailable = false
    private var hostCaptureAvailable = false
    private var selectedExpectedPeerID: String?
    @Published var pairedDevices: [PairedDevice] = []
    @Published var canResumeViewing = false
    @Published var connectedDeviceID: String?
    @Published var streamUnavailable = false
    @Published var loginEnabled = false
    @Published var page: Page = .share
    @Published var quality: Quality = .automatic
    @Published var address = ""
    @Published var invitation = ""
    @Published var pastedInvitation = ""
    @Published var isHosting = false
    @Published var isConnecting = false
    @Published var isViewing = false
    @Published var hasViewer = false
    @Published var screenAllowed = false
    @Published var controlAllowed = false
    @Published var fullKeyboardControl = true
    @Published var keyboardCaptureStatus: RemoteKeyboardCaptureStatus = .inactive
    @Published var status = "Ready when you are"
    @Published var error: String?
    @Published var remoteName = "Remote Mac"
    @Published var fps = 0
    @Published var mbps = 0.0
    @Published var pingMS: Double?
    @Published var dropped = 0
    @Published private(set) var transportStatistics: TransportStatistics?
    @Published private(set) var remoteHostPerformance: HostPerformanceSnapshot?
    @Published private(set) var activeQualityDescription = ""
    private var performanceSamples: [PerformanceSample] = []
    private var metricsStarted = ProcessInfo.processInfo.systemUptime
    private var previousStatistics: TransportStatistics?
    private var lastEncodeMilliseconds: Double?
    private var lastPreparationMilliseconds: Double?
    private var lastHandoffMilliseconds: Double?
    private var lastFrameID: UInt64?
    private var pipelineStatistics: MediaPipelineStatistics?
    private var lastEnqueueTime: TimeInterval?
    private var enqueueGapEvents: UInt64 = 0
    private var longestEnqueueGapMS: Double = 0
    private var adaptiveStream = AdaptiveStreamController()
    private var activeStreamConfiguration = StreamConfiguration.automaticInitial
    private var updatingStream = false
    private var hostMediaMailbox = MediaSessionMailbox()
    private var viewerDecodedMailbox = LatestDecodedFrameMailbox()
    private var inputSequencer = InputSequencer()
    private var inputReceiver = InputReceiver()
    private var pointerTimer: Timer?
    @Published var copied = false
    @Published var diagnosticRunning = false
    @Published var diagnosticResult: String?
    @Published var lockProbeImage: NSImage?
    private var diagnostic: LocalDiagnostic?
    var preventsUpdateRestart: Bool {
        isHosting || isConnecting || isViewing || hasViewer || canResumeViewing || isRecovering || diagnosticRunning
    }
    private(set) var diagnosticUsesInternet = false
    let desktop = RemoteDesktopView(frame: .zero)
    private var listener: SecureListener?
    private var hostPeer: (any RemotePeer)?
    private var viewerPeer: (any RemotePeer)?
    private var streamer: ScreenStreamer?
    private var injector: InputInjector?
    private var sessionID = UUID()
    private var timer: Timer?
    private var lastTraffic = ProcessInfo.processInfo.systemUptime
    private var lastPing: Data?
    private var lastPingTime = ProcessInfo.processInfo.systemUptime
    private var lastPongReceived = ProcessInfo.processInfo.systemUptime
    private var frameCount = 0
    private var byteCount = 0
    private var awakeID: IOPMAssertionID = 0

    init(networkHelperURL: URL? = nil, pairingStore: any PairingStore = KeychainPairingStore()) {
        self.networkHelperURL = networkHelperURL
        self.pairingStore = pairingStore
        do { pairedDevices = try pairingStore.listDevices() }
        catch { self.error = "Saved device trust could not be loaded: \(error.localizedDescription)" }
        loginEnabled = SMAppService.mainApp.status == .enabled
        refreshPermissions()
        address = Self.addresses().first ?? ""
        desktop.onInput = { [weak self] input in
            _ = self?.sendViewerInput(input)
        }
        desktop.onCapturedKeyboardInput = { [weak self] input in self?.sendViewerInput(input) ?? false }
        desktop.onKeyboardCaptureStatus = { [weak self] status in self?.keyboardCaptureStatus = status }
        desktop.onDisconnect = { [weak self] in self?.endViewing() }
        desktop.onNeedsKeyframe = { [weak self] in
            _ = self?.viewerPeer?.send(WireMessage(kind: .requestKeyframe, payload: Data()))
        }
        desktop.onFrameEnqueued = { [weak self] in
            guard let self else { return }
            self.frameCount += 1
            let now = ProcessInfo.processInfo.systemUptime
            if let previous = self.lastEnqueueTime {
                let gap = (now - previous) * 1000
                self.longestEnqueueGapMS = max(self.longestEnqueueGapMS, gap)
                if gap > 250 { self.enqueueGapEvents += 1 }
            }
            self.lastEnqueueTime = now
        }
        pointerTimer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushPointer() }
        }
        if let pointerTimer { RunLoop.main.add(pointerTimer, forMode: .common) }
        // Test/diagnostic stores never open a persisted production connection.
        if pairingStore is KeychainPairingStore, networkHelperURL == nil {
            fullKeyboardControl = UserDefaults.standard.object(forKey: "FarReach.fullKeyboardControl") as? Bool ?? true
            desktop.systemShortcutsEnabled = fullKeyboardControl
            signalingURL = UserDefaults.standard.string(forKey: "FarReach.signalingURL")
                ?? Bundle.main.object(forInfoDictionaryKey: "FarReachSignalingURL") as? String ?? ""
            if !signalingURL.isEmpty { configureSignaling() }
            startNetworkMonitoring()
        }
    }

    private func sendViewerInput(_ input: RemoteInput) -> Bool {
        guard viewerDevice != nil, let peer = viewerPeer, input.isValid,
              ((isViewing && remoteStreamAvailable && !isRecovering) || input.kind == .releaseAll) else { return false }
        let events = inputSequencer.submit(input, now: ProcessInfo.processInfo.systemUptime)
        return events.reduce(true) { result, event in sendInput(event, peer: peer) && result }
    }

    private func sendInput(_ input: RemoteInput, peer: any RemotePeer) -> Bool {
        guard let data = try? JSONEncoder().encode(input) else { return false }
        return peer.send(WireMessage(kind: input.kind == .move && peer is WebRTCPeer ? .pointer : .input, payload: data))
    }
    private func flushPointer() {
        guard isViewing, remoteStreamAvailable, !isRecovering, let peer = viewerPeer else { return }
        for event in inputSequencer.flush(now: ProcessInfo.processInfo.systemUptime) { _ = sendInput(event, peer: peer) }
    }

    func setFullKeyboardControl(_ enabled: Bool) {
        fullKeyboardControl = enabled
        desktop.systemShortcutsEnabled = enabled
        if pairingStore is KeychainPairingStore {
            UserDefaults.standard.set(enabled, forKey: "FarReach.fullKeyboardControl")
        }
    }

    var keyboardControlDescription: String {
        switch keyboardCaptureStatus {
        case .disabled: return "System shortcuts stay on this Mac"
        case .inactive: return "Click the remote screen to give it keyboard focus"
        case .capturing: return "Keyboard controls the remote Mac · ⌃⌥Esc releases it"
        case .permissionRequired: return "Allow Accessibility on this Mac for full keyboard control"
        case .unavailable: return "Keyboard capture unavailable · check permissions and reopen FarReach"
        }
    }

    func saveSignalingSettings() {
        guard !isHosting, !isConnecting, !isViewing, viewerPeer == nil else { return }
        configureSignaling()
        if signaling != nil || signalingURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.set(signalingURL, forKey: "FarReach.signalingURL")
        }
    }

    func configureSignaling() {
        signaling?.stop(); signaling = nil; signalingReady = false
        signalingURL = signalingURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !signalingURL.isEmpty else { signalingStatus = "Cloud signaling is not configured"; return }
        do {
            guard let endpoint = URL(string: signalingURL) else { throw WebRTCTransportError.invalidConfiguration }
            let client = try CloudSignalingClient(identity: identity(), endpoint: endpoint, peers: pairedDevices)
            signaling = client
            client.onStatus = { [weak self, weak client] value in
                guard let self, let client, self.signaling === client else { return }
                self.signalingStatus = value; self.signalingReady = client.isReady
            }
            client.onReady = { [weak self, weak client] in
                guard let self, let client, self.signaling === client else { return }
                self.signalingReady = true
                if self.isRecovering { self.scheduleRecovery(after: 0) }
            }
            client.onSignal = { [weak self] from, message in self?.receiveSignal(from: from, message: message) }
            client.onError = { [weak self] message in self?.signalingStatus = message }
            client.onAttemptUnavailable = { [weak self] id, attemptID in
                guard let self, self.signalAttempt?.peerID == id, self.signalAttempt?.id == attemptID else { return }
                self.failSignalAttempt("The saved Mac is offline or has not enabled this pairing on the same signaling service.")
            }
            client.start()
        } catch { signalingStatus = error.localizedDescription; self.error = error.localizedDescription }
    }

    func startCloudHosting() {
        guard !isHosting, !isConnecting, !isViewing, viewerPeer == nil, !pairedDevices.isEmpty else { return }
        if signaling == nil { configureSignaling() }
        guard signaling != nil else { error = "Set a signaling service URL in Setup first."; return }
        refreshPermissions()
        guard screenAllowed else { error = "Allow Screen Recording before sharing."; page = .setup; return }
        error = nil; cloudHosting = true; isHosting = true; connectionMode = .internet
        sessionID = UUID(); invitation = ""; hostExpectedPeerID = nil
        status = "Available to paired Macs through cloud signaling"
        if awakeID == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "FarReach sharing is available" as CFString, &awakeID)
        }
    }

    func connectPairedDevice(_ device: PairedDevice) {
        guard !isHosting, !isConnecting, !isViewing, viewerPeer == nil,
              pairedDevices.contains(where: { $0.id == device.id }), let signaling, signaling.isReady else { return }
        connectionIntent = (device.id, true)
        beginPairedAttempt(device, signaling: signaling)
    }

    private func beginPairedAttempt(_ device: PairedDevice, signaling: CloudSignalingClient) {
        guard viewerPeer == nil, signalAttempt == nil, !isHosting else { return }
        error = nil; selectedExpectedPeerID = device.id; remoteName = device.name
        let attempt = SignalAttempt(id: UUID().uuidString, peerID: device.id, phase: .waitingOffer)
        signalAttempt = attempt; isConnecting = true; page = .connect
        status = "Contacting \(device.name)…"
        armSignalDeadline(attempt.id)
        if !signaling.send(CloudSignalMessage(kind: .request, attemptID: attempt.id), to: device.id) {
            failSignalAttempt("Cloud signaling is unavailable. Try again when it reconnects.")
        }
    }

    private func armSignalDeadline(_ id: String) {
        signalDeadline?.cancel()
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.signalAttempt?.id == id else { return }
            self.failSignalAttempt("Connection setup timed out. Check that the other Mac is sharing and both networks permit direct UDP.")
        }
        signalDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: deadline)
    }

    private func clearSignalAttempt(notify: Bool = false) {
        if let attempt = signalAttempt { signaling?.cancelAttempt(attempt.id) }
        if notify, let attempt = signalAttempt {
            signaling?.send(CloudSignalMessage(kind: .cancel, attemptID: attempt.id), to: attempt.peerID)
        }
        signalDeadline?.cancel(); signalDeadline = nil; signalAttempt = nil
    }

    private func failSignalAttempt(_ message: String) {
        if cloudHosting { resetCloudHostSession() }
        else if connectionIntent != nil, isRecovering { retireViewerTransport(); scheduleRecovery() }
        else { disconnect() }
        error = message
    }

    private func resetCloudHostSession() {
        clearSignalAttempt(notify: true)
        sessionID = UUID()
        internetHost?.onClose = nil; internetHost?.close(); internetHost = nil
        endHostSession(); hostExpectedPeerID = nil
        activeSignalSessionID = nil
        invitation = ""; pastedResponse = ""; connectionPath = ""
        timer?.invalidate(); timer = nil
        status = "Available to paired Macs through cloud signaling"
    }

    // All signaling is decrypted and identity-checked by CloudSignalingClient.
    // App state independently checks trust, the user-enabled host role, attempt,
    // and phase before it creates or changes a desktop transport.
    func receiveSignal(from: String, message: CloudSignalMessage) {
        guard pairedDevices.contains(where: { $0.id == from }),
              message.expiresAt > Date().timeIntervalSince1970,
              message.expiresAt <= Date().timeIntervalSince1970 + 120 else { return }
        if message.kind == .close {
            guard cloudHosting, hostDevice?.id == from, message.sessionID == activeSignalSessionID else { return }
            let oldSession = activeSignalSessionID
            resetCloudHostSession()
            signaling?.send(.init(kind: .closed, attemptID: message.attemptID, sessionID: oldSession), to: from)
            return
        }
        if message.kind == .closed { return }
        if message.kind == .request {
            guard cloudHosting, isHosting, hostPeer == nil, internetHost == nil, signalAttempt == nil else {
                let retryable = cloudHosting && isHosting && (hostDevice?.id == from || hostExpectedPeerID == from)
                signaling?.send(CloudSignalMessage(kind: retryable ? .busy : .reject, attemptID: message.attemptID), to: from)
                return
            }
            let attempt = SignalAttempt(id: message.attemptID, peerID: from, phase: .creatingOffer)
            signalAttempt = attempt; hostExpectedPeerID = from
            armSignalDeadline(attempt.id)
            startInternetHosting()
            return
        }
        guard let attempt = signalAttempt, attempt.id == message.attemptID, attempt.peerID == from else { return }
        if message.requiresTransportUpdate {
            let expectedOffer = message.kind == .offer && !isHosting && attempt.phase == .waitingOffer && viewerPeer == nil
            let expectedAnswer = message.kind == .answer && cloudHosting && attempt.phase == .waitingAnswer
            guard expectedOffer || expectedAnswer else { return }
            if cloudHosting { resetCloudHostSession() } else { disconnect() }
            error = WebRTCTransportError.incompatibleVersion.localizedDescription
            return
        }
        switch message.kind {
        case .offer:
            guard !isHosting, attempt.phase == .waitingOffer, viewerPeer == nil,
                  let offer = message.body, offer.hasPrefix("farreach-offer://v2/") else { return }
            signalAttempt?.phase = .connecting
            startViewerConnection(offer)
        case .answer:
            guard cloudHosting, attempt.phase == .waitingAnswer, let answer = message.body else { return }
            do {
                guard let internetHost else { return }
                signalAttempt?.phase = .connecting
                try internetHost.applyResponse(answer)
                status = "Checking the direct path between your Macs…"
            } catch { failSignalAttempt(error.localizedDescription) }
        case .reject:
            disconnect()
            error = "The other Mac is not available for a new connection. Enable sharing there and try again."
        case .cancel: failSignalAttempt("The other Mac cancelled connection setup.")
        case .busy:
            beginRecovery()
            retireViewerTransport()
            scheduleRecovery()
        case .request, .close, .closed: break
        }
    }

    private func startNetworkMonitoring() {
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                let restored = !self.networkAvailable && available
                self.networkAvailable = available
                if restored {
                    self.signaling?.networkBecameAvailable()
                    if self.isRecovering { self.scheduleRecovery(after: 0) }
                } else if !available, self.viewerPeer != nil { self.noteConnectionState(.recovering) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "FarReach.network.path"))
    }

    private func beginRecovery() {
        guard connectionIntent != nil else { return }
        if recoveryStarted == nil {
            recoveryStarted = ProcessInfo.processInfo.systemUptime
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isRecovering else { return }
                self.disconnect()
                self.error = "The direct path did not recover within 60 seconds. Check both networks and connect again."
            }
            recoveryDeadline = work
            DispatchQueue.main.asyncAfter(deadline: .now() + RecoveryPolicy.budget, execute: work)
        }
        isRecovering = true; isConnecting = true
        desktop.releaseInput(); desktop.inputEnabled = false
        desktop.clear(); viewerDecodedMailbox.authorize(0)
        viewerPeer?.setMediaAuthorization(false, generation: 0)
        remoteStreamAvailable = false; streamUnavailable = true
        status = "Connection interrupted · recovering the direct path…"
    }

    func noteConnectionState(_ state: PeerConnectionState) {
        guard connectionIntent != nil else { return }
        switch state {
        case .recovering:
            beginRecovery()
            guard lossGrace == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isRecovering else { return }
                self.lossGrace = nil
                self.retireViewerTransport()
                self.scheduleRecovery(after: 0)
            }
            lossGrace = work
            DispatchQueue.main.asyncAfter(deadline: .now() + RecoveryPolicy.grace, execute: work)
        case .connected:
            guard lossGrace != nil, viewerDevice != nil else { return }
            cancelRecovery()
            if connectionIntent?.viewing == true { resumeViewing() }
            else { canResumeViewing = true; isConnecting = false }
        case .closed: break // onClose owns teardown and retry.
        }
    }

    private func cancelRecovery() {
        recoveryWork?.cancel(); recoveryWork = nil
        recoveryDeadline?.cancel(); recoveryDeadline = nil
        lossGrace?.cancel(); lossGrace = nil
        recoveryStarted = nil; recoveryAttempt = 0; isRecovering = false
    }

    private func scheduleRecovery(after explicitDelay: TimeInterval? = nil) {
        guard isRecovering, let intent = connectionIntent, !isHosting else { return }
        guard let started = recoveryStarted, RecoveryPolicy.permitsRetry(started: started, now: ProcessInfo.processInfo.systemUptime) else {
            disconnect(); error = "Connection recovery timed out. Connect again when both networks are available."; return
        }
        recoveryWork?.cancel()
        let delay = explicitDelay ?? RecoveryPolicy.retryDelay(attempt: recoveryAttempt)
        recoveryAttempt += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRecovering, self.connectionIntent?.deviceID == intent.deviceID else { return }
            self.recoveryWork = nil
            guard self.networkAvailable, let signaling = self.signaling, signaling.isReady else { self.scheduleRecovery(); return }
            guard self.viewerPeer == nil, self.signalAttempt == nil,
                  let device = self.pairedDevices.first(where: { $0.id == intent.deviceID }) else { return }
            self.beginPairedAttempt(device, signaling: signaling)
        }
        recoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func refreshPermissions() {
        let previousControlPermission = controlAllowed
        screenAllowed = CGPreflightScreenCaptureAccess()
        controlAllowed = InputInjector.accessibilityGranted
        if previousControlPermission != controlAllowed { desktop.refreshKeyboardCapture() }
    }
    func requestScreenPermission() {
        _ = CGRequestScreenCaptureAccess()
        openPrivacy("Privacy_ScreenCapture")
        refreshPermissions()
    }
    func requestControlPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacy("Privacy_Accessibility")
        refreshPermissions()
    }
    private func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor) { NSWorkspace.shared.open(url) }
    }

    func runLocalDiagnostic(internet: Bool = false, lockProbe: Bool = false) {
        guard !isHosting, !isViewing, !isConnecting, !diagnosticRunning, viewerPeer == nil else { return }
        refreshPermissions()
        guard screenAllowed, controlAllowed else { error = "Allow Screen Recording and Accessibility before running the local live check."; return }
        error = nil
        diagnosticResult = nil
        lockProbeImage = nil
        diagnosticRunning = true
        diagnosticUsesInternet = internet
        let check = LocalDiagnostic(model: self, internet: internet, lockProbe: lockProbe)
        diagnostic = check
        check.run()
    }

    func startHosting() {
        guard !isHosting, !isConnecting, !isViewing, viewerPeer == nil else { return }
        error = nil
        refreshPermissions()
        guard screenAllowed else {
            error = "Allow Screen Recording first, then quit and reopen FarReach if macOS asks."
            page = .setup
            return
        }
        if connectionMode == .internet && (!diagnosticRunning || diagnosticUsesInternet) {
            startInternetHosting()
            return
        }
        do {
            let key = try PairingInvitation.generateKey()
            // Parse before opening a listener, so a missing address cannot leave hosting armed.
            _ = try PairingInvitation(host: address.trimmingCharacters(in: .whitespacesAndNewlines), port: 9877, key: key)
            let server = try SecureListener(key: key, port: 9877)
            listener = server
            isHosting = true
            sessionID = UUID()
            let id = sessionID
            status = "Starting secure listener…"
            server.onReady = { [weak self] port in
                guard let self, self.sessionID == id, self.isHosting else { return }
                do {
                    self.invitation = try PairingInvitation(host: self.address.trimmingCharacters(in: .whitespacesAndNewlines), port: port, key: key).urlString
                    self.status = "Waiting for your other Mac"
                } catch { self.stopHosting(); self.error = error.localizedDescription }
            }
            server.onConnection = { [weak self] peer in self?.accept(peer, session: id) }
            server.onError = { [weak self] error in
                guard let self, self.sessionID == id else { return }
                self.stopHosting()
                self.error = error.localizedDescription
            }
            server.start()
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "FarReach sharing is active" as CFString, &awakeID)
            startMetrics()
        } catch { self.error = error.localizedDescription }
    }


    private func configuredSTUN() -> [String] {
        if diagnosticRunning { return [] }
        let server = stunServer.trimmingCharacters(in: .whitespacesAndNewlines)
        return server.isEmpty ? [] : [server]
    }

    private func startInternetHosting() {
        do {
            let peer = try WebRTCPeer(role: .host, stunURLs: configuredSTUN(), helperURL: networkHelperURL)
            internetHost = peer
            sessionID = UUID()
            let id = sessionID
            isHosting = true
            invitation = ""
            pastedResponse = ""
            connectionPath = ""
            status = "Discovering direct connection addresses…"
            peer.onInvitation = { [weak self, weak peer] invite in
                guard let self, let peer, self.internetHost === peer, self.sessionID == id else { return }
                if self.cloudHosting {
                    guard let attempt = self.signalAttempt, attempt.phase == .creatingOffer else { return }
                    self.signalAttempt?.phase = .waitingAnswer
                    guard self.signaling?.send(CloudSignalMessage(kind: .offer, attemptID: attempt.id, body: invite), to: attempt.peerID) == true else {
                        self.failSignalAttempt("Cloud signaling disconnected during setup. Try connecting again."); return
                    }
                    self.status = "Waiting for the paired Mac’s connection response…"
                    return
                }
                self.invitation = invite
                self.status = "Invitation ready · waiting for the other Mac’s response"
            }
            peer.onPath = { [weak self, weak peer] path in
                guard let self, let peer, self.internetHost === peer, self.sessionID == id else { return }
                self.connectionPath = Self.describePath(path)
            }
            peer.onVideoDropped = { [weak self, weak peer] in
                guard let self, let peer, self.internetHost === peer, self.sessionID == id else { return }
                self.hostMediaMailbox.requireKeyframe()
                self.streamer?.requestKeyframe()
            }
            peer.onReady = { [weak self, weak peer] in
                guard let self, let peer, self.sessionID == id else { return }
                self.startMetrics()
                self.accept(peer, session: id)
            }
            peer.onClose = { [weak self] err in
                guard let self, self.sessionID == id else { return }
                if self.cloudHosting {
                    self.resetCloudHostSession(); self.error = err?.localizedDescription; return
                }
                self.stopHosting()
                self.error = err?.localizedDescription
                self.status = "Direct connection ended · no relay was used"
            }
            peer.start()
            if awakeID == 0 {
                IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn), "FarReach direct sharing is active" as CFString, &awakeID)
            }
        } catch {
            if cloudHosting { failSignalAttempt(error.localizedDescription) }
            else { self.error = error.localizedDescription }
        }
    }

    func finishInternetPairing() {
        guard let internetHost, !hasViewer else { return }
        do {
            try internetHost.applyResponse(pastedResponse.trimmingCharacters(in: .whitespacesAndNewlines))
            pastedResponse = ""
            status = "Checking the direct path between your Macs…"
        } catch { self.error = error.localizedDescription }
    }

    func copyResponse() {
        guard !connectionResponse.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(connectionResponse, forType: .string)
        responseCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.responseCopied = false }
    }

    private func clearResponse() {
        if !connectionResponse.isEmpty, NSPasteboard.general.string(forType: .string) == connectionResponse { NSPasteboard.general.clearContents() }
        connectionResponse = ""
        responseCopied = false
    }

    static func describePath(_ value: String) -> String {
        // The helper never admits a relay. Do not expose peer IPs in the status bar.
        if let data = value.data(using: .utf8), let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let local = fields["localType"] as? String, let remote = fields["remoteType"] as? String {
            return "Direct UDP · \(local) ↔ \(remote)"
        }
        return "Direct UDP · no relay"
    }

    func inspectNetwork() {
        guard !networkCheckRunning else { return }
        networkCheckRunning = true
        let local = DirectNetworkSnapshot.localAddresses()
        let globals = local.filter(\.isInternetRoutable)
        let localSummary = globals.isEmpty
            ? "No public address is assigned to this Mac. This does not rule out direct UDP hole punching."
            : "Public address candidates: " + globals.map(\.address).joined(separator: ", ") + ". Firewall access is still unverified."
        networkCheckResult = localSummary + " Checking the router without changing it…"
        let probe = RouterMapping()
        routerInspector = probe
        probe.onChange = { [weak self, weak probe] result in
            guard let self, let probe, self.routerInspector === probe else { return }
            self.networkCheckResult = localSummary + " " + result.message + " No router ports were opened."
            self.networkCheckRunning = false
        }
        probe.inspect()
    }

    private func identity() throws -> DeviceIdentity {
        if let localIdentity { return localIdentity }
        let identity = try pairingStore.loadOrCreateIdentity()
        localIdentity = identity
        return identity
    }

    private func remember(_ device: PairedDevice) throws {
        guard !diagnosticRunning else { return }
        try pairingStore.save(device)
        pairedDevices = try pairingStore.listDevices()
        signaling?.updatePeers(pairedDevices)
    }

    private func accept(_ peer: any RemotePeer, session id: UUID) {
        guard isHosting, sessionID == id, hostPeer == nil else { peer.close(); return }
        hostPeer = peer
        hasViewer = false
        hostDevice = nil
        inputReceiver.reset()
        peer.onStatistics = { [weak self, weak peer] statistics in
            guard let self, let peer, self.hostPeer === peer else { return }
            self.receiveStatistics(statistics, host: true)
        }
        peer.onConnectionState = { [weak self, weak peer] state in
            guard let self, let peer, self.hostPeer === peer else { return }
            if state == .recovering { self.injector?.releaseAll() }
        }
        lastTraffic = ProcessInfo.processInfo.systemUptime
        status = "Verifying the other Mac’s identity…"
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer, self.hostPeer === peer else { return }
            self.lastTraffic = ProcessInfo.processInfo.systemUptime
            switch message.kind {
            case .pairing: self.hostHandshake?.receive(message.payload)
            case .input, .pointer:
                guard self.hostDevice != nil, self.hasViewer, self.controlAllowed,
                      let event = try? JSONDecoder().decode(RemoteInput.self, from: message.payload) else { return }
                guard self.hostCaptureAvailable || event.kind == .releaseAll else { return }
                if self.diagnosticRunning && self.diagnostic?.ownsFocus != true { self.diagnostic?.cancel(); return }
                if message.kind == .pointer && event.kind != .move { return }
                for ordered in self.inputReceiver.receive(event) { self.injector?.apply(ordered) }
            case .sessionControl:
                guard self.hostDevice != nil,
                      let command = try? JSONDecoder().decode(SessionControl.self, from: message.payload) else { peer.close(); return }
                switch command.action {
                case .resume:
                    if self.streamer != nil, self.hostCaptureAvailable {
                        peer.setMediaAuthorization(true, generation: self.captureGeneration)
                        self.sendStreamState(.available, generation: self.captureGeneration)
                        self.streamer?.requestKeyframe()
                    } else { self.startCapture(for: peer, session: id) }
                case .pause: self.pauseHostCapture()
                case .wake:
                    _ = InputInjector.wakeDisplay()
                    self.sendStreamState(.wakeRequested, generation: self.captureGeneration)
                }
            case .ping: _ = peer.send(WireMessage(kind: .pong, payload: message.payload))
            case .pong: self.recordPong(message.payload)
            case .requestKeyframe:
                if self.hostDevice != nil { self.streamer?.requestKeyframe() }
            case .disconnect: peer.close()
            default: break
            }
        }
        peer.onClose = { [weak self, weak peer] err in
            guard let self, let peer, self.hostPeer === peer else { return }
            if self.internetHost != nil {
                if self.cloudHosting { self.resetCloudHostSession() }
                else {
                    self.stopHosting()
                    self.status = "Device trust is saved · new connection setup is needed"
                }
            } else {
                self.endHostSession()
                self.status = "Waiting for your other Mac"
            }
            if let err { self.error = "Connection ended: \(err.localizedDescription)" }
        }
        do {
            guard let binding = peer.channelBinding else { throw RemoteProtocolError.securityNegotiationFailed }
            let handshake = try PairingHandshake(identity: try identity(), localName: Host.current().localizedName ?? "Mac", role: .host, channelBinding: binding, expectedPeerID: hostExpectedPeerID)
            hostHandshake = handshake
            handshake.onSend = { [weak peer] message in _ = peer?.send(message) }
            handshake.onAuthenticated = { [weak self, weak peer] device in
                guard let self, let peer, self.hostPeer === peer, self.sessionID == id else { return }
                do { try self.remember(device) } catch { self.error = "Could not save device trust: \(error.localizedDescription)"; peer.close(); return }
                self.hostAuthDeadline?.cancel()
                self.activeSignalSessionID = self.signalAttempt?.id
                self.clearSignalAttempt()
                self.hostDevice = device
                peer.setMediaAuthorization(true, generation: 0)
                self.connectedDeviceID = device.id
                self.status = "Paired with \(device.name) · available in the background"
            }
            handshake.onFailure = { [weak self, weak peer] err in self?.error = err.localizedDescription; peer?.close() }
            let timeout = DispatchWorkItem { [weak self, weak peer] in
                guard let self, self.hostDevice == nil, self.sessionID == id else { return }
                self.error = "Device authentication timed out."; peer?.close()
            }
            hostAuthDeadline = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
            handshake.start()
        } catch { self.error = error.localizedDescription; peer.close() }
    }

    private func startCapture(for peer: any RemotePeer, session id: UUID) {
        guard hostPeer === peer, hostDevice != nil, streamer == nil, isHosting else { return }
        refreshPermissions()
        guard screenAllowed else { sendStreamState(.unavailable, generation: nextCaptureGeneration()); return }
        hasViewer = true
        hostCaptureAvailable = false
        sendStreamState(.starting, generation: nextCaptureGeneration())
        adaptiveStream = AdaptiveStreamController(maximum: quality == .automatic ? .automaticMaximum : quality.configuration, automatic: quality == .automatic)
        activeStreamConfiguration = adaptiveStream.configuration
        let capture = ScreenStreamer(config: adaptiveStream.configuration)
        streamer = capture
        hostMediaMailbox = MediaSessionMailbox()
        let mailbox = hostMediaMailbox
        capture.canEncodeFrame = { [weak peer] in peer?.mediaCapacityAvailable == true }
        capture.onStatistics = { statistics in mailbox.recordPipeline(statistics) }
        capture.onAvailability = { [weak self, weak capture, weak peer] available, generation in
            DispatchQueue.main.async {
                guard let self, let capture, let peer, self.streamer === capture, self.hostPeer === peer else { return }
                self.captureGeneration = generation
                self.hostCaptureAvailable = available
                mailbox.authorize(available ? generation : 0)
                peer.setMediaAuthorization(available, generation: available ? generation : 0)
                self.sendStreamState(available ? .available : .unavailable, generation: generation)
                if !available { self.injector?.releaseAll(); self.status = "Screen is unavailable · connection remains paired" }
            }
        }
        capture.onFrameEvent = { [weak peer, weak capture] frame, generation in
            guard let peer, let capture, mailbox.permits(generation) else { return }
            do {
                if try !mailbox.send(frame, generation: generation, peer: peer) { capture.requestKeyframe() }
            } catch { peer.close() }
        }
        capture.onError = { [weak self, weak peer, weak capture] err in
            DispatchQueue.main.async {
                guard let self, let peer, let capture, self.hostPeer === peer, self.streamer === capture else { return }
                self.error = "Screen capture paused: \(err.localizedDescription)"
                self.pauseHostCapture(unavailable: true)
            }
        }
        Task {
            do {
                try await capture.start()
                guard sessionID == id, hostPeer === peer, streamer === capture else { await capture.stop(); return }
                if injector == nil { injector = InputInjector(displayID: capture.captureDisplayID) }
                let bounds = CGDisplayBounds(capture.captureDisplayID)
                let info = HostInfo(name: Host.current().localizedName ?? "Mac", width: Int(bounds.width), height: Int(bounds.height), pointWidth: Int(bounds.width), pointHeight: Int(bounds.height), fps: adaptiveStream.configuration.framesPerSecond)
                if let bytes = try? JSONEncoder().encode(info) { _ = peer.send(WireMessage(kind: .hello, payload: bytes)) }
                status = controlAllowed ? "Sharing screen · remote control enabled" : "Sharing screen · view only"
            } catch {
                guard hostPeer === peer, streamer === capture else { return }
                self.error = "Could not capture the display: \(error.localizedDescription)"
                pauseHostCapture(unavailable: true)
            }
        }
    }

    private func nextCaptureGeneration() -> UInt64 {
        captureGeneration = UInt64.random(in: 1...UInt64.max)
        return captureGeneration
    }
    private func sendStreamState(_ state: StreamState.State, generation: UInt64) {
        guard let bytes = try? JSONEncoder().encode(StreamState(state, generation: generation)) else { return }
        _ = hostPeer?.send(WireMessage(kind: .streamState, payload: bytes))
    }
    private func pauseHostCapture(unavailable: Bool = false) {
        hostMediaMailbox.authorize(0)
        hostPeer?.setMediaAuthorization(false, generation: 0)
        injector?.releaseAll(); injector = nil
        let old = streamer; streamer = nil
        if let old { Task { await old.stop() } }
        hasViewer = false; hostCaptureAvailable = false; frameCount = 0; byteCount = 0; fps = 0
        sendStreamState(unavailable ? .unavailable : .paused, generation: nextCaptureGeneration())
        status = unavailable ? "Screen unavailable · paired connection remains open" : "Available to paired Mac · screen saver may run"
    }
    private func endHostSession() {
        hostMediaMailbox.authorize(0)
        hostPeer?.setMediaAuthorization(false, generation: 0)
        InputInjector.endRemoteActivity()
        hostAuthDeadline?.cancel(); hostHandshake?.cancel(); hostHandshake = nil
        hostPeer?.onClose = nil
        pauseHostCapture()
        hostPeer?.close(); hostPeer = nil; hostDevice = nil
        connectedDeviceID = nil; pingMS = nil
    }
    func stopHosting() {
        clearSignalAttempt(notify: true)
        cloudHosting = false; hostExpectedPeerID = nil
        sessionID = UUID()
        listener?.stop()
        listener = nil
        internetHost?.onClose = nil
        internetHost?.close()
        internetHost = nil
        endHostSession()
        isHosting = false
        if !invitation.isEmpty, NSPasteboard.general.string(forType: .string) == invitation { NSPasteboard.general.clearContents() }
        invitation = ""
        pastedResponse = ""
        connectionPath = ""
        if awakeID != 0 { IOPMAssertionRelease(awakeID); awakeID = 0 }
        timer?.invalidate()
        timer = nil
        status = "Sharing stopped · invitation revoked"
    }
    func copyInvitation() {
        guard !invitation.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(invitation, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.copied = false }
    }

    func connect() {
        guard !isHosting, !isConnecting, !isViewing, viewerPeer == nil else { return }
        startViewerConnection(pastedInvitation.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func startViewerConnection(_ text: String) {
        error = nil
        do {
            let peer: any RemotePeer
            if text.hasPrefix("farreach-offer://") {
                let rtc = try WebRTCPeer(role: .viewer(invitation: text), stunURLs: configuredSTUN(), helperURL: networkHelperURL)
                rtc.onResponse = { [weak self, weak rtc] response in
                    guard let self, let rtc, self.viewerPeer === rtc else { return }
                    if let attempt = self.signalAttempt, attempt.phase == .connecting {
                        guard self.signaling?.send(CloudSignalMessage(kind: .answer, attemptID: attempt.id, body: response), to: attempt.peerID) == true else {
                            self.failSignalAttempt("Cloud signaling disconnected during setup. Try connecting again."); return
                        }
                        self.status = "Checking the direct path between your Macs…"
                        return
                    }
                    self.connectionResponse = response
                    self.status = "Copy the response to the sharing Mac to finish pairing"
                }
                rtc.onPath = { [weak self, weak rtc] path in
                    guard let self, let rtc, self.viewerPeer === rtc else { return }
                    self.connectionPath = Self.describePath(path)
                }
                peer = rtc
            } else {
                let invite = try PairingInvitation(string: text)
                peer = try SecurePeer(host: invite.host, port: invite.port, key: invite.key)
            }
            viewerPeer = peer
            inputSequencer.reset()
            peer.onStatistics = { [weak self, weak peer] statistics in
                guard let self, let peer, self.viewerPeer === peer else { return }
                self.receiveStatistics(statistics, host: false)
            }
            peer.onConnectionState = { [weak self, weak peer] state in
                guard let self, let peer, self.viewerPeer === peer else { return }
                self.noteConnectionState(state)
            }
            installMediaReceiver(on: peer)
            desktop.clear()
            remoteName = "Remote Mac"
            isConnecting = true
            status = "Preparing secure connection…"
            connectionResponse = ""
            connectionPath = ""
            lastTraffic = ProcessInfo.processInfo.systemUptime
            peer.onReady = { [weak self, weak peer] in
                guard let self, let peer, self.viewerPeer === peer else { return }
                self.pastedInvitation = ""
                self.clearResponse()
                self.startMetrics()
                self.status = "Verifying the paired Mac…"
                self.lastTraffic = ProcessInfo.processInfo.systemUptime
                do {
                    guard let binding = peer.channelBinding else { throw RemoteProtocolError.securityNegotiationFailed }
                    let handshake = try PairingHandshake(identity: self.identity(), localName: Host.current().localizedName ?? "Mac", role: .viewer, channelBinding: binding, expectedPeerID: self.selectedExpectedPeerID)
                    self.viewerHandshake = handshake
                    handshake.onSend = { [weak peer] message in _ = peer?.send(message) }
                    handshake.onAuthenticated = { [weak self, weak peer] device in
                        guard let self, let peer, self.viewerPeer === peer else { return }
                        do { try self.remember(device) } catch { self.error = "Could not save device trust: \(error.localizedDescription)"; peer.close(); return }
                        self.viewerAuthDeadline?.cancel()
                        self.activeSignalSessionID = self.signalAttempt?.id
                        self.clearSignalAttempt()
                        self.viewerDevice = device
                        peer.setMediaAuthorization(true, generation: 0)
                        self.connectedDeviceID = device.id
                        self.remoteName = device.name
                        self.isConnecting = false
                        self.canResumeViewing = true
                        if self.connectionIntent == nil { self.connectionIntent = (device.id, true) }
                        self.cancelRecovery()
                        if self.connectionIntent?.viewing == true { self.resumeViewing() }
                        else { self.status = "Paired connection recovered · ready to resume" }
                    }
                    handshake.onFailure = { [weak self, weak peer] err in
                        self?.connectionIntent = nil; self?.cancelRecovery()
                        self?.error = err.localizedDescription; peer?.close()
                    }
                    let timeout = DispatchWorkItem { [weak self, weak peer] in
                        guard let self, self.viewerDevice == nil, self.viewerPeer === peer else { return }
                        self.error = "Device authentication timed out."; peer?.close()
                    }
                    self.viewerAuthDeadline = timeout
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
                    handshake.start()
                } catch { self.error = error.localizedDescription; peer.close() }
            }
            peer.onMessage = { [weak self, weak peer] message in
                guard let self, let peer, self.viewerPeer === peer else { return }
                self.lastTraffic = ProcessInfo.processInfo.systemUptime
                if message.kind == .pairing { self.viewerHandshake?.receive(message.payload); return }
                if message.kind == .ping { _ = peer.send(WireMessage(kind: .pong, payload: message.payload)); return }
                if message.kind == .pong { self.recordPong(message.payload); return }
                guard self.viewerDevice != nil else { peer.close(); return }
                do {
                    switch message.kind {
                    case .hello:
                        let info = try JSONDecoder().decode(HostInfo.self, from: message.payload)
                        guard info.isValid else { throw RemoteProtocolError.malformedFrame }
                        self.remoteHostPerformance = info.performance
                        // Display name comes from the authenticated device identity.
                    case .streamState:
                        let state = try JSONDecoder().decode(StreamState.self, from: message.payload)
                        if state.state == .wakeRequested { self.status = "Wake requested · enter the password only when the remote lock screen is visible"; return }
                        if state.state == .available && (!self.isViewing || self.isRecovering) { return }
                        self.expectedGeneration = state.generation
                        self.lastEnqueueTime = nil
                        self.remoteStreamAvailable = state.state == .available
                        self.streamUnavailable = !self.remoteStreamAvailable
                        self.desktop.clear(); self.desktop.inputEnabled = false
                        self.viewerDecodedMailbox.authorize(state.state == .available ? state.generation : 0)
                        peer.setMediaAuthorization(state.state == .available, generation: state.state == .available ? state.generation : 0)
                        if state.state == .available {
                            self.status = "Connected to \(self.remoteName)"
                            // Control and lossy video are independent channels. Request
                            // a fresh IDR after accepting this epoch, even if its first
                            // frame overtook the availability message and was discarded.
                            _ = peer.send(WireMessage(kind: .requestKeyframe, payload: Data()))
                        }
                        else if state.state == .paused { self.status = "Paired connection kept open · ready to resume" }
                        else { self.status = "Waiting for a fresh remote screen · use Wake Display if needed" }
                    case .video:
                        guard self.isViewing, self.remoteStreamAvailable else { return }
                        let envelope = try StreamFrameEnvelope(data: message.payload)
                        guard envelope.generation == self.expectedGeneration else { return }
                        let frame = try EncodedFrame(data: envelope.frame)
                        if try self.desktop.display(frame) {
                            self.desktop.inputEnabled = true
                            self.streamUnavailable = false
                        }
                        self.byteCount += message.payload.count
                    case .disconnect: self.disconnect()
                    default: break
                    }
                } catch { self.error = "Invalid remote stream: \(error.localizedDescription)"; self.disconnect() }
            }
            peer.onClose = { [weak self, weak peer] err in
                guard let self, let peer, self.viewerPeer === peer else { return }
                if self.connectionIntent != nil, self.signaling != nil {
                    self.beginRecovery(); self.retireViewerTransport(); self.scheduleRecovery(after: RecoveryPolicy.grace)
                } else {
                    self.disconnect()
                    self.status = "Device trust is saved · connection setup is needed again"
                    if let err { self.error = "Connection ended: \(err.localizedDescription)" }
                }
            }
            peer.start()
        } catch {
            if signalAttempt != nil { failSignalAttempt(error.localizedDescription) }
            else { self.error = error.localizedDescription }
        }
    }
    private func sendControl(_ action: SessionControl.Action) {
        guard viewerDevice != nil, let data = try? JSONEncoder().encode(SessionControl(action)) else { return }
        _ = viewerPeer?.send(WireMessage(kind: .sessionControl, payload: data))
    }

    private func installMediaReceiver(on peer: any RemotePeer) {
        let mailbox = LatestDecodedFrameMailbox(), preparer = MediaFramePreparer()
        viewerDecodedMailbox = mailbox
        // These values belong to this transport's serial media callback queue.
        // A new transport gets its own decoder, even if an old decode is finishing.
        var decoderEpoch: UInt64?
        var lastKeyframeRequest = -TimeInterval.infinity
        peer.onMediaMessage = { [weak self, weak peer] message in
            guard let peer, message.kind == .video else { return }
            do {
                let envelope = try StreamFrameEnvelope(data: message.payload)
                guard let epoch = mailbox.token(for: envelope.generation) else { return }
                let frame = try EncodedFrame(data: envelope.frame)
                if decoderEpoch != epoch {
                    preparer.reset()
                    decoderEpoch = epoch
                }
                guard mailbox.permits(generation: envelope.generation, epoch: epoch) else { return }
                let preparationStarted = ProcessInfo.processInfo.systemUptime
                let prepared: PreparedMediaFrame
                do {
                    prepared = try preparer.decode(frame)
                } catch let error as MediaError {
                    switch error {
                    case .needsKeyframe, .codec:
                        // Native decoder failures discard its reference state. A
                        // bounded IDR request recovers it; UI pressure never does.
                        let now = ProcessInfo.processInfo.systemUptime
                        if mailbox.permits(generation: envelope.generation, epoch: epoch), now - lastKeyframeRequest >= 0.25 {
                            lastKeyframeRequest = now
                            _ = peer.send(WireMessage(kind: .requestKeyframe, payload: Data()))
                        }
                        return
                    case .invalidFrame, .noDisplay, .stopped: throw error
                    }
                }
                guard prepared.isDecoded else { throw MediaError.invalidFrame("Decoder returned compressed media") }
                let preparedAt = ProcessInfo.processInfo.systemUptime
                guard mailbox.permits(generation: envelope.generation, epoch: epoch) else { return }
                let delivery = DecodedFrameDelivery(generation: envelope.generation, epoch: epoch, prepared: prepared,
                    preparationMilliseconds: (preparedAt - preparationStarted) * 1000,
                    preparedAt: preparedAt, payloadBytes: message.payload.count)
                guard mailbox.publish(delivery) else { return }
                DispatchQueue.main.async { [weak self, weak peer] in
                    guard let delivery = mailbox.take(), let self, let peer, self.viewerPeer === peer,
                          self.isViewing, self.remoteStreamAvailable, !self.isRecovering,
                          self.expectedGeneration == delivery.generation,
                          mailbox.permits(generation: delivery.generation, epoch: delivery.epoch) else { return }
                    do {
                        if try self.desktop.display(delivery.prepared) {
                            self.desktop.inputEnabled = true; self.streamUnavailable = false
                        }
                        self.lastEncodeMilliseconds = MediaSessionMailbox.encodeDuration(delivery.prepared.frame)
                        self.lastFrameID = delivery.prepared.frame.frameID
                        self.lastPreparationMilliseconds = delivery.preparationMilliseconds
                        self.lastHandoffMilliseconds = (ProcessInfo.processInfo.systemUptime - delivery.preparedAt) * 1000
                        self.lastTraffic = ProcessInfo.processInfo.systemUptime
                        self.byteCount += delivery.payloadBytes
                    } catch { self.error = "Invalid remote stream: \(error.localizedDescription)"; self.disconnect() }
                }
            } catch {
                DispatchQueue.main.async { [weak self, weak peer] in
                    guard let self, let peer, self.viewerPeer === peer else { return }
                    self.error = "Invalid remote stream: \(error.localizedDescription)"; self.disconnect()
                }
            }
        }
    }

    private func receiveStatistics(_ statistics: TransportStatistics, host: Bool) {
        transportStatistics = statistics
        defer { previousStatistics = statistics }
        guard host, let streamer, !updatingStream else { return }
        let received = statistics.packetsReceived >= (previousStatistics?.packetsReceived ?? 0)
            ? statistics.packetsReceived - (previousStatistics?.packetsReceived ?? 0) : 0
        let lost = statistics.packetsLost >= (previousStatistics?.packetsLost ?? 0)
            ? statistics.packetsLost - (previousStatistics?.packetsLost ?? 0) : 0
        let loss = received + lost == 0 ? 0 : Double(lost) / Double(received + lost)
        let feedback = StreamFeedback(availableBitrate: statistics.targetBitrate > 0 ? statistics.targetBitrate : nil,
            rttMilliseconds: statistics.rttMS > 0 ? statistics.rttMS : nil, lossFraction: loss,
            sendQueueMilliseconds: TransportPressure.feedbackQueueMS(statistics, previous: previousStatistics,
                usesMediaCredits: hostPeer?.usesMediaCredits ?? false))
        guard let configuration = adaptiveStream.update(feedback, now: ProcessInfo.processInfo.systemUptime) else { return }
        activeQualityDescription = "\(configuration.maxDimension) px max · \(configuration.framesPerSecond) fps · \(configuration.bitrate / 1_000) kbps"
        updatingStream = true
        Task { [weak self, weak streamer] in
            guard let self, let streamer else { return }
            defer { self.updatingStream = false }
            do {
                try await streamer.updateConfiguration(configuration)
                if self.streamer === streamer { self.activeStreamConfiguration = configuration }
            }
            catch { if self.streamer === streamer { self.error = "Quality adjustment failed: \(error.localizedDescription)" } }
        }
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "FarReach-connection-diagnostics.json"
        panel.title = "Export connection measurements"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try diagnosticsData().write(to: url, options: .atomic) }
        catch { self.error = "Could not export diagnostics: \(error.localizedDescription)" }
    }

    func diagnosticsData() throws -> Data {
        let report = PerformanceReport(formatVersion: 1,
            transport: (viewerPeer ?? hostPeer) is WebRTCPeer ? "direct-webrtc-udp" : "local-tls",
            quality: viewerPeer != nil ? "Viewer; encoder quality is selected by the host" : quality.rawValue, samples: performanceSamples,
            measurementNotes: ["RTT is not glass-to-glass latency.", "FPS counts admitted frames, not display scanout.",
                "Payload throughput excludes transport overhead.", "Missing packets are observed sequence gaps; late repairs can include reordering.",
                "Capture-to-encode uses two timestamps from the capture Mac; receiver preparation and handoff use only the viewer clock.",
                "Enqueue gaps above 250 ms are counted separately; an unchanged desktop can cause a gap and these are not physical display freezes.",
                "Encoding skips count admission attempts, including cached-image retries; they are not a packet-loss or captured-frame-loss percentage.",
                "Summary percentiles describe the retained periodic samples, not every captured frame.",
                "Target bitrate is a local sending estimate and is omitted on the receiving viewer.",
                "Remote host counters, when supplied, reset with the reported capture generation; legacy hosts may omit them.",
                "No screen content, input events, keys, addresses, or device identifiers are included."],
            remoteHostPerformance: remoteHostPerformance)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }
    func resumeViewing() {
        guard viewerDevice != nil, viewerPeer != nil, !isHosting else { return }
        if let id = viewerDevice?.id { connectionIntent = (id, true) }
        guard !isRecovering else { return }
        error = nil
        isViewing = true; isConnecting = false
        remoteStreamAvailable = false; streamUnavailable = true; expectedGeneration = 0
        viewerDecodedMailbox.authorize(0)
        viewerPeer?.setMediaAuthorization(false, generation: 0)
        desktop.clear(); desktop.inputEnabled = false
        status = "Resuming the paired connection…"
        sendControl(.wake)
        sendControl(.resume)
    }
    func wakeRemoteDisplay() {
        guard viewerDevice != nil, viewerPeer != nil else { return }
        sendControl(.wake)
        if isViewing { sendControl(.resume) }
    }
    func endViewing() {
        if let intent = connectionIntent { connectionIntent = (intent.deviceID, false) }
        if isRecovering {
            isViewing = false; desktop.clear(); desktop.inputEnabled = false; page = .devices
            return
        }
        guard viewerDevice != nil, viewerPeer != nil else { disconnect(); return }
        desktop.releaseInput()
        viewerDecodedMailbox.authorize(0)
        viewerPeer?.setMediaAuthorization(false, generation: 0)
        sendControl(.pause)
        isViewing = false; isConnecting = false; remoteStreamAvailable = false
        desktop.clear(); desktop.inputEnabled = false
        canResumeViewing = true
        page = .devices
        status = "Paired connection kept open · ready to resume"
    }
    func disconnect() {
        sendSessionClose()
        connectionIntent = nil
        cancelRecovery()
        retireViewerTransport()
        status = "Connection closed · device trust is saved"
    }
    private func sendSessionClose() {
        if let device = viewerDevice, let session = activeSignalSessionID {
            signaling?.send(.init(kind: .close, attemptID: UUID().uuidString, sessionID: session), to: device.id)
        }
    }
    private func retireViewerTransport() {
        if isRecovering { sendSessionClose() }
        clearSignalAttempt(notify: true)
        viewerAuthDeadline?.cancel(); viewerHandshake?.cancel(); viewerHandshake = nil
        viewerPeer?.onClose = nil
        desktop.releaseInput()
        viewerDecodedMailbox.authorize(0)
        viewerPeer?.setMediaAuthorization(false, generation: 0)
        viewerPeer?.close(); viewerPeer = nil; viewerDevice = nil
        desktop.clear(); desktop.inputEnabled = false
        isConnecting = false; isViewing = false; canResumeViewing = false
        connectedDeviceID = nil; remoteStreamAvailable = false; expectedGeneration = 0
        activeSignalSessionID = nil
        clearResponse(); connectionPath = ""
        timer?.invalidate(); timer = nil; pingMS = nil
        if isRecovering { isConnecting = true }
    }
    func forgetDevice(_ id: String) {
        do {
            try pairingStore.forget(id: id)
            pairedDevices = try pairingStore.listDevices()
            signaling?.updatePeers(pairedDevices)
            if viewerDevice?.id == id || selectedExpectedPeerID == id || connectionIntent?.deviceID == id { disconnect() }
            if hostDevice?.id == id || (isHosting && hostDevice == nil) { stopHosting() }
            if selectedExpectedPeerID == id { selectedExpectedPeerID = nil }
        } catch { self.error = error.localizedDescription }
    }
    func setUpConnection(to device: PairedDevice) {
        guard viewerPeer == nil, !isHosting, !isConnecting else { return }
        selectedExpectedPeerID = device.id
        remoteName = device.name
        page = .connect
        status = "Trust saved for \(device.name) · paste a fresh connection invitation"
    }
    func pairAnotherMac() {
        guard viewerPeer == nil, !isHosting, !isConnecting else { return }
        selectedExpectedPeerID = nil
        pastedInvitation = ""
        page = .connect
    }
    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if enabled && !loginEnabled { error = "Approve FarReach under System Settings → General → Login Items." }
        } catch { self.error = "Could not change login startup: \(error.localizedDescription)" }
    }
    func shutdown() {
        networkMonitor?.cancel(); networkMonitor = nil
        pointerTimer?.invalidate(); pointerTimer = nil
        routerInspector?.stop(); diagnostic?.cancel(); stopHosting(); disconnect()
        signaling?.stop(); signaling = nil; signalingReady = false
    }

    private func startMetrics() {
        timer?.invalidate()
        frameCount = 0; byteCount = 0; dropped = 0; pingMS = nil; lastPing = nil
        metricsStarted = ProcessInfo.processInfo.systemUptime
        lastPongReceived = metricsStarted
        lastEnqueueTime = nil; enqueueGapEvents = 0; longestEnqueueGapMS = 0
        performanceSamples.removeAll(); transportStatistics = nil; previousStatistics = nil
        remoteHostPerformance = nil
        pipelineStatistics = nil
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    private func tick() {
        let totals = hostMediaMailbox.drain()
        frameCount += totals.frames; byteCount += totals.bytes; dropped += totals.drops
        if let duration = totals.encodeMilliseconds { lastEncodeMilliseconds = duration }
        if let frameID = totals.frameID { lastFrameID = frameID }
        if let pipeline = totals.pipeline { pipelineStatistics = pipeline }
        fps = frameCount; mbps = Double(byteCount) * 8 / 1_000_000
        frameCount = 0; byteCount = 0
        let now = ProcessInfo.processInfo.systemUptime
        let stats = transportStatistics
        performanceSamples.append(PerformanceSample(elapsedSeconds: now - metricsStarted,
            applicationRTTMilliseconds: pingMS, transportRTTMilliseconds: stats?.rttMS,
            sendQueueMilliseconds: stats?.queueMS, targetBitrate: hostPeer != nil ? stats?.targetBitrate : nil,
            encodedMegabitsPerSecond: mbps, admittedFramesPerSecond: fps,
            packetsReceived: stats?.packetsReceived, packetsLost: stats?.packetsLost,
            packetsRepaired: stats?.packetsRepaired, framesDropped: stats?.framesDropped,
            captureToEncodeMilliseconds: lastEncodeMilliseconds, localPreparationMilliseconds: lastPreparationMilliseconds,
            localMainHandoffMilliseconds: lastHandoffMilliseconds, frameID: lastFrameID,
            capturedFrames: pipelineStatistics?.capturedFrames, skippedBeforeEncoding: pipelineStatistics?.skippedBeforeEncoding,
            encoderDroppedFrames: pipelineStatistics?.encoderDroppedFrames, recoveryRequests: pipelineStatistics?.recoveryRequests,
            enqueueGapEvents: enqueueGapEvents, longestEnqueueGapMilliseconds: longestEnqueueGapMS,
            remoteHostPerformance: remoteHostPerformance))
        if performanceSamples.count > 1800 { performanceSamples.removeFirst(performanceSamples.count - 1800) }
        sendHostPerformance(now: now)
        if let peer = viewerPeer ?? hostPeer {
            if now - lastPongReceived > 3, hostPeer != nil { injector?.releaseAll() }
            if now - lastPongReceived > 3, viewerPeer != nil, connectionIntent != nil, signaling != nil {
                noteConnectionState(.recovering)
            }
            if now - lastTraffic > 20 {
                error = "The other Mac stopped responding. Reconnect when its network is available."
                peer.close()
                return
            }
            if lastPing == nil || now - lastPingTime > 5 {
                let data = Data(UUID().uuidString.replacingOccurrences(of: "-", with: "").utf8)
                lastPing = data; lastPingTime = now
                _ = peer.send(WireMessage(kind: .ping, payload: data))
            }
        }
        let wasAllowed = controlAllowed
        refreshPermissions()
        if wasAllowed && !controlAllowed { injector?.releaseAll() }

    }
    private func recordPong(_ data: Data) {
        guard data == lastPing else { return }
        pingMS = (ProcessInfo.processInfo.systemUptime - lastPingTime) * 1000
        lastPongReceived = ProcessInfo.processInfo.systemUptime
        lastPing = nil
        if lossGrace != nil { noteConnectionState(.connected) }
    }

    private func sendHostPerformance(now: TimeInterval) {
        guard hostDevice != nil, let peer = hostPeer else { return }
        let source = pipelineStatistics
        let size = streamer?.frameSize ?? .zero
        let configuration = activeStreamConfiguration
        let performance = HostPerformanceSnapshot(elapsedSeconds: max(0, now - metricsStarted),
            captureGeneration: captureGeneration, captureAvailable: hostCaptureAvailable,
            captureWidth: Int(size.width), captureHeight: Int(size.height),
            configuredMaxDimension: configuration.maxDimension, configuredFPS: configuration.framesPerSecond,
            encoderBitrate: configuration.bitrate, capturedFrames: source?.capturedFrames ?? 0,
            encodedFrames: source?.encodedFrames ?? 0, encodedKeyframes: source?.keyframes ?? 0,
            skippedBeforeEncoding: source?.skippedBeforeEncoding ?? 0, encoderDroppedFrames: source?.encoderDroppedFrames ?? 0,
            recoveryRequests: source?.recoveryRequests ?? 0, dataRateLimitSupported: source?.dataRateLimitSupported,
            transport: transportStatistics,
            softwareVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unpackaged",
            softwareBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unpackaged")
        let info = HostInfo(name: "FarReach host", width: max(1, Int(size.width)), height: max(1, Int(size.height)),
            fps: configuration.framesPerSecond, performance: performance)
        guard info.isValid, let bytes = try? JSONEncoder().encode(info), bytes.count <= MessageKind.hello.maximumPayloadSize else { return }
        _ = peer.send(WireMessage(kind: .hello, payload: bytes))
    }

    static func addresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var values: [String] = []
        var next: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = next {
            defer { next = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let host = String(cString: buffer)
                if !host.hasPrefix("169.254.") { values.append(host) }
            }
        }
        return Array(Set(values)).sorted { a, b in
            func tailnet(_ s: String) -> Bool { let p = s.split(separator: "."); return p.count == 4 && p[0] == "100" && (64...127).contains(Int(p[1]) ?? 0) }
            if tailnet(a) != tailnet(b) { return tailnet(a) }
            return a < b
        }
    }
}
