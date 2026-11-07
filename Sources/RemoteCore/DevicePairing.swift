import Foundation
import CryptoKit
import Security

public enum DevicePairingError: LocalizedError, Equatable {
    case invalidIdentity
    case invalidDevice
    case invalidName
    case malformedMessage
    case wrongRole
    case selfPairing
    case unexpectedPeer
    case invalidSignature
    case duplicateMessage
    case randomGenerationFailed
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentity: return "The local device identity is invalid."
        case .invalidDevice: return "The saved device record is invalid."
        case .invalidName: return "Use a device name with 1–128 characters and no control characters."
        case .malformedMessage: return "The remote device sent an invalid pairing message."
        case .wrongRole: return "Both devices selected the same role, or the pairing roles changed."
        case .selfPairing: return "A device cannot pair with its own identity."
        case .unexpectedPeer: return "This connection does not match the saved device you selected."
        case .invalidSignature: return "The remote device could not prove its saved identity."
        case .duplicateMessage: return "The remote device repeated a pairing message."
        case .randomGenerationFailed: return "macOS could not create a fresh pairing challenge."
        case .keychain(let status): return "FarReach could not access its local Keychain data (error \(status)). Unlock the login Keychain or review this app’s Keychain access."
        }
    }
}

/// Stable Ed25519 device identity. This is not the user's macOS login credential.
/// Private material is intentionally not Codable or exposed as a public property.
public struct DeviceIdentity {
    private let key: Curve25519.Signing.PrivateKey
    public var publicKey: Data { key.publicKey.rawRepresentation }
    public var id: String { Self.identifier(for: publicKey) }

    public init() { key = Curve25519.Signing.PrivateKey() }
    public init(rawRepresentation: Data) throws {
        guard rawRepresentation.count == 32 else { throw DevicePairingError.invalidIdentity }
        do { key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation) }
        catch { throw DevicePairingError.invalidIdentity }
    }
    fileprivate var privateRepresentation: Data { key.rawRepresentation }
    fileprivate func signature(for message: Data) throws -> Data { try key.signature(for: message) }
    // Separate HKDF domain keeps the signaling agreement key independent from
    // the Ed25519 signing key. Private bytes never leave RemoteCore.
    func signalingAgreementKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key.rawRepresentation),
            salt: Data("FarReach-signaling-agreement-v1".utf8),
            info: Data("X25519 private key".utf8), outputByteCount: 32)
        return try derived.withUnsafeBytes { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data($0)) }
    }
    func signalingSignature(for data: Data) throws -> Data { try key.signature(for: data) }
    public static func identifier(for publicKey: Data) -> String { Data(SHA256.hash(data: publicKey)).pairingBase64URL }
}

public struct PairedDevice: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public let publicKey: Data
    public var lastSeen: Date

    public init(name: String, publicKey: Data, lastSeen: Date = Date()) throws {
        guard Self.validName(name) else { throw DevicePairingError.invalidName }
        guard publicKey.count == 32, (try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)) != nil,
              lastSeen.timeIntervalSinceReferenceDate.isFinite else { throw DevicePairingError.invalidDevice }
        self.id = DeviceIdentity.identifier(for: publicKey)
        self.name = name
        self.publicKey = publicKey
        self.lastSeen = lastSeen
    }
    public var isValid: Bool {
        publicKey.count == 32 && id == DeviceIdentity.identifier(for: publicKey)
            && Self.validName(name) && lastSeen.timeIntervalSinceReferenceDate.isFinite
    }
    fileprivate static func validName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 128
            && value.utf8.count <= 512 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    private enum CodingKeys: String, CodingKey { case id, name, publicKey, lastSeen }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let suppliedID = try container.decode(String.self, forKey: .id)
        try self.init(name: container.decode(String.self, forKey: .name),
                      publicKey: container.decode(Data.self, forKey: .publicKey),
                      lastSeen: container.decode(Date.self, forKey: .lastSeen))
        guard suppliedID == id else { throw DevicePairingError.invalidDevice }
    }
}

public protocol PairingStore: AnyObject {
    func loadOrCreateIdentity() throws -> DeviceIdentity
    func listDevices() throws -> [PairedDevice]
    func save(_ device: PairedDevice) throws
    func forget(id: String) throws
}

