import Foundation
import CryptoKit

public enum CloudSignalingError: LocalizedError, Equatable {
    case invalidEndpoint, invalidMessage, untrustedPeer, invalidProof, expiredMessage, replayedMessage
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Use an HTTPS signaling service address without credentials, a query, or a fragment."
        case .invalidMessage: return "The signaling service sent an invalid message."
        case .untrustedPeer: return "Pair this Mac before using cloud reconnection."
        case .invalidProof: return "The saved Mac’s signaling identity could not be verified."
        case .expiredMessage: return "The connection request expired. Try again and check both Macs’ clocks."
        case .replayedMessage: return "A repeated connection message was ignored."
        }
    }
}

/// Only connection negotiation travels here; desktop frames and input stay on
/// the authenticated direct transport. The encrypted body is never logged.
public struct CloudSignalMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case request, offer, answer, reject, cancel, close, closed, busy }
    public let kind: Kind
    public let attemptID: String
    public let expiresAt: Double
    public let body: String?
    public let sessionID: String?
    public init(kind: Kind, attemptID: String, expiresAt: Double = Date().timeIntervalSince1970 + 90, body: String? = nil, sessionID: String? = nil) {
        self.kind = kind; self.attemptID = attemptID; self.expiresAt = expiresAt; self.body = body; self.sessionID = sessionID
    }
    /// Legacy descriptions are authenticated and surfaced solely so the app can
    /// explain the required update. They must never reach the v2 transport.
    public var requiresTransportUpdate: Bool {
        switch kind {
        case .offer: return body?.hasPrefix("farreach-offer://v1/") == true
        case .answer: return body?.hasPrefix("farreach-answer://v1/") == true
        default: return false
        }
    }
    func validate(now: Double = Date().timeIntervalSince1970) throws {
        guard let identifier = UUID(uuidString: attemptID), identifier.uuidString == attemptID.uppercased(),
              expiresAt.isFinite else { throw CloudSignalingError.invalidMessage }
        guard expiresAt > now, expiresAt <= now + 120 else { throw CloudSignalingError.expiredMessage }
        if let sessionID, UUID(uuidString: sessionID) == nil { throw CloudSignalingError.invalidMessage }
        switch kind {
        case .offer, .answer:
            let scheme = kind == .offer ? "farreach-offer://" : "farreach-answer://"
            guard let body, let prefix = [scheme + "v2/", scheme + "v1/"].first(where: body.hasPrefix), body.utf8.count < 256 * 1024,
                  !body.dropFirst(prefix.count).isEmpty,
                  body.dropFirst(prefix.count).utf8.allSatisfy(Self.base64Character) else { throw CloudSignalingError.invalidMessage }
        case .request, .reject, .cancel, .busy:
            guard body == nil else { throw CloudSignalingError.invalidMessage }
        case .close, .closed:
            guard body == nil, sessionID != nil else { throw CloudSignalingError.invalidMessage }
        }
    }
    private static func base64Character(_ c: UInt8) -> Bool {
        (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) || c == 45 || c == 95
    }
}

struct SignalingPublicKeys: Codable, Equatable {
    let publicKey: String
    let agreementKey: String
    let keySignature: String
}

/// Public-key proof is checked against the locally saved signing identity, so
/// the service cannot substitute an agreement key and read offer/answer secrets.
struct SignalingCryptography {
    static let maximumEnvelopeBytes = 400 * 1024
    let identity: DeviceIdentity
    private let agreement: Curve25519.KeyAgreement.PrivateKey
    let publicKeys: SignalingPublicKeys

    init(identity: DeviceIdentity) throws {
        self.identity = identity
        agreement = try identity.signalingAgreementKey()
        let agreementBytes = agreement.publicKey.rawRepresentation
        var proof = Data("FarReach-signaling-key-v1\0".utf8); proof.append(agreementBytes)
        publicKeys = SignalingPublicKeys(publicKey: identity.publicKey.signalingBase64URL,
            agreementKey: agreementBytes.signalingBase64URL,
            keySignature: try identity.signalingSignature(for: proof).signalingBase64URL)
    }

