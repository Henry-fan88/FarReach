import Foundation
import CoreMedia

public enum MediaError: LocalizedError {
    case invalidFrame(String)
    case codec(String, OSStatus)
    case noDisplay
    case stopped
    case needsKeyframe

    public var errorDescription: String? {
        switch self {
        case .invalidFrame(let reason): return "Invalid video frame: \(reason)"
        case .codec(let operation, let code): return "\(operation) failed (\(code))."
        case .noDisplay: return "No display is available for sharing."
        case .stopped: return "Screen sharing stopped."
        case .needsKeyframe: return "Waiting for a fresh video keyframe."
        }
    }
}

/// One complete H.264 access unit in AVCC format, with its parameter sets.
/// Framing is independent of the encrypted network transport.
public struct EncodedFrame: Sendable {
    public let width: UInt32
    public let height: UInt32
    public let isKeyframe: Bool
    public let sps: Data
    public let pps: Data
    public let payload: Data
    /// Monotonic times from the capture Mac, never wall-clock timestamps. They
    /// must not be subtracted from a different Mac's clock without calibration.
    public let frameID: UInt64
    public let captureTimeNanoseconds: UInt64
    public let encodedTimeNanoseconds: UInt64
    public static let maximumPayload = 12 * 1024 * 1024

    public init(width: UInt32, height: UInt32, isKeyframe: Bool, sps: Data, pps: Data, payload: Data,
                frameID: UInt64 = 0, captureTimeNanoseconds: UInt64 = 0, encodedTimeNanoseconds: UInt64 = 0) throws {
        guard (2...8192).contains(width), (2...8192).contains(height),
              !sps.isEmpty, sps.count <= 65536, !pps.isEmpty, pps.count <= 65536,
              !payload.isEmpty, payload.count <= Self.maximumPayload else {
            throw MediaError.invalidFrame("dimensions or lengths are outside the supported limits")
        }
        // Validate every NAL length before handing data to the platform decoder.
        var offset = 0
        while offset < payload.count {
            guard payload.count - offset >= 4 else { throw MediaError.invalidFrame("truncated NAL length") }
            let length = Int(Self.uint32(payload, offset))
            offset += 4
            guard length > 0, length <= payload.count - offset else { throw MediaError.invalidFrame("invalid NAL length") }
            offset += length
        }
        self.width = width; self.height = height; self.isKeyframe = isKeyframe
        self.sps = sps; self.pps = pps; self.payload = payload
        self.frameID = frameID
        self.captureTimeNanoseconds = captureTimeNanoseconds
        self.encodedTimeNanoseconds = encodedTimeNanoseconds
    }

    public func serialized() throws -> Data {
        var result = Data("FRV2".utf8)
        for value in [width, height] { Self.append(value, to: &result) }
        result.append(isKeyframe ? 1 : 0)
        for value in [sps.count, pps.count, payload.count] { Self.append(UInt32(value), to: &result) }
        for value in [frameID, captureTimeNanoseconds, encodedTimeNanoseconds] {
            for shift in stride(from: 56, through: 0, by: -8) { result.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        result.append(sps); result.append(pps); result.append(payload)
        return result
    }

    public init(data: Data) throws {
        let version2 = data.prefix(4) == Data("FRV2".utf8)
        let headerLength = version2 ? 49 : 25
        guard data.count >= headerLength, version2 || data.prefix(4) == Data("FRV1".utf8), data[data.startIndex + 12] <= 1 else {
            throw MediaError.invalidFrame("unsupported header")
        }
        let spsCount = Int(Self.uint32(data, 13)), ppsCount = Int(Self.uint32(data, 17)), payloadCount = Int(Self.uint32(data, 21))
        guard spsCount <= 65536, ppsCount <= 65536, payloadCount <= Self.maximumPayload,
              headerLength + spsCount + ppsCount + payloadCount == data.count else { throw MediaError.invalidFrame("invalid frame length") }
        let start = data.startIndex + headerLength
        try self.init(width: Self.uint32(data, 4), height: Self.uint32(data, 8), isKeyframe: data[data.startIndex + 12] == 1,
                      sps: Data(data[start..<(start + spsCount)]),
                      pps: Data(data[(start + spsCount)..<(start + spsCount + ppsCount)]),
                      payload: Data(data[(start + spsCount + ppsCount)...]),
                      frameID: version2 ? Self.uint64(data, 25) : 0,
                      captureTimeNanoseconds: version2 ? Self.uint64(data, 33) : 0,
                      encodedTimeNanoseconds: version2 ? Self.uint64(data, 41) : 0)
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return (UInt32(data[i]) << 24) | (UInt32(data[i + 1]) << 16) | (UInt32(data[i + 2]) << 8) | UInt32(data[i + 3])
    }
    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    private static func uint64(_ data: Data, _ offset: Int) -> UInt64 {
        data.dropFirst(offset).prefix(8).reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