/// Used by tests and explicit temporary diagnostic sessions. No filesystem or
/// Keychain operations are performed by this implementation.
public final class InMemoryPairingStore: PairingStore {
    private let lock = NSLock()
    private var identity: DeviceIdentity?
    private var devices: [String: PairedDevice] = [:]
    public init(identity: DeviceIdentity? = nil) { self.identity = identity }
    public func loadOrCreateIdentity() throws -> DeviceIdentity {
        lock.lock(); defer { lock.unlock() }
        if let identity { return identity }
        let created = DeviceIdentity(); identity = created; return created
    }
    public func listDevices() throws -> [PairedDevice] {
        lock.lock(); defer { lock.unlock() }
        return Self.sorted(Array(devices.values))
    }
    public func save(_ device: PairedDevice) throws {
        guard device.isValid else { throw DevicePairingError.invalidDevice }
        lock.lock(); defer { lock.unlock() }
        devices[device.id] = device
    }
    public func forget(id: String) throws {
        guard Data(pairingBase64URL: id, count: 32) != nil else { throw DevicePairingError.invalidDevice }
        lock.lock(); defer { lock.unlock() }
        devices.removeValue(forKey: id)
    }
    fileprivate static func sorted(_ devices: [PairedDevice]) -> [PairedDevice] {
        devices.sorted {
            if $0.lastSeen != $1.lastSeen { return $0.lastSeen > $1.lastSeen }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id < $1.id
        }
    }
}

/// Explicit classic macOS login Keychain storage, usable by locally built apps.
/// This does not claim the data-protection Keychain's accessibility classes or
/// ThisDeviceOnly behavior. Items are not configured for iCloud synchronization.
/// A successfully loaded private identity is cached in memory while this store
/// lives; a locked Keychain can deny fresh reads or trust-record updates.
public final class KeychainPairingStore: PairingStore {
    private let namespace: String
    private let lock = NSLock()
    private var cachedIdentity: DeviceIdentity?
    public init(namespace: String = "org.farreach.mac.pairing.v1") { self.namespace = namespace }

    public func loadOrCreateIdentity() throws -> DeviceIdentity {
        lock.lock(); defer { lock.unlock() }
        try validateNamespace()
        if let cachedIdentity { return cachedIdentity }
        if let bytes = try read(service: namespace + ".identity", account: "local") {
            let identity = try DeviceIdentity(rawRepresentation: bytes)
            cachedIdentity = identity
            return identity
        }
        let identity = DeviceIdentity()
        let status = add(service: namespace + ".identity", account: "local", data: identity.privateRepresentation, label: "FarReach device identity")
        if status == errSecDuplicateItem {
            // A second process may have initialized the namespace concurrently.
            guard let bytes = try read(service: namespace + ".identity", account: "local") else { throw DevicePairingError.keychain(errSecItemNotFound) }
            let stored = try DeviceIdentity(rawRepresentation: bytes)
            cachedIdentity = stored
            return stored
        }
        guard status == errSecSuccess else { throw DevicePairingError.keychain(status) }
        cachedIdentity = identity
        return identity
    }

    public func listDevices() throws -> [PairedDevice] {
        lock.lock(); defer { lock.unlock() }
        try validateNamespace()
        var query = base(service: namespace + ".devices")
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        // The classic login Keychain does not support requesting every item's
        // secret data in the same match-all query. Enumerate accounts first,
        // then read only each exact account with matchLimitOne.
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw DevicePairingError.keychain(status) }
        guard let items = result as? [[String: Any]] else { throw DevicePairingError.invalidDevice }
        let devices = try items.map { item -> PairedDevice in
            guard let account = item[kSecAttrAccount as String] as? String,
                  Data(pairingBase64URL: account, count: 32) != nil,
                  let bytes = try read(service: namespace + ".devices", account: account), bytes.count <= 4096 else { throw DevicePairingError.invalidDevice }
            let device = try JSONDecoder().decode(PairedDevice.self, from: bytes)
            guard device.id == account, device.isValid else { throw DevicePairingError.invalidDevice }
            return device
        }
        return InMemoryPairingStore.sorted(devices)
    }

    public func save(_ device: PairedDevice) throws {
        guard device.isValid else { throw DevicePairingError.invalidDevice }
        let bytes = try JSONEncoder().encode(device)
        guard bytes.count <= 4096 else { throw DevicePairingError.invalidDevice }
        lock.lock(); defer { lock.unlock() }
        try validateNamespace()
        let service = namespace + ".devices"
        let status = add(service: service, account: device.id, data: bytes, label: "FarReach paired device")
        if status == errSecDuplicateItem {
            var query = base(service: service)
            query[kSecAttrAccount as String] = device.id
            let update = [kSecValueData as String: bytes] as CFDictionary
            let updated = SecItemUpdate(query as CFDictionary, update)
            guard updated == errSecSuccess else { throw DevicePairingError.keychain(updated) }
        } else if status != errSecSuccess { throw DevicePairingError.keychain(status) }
    }

    public func forget(id: String) throws {
        guard Data(pairingBase64URL: id, count: 32) != nil else { throw DevicePairingError.invalidDevice }
        lock.lock(); defer { lock.unlock() }
        try validateNamespace()
        var query = base(service: namespace + ".devices")
        query[kSecAttrAccount as String] = id
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DevicePairingError.keychain(status) }
    }

    private func validateNamespace() throws {
        guard !namespace.isEmpty, namespace.utf8.count <= 200,
              !namespace.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw DevicePairingError.invalidDevice }
    }
    private func base(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecUseDataProtectionKeychain as String: false]
    }
    private func read(service: String, account: String) throws -> Data? {
        var query = base(service: service)
        query[kSecAttrAccount as String] = account
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw DevicePairingError.keychain(status) }
        guard let bytes = result as? Data, bytes.count <= 4096 else { throw DevicePairingError.invalidIdentity }
        return bytes
    }
    private func add(service: String, account: String, data: Data, label: String) -> OSStatus {
        var query = base(service: service)
        query[kSecAttrAccount as String] = account
        query[kSecValueData as String] = data
        query[kSecAttrLabel as String] = label
        return SecItemAdd(query as CFDictionary, nil)
    }
}