    func authentication(nonce: String, peers: [String]) throws -> Data {
        guard let challenge = Data(signalingBase64URL: nonce, count: 32), peers.count <= 64 else { throw CloudSignalingError.invalidMessage }
        var proof = Data("FarReach-signaling-auth-v1\0".utf8)
        proof.append(challenge); proof.append(agreement.publicKey.rawRepresentation)
        return try JSONSerialization.data(withJSONObject: [
            "type": "authenticate", "publicKey": publicKeys.publicKey,
            "agreementKey": publicKeys.agreementKey, "keySignature": publicKeys.keySignature,
            "signature": try identity.signalingSignature(for: proof).signalingBase64URL, "peers": peers
        ])
    }

    func encrypt(_ message: CloudSignalMessage, to peer: PairedDevice, keys: SignalingPublicKeys,
                 now: Double = Date().timeIntervalSince1970) throws -> String {
        try message.validate(now: now)
        let symmetric = try sharedKey(peer: peer, keys: keys)
        let bytes = try JSONEncoder().encode(message)
        let sealed = try AES.GCM.seal(bytes, using: symmetric, authenticating: aad(from: identity.id, to: peer.id))
        guard let combined = sealed.combined else { throw CloudSignalingError.invalidMessage }
        let encoded = combined.signalingBase64URL
        guard encoded.utf8.count <= Self.maximumEnvelopeBytes else { throw CloudSignalingError.invalidMessage }
        return encoded
    }

    func decrypt(_ payload: String, from peer: PairedDevice, keys: SignalingPublicKeys,
                 now: Double = Date().timeIntervalSince1970) throws -> CloudSignalMessage {
        guard payload.utf8.count <= Self.maximumEnvelopeBytes,
              let bytes = Data(signalingBase64URL: payload), bytes.count >= 28 else { throw CloudSignalingError.invalidMessage }
        let symmetric = try sharedKey(peer: peer, keys: keys)
        let sealed = try AES.GCM.SealedBox(combined: bytes)
        let clear = try AES.GCM.open(sealed, using: symmetric, authenticating: aad(from: peer.id, to: identity.id))
        let message = try JSONDecoder().decode(CloudSignalMessage.self, from: clear)
        try message.validate(now: now)
        return message
    }

    private func sharedKey(peer: PairedDevice, keys: SignalingPublicKeys) throws -> SymmetricKey {
        guard peer.isValid, peer.id != identity.id,
              let signingBytes = Data(signalingBase64URL: keys.publicKey, count: 32), signingBytes == peer.publicKey,
              let agreementBytes = Data(signalingBase64URL: keys.agreementKey, count: 32),
              let signature = Data(signalingBase64URL: keys.keySignature, count: 64) else { throw CloudSignalingError.untrustedPeer }
        var proof = Data("FarReach-signaling-key-v1\0".utf8); proof.append(agreementBytes)
        let signing = try Curve25519.Signing.PublicKey(rawRepresentation: signingBytes)
        guard signing.isValidSignature(signature, for: proof) else { throw CloudSignalingError.invalidProof }
        let other = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreementBytes)
        let secret = try agreement.sharedSecretFromKeyAgreement(with: other)
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self,
            salt: Data("FarReach-signaling-seal-v1".utf8),
            sharedInfo: Data([identity.id, peer.id].sorted().joined(separator: "\0").utf8), outputByteCount: 32)
    }
    private func aad(from: String, to: String) -> Data {
        Data("FarReach-signaling-message-v1\0\(from)\0\(to)".utf8)
    }
}

struct SignalingReplayWindow {
    private var entries: [String: Double] = [:]
    mutating func accept(_ message: CloudSignalMessage, from: String, now: Double = Date().timeIntervalSince1970) throws {
        try message.validate(now: now)
        entries = entries.filter { $0.value > now }
        let key = from + ":" + message.attemptID.lowercased() + ":" + message.kind.rawValue
        guard entries[key] == nil else { throw CloudSignalingError.replayedMessage }
        guard entries.count < 1024 else { throw CloudSignalingError.invalidMessage }
        entries[key] = message.expiresAt
    }
}

