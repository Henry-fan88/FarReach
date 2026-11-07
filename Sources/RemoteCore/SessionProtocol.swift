import Foundation

public struct SessionControl: Codable, Equatable {
    public enum Action: String, Codable { case resume, pause, wake }
    public let action: Action
    public init(_ action: Action) { self.action = action }
}

public struct StreamState: Codable, Equatable {
    public enum State: String, Codable { case starting, available, unavailable, paused, wakeRequested }
    public let state: State
    public let generation: UInt64
    public init(_ state: State, generation: UInt64) { self.state = state; self.generation = generation }
}

/// Capture generations prevent a delayed pre-pause or pre-blank frame from
/// being displayed after a stream availability transition.
public struct StreamFrameEnvelope {
    public let generation: UInt64
    public let frame: Data
    public init(generation: UInt64, frame: Data) throws {
        guard generation != 0, frame.count >= 25, frame.count <= MessageKind.video.maximumPayloadSize - 12,
              [Data("FRV1".utf8), Data("FRV2".utf8)].contains(frame.prefix(4)) else { throw RemoteProtocolError.malformedFrame }
        self.generation = generation; self.frame = frame
    }
    public init(data: Data) throws {
        guard data.count >= 37, data.prefix(4) == Data("FRS1".utf8) else { throw RemoteProtocolError.malformedFrame }
        var generation: UInt64 = 0
        for b in data.dropFirst(4).prefix(8) { generation = (generation << 8) | UInt64(b) }
        try self.init(generation: generation, frame: Data(data.dropFirst(12)))
    }
    public func encoded() -> Data {
        var result = Data("FRS1".utf8)
        for shift in stride(from: 56, through: 0, by: -8) { result.append(UInt8(truncatingIfNeeded: generation >> shift)) }
        result.append(frame)
        return result
    }
}
