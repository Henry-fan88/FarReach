import Foundation
import Darwin

public enum WebRTCRole: Equatable {
    case host
    case viewer(invitation: String)
}

public enum WebRTCTransportError: LocalizedError, Equatable {
    case helperMissing
    case invalidConfiguration
    case invalidResponse
    case malformedHelperOutput
    case helperUnavailable
    case connectionFailed
    case connectionTimedOut
    case closed
    case overloaded
    case incompatibleVersion

    public var errorDescription: String? {
        switch self {
        case .helperMissing: return "FarReach's bundled networking helper is missing. Rebuild or reinstall the complete app."
        case .invalidConfiguration: return "Use a FarReach offer and STUN discovery addresses. TURN relays are not supported in direct-only mode."
        case .invalidResponse: return "Paste the complete FarReach answer into the Mac that created the offer."
        case .malformedHelperOutput: return "The networking helper sent an invalid message. The connection was stopped."
        case .helperUnavailable: return "FarReach's networking helper stopped unexpectedly. Try starting a fresh connection."
        case .connectionFailed: return "The direct connection could not be established. Check the offer, answer, and both networks; no relay is used."
        case .connectionTimedOut: return "The direct connection timed out. Start again with a fresh offer and answer."
        case .closed: return "The connection is already closed."
        case .overloaded: return "The connection's control queue is full. The connection was stopped."
        case .incompatibleVersion: return "Update FarReach on both Macs to the same version. This build requires the version 2 media protocol."
        }
    }
}

/// Bundled Pion/WebRTC helper transport. Secrets travel only inside bounded
/// stdin/stdout frames, never process arguments, the environment, or logs.
/// Control callbacks run on callbackQueue. onMediaMessage runs off the UI queue.
public final class WebRTCPeer: RemotePeer {
    public var onReady: (() -> Void)?
    public var onMessage: ((WireMessage) -> Void)?
    public var onClose: ((Error?) -> Void)?
    public var onInvitation: ((String) -> Void)?
    public var onResponse: ((String) -> Void)?
    public var onPath: ((String) -> Void)?
    public var onVideoDropped: (() -> Void)?
    public var onStatistics: ((TransportStatistics) -> Void)?
    public var onConnectionState: ((PeerConnectionState) -> Void)?
    public var onMediaMessage: ((WireMessage) -> Void)?

