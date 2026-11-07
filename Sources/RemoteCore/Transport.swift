import Foundation
import Network
import Security

private enum SecureParameters {
    static func make(key: Data) throws -> NWParameters {
        guard key.count == 32 else { throw RemoteProtocolError.invalidKey }
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        let identity = Data("FarReach-v1".utf8)
        let dispatchKey = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let dispatchIdentity = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(security, dispatchKey as __DispatchData, dispatchIdentity as __DispatchData)
        // Pin a single authenticated PSK suite. There are no certificate exceptions,
        // anonymous suites, plaintext mode, or opportunistic encryption fallback.
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(security, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_add_tls_application_protocol(security, "farreach/1")
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 3
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}

/// An authenticated TLS-PSK connection. All callbacks run on callbackQueue.
/// Set callbacks before start(), or inside SecureListener.onConnection for accepted peers.
public final class SecurePeer {
    public var onReady: (() -> Void)?
    public var onMessage: ((WireMessage) -> Void)?
    public var onClose: ((Error?) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var started = false
    private var ready = false
    private var binding: Data?
    private var closed = false
    private var pendingVideo = false
    private var pendingControlBytes = 0
    private var handshakeTimeout: DispatchWorkItem?
    private var readTimeout: DispatchWorkItem?
    fileprivate var internalReady: (() -> Bool)?
    fileprivate var internalClose: (() -> Void)?

    public init(host: String, port: UInt16, key: Data, callbackQueue: DispatchQueue = .main) throws {
        guard !host.isEmpty, let port = NWEndpoint.Port(rawValue: port), port.rawValue > 0 else { throw RemoteProtocolError.invalidInvitation }
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: try SecureParameters.make(key: key))
        self.queue = DispatchQueue(label: "app.farreach.peer.\(UUID().uuidString)", qos: .userInteractive)
        self.callbackQueue = callbackQueue
        queue.setSpecific(key: queueKey, value: 1)
    }

    fileprivate init(connection: NWConnection, callbackQueue: DispatchQueue) {
        self.connection = connection
        self.queue = DispatchQueue(label: "app.farreach.accepted.\(UUID().uuidString)", qos: .userInteractive)
        self.callbackQueue = callbackQueue
        queue.setSpecific(key: queueKey, value: 1)
    }

    public var channelBinding: Data? {
        let value = { [self] in ready && !closed ? binding : nil }
        if DispatchQueue.getSpecific(key: queueKey) != nil { return value() }
        return queue.sync(execute: value)
    }

    public func start() {
        queue.async { [self] in
            guard !started, !closed else { return }
            started = true
            connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
            let timeout = DispatchWorkItem { [weak self] in self?.finish(RemoteProtocolError.timedOut) }
            handshakeTimeout = timeout
            queue.asyncAfter(deadline: .now() + 10, execute: timeout)
            connection.start(queue: queue)
        }
    }

    /// Video admission is limited to one unconsumed send. false means the caller
    /// must discard that frame and request an encoder keyframe before resuming.
    /// Control traffic is bounded to 64 KiB; an overloaded connection closes.
    @discardableResult public func send(_ message: WireMessage) -> Bool {
        let body: () -> Bool = { [self] in
            guard ready, !closed else { return false }
            guard message.payload.count <= message.kind.maximumPayloadSize else {
                finish(RemoteProtocolError.frameTooLarge)
                return false
            }
            let isVideo = message.kind == .video
            if isVideo && pendingVideo { return false }
            if !isVideo && pendingControlBytes + message.payload.count + 5 > 65536 {
                finish(RemoteProtocolError.busy)
                return false
            }
            guard let data = try? message.encoded() else { return false }
            if isVideo { pendingVideo = true } else { pendingControlBytes += data.count }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if isVideo { self.pendingVideo = false } else { self.pendingControlBytes -= data.count }
                if let error { self.finish(error) }
            })
            return true
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { return body() }
        return queue.sync(execute: body)
    }

    // Retain until cancellation is submitted: session owners normally clear their
    // last peer reference immediately after calling close().
    public func close() { queue.async { [self] in finish(nil) } }

    deinit { connection.cancel() }

    private func handle(_ state: NWConnection.State) {
        guard !closed else { return }
        switch state {
        case .ready:
            handshakeTimeout?.cancel()
            handshakeTimeout = nil
            guard let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
                  sec_protocol_metadata_get_negotiated_tls_protocol_version(tls.securityProtocolMetadata) == .TLSv12,
                  sec_protocol_metadata_get_negotiated_tls_ciphersuite(tls.securityProtocolMetadata).rawValue == TLS_PSK_WITH_AES_128_GCM_SHA256 else {
                finish(RemoteProtocolError.securityNegotiationFailed)
                return
            }
            let label = "farreach-device-binding-v1"
            guard let exported = label.withCString({ sec_protocol_metadata_create_secret(tls.securityProtocolMetadata, label.utf8.count, $0, 32) }) else {
                finish(RemoteProtocolError.securityNegotiationFailed)
                return
            }
            let secret = Data(exported as DispatchData)
            guard secret.count == 32, secret.contains(where: { $0 != 0 }) else {
                finish(RemoteProtocolError.securityNegotiationFailed)
                return
            }
            binding = secret
            guard internalReady?() ?? true else { finish(RemoteProtocolError.busy); return }
            ready = true
            callbackQueue.async { [weak self] in
                guard let self else { return }
                guard self.queue.sync(execute: { self.ready && !self.closed }) else { return }
                self.onReady?()
                // Let an accepted connection's owner install handlers first.
                self.queue.async { [weak self] in self?.receiveHeader() }
            }
        case .failed(let error): finish(error)
        case .waiting(let error):
            // Established input sessions must not linger while the route is gone.
            if ready { finish(error) }
        case .cancelled: finish(nil)
        default: break
        }
    }

    private func receiveHeader() {
        guard !closed else { return }
        // Idle connections are valid. A deadline starts only after the first
        // header byte arrives; partially delivered messages cannot hold memory forever.
        receiveExactly(count: 5, buffer: Data(), readingHeader: true) { [weak self] header in
            guard let self else { return }
            do {
                let (kind, length) = try WireMessage.decodeHeader(header)
                if length == 0 { self.deliver(WireMessage(kind: kind)); return }
                self.armReadTimeout()
                self.receiveExactly(count: length, buffer: Data(), readingHeader: false) { [weak self] data in
                    self?.deliver(WireMessage(kind: kind, payload: data))
                }
            } catch { self.finish(error) }
        }
    }

    private func receiveExactly(count: Int, buffer: Data, readingHeader: Bool, completion: @escaping (Data) -> Void) {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: count - buffer.count) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let error { self.finish(error); return }
            guard let data, !data.isEmpty else {
                self.finish(RemoteProtocolError.connectionClosed)
                return
            }
            if readingHeader && buffer.isEmpty { self.armReadTimeout() }
            var combined = buffer
            combined.append(data)
            if combined.count == count { completion(combined) }
            else if complete { self.finish(RemoteProtocolError.connectionClosed) }
            else { self.receiveExactly(count: count, buffer: combined, readingHeader: readingHeader, completion: completion) }
        }
    }

    private func armReadTimeout() {
        readTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.finish(RemoteProtocolError.timedOut) }
        readTimeout = timeout
        queue.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    private func deliver(_ message: WireMessage) {
        readTimeout?.cancel()
        readTimeout = nil
        callbackQueue.async { [weak self] in
            guard let self else { return }
            guard self.queue.sync(execute: { self.ready && !self.closed }) else { return }
            self.onMessage?(message)
            // Backpressure reaches the socket instead of building an unbounded
            // dispatch queue of decoded frames waiting on the UI.
            self.queue.async { [weak self] in self?.receiveHeader() }
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        ready = false
        binding = nil
        handshakeTimeout?.cancel()
        readTimeout?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        internalClose?()
        internalClose = nil
        callbackQueue.async { [self] in onClose?(error) }
    }
}