public enum PairingRole: String, Codable, Sendable { case host, viewer }

/// Mutual persistent-device authentication bound to the authenticated transport.
/// The caller supplies the real TLS exporter or authenticated offer/answer SDP
/// binding from RemotePeer. It establishes identity, not a reachable address.
/// Call all methods on one queue; callbacks are synchronous and reentrant-safe.
/// The owner must enforce its handshake timeout and decide whether to save trust.
public final class PairingHandshake {
    public var onSend: ((WireMessage) -> Void)?
    public var onAuthenticated: ((PairedDevice) -> Void)?
    public var onFailure: ((Error) -> Void)?
    public var isAuthenticated: Bool { state == .authenticated }
    public private(set) var authenticatedPeer: PairedDevice?

    private enum State { case idle, running, authenticated, failed, cancelled }
    private let identity: DeviceIdentity
    private let role: PairingRole
    private let expectedPeerID: String?
    private let channelBinding: Data
    private let local: Hello
    private var remote: Hello?
    private var earlyProof: Proof?
    private var state = State.idle
    private var sentHello = false
    private var sentProof = false
    private var verifiedProof = false

    private struct Header: Decodable { let version: Int; let type: String }
    private struct Hello: Codable {
        let version: Int
        let type: String
        let role: PairingRole
        let id: String
        let name: String
        let publicKey: String
        let nonce: String
    }
    private struct Proof: Codable {
        let version: Int
        let type: String
        let role: PairingRole
        let signature: String
    }

    public init(identity: DeviceIdentity, localName: String, role: PairingRole, channelBinding: Data, expectedPeerID: String? = nil) throws {
        guard channelBinding.count == 32, channelBinding.contains(where: { $0 != 0 }) else { throw DevicePairingError.invalidIdentity }
        guard PairedDevice.validName(localName) else { throw DevicePairingError.invalidName }
        if let expectedPeerID, Data(pairingBase64URL: expectedPeerID, count: 32) == nil { throw DevicePairingError.invalidDevice }
        var nonce = Data(count: 32)
        let result = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard result == errSecSuccess else { throw DevicePairingError.randomGenerationFailed }
        self.identity = identity
        self.role = role
        self.expectedPeerID = expectedPeerID
        self.channelBinding = channelBinding
        self.local = Hello(version: 1, type: "hello", role: role, id: identity.id, name: localName,
                           publicKey: identity.publicKey.pairingBase64URL, nonce: nonce.pairingBase64URL)
    }

    public func start() {
        guard state == .idle else { return }
        state = .running
        do {
            let payload = try Self.encode(local)
            sentHello = true // Set before a synchronous transport can call back.
            onSend?(WireMessage(kind: .pairing, payload: payload))
            try advance()
        } catch { fail(error) }
    }