    public static let defaultSTUNURLs = ["stun:stun.cloudflare.com:3478"]
    static let maximumHandshakeBytes = 256 * 1024
    private static let maximumPendingControlBytes = 64 * 1024
    private let role: WebRTCRole
    private let configuration: Data
    private let helperURL: URL
    private let callbackQueue: DispatchQueue
    private let flowControlEnabled: Bool
    private let queue = DispatchQueue(label: "FarReach.webrtc.state", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let mediaQueue = DispatchQueue(label: "FarReach.webrtc.media", qos: .userInteractive)
    private var runtime: HelperRuntime?
    private var started = false
    private var ready = false
    private var binding: Data?
    private var closed = false
    private var receivedInitialSignal = false
    private var appliedResponse = false
    private var pendingVideo = false
    private var pendingControlBytes = 0
    private var pendingPointer = false
    private var authorized = false
    private var mediaGeneration: UInt64 = 0
    private var authorizationEpoch: UInt64 = 0
    private var transportConnected = false
    private var mediaCreditAvailable = false
    private var mediaDelivering = false
    private struct QueuedMedia { let message: WireMessage; let epoch: UInt64 }
    private var mediaPending: [QueuedMedia] = []
    private var mediaPendingBytes = 0
    private var mediaInFlightBytes = 0
    private var requireKeyframe = true
    private var lastKeyframeRequest: TimeInterval = -1
    private var deliveryCount = 0
    private var deliveryBytes = 0
    private var latestStatistics: TransportStatistics?
    private var statisticsScheduled = false
    private var latestPointer: (message: WireMessage, epoch: UInt64)?
    private var pointerScheduled = false
    private var assembler = MediaIPCAssembler()
    private var deadline: DispatchWorkItem?
    private var mediaExpiryTimer: DispatchSourceTimer?

    private struct Configuration: Encodable {
        let protocolVersion = 2
        let role: String
        let invitation: String?
        let stunURLs: [String]
        let mediaFlowControl: Bool?
    }
    private struct Answer: Encodable { let response: String }
    private struct Event: Decodable { let type: String; let value: String? }
    private enum Delivery {
        case internalUpdate, ready, invitation(String), response(String), path(String), videoDropped, state(PeerConnectionState), message(WireMessage)
    }

    public init(role: WebRTCRole, stunURLs: [String] = WebRTCPeer.defaultSTUNURLs,
                helperURL: URL? = nil, mediaFlowControl: Bool = true, callbackQueue: DispatchQueue = .main) throws {
        guard stunURLs.count <= 3, stunURLs.allSatisfy(Self.validSTUNURL) else { throw WebRTCTransportError.invalidConfiguration }
        let configuration: Configuration
        switch role {
        case .host: configuration = Configuration(role: "host", invitation: nil, stunURLs: stunURLs, mediaFlowControl: mediaFlowControl ? true : nil)
        case .viewer(let invitation):
            if invitation.hasPrefix("farreach-offer://v1/") { throw WebRTCTransportError.incompatibleVersion }
            guard Self.validInvitation(invitation, prefix: "farreach-offer://v2/") else { throw WebRTCTransportError.invalidConfiguration }
            configuration = Configuration(role: "viewer", invitation: invitation, stunURLs: stunURLs, mediaFlowControl: mediaFlowControl ? true : nil)
        }
        let bytes = try JSONEncoder().encode(configuration)
        guard bytes.count <= Self.maximumHandshakeBytes else { throw WebRTCTransportError.invalidConfiguration }
        let executable = helperURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/FarReachNetwork")
        guard executable.isFileURL, executable.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executable.path),
              (try? executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { throw WebRTCTransportError.helperMissing }
        self.role = role
        self.configuration = bytes
        self.helperURL = executable
        self.callbackQueue = callbackQueue
        self.flowControlEnabled = mediaFlowControl
        queue.setSpecific(key: queueKey, value: 1)
    }

    public var channelBinding: Data? {
        let value = { [self] in ready && !closed ? binding : nil }
        if DispatchQueue.getSpecific(key: queueKey) != nil { return value() }
        return queue.sync(execute: value)
    }

    public var mediaCapacityAvailable: Bool {
        onStateQueue { ready && !closed && transportConnected && authorized && mediaGeneration != 0 && !pendingVideo && (!flowControlEnabled || mediaCreditAvailable) }
    }

    public var usesMediaCredits: Bool { flowControlEnabled }

    public func setMediaAuthorization(_ authorized: Bool, generation: UInt64) {
        onStateQueue {
            guard !closed, ready, let runtime else { return }
            guard self.authorized != authorized || mediaGeneration != generation else { return }
            self.authorized = authorized
            mediaGeneration = authorized ? generation : 0
            mediaCreditAvailable = false
            authorizationEpoch &+= 1
            latestPointer = nil
            requireKeyframe = true
            assembler.reset()
            mediaPending.removeAll(); mediaPendingBytes = 0
            runtime.cancelMedia()
            let command = MediaAuthorization(authorized: authorized, generation: mediaGeneration)
            if let data = try? JSONEncoder().encode(command) {
                write(kind: MediaIPC.authorizationKind, payload: data, runtime: runtime, completion: nil)
            }
        }
    }

    private struct MediaAuthorization: Encodable { let authorized: Bool; let generation: UInt64 }
    private struct MediaCapacity: Decodable { let generation: UInt64; let available: Bool }

    private func onStateQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return work() }
        return queue.sync(execute: work)
    }

    public func start() {
        queue.async { [self] in
            guard !started, !closed else { return }
            started = true
            do {
                let runtime = try HelperRuntime(executable: helperURL)
                self.runtime = runtime
                try runtime.launch()
                let expiry = DispatchSource.makeTimerSource(queue: queue)
                expiry.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
                expiry.setEventHandler { [weak self] in
                    guard let self, !self.closed else { return }
                    if self.assembler.expire(now: ProcessInfo.processInfo.systemUptime) { self.lostMedia() }
                }
                mediaExpiryTimer = expiry
                expiry.resume()
                armDeadline(seconds: 30)
                runtime.readPackets { [weak self, weak runtime] packet in
                    guard let self, let runtime else { return false }
                    return self.receive(packet, from: runtime)
                } failure: { [weak self] error in
                    self?.queue.async { [weak self] in self?.finish(error) }
                }
                write(kind: 240, payload: configuration, runtime: runtime, completion: nil)
            } catch { finish(WebRTCTransportError.helperUnavailable) }
        }
    }

    /// For a host waiting for the viewer's answer. At most one answer is accepted
    /// per peer; starting again creates a new authenticated negotiation.
    public func applyResponse(_ response: String) throws {
        if response.hasPrefix("farreach-answer://v1/") { throw WebRTCTransportError.incompatibleVersion }
        guard role == .host, Self.validInvitation(response, prefix: "farreach-answer://v2/") else { throw WebRTCTransportError.invalidResponse }
        let payload = try JSONEncoder().encode(Answer(response: response))
        guard payload.count <= Self.maximumHandshakeBytes else { throw WebRTCTransportError.invalidResponse }
        let work = { [self] in
            guard started, !closed, let runtime else { throw WebRTCTransportError.closed }
            guard receivedInitialSignal, !appliedResponse, !ready else { throw WebRTCTransportError.invalidResponse }
            appliedResponse = true
            armDeadline(seconds: 30)
            write(kind: 241, payload: payload, runtime: runtime, completion: nil)
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { try work() }
        else { try queue.sync(execute: work) }
    }

    @discardableResult public func send(_ message: WireMessage) -> Bool {
        let work: () -> Bool = { [self] in
            guard ready, !closed, let runtime else { return false }
            guard message.payload.count <= message.kind.maximumPayloadSize else {
                finish(RemoteProtocolError.frameTooLarge); return false
            }
            let video = message.kind == .video
            if video && (!transportConnected || pendingVideo || (flowControlEnabled && !mediaCreditAvailable) || !authorized || mediaGeneration == 0 ||
                         MediaIPC.generation(message.payload) != mediaGeneration) { return false }
            if message.kind == .pointer && pendingPointer { return false }
            let size = message.payload.count + 5
            if !video && pendingControlBytes + size > Self.maximumPendingControlBytes {
                finish(WebRTCTransportError.overloaded); return false
            }
            if video { pendingVideo = true; mediaCreditAvailable = false } else { pendingControlBytes += size }
            if message.kind == .pointer { pendingPointer = true }
            let completed: () -> Void = { [weak self] in
                guard let self else { return }
                if video { self.pendingVideo = false } else { self.pendingControlBytes -= size }
                if message.kind == .pointer { self.pendingPointer = false }
            }
            if video {
                runtime.writeVideo(message.payload) { [weak self] error in
                    self?.queue.async { [weak self] in
                        completed()
                        if let error, let self, !self.closed { self.finish(error) }
                    }
                }
            } else { write(kind: message.kind.rawValue, payload: message.payload, runtime: runtime, completion: completed) }
            return true
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { return work() }
        return queue.sync(execute: work)
    }

    public func close() { queue.async { [self] in finish(nil) } }
    deinit { deadline?.cancel(); mediaExpiryTimer?.cancel(); runtime?.shutdown() }

    private func write(kind: UInt8, payload: Data, runtime: HelperRuntime, completion: (() -> Void)?) {
        let bytes = HelperPacket(kind: kind, payload: payload).encoded()
        runtime.write(bytes) { [weak self] error in
            self?.queue.async { [weak self] in
                guard let self else { return }
                completion?()
                if let error, !self.closed { self.finish(error) }
            }
        }
    }

    private func receive(_ packet: HelperPacket, from runtime: HelperRuntime) -> Bool {
        onStateQueue {
            guard !closed, self.runtime === runtime else { return false }
            do {
                if packet.kind == MediaIPC.chunkKind {
                    guard ready else { throw WebRTCTransportError.malformedHelperOutput }
                    // A newly authenticated stream explicitly authorizes its epoch.
                    guard authorized, mediaGeneration != 0 else { return true }
                    let result = try assembler.push(packet.payload, now: ProcessInfo.processInfo.systemUptime)
                    if result.dropped { lostMedia() }
                    if let frame = result.frame { deliverMedia(WireMessage(kind: .video, payload: frame), runtime: runtime) }
                    return true
                }
                if let kind = MessageKind(rawValue: packet.kind) {
                    guard ready else { throw WebRTCTransportError.malformedHelperOutput }
                    let message = WireMessage(kind: kind, payload: packet.payload)
                    if kind == .video { deliverMedia(message, runtime: runtime) }
                    else if kind == .pointer { deliverPointer(message, runtime: runtime) }
                    else { enqueue(.message(message), bytes: packet.payload.count, runtime: runtime) }
                    return !closed
                }
                guard packet.kind == 242 else { throw WebRTCTransportError.malformedHelperOutput }
                let event = try JSONDecoder().decode(Event.self, from: packet.payload)
                let delivery: Delivery
                switch event.type {
                case "invitation":
                    guard role == .host, !receivedInitialSignal, !ready, let value = event.value,
                          Self.validInvitation(value, prefix: "farreach-offer://v2/") else { throw WebRTCTransportError.malformedHelperOutput }
                    receivedInitialSignal = true; deadline?.cancel(); deadline = nil
                    delivery = .invitation(value)
                case "response":
                    guard case .viewer = role, !receivedInitialSignal, !ready, let value = event.value,
                          Self.validInvitation(value, prefix: "farreach-answer://v2/") else { throw WebRTCTransportError.malformedHelperOutput }
                    receivedInitialSignal = true
                    armDeadline(seconds: 30 * 60)
                    delivery = .response(value)
                case "binding":
                    guard !ready, receivedInitialSignal, binding == nil, let value = event.value,
                          let bytes = Self.decodeBinding(value) else { throw WebRTCTransportError.malformedHelperOutput }
                    binding = bytes
                    return true
                case "ready":
                    guard !ready, receivedInitialSignal, binding?.count == 32 else { throw WebRTCTransportError.malformedHelperOutput }
                    ready = true; deadline?.cancel(); deadline = nil
                    transportConnected = true
                    delivery = .ready
                case "path":
                    guard let value = event.value, value.utf8.count <= 512 else { throw WebRTCTransportError.malformedHelperOutput }
                    delivery = .path(value)
                case "videoDropped":
                    guard ready else { throw WebRTCTransportError.malformedHelperOutput }
                    delivery = .videoDropped
                case "connectionState":
                    guard let value = event.value, let state = PeerConnectionState(rawValue: value) else { throw WebRTCTransportError.malformedHelperOutput }
                    transportConnected = state == .connected
                    delivery = .state(state)
                case "mediaCapacity":
                    guard flowControlEnabled, ready, let value = event.value,
                          let bytes = value.data(using: .utf8), bytes.count <= 256 else { throw WebRTCTransportError.malformedHelperOutput }
                    let capacity = try JSONDecoder().decode(MediaCapacity.self, from: bytes)
                    // Credits acknowledge local helper/pacer capacity, not network
                    // delivery. Old capture epochs cannot unblock a new encoder.
                    if authorized, mediaGeneration != 0, capacity.generation == mediaGeneration {
                        mediaCreditAvailable = capacity.available
                    }
                    return true
                case "statistics":
                    guard let value = event.value, let bytes = value.data(using: .utf8), bytes.count <= 8192 else { throw WebRTCTransportError.malformedHelperOutput }
                    let statistics = try JSONDecoder().decode(TransportStatistics.self, from: bytes)
                    guard statistics.isValid else { throw WebRTCTransportError.malformedHelperOutput }
                    // Statistics are periodic and may describe a preceding
                    // capture epoch; never use their auth flag for admission.
                    latestStatistics = statistics
                    scheduleStatistics(runtime: runtime)
                    return true
                case "error":
                    // Never expose remote SDP or arbitrary helper strings.
                    finish(event.value == "incompatibleVersion" ? WebRTCTransportError.incompatibleVersion : .connectionFailed)
                    return false
                case "closed": finish(nil); return false
                default: throw WebRTCTransportError.malformedHelperOutput
                }
                enqueue(delivery, bytes: packet.payload.count, runtime: runtime)
                return !closed
            } catch { finish(WebRTCTransportError.malformedHelperOutput); return false }
        }
    }

    private func enqueue(_ delivery: Delivery, bytes: Int, runtime: HelperRuntime) {
        guard deliveryCount < 256, deliveryBytes + bytes <= 512 * 1024 else {
            finish(WebRTCTransportError.overloaded); return
        }
        deliveryCount += 1; deliveryBytes += bytes
        callbackQueue.async { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            let valid = self.onStateQueue { () -> Bool in
                self.deliveryCount -= 1; self.deliveryBytes -= bytes
                return !self.closed && self.runtime === runtime
            }
            guard valid else { return }
            switch delivery {
            case .internalUpdate: break
            case .ready: self.onReady?()
            case .invitation(let value): self.onInvitation?(value)
            case .response(let value): self.onResponse?(value)
            case .path(let value): self.onPath?(value)
            case .videoDropped: self.onVideoDropped?()
            case .state(let value): self.onConnectionState?(value)
            case .message(let value): self.onMessage?(value)
            }
        }
    }

    private func scheduleStatistics(runtime: HelperRuntime) {
        guard !statisticsScheduled else { return }
        statisticsScheduled = true
        callbackQueue.async { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            let statistics = self.onStateQueue { () -> TransportStatistics? in
                self.statisticsScheduled = false
                guard !self.closed, self.runtime === runtime else { return nil }
                return self.latestStatistics
            }
            if let statistics { self.onStatistics?(statistics) }
        }
    }

    private func deliverPointer(_ message: WireMessage, runtime: HelperRuntime) {
        // Pointer snapshots are replaceable. They must never consume the
        // reliable-control budget or queue hundreds of stale moves during a UI stall.
        guard authorized, mediaGeneration != 0 else { return }
        latestPointer = (message, authorizationEpoch)
        guard !pointerScheduled else { return }
        pointerScheduled = true
        callbackQueue.async { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            let pointer = self.onStateQueue { () -> WireMessage? in
                self.pointerScheduled = false
                let value = self.latestPointer; self.latestPointer = nil
                guard !self.closed, self.runtime === runtime, self.authorized,
                      let value, self.authorizationEpoch == value.epoch else { return nil }
                return value.message
            }
            if let pointer { self.onMessage?(pointer) }
        }
    }

    private func lostMedia() {
        requireKeyframe = true
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastKeyframeRequest >= 0.25 else { return }
        lastKeyframeRequest = now
        _ = send(WireMessage(kind: .requestKeyframe))
    }

    private func deliverMedia(_ message: WireMessage, runtime: HelperRuntime) {
        guard authorized, mediaGeneration != 0,
              MediaIPC.generation(message.payload) == mediaGeneration else { return }
        if requireKeyframe && !MediaIPC.isKeyframe(message.payload) { lostMedia(); return }
        // A repair can release a chain of compressed reference frames at once.
        // Preserve that bounded chain for background decode; only decoded pixels
        // are replaceable at the UI boundary.
        if mediaPending.count + (mediaInFlightBytes > 0 ? 1 : 0) >= 12 ||
            mediaPendingBytes + mediaInFlightBytes + message.payload.count > 8 * 1024 * 1024 {
            mediaPending.removeAll(); mediaPendingBytes = 0
            lostMedia()
            guard MediaIPC.isKeyframe(message.payload),
                  mediaInFlightBytes + message.payload.count <= 8 * 1024 * 1024 else { return }
        }
        requireKeyframe = false
        mediaPending.append(QueuedMedia(message: message, epoch: authorizationEpoch))
        mediaPendingBytes += message.payload.count
        guard !mediaDelivering else { return }
        mediaDelivering = true
        mediaQueue.async { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            self.drainMedia(runtime: runtime)
        }
    }

    private func drainMedia(runtime: HelperRuntime) {
        while true {
            let next = onStateQueue { () -> QueuedMedia? in
                mediaInFlightBytes = 0
                guard !closed, self.runtime === runtime, !mediaPending.isEmpty else {
                    mediaPending.removeAll(); mediaPendingBytes = 0; mediaDelivering = false
                    return nil
                }
                let item = mediaPending.removeFirst()
                mediaPendingBytes -= item.message.payload.count
                mediaInFlightBytes = item.message.payload.count
                return item
            }
            guard let next else { return }
            guard onStateQueue({ authorized && authorizationEpoch == next.epoch && !closed }) else { continue }
            if let callback = onMediaMessage { callback(next.message) }
            else {
                // Compatibility for clients without a background media consumer.
                // This wait occupies only the media worker, never the pipe reader.
                let delivered = DispatchSemaphore(value: 0)
                callbackQueue.async { [weak self, weak runtime] in
                    defer { delivered.signal() }
                    guard let self, let runtime,
                          self.onStateQueue({ !self.closed && self.runtime === runtime && self.authorized && self.authorizationEpoch == next.epoch }) else { return }
                    self.onMessage?(next.message)
                }
                while delivered.wait(timeout: .now() + 0.1) == .timedOut {
                    if runtime.isCancelled { break }
                }
            }
        }
    }

    private func armDeadline(seconds: TimeInterval) {
        deadline?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.finish(WebRTCTransportError.connectionTimedOut) }
        deadline = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }
    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true; ready = false; binding = nil
        authorized = false; mediaGeneration = 0; authorizationEpoch &+= 1; assembler.reset()
        mediaCreditAvailable = false
        mediaPending.removeAll(); mediaPendingBytes = 0; latestPointer = nil
        deadline?.cancel(); deadline = nil
        mediaExpiryTimer?.cancel(); mediaExpiryTimer = nil
        runtime?.shutdown(); runtime = nil
        callbackQueue.async { [self] in onConnectionState?(.closed); onClose?(error) }
    }

    private static func decodeBinding(_ value: String) -> Data? {
        guard value.count == 43,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }),
              let data = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="),
              data.count == 32, data.contains(where: { $0 != 0 }) else { return nil }
        let canonical = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return value == canonical ? data : nil
    }

    private static func validInvitation(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix), value.utf8.count <= maximumHandshakeBytes - 1024 else { return false }
        let body = value.dropFirst(prefix.count)
        return !body.isEmpty && body.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0)
        }
    }
    private static func validSTUNURL(_ value: String) -> Bool {
        guard value.hasPrefix("stun:"), value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let url = URLComponents(string: "udp://" + value.dropFirst(5)),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.path.isEmpty, url.query == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else { return false }
        return true
    }
}

