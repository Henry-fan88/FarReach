import Foundation
import Security
import Darwin

public enum RemoteProtocolError: LocalizedError, Equatable {
    case invalidInvitation
    case invalidKey
    case randomGenerationFailed
    case malformedFrame
    case frameTooLarge
    case timedOut
    case connectionClosed
    case busy
    case securityNegotiationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidInvitation: return "Use a complete FarReach invitation with a host, port, and pairing key."
        case .invalidKey: return "The pairing key must contain exactly 32 random bytes."
        case .randomGenerationFailed: return "macOS could not create a secure pairing key."
        case .malformedFrame: return "The remote computer sent an invalid protocol message."
        case .frameTooLarge: return "The remote message exceeds the size limit."
        case .timedOut: return "The connection timed out. Check the address, private network, and pairing key."
        case .connectionClosed: return "The remote computer disconnected."
        case .busy: return "This Mac already has a connected viewer."
        case .securityNegotiationFailed: return "The remote computer did not negotiate the required encrypted protocol."
        }
    }
}

/// The key is a bearer credential. Never log this value or persist it unprotected.
public struct PairingInvitation: Equatable {
    public let host: String
    public let port: UInt16
    public let key: Data

    public init(host: String, port: UInt16, key: Data) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.utf8.count <= 253, port > 0,
              !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              !host.contains(where: { "/?#@[]%".contains($0) }),
              host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:").contains($0) }),
              Self.isValidHost(host)
        else { throw RemoteProtocolError.invalidInvitation }
        guard key.count == 32 else { throw RemoteProtocolError.invalidKey }
        self.host = host
        self.port = port
        self.key = key
    }

    public init(string: String) throws {
        guard let url = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "remotemac", let rawHost = url.host,
              let port = url.port, (1...65535).contains(port),
              url.user == nil, url.password == nil, url.fragment == nil,
              url.path.isEmpty, let items = url.queryItems, items.count == 1,
              items[0].name == "key", let encoded = items[0].value,
              encoded.count == 43,
              encoded.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }),
              let key = Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=")
        else { throw RemoteProtocolError.invalidInvitation }
        // Foundation retains brackets for IPv6 URL hosts on some macOS versions.
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        try self.init(host: host, port: UInt16(port), key: key)
        guard self.key.base64URL == encoded else { throw RemoteProtocolError.invalidInvitation }
    }

    public var urlString: String {
        let authority = host.contains(":") ? "[\(host)]" : host
        return "remotemac://\(authority):\(port)?key=\(key.base64URL)"
    }

    public static func generateKey() throws -> Data {
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw RemoteProtocolError.randomGenerationFailed }
        return key
    }

    private static func isValidHost(_ host: String) -> Bool {
        if host.contains(":") {
            var address = in6_addr()
            return host.withCString { inet_pton(AF_INET6, $0, &address) } == 1
        }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            var address = in_addr()
            return host.withCString { inet_pton(AF_INET, $0, &address) } == 1
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" }
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Numeric host-side measurements only. Capture counters reset with capture
/// generations; no identity, address, screen content, or input is included.
public struct HostPerformanceSnapshot: Codable, Equatable, Sendable {
    public let softwareVersion: String?
    public let softwareBuild: String?
    public let elapsedSeconds: Double
    public let captureGeneration: UInt64
    public let captureAvailable: Bool
    public let captureWidth: Int
    public let captureHeight: Int
    public let configuredMaxDimension: Int
    public let configuredFPS: Int
    public let encoderBitrate: Int
    public let capturedFrames: UInt64
    public let encodedFrames: UInt64
    public let encodedKeyframes: UInt64
    public let skippedBeforeEncoding: UInt64
    public let encoderDroppedFrames: UInt64
    public let recoveryRequests: UInt64
    public let dataRateLimitSupported: Bool?
    public let targetBitrate: Int?
    public let estimatedBitrate: Int?
    public let queuedBytes: Int?
    public let queueMS: Double?
    public let packetsSent: UInt64?
    public let transportKeyframes: UInt64?
    public let framesDropped: UInt64?
    public let keyframeRequests: UInt64?
    public let admissionDroppedFrames: UInt64?
    public let dependencySuppressedFrames: UInt64?
    public let pacingDroppedEvents: UInt64?
    public let packetizationFailures: UInt64?

    public init(elapsedSeconds: Double, captureGeneration: UInt64, captureAvailable: Bool,
                captureWidth: Int, captureHeight: Int, configuredMaxDimension: Int, configuredFPS: Int,
                encoderBitrate: Int, capturedFrames: UInt64, encodedFrames: UInt64, encodedKeyframes: UInt64,
                skippedBeforeEncoding: UInt64, encoderDroppedFrames: UInt64, recoveryRequests: UInt64,
                dataRateLimitSupported: Bool? = nil, transport: TransportStatistics? = nil,
                softwareVersion: String? = nil, softwareBuild: String? = nil) {
        self.softwareVersion = softwareVersion; self.softwareBuild = softwareBuild
        self.elapsedSeconds = elapsedSeconds; self.captureGeneration = captureGeneration; self.captureAvailable = captureAvailable
        self.captureWidth = captureWidth; self.captureHeight = captureHeight; self.configuredMaxDimension = configuredMaxDimension
        self.configuredFPS = configuredFPS; self.encoderBitrate = encoderBitrate; self.capturedFrames = capturedFrames
        self.encodedFrames = encodedFrames; self.encodedKeyframes = encodedKeyframes; self.skippedBeforeEncoding = skippedBeforeEncoding
        self.encoderDroppedFrames = encoderDroppedFrames; self.recoveryRequests = recoveryRequests
        self.dataRateLimitSupported = dataRateLimitSupported
        targetBitrate = transport?.targetBitrate; estimatedBitrate = transport?.estimatedBitrate
        queuedBytes = transport?.queuedBytes; queueMS = transport?.queueMS
        packetsSent = transport?.packetsSent; transportKeyframes = transport?.keyframes; framesDropped = transport?.framesDropped
        keyframeRequests = transport?.keyframeRequests; admissionDroppedFrames = transport?.admissionDroppedFrames
        dependencySuppressedFrames = transport?.dependencySuppressedFrames; pacingDroppedEvents = transport?.pacingDroppedEvents
        packetizationFailures = transport?.packetizationFailures
    }

    public var isValid: Bool {
        Self.validVersion(softwareVersion) && Self.validVersion(softwareBuild) &&
        elapsedSeconds.isFinite && elapsedSeconds >= 0 &&
        (0...16384).contains(captureWidth) && (0...16384).contains(captureHeight) &&
        (1...16384).contains(configuredMaxDimension) && (1...120).contains(configuredFPS) &&
        (0...40_000_000).contains(encoderBitrate) &&
        (targetBitrate.map { (0...40_000_000).contains($0) } ?? true) &&
        (estimatedBitrate.map { (0...40_000_000).contains($0) } ?? true) &&
        (queuedBytes.map { (0...64 * 1024 * 1024).contains($0) } ?? true) &&
        (queueMS.map { $0.isFinite && (0...120_000).contains($0) } ?? true)
    }
    private static func validVersion(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [43, 45, 46, 95].contains($0)
        }
    }
}