/// One viewer per host. Pending TLS handshakes are capped at four and expire
/// after ten seconds. The listener starts only when start() is explicitly called.
public final class SecureListener {
    public var onReady: ((UInt16) -> Void)?
    public var onConnection: ((SecurePeer) -> Void)?
    public var onError: ((Error) -> Void)?

    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.farreach.listener", qos: .userInteractive)
    private let callbackQueue: DispatchQueue
    private var peers: [UUID: SecurePeer] = [:]
    private var active: UUID?
    private var stopped = false
    private var started = false

    public init(key: Data, port: UInt16 = 9877, callbackQueue: DispatchQueue = .main) throws {
        let parameters = try SecureParameters.make(key: key)
        self.listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.callbackQueue = callbackQueue
    }

    public func start() {
        queue.async { [self] in
            guard !started, !stopped else { return }
            started = true
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.stopped else { return }
                switch state {
                case .ready:
                    if let port = self.listener.port {
                        self.callbackQueue.async { [weak self] in self?.onReady?(port.rawValue) }
                    }
                case .failed(let error):
                    self.callbackQueue.async { [weak self] in self?.onError?(error) }
                    self.stop()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            for peer in peers.values { peer.close() }
            peers.removeAll()
            active = nil
        }
    }

    deinit {
        listener.cancel()
        for peer in peers.values { peer.close() }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, active == nil, peers.count < 4 else { connection.cancel(); return }
        let id = UUID()
        let peer = SecurePeer(connection: connection, callbackQueue: callbackQueue)
        peers[id] = peer
        peer.internalReady = { [weak self] in
            guard let self else { return false }
            return self.queue.sync {
                guard !self.stopped, self.active == nil else { return false }
                self.active = id
                return true
            }
        }
        peer.onReady = { [weak self, weak peer] in
            guard let self, let peer else { return }
            guard self.queue.sync(execute: { !self.stopped && self.active == id }) else { peer.close(); return }
            self.onConnection?(peer)
        }
        peer.internalClose = { [weak self] in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.peers.removeValue(forKey: id)
                if self.active == id { self.active = nil }
            }
        }
        peer.start()
    }
}
