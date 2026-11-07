import XCTest
@testable import RemoteCore

final class MediaIPCTests: XCTestCase {
    func testChunkRoundTripAndBoundedAssembly() throws {
        let data = Data(repeating: 42, count: 100_003)
        var assembly = MediaIPCAssembler()
        var result: Data?
        for offset in stride(from: 0, to: data.count, by: MediaIPC.chunkSize) {
            let chunk = MediaIPC.chunk(data, transfer: 7, offset: offset)
            XCTAssertLessThanOrEqual(chunk.count, 16_400)
            let value = try assembly.push(chunk, now: 0.1)
            XCTAssertFalse(value.dropped)
            result = value.frame
            XCTAssertLessThanOrEqual(assembly.pendingBytes, data.count)
        }
        XCTAssertEqual(result, data)
        XCTAssertEqual(assembly.pendingBytes, 0)
    }

    func testGenerationFlushAndSilentIncompleteExpiry() throws {
        let old = Data(repeating: 1, count: 40_000)
        let new = Data(repeating: 2, count: 40)
        var assembly = MediaIPCAssembler()
        _ = try assembly.push(MediaIPC.chunk(old, transfer: 1, offset: 0), now: 10)
        XCTAssertTrue(assembly.expire(now: 11.1))
        XCTAssertEqual(assembly.pendingBytes, 0)
        let tail = try assembly.push(MediaIPC.chunk(old, transfer: 1, offset: MediaIPC.chunkSize), now: 11.2)
        XCTAssertNil(tail.frame)
        let result = try assembly.push(MediaIPC.chunk(new, transfer: 2, offset: 0), now: 11.3)
        XCTAssertEqual(result.frame, new)
    }

    func testWrongOffsetAndOversizeAreRejected() throws {
        var assembly = MediaIPCAssembler()
        let data = Data(repeating: 1, count: 50_000)
        _ = try assembly.push(MediaIPC.chunk(data, transfer: 1, offset: 0), now: 0)
        XCTAssertThrowsError(try assembly.push(MediaIPC.chunk(data, transfer: 1, offset: 32_768), now: 0))
        var chunk = MediaIPC.chunk(data, transfer: 2, offset: 0)
        chunk.replaceSubrange(8..<12, with: [255, 255, 255, 255])
        XCTAssertThrowsError(try assembly.push(chunk, now: 0))
        XCTAssertThrowsError(try assembly.push(Data(repeating: 0, count: 16_401), now: 0))
    }

    func testStatisticsRejectInvalidNumbers() {
        XCTAssertTrue(TransportStatistics().isValid)
        XCTAssertFalse(TransportStatistics(rttMS: .nan).isValid)
        XCTAssertFalse(TransportStatistics(queuedBytes: -1).isValid)
        XCTAssertFalse(TransportStatistics(targetBitrate: 100_000_000).isValid)
    }
}