public struct HostInfo: Codable, Equatable {
    public let protocolVersion: Int
    public let name: String
    public let width: Int
    public let height: Int
    public let pointWidth: Int
    public let pointHeight: Int
    public let fps: Int
    public let performance: HostPerformanceSnapshot?

    public init(name: String, width: Int, height: Int, pointWidth: Int? = nil, pointHeight: Int? = nil, fps: Int = 30,
                performance: HostPerformanceSnapshot? = nil) {
        self.protocolVersion = 1
        self.name = String(name.prefix(256))
        self.width = width
        self.height = height
        self.pointWidth = pointWidth ?? width
        self.pointHeight = pointHeight ?? height
        self.fps = fps
        self.performance = performance
    }

    public var isValid: Bool {
        protocolVersion == 1 && !name.isEmpty && name.count <= 256 &&
        (1...16384).contains(width) && (1...16384).contains(height) &&
        (1...16384).contains(pointWidth) && (1...16384).contains(pointHeight) &&
        (1...120).contains(fps) && (performance?.isValid ?? true)
    }
}

public enum MessageKind: UInt8, CaseIterable {
    case hello = 1
    case video = 2
    case input = 3
    case ping = 4
    case pong = 5
    case disconnect = 6
    case requestKeyframe = 7
    case pairing = 8
    case sessionControl = 9
    case streamState = 10
    case pointer = 11

    public var maximumPayloadSize: Int {
        switch self {
        case .video: return 16 * 1024 * 1024
        case .hello, .input, .pairing, .sessionControl, .streamState, .pointer: return 4096
        case .ping, .pong, .requestKeyframe: return 32
        case .disconnect: return 512
        }
    }
}

public struct WireMessage: Equatable {
    public let kind: MessageKind
    public let payload: Data

    public init(kind: MessageKind, payload: Data = Data()) {
        self.kind = kind
        self.payload = payload
    }

    public func encoded() throws -> Data {
        guard payload.count <= kind.maximumPayloadSize else { throw RemoteProtocolError.frameTooLarge }
        let length = UInt32(payload.count)
        var result = Data([kind.rawValue, UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16), UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)])
        result.append(payload)
        return result
    }

    public static func decodeHeader(_ data: Data) throws -> (kind: MessageKind, length: Int) {
        guard data.count == 5, let kind = MessageKind(rawValue: data[data.startIndex]) else { throw RemoteProtocolError.malformedFrame }
        let bytes = Array(data.dropFirst())
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard length <= kind.maximumPayloadSize else { throw RemoteProtocolError.frameTooLarge }
        return (kind, length)
    }
}