    public func receive(_ data: Data) {
        guard state != .failed, state != .cancelled else { return }
        guard state != .authenticated else { fail(DevicePairingError.duplicateMessage); return }
        do {
            guard data.count <= MessageKind.pairing.maximumPayloadSize,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DevicePairingError.malformedMessage }
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard header.version == 1 else { throw DevicePairingError.malformedMessage }
            switch header.type {
            case "hello":
                guard Set(object.keys) == Set(["version", "type", "role", "id", "name", "publicKey", "nonce"]), remote == nil else { throw DevicePairingError.duplicateMessage }
                let hello = try JSONDecoder().decode(Hello.self, from: data)
                guard hello.role != role else { throw DevicePairingError.wrongRole }
                guard let key = Data(pairingBase64URL: hello.publicKey, count: 32),
                      Data(pairingBase64URL: hello.nonce, count: 32) != nil,
                      hello.id == DeviceIdentity.identifier(for: key), PairedDevice.validName(hello.name),
                      (try? Curve25519.Signing.PublicKey(rawRepresentation: key)) != nil else { throw DevicePairingError.malformedMessage }
                guard hello.id != identity.id else { throw DevicePairingError.selfPairing }
                if let expectedPeerID, hello.id != expectedPeerID { throw DevicePairingError.unexpectedPeer }
                remote = hello
            case "proof":
                guard Set(object.keys) == Set(["version", "type", "role", "signature"]), earlyProof == nil, !verifiedProof else { throw DevicePairingError.duplicateMessage }
                let proof = try JSONDecoder().decode(Proof.self, from: data)
                guard proof.role != role else { throw DevicePairingError.wrongRole }
                guard Data(pairingBase64URL: proof.signature, count: 64) != nil else { throw DevicePairingError.malformedMessage }
                earlyProof = proof
            default: throw DevicePairingError.malformedMessage
            }
            try advance()
        } catch { fail(error as? DevicePairingError ?? DevicePairingError.malformedMessage) }
    }

    public func cancel() {
        state = .cancelled
        remote = nil; earlyProof = nil; authenticatedPeer = nil
    }

    private func advance() throws {
        guard state == .running, sentHello, let remote else { return }
        if let proof = earlyProof {
            guard let signature = Data(pairingBase64URL: proof.signature, count: 64),
                  let bytes = Data(pairingBase64URL: remote.publicKey, count: 32) else { throw DevicePairingError.malformedMessage }
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: bytes)
            guard key.isValidSignature(signature, for: transcript(signer: remote.role)) else { throw DevicePairingError.invalidSignature }
            verifiedProof = true; earlyProof = nil
        }
        if !sentProof {
            let signature = try identity.signature(for: transcript(signer: role))
            let proof = Proof(version: 1, type: "proof", role: role, signature: signature.pairingBase64URL)
            let payload = try Self.encode(proof)
            sentProof = true
            onSend?(WireMessage(kind: .pairing, payload: payload))
        }
        guard state == .running, sentProof, verifiedProof,
              let publicKey = Data(pairingBase64URL: remote.publicKey, count: 32) else { return }
        let device = try PairedDevice(name: remote.name, publicKey: publicKey)
        state = .authenticated
        authenticatedPeer = device
        onAuthenticated?(device)
    }

    private func transcript(signer: PairingRole) -> Data {
        // Fixed-width keys/nonces and explicit roles avoid ambiguous transcript
        // encodings, cross-role reflection, and proof replay into a fresh session.
        let host = role == .host ? local : remote!
        let viewer = role == .viewer ? local : remote!
        var result = Data("FarReach-device-proof-v1\0".utf8)
        result.append(signer == .host ? 1 : 2)
        result.append(channelBinding)
        result.append(Data(pairingBase64URL: host.publicKey, count: 32)!)
        result.append(Data(pairingBase64URL: viewer.publicKey, count: 32)!)
        result.append(Data(pairingBase64URL: host.nonce, count: 32)!)
        result.append(Data(pairingBase64URL: viewer.nonce, count: 32)!)
        return result
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= MessageKind.pairing.maximumPayloadSize else { throw DevicePairingError.malformedMessage }
        return data
    }
    private func fail(_ error: Error) {
        guard state != .failed, state != .cancelled else { return }
        state = .failed
        remote = nil; earlyProof = nil; authenticatedPeer = nil
        onFailure?(error)
    }
}

private extension Data {
    var pairingBase64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    init?(pairingBase64URL text: String, count: Int) {
        guard text.utf8.count == (count * 8 + 5) / 6,
              text.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }) else { return nil }
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let bytes = Data(base64Encoded: padded), bytes.count == count, bytes.pairingBase64URL == text else { return nil }
        self = bytes
    }
}