@MainActor public final class CloudSignalingClient {
    public var onStatus: ((String) -> Void)?
    public var onReady: (() -> Void)?
    public var onSignal: ((String, CloudSignalMessage) -> Void)?
    public var onError: ((String) -> Void)?
    public var onUnavailable: ((String) -> Void)?
    /// A failure can only cancel the negotiation that initiated this request.
    public var onAttemptUnavailable: ((String, String) -> Void)?
    public private(set) var isReady = false
    private let cryptography: SignalingCryptography
    private let socketURL: URL
    private let session: URLSession
    private var peers: [String: PairedDevice]
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var authenticationTask: Task<Void, Never>?
    private var running = false
    private var generation = UUID()
    private var retryCount = 0
    private var challengeReceived = false
    private var awaitingPong = false
    private var pending: [String: [CloudSignalMessage]] = [:]
    private var lookupIDs: [String: String] = [:]
    private var requests: [String: (peer: String, attempt: String, expiry: Double)] = [:]
    private var supportsCorrelation = false
    private var replay = SignalingReplayWindow()

    public init(identity: DeviceIdentity, endpoint: URL, peers: [PairedDevice]) throws {
        cryptography = try SignalingCryptography(identity: identity)
        socketURL = try Self.webSocketURL(endpoint: endpoint, deviceID: identity.id)
        self.peers = try Self.validatedPeers(peers, localID: identity.id)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    public static func webSocketURL(endpoint: URL, deviceID: String) throws -> URL {
        guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              Data(signalingBase64URL: deviceID, count: 32) != nil else { throw CloudSignalingError.invalidEndpoint }
        switch parts.scheme?.lowercased() {
        case "https", "wss": parts.scheme = "wss"
        case "http", "ws":
            guard ["127.0.0.1", "[::1]", "::1", "localhost"].contains(host.lowercased()) else { throw CloudSignalingError.invalidEndpoint }
            parts.scheme = "ws"
        default: throw CloudSignalingError.invalidEndpoint
        }
        guard parts.path.isEmpty || parts.path == "/" else { throw CloudSignalingError.invalidEndpoint }
        parts.path = "/v1/devices/" + deviceID
        guard let url = parts.url else { throw CloudSignalingError.invalidEndpoint }
        return url
    }

    public func start() {
        guard !running else { return }
        running = true; retryCount = 0; connect()
    }

    public func stop() {
        running = false
        tearDown()
        onStatus?("Cloud discovery is off")
    }

    /// Only a disconnected discovery socket is restarted. A path notification
    /// must never disrupt healthy signaling or an authenticated desktop path.
    public func networkBecameAvailable() {
        guard running, !isReady else { return }
        retryCount = 0
        connect()
    }

    public func cancelAttempt(_ attemptID: String) {
        for id in Array(pending.keys) {
            pending[id]?.removeAll { $0.attemptID == attemptID }
            if pending[id]?.isEmpty == true { pending.removeValue(forKey: id); lookupIDs.removeValue(forKey: id) }
        }
        requests = requests.filter { $0.value.attempt != attemptID }
    }

    public func updatePeers(_ devices: [PairedDevice]) {
        do {
            peers = try Self.validatedPeers(devices, localID: cryptography.identity.id)
            pending = pending.filter { peers[$0.key] != nil }
            if isReady { sendObject(["type": "peers", "peers": peers.keys.sorted()]) }
        } catch { onError?("Cloud discovery supports up to 64 saved Macs with valid identities.") }
    }

    @discardableResult public func send(_ message: CloudSignalMessage, to deviceID: String) -> Bool {
        prunePending()
        guard isReady, peers[deviceID] != nil,
              requests.count < 128, pending.values.reduce(0, { $0 + $1.count }) < 32 else { return false }
        do { try message.validate() } catch { onError?(error.localizedDescription); return false }
        let needsLookup = pending[deviceID] == nil
        pending[deviceID, default: []].append(message)
        if needsLookup {
            let requestID = UUID().uuidString
            lookupIDs[deviceID] = requestID
            var object: [String: Any] = ["type": "lookup", "to": deviceID]
            if supportsCorrelation { object["requestId"] = requestID }
            sendObject(object)
        }
        return true
    }

    private static func validatedPeers(_ values: [PairedDevice], localID: String) throws -> [String: PairedDevice] {
        guard values.count <= 64, values.allSatisfy({ $0.isValid && $0.id != localID }),
              Set(values.map(\.id)).count == values.count else { throw CloudSignalingError.untrustedPeer }
        return Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
    }

    private func connect() {
        guard running else { return }
        tearDown()
        let token = generation
        var request = URLRequest(url: socketURL)
        request.timeoutInterval = 30
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = SignalingCryptography.maximumEnvelopeBytes + 4096
        socket = task; task.resume()
        onStatus?("Connecting to cloud discovery…")
        authenticationTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
            guard let self, self.generation == token, !self.isReady else { return }
            self.connectionFailed(token: token)
        }
        receiveTask = Task { [weak self, weak task] in
            guard let task else { return }
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard let self, self.generation == token else { return }
                    try self.receive(message)
                }
            } catch {
                guard let self, self.generation == token else { return }
                self.connectionFailed(token: token)
            }
        }
    }

    private func receive(_ input: URLSessionWebSocketTask.Message) throws {
        let bytes: Data
        switch input {
        case .string(let value):
            if value == "pong" { awaitingPong = false; return }
            bytes = Data(value.utf8)
        case .data: throw CloudSignalingError.invalidMessage
        @unknown default: throw CloudSignalingError.invalidMessage
        }
        guard bytes.count <= SignalingCryptography.maximumEnvelopeBytes + 4096,
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let type = object["type"] as? String else { throw CloudSignalingError.invalidMessage }
        if type == "challenge" {
            guard !isReady, !challengeReceived, let nonce = object["nonce"] as? String else { throw CloudSignalingError.invalidMessage }
            challengeReceived = true
            sendData(try cryptography.authentication(nonce: nonce, peers: peers.keys.sorted()))
            return
        }
        if type == "ready" {
            guard challengeReceived, !isReady else { throw CloudSignalingError.invalidMessage }
            supportsCorrelation = (object["capabilities"] as? [String])?.contains("request-correlation-v1") == true
            isReady = true; retryCount = 0; authenticationTask?.cancel(); authenticationTask = nil
            onStatus?("Cloud discovery connected"); beginHeartbeat(); onReady?()
            return
        }
        guard isReady else { throw CloudSignalingError.invalidMessage }
        switch type {
        case "peer":
            guard let id = object["to"] as? String, let online = object["online"] as? Bool else { throw CloudSignalingError.invalidMessage }
            if supportsCorrelation, object["requestId"] as? String != lookupIDs[id] { return }
            guard let queued = pending.removeValue(forKey: id), let peer = peers[id] else { return }
            lookupIDs.removeValue(forKey: id)
            guard online else {
                onUnavailable?(id)
                if supportsCorrelation { for message in queued { onAttemptUnavailable?(id, message.attemptID) } }
                return
            }
            let keys = try Self.keys(object)
            do {
                for message in queued {
                    let payload = try cryptography.encrypt(message, to: peer, keys: keys)
                    let requestID = UUID().uuidString
                    var object: [String: Any] = ["type": "signal", "to": id, "payload": payload]
                    if supportsCorrelation {
                        object["requestId"] = requestID
                        requests[requestID] = (id, message.attemptID, message.expiresAt)
                    }
                    sendObject(object)
                }
            } catch {
                onError?("The saved Mac’s signaling identity or connection request could not be verified."); onUnavailable?(id)
                for message in queued { onAttemptUnavailable?(id, message.attemptID) }
            }
        case "signal":
            guard let id = object["from"] as? String, let payload = object["payload"] as? String else { throw CloudSignalingError.invalidMessage }
            guard let peer = peers[id] else { return }
            do {
                let clear = try cryptography.decrypt(payload, from: peer, keys: Self.keys(object))
                try replay.accept(clear, from: id)
                onSignal?(id, clear)
            } catch CloudSignalingError.replayedMessage { return }
            catch { onError?("An invalid or expired cloud connection message was ignored.") }
        case "error":
            if let id = object["to"] as? String, peers[id] != nil {
                if supportsCorrelation, let requestID = object["requestId"] as? String {
                    if lookupIDs[id] == requestID {
                        let queued = pending.removeValue(forKey: id) ?? []
                        lookupIDs.removeValue(forKey: id)
                        for message in queued { onAttemptUnavailable?(id, message.attemptID) }
                    } else if let request = requests.removeValue(forKey: requestID), request.peer == id {
                        onAttemptUnavailable?(id, request.attempt)
                    }
                }
                // Legacy service errors have no attempt identity. Inform status,
                // but never cancel a newer negotiation on ambiguous evidence.
                onUnavailable?(id)
            } else { onError?("Cloud discovery could not complete the request.") }
        case "sent":
            if let requestID = object["requestId"] as? String { requests.removeValue(forKey: requestID) }
        case "peers-updated": break
        default: throw CloudSignalingError.invalidMessage
        }
    }

    private static func keys(_ object: [String: Any]) throws -> SignalingPublicKeys {
        guard let publicKey = object["publicKey"] as? String, let agreementKey = object["agreementKey"] as? String,
              let signature = object["keySignature"] as? String else { throw CloudSignalingError.invalidMessage }
        return SignalingPublicKeys(publicKey: publicKey, agreementKey: agreementKey, keySignature: signature)
    }

    private func sendObject(_ object: [String: Any]) {
        do { sendData(try JSONSerialization.data(withJSONObject: object)) }
        catch { onError?("Cloud discovery could not encode the request.") }
    }
    private func sendData(_ bytes: Data) {
        guard let socket, let text = String(data: bytes, encoding: .utf8) else { return }
        let token = generation
        Task { [weak self, weak socket] in
            guard let socket else { return }
            do { try await socket.send(.string(text)) }
            catch { self?.connectionFailed(token: token) }
        }
    }
    private func beginHeartbeat() {
        let token = generation
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
                guard let self, self.generation == token, let socket = self.socket else { return }
                self.prunePending()
                guard !self.awaitingPong else { self.connectionFailed(token: token); return }
                self.awaitingPong = true
                do { try await socket.send(.string("ping")) }
                catch { self.connectionFailed(token: token); return }
            }
        }
    }
    private func prunePending() {
        let now = Date().timeIntervalSince1970
        requests = requests.filter { $0.value.expiry > now }
        var expired: [String] = []
        for (id, messages) in pending {
            let live = messages.filter { $0.expiresAt > now }
            if live.isEmpty {
                pending.removeValue(forKey: id); lookupIDs.removeValue(forKey: id); expired.append(id)
                for message in messages { onAttemptUnavailable?(id, message.attemptID) }
            }
            else { pending[id] = live }
        }
        for id in expired { onUnavailable?(id) }
    }
    private func connectionFailed(token: UUID) {
        guard running, generation == token else { return }
        let unavailable = pending
        let forwarded = Array(requests.values)
        tearDown()
        onStatus?("Cloud discovery unavailable · retrying")
        for (id, messages) in unavailable {
            onUnavailable?(id)
            for message in messages { onAttemptUnavailable?(id, message.attemptID) }
        }
        for request in forwarded { onAttemptUnavailable?(request.peer, request.attempt) }
        retryCount = min(retryCount + 1, 6)
        let delay = min(pow(2.0, Double(retryCount)), 60) + Double.random(in: 0...1)
        retryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            self?.connect()
        }
    }
    private func tearDown() {
        generation = UUID(); isReady = false; challengeReceived = false; awaitingPong = false
        receiveTask?.cancel(); receiveTask = nil
        retryTask?.cancel(); retryTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        authenticationTask?.cancel(); authenticationTask = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        pending.removeAll(); lookupIDs.removeAll(); requests.removeAll(); supportsCorrelation = false
    }
    deinit {
        receiveTask?.cancel(); retryTask?.cancel(); heartbeatTask?.cancel(); authenticationTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

extension Data {
    var signalingBase64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    init?(signalingBase64URL text: String, count: Int? = nil) {
        guard !text.isEmpty, text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              count.map({ text.utf8.count == ($0 * 8 + 5) / 6 }) ?? true else { return nil }
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - text.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), count.map({ data.count == $0 }) ?? true,
              data.signalingBase64URL == text else { return nil }
        self = data
    }
}