private struct HelperPacket {
    let kind: UInt8
    let payload: Data
    func encoded() -> Data {
        let size = UInt32(payload.count)
        var data = Data([kind, UInt8(truncatingIfNeeded: size >> 24), UInt8(truncatingIfNeeded: size >> 16), UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size)])
        data.append(payload)
        return data
    }
}

/// Owns only this peer's helper and pipe descriptors. Nonblocking reads/writes
/// allow shutdown even if the helper stops consuming input or producing output.
private final class HelperRuntime {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let reader = DispatchQueue(label: "FarReach.webrtc.stdout", qos: .userInteractive)
    private let writer = DispatchQueue(label: "FarReach.webrtc.stdin", qos: .userInteractive)
    private let cleanup = DispatchQueue(label: "FarReach.webrtc.cleanup")
    private let workers = DispatchGroup()
    private let lock = NSLock()
    private var cancelled = false
    private var launched = false
    private struct PendingWrite { let data: Data; let completion: (Error?) -> Void }
    private struct PendingMedia {
        let data: Data
        let transfer: UInt64
        var offset: Int
        let completion: (Error?) -> Void
    }
    private var controls: [PendingWrite] = []
    private var controlBytes = 0
    private var media: PendingMedia?
    private var nextTransfer: UInt64 = 0
    private var draining = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    init(executable: URL) throws {
        process.executableURL = executable
        process.arguments = []
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        for descriptor in [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw WebRTCTransportError.helperUnavailable }
        }
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw WebRTCTransportError.helperUnavailable }
    }
    func launch() throws {
        // EOF on stdout is processed by the reader so a final 'closed' event is
        // not raced by the Process termination callback.
        try process.run()
        launched = true
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }
    func readPackets(_ receive: @escaping (HelperPacket) -> Bool, failure: @escaping (Error) -> Void) {
        workers.enter()
        reader.async { [self] in
            defer { workers.leave() }
            do {
                while !isCancelled {
                    let header = try readExactly(5)
                    let bytes = Array(header)
                    let length = Int(bytes[1]) << 24 | Int(bytes[2]) << 16 | Int(bytes[3]) << 8 | Int(bytes[4])
                    let limit: Int
                    if let kind = MessageKind(rawValue: bytes[0]) { limit = kind.maximumPayloadSize }
                    else if bytes[0] == 242 { limit = WebRTCPeer.maximumHandshakeBytes }
                    else if bytes[0] == MediaIPC.chunkKind { limit = MediaIPC.headerSize + MediaIPC.chunkSize }
                    else { throw WebRTCTransportError.malformedHelperOutput }
                    guard length <= limit else { throw WebRTCTransportError.malformedHelperOutput }
                    let payload = length == 0 ? Data() : try readExactly(length)
                    if !receive(HelperPacket(kind: bytes[0], payload: payload)) { return }
                }
            } catch { if !isCancelled { failure(error) } }
        }
    }
    func write(_ data: Data, completion: @escaping (Error?) -> Void) {
        lock.lock()
        guard !cancelled else { lock.unlock(); completion(WebRTCTransportError.closed); return }
        guard controls.count < 256, controlBytes + data.count <= 512 * 1024 else {
            lock.unlock(); completion(WebRTCTransportError.overloaded); return
        }
        controls.append(PendingWrite(data: data, completion: completion)); controlBytes += data.count
        startDrainLocked()
        lock.unlock()
    }

    func writeVideo(_ data: Data, completion: @escaping (Error?) -> Void) {
        lock.lock()
        guard !cancelled, media == nil else { lock.unlock(); completion(WebRTCTransportError.closed); return }
        nextTransfer &+= 1
        media = PendingMedia(data: data, transfer: nextTransfer, offset: 0, completion: completion)
        startDrainLocked()
        lock.unlock()
    }

    /// Cancels unsent chunks, not a partially written chunk. The next transfer
    /// starts at offset zero so the receiving assembler can discard its old tail.
    func cancelMedia() {
        lock.lock(); let discarded = media; media = nil; lock.unlock()
        discarded?.completion(nil)
    }

    private func startDrainLocked() {
        guard !draining else { return }
        draining = true
        workers.enter()
        writer.async { [self] in drain(); workers.leave() }
    }

    private func drain() {
        while true {
            lock.lock()
            if cancelled {
                let abandoned = controls; controls = []; controlBytes = 0
                let abandonedMedia = media; media = nil; draining = false
                lock.unlock()
                abandoned.forEach { $0.completion(WebRTCTransportError.closed) }
                abandonedMedia?.completion(WebRTCTransportError.closed)
                return
            }
            let data: Data
            var completion: ((Error?) -> Void)?
            if !controls.isEmpty {
                let next = controls.removeFirst(); controlBytes -= next.data.count
                data = next.data; completion = next.completion
            } else if var next = media {
                let payload = MediaIPC.chunk(next.data, transfer: next.transfer, offset: next.offset)
                next.offset += payload.count - MediaIPC.headerSize
                data = HelperPacket(kind: MediaIPC.chunkKind, payload: payload).encoded()
                if next.offset == next.data.count { media = nil; completion = next.completion }
                else { media = next }
            } else {
                draining = false; lock.unlock(); return
            }
            lock.unlock()
            do { try writeBytes(data); completion?(nil) }
            catch {
                completion?(error)
                lock.lock()
                let abandoned = controls; controls = []; controlBytes = 0
                let abandonedMedia = media; media = nil; draining = false
                lock.unlock()
                abandoned.forEach { $0.completion(error) }; abandonedMedia?.completion(error)
                return
            }
        }
    }

    private func writeBytes(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                guard !isCancelled else { throw WebRTCTransportError.closed }
                let count = Darwin.write(input.fileHandleForWriting.fileDescriptor, base.advanced(by: offset), raw.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    try wait(input.fileHandleForWriting.fileDescriptor, events: Int16(POLLOUT)); continue
                }
                throw WebRTCTransportError.helperUnavailable
            }
        }
    }
    func shutdown() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        lock.unlock()
        workers.notify(queue: cleanup) { [self] in
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        guard launched else { return }
        cleanup.asyncAfter(deadline: .now() + 0.3) { [self] in
            if process.isRunning { process.terminate() }
        }
        cleanup.asyncAfter(deadline: .now() + 1.3) { [self] in
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            process.terminationHandler = nil
        }
    }
    private func readExactly(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        try bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < count {
                guard !isCancelled else { throw WebRTCTransportError.closed }
                let size = Darwin.read(output.fileHandleForReading.fileDescriptor, base.advanced(by: offset), count - offset)
                if size > 0 { offset += size; continue }
                if size == 0 { throw WebRTCTransportError.helperUnavailable }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try wait(output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN))
                    continue
                }
                throw WebRTCTransportError.helperUnavailable
            }
        }
        return bytes
    }
    private func wait(_ descriptor: Int32, events: Int16) throws {
        var item = pollfd(fd: descriptor, events: events, revents: 0)
        while !isCancelled {
            let result = poll(&item, 1, 100)
            if result < 0 { if errno == EINTR { continue }; throw WebRTCTransportError.helperUnavailable }
            if result == 0 { continue }
            if item.revents & Int16(POLLNVAL | POLLERR) != 0 { throw WebRTCTransportError.helperUnavailable }
            if item.revents & Int16(events | Int16(POLLHUP)) != 0 { return }
        }
        throw WebRTCTransportError.closed
    }
    deinit {
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        if launched && process.isRunning { process.terminate() }
    }
}
