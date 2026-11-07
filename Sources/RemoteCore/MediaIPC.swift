import Foundation

/// Local helper v2 framing. Transfer IDs are local counters, never device IDs.
/// Small chunks let input and session messages interrupt a large video write.
enum MediaIPC {
    static let chunkKind: UInt8 = 243
    static let authorizationKind: UInt8 = 244
    static let chunkSize = 16 * 1024
    static let headerSize = 16

    static func chunk(_ data: Data, transfer: UInt64, offset: Int) -> Data {
        var result = Data()
        append(transfer, bytes: 8, to: &result)
        append(UInt64(data.count), bytes: 4, to: &result)
        append(UInt64(offset), bytes: 4, to: &result)
        result.append(data.subdata(in: offset..<min(data.count, offset + chunkSize)))
        return result
    }

    static func generation(_ data: Data) -> UInt64? {
        guard data.count >= 37, data.prefix(4) == Data("FRS1".utf8) else { return nil }
        return integer(data, at: 4, bytes: 8)
    }

    static func isKeyframe(_ data: Data) -> Bool {
        let offset = data.prefix(4) == Data("FRS1".utf8) ? 12 : 0
        guard data.count >= offset + 25 else { return false }
        return data[data.startIndex + offset + 12] == 1
    }

    static func integer(_ data: Data, at offset: Int, bytes: Int) -> UInt64 {
        data[(data.startIndex + offset)..<(data.startIndex + offset + bytes)].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func append(_ value: UInt64, bytes: Int, to data: inout Data) {
        for shift in stride(from: (bytes - 1) * 8, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}

/// Strictly ordered local pipe assembly, bounded to one frame and one second.
/// Network reordering is handled in Go, never by this local framing layer.
struct MediaIPCAssembler {
    private var transfer: UInt64?
    private var total = 0
    private var bytes = Data()
    private var started: TimeInterval = 0
    var pendingBytes: Int { bytes.count }

    mutating func reset() { transfer = nil; total = 0; bytes = Data(); started = 0 }

    mutating func expire(now: TimeInterval) -> Bool {
        guard transfer != nil, now - started > 1 else { return false }
        reset(); return true
    }

    mutating func push(_ packet: Data, now: TimeInterval) throws -> (frame: Data?, dropped: Bool) {
        var dropped = expire(now: now)
        guard packet.count > MediaIPC.headerSize, packet.count <= MediaIPC.headerSize + MediaIPC.chunkSize else {
            throw WebRTCTransportError.malformedHelperOutput
        }
        let id = MediaIPC.integer(packet, at: 0, bytes: 8)
        let size = Int(MediaIPC.integer(packet, at: 8, bytes: 4))
        let offset = Int(MediaIPC.integer(packet, at: 12, bytes: 4))
        guard size >= 37, size <= MessageKind.video.maximumPayloadSize,
              offset < size, packet.count - MediaIPC.headerSize == min(MediaIPC.chunkSize, size - offset) else {
            throw WebRTCTransportError.malformedHelperOutput
        }
        if offset == 0 {
            dropped = dropped || transfer != nil
            transfer = id; total = size; bytes = Data(); started = now
        }
        guard transfer == id, total == size, offset == bytes.count else {
            // A transfer that expired or was flushed may finish arriving. Ignore
            // its tail without ever applying it to a newer frame.
            if transfer == nil { return (nil, true) }
            throw WebRTCTransportError.malformedHelperOutput
        }
        bytes.append(packet.dropFirst(MediaIPC.headerSize))
        guard bytes.count == total else { return (nil, dropped) }
        let frame = bytes
        reset()
        return (frame, dropped)
    }
}
