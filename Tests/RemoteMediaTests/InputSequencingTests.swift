import XCTest
@testable import RemoteMedia

final class InputSequencingTests: XCTestCase {
    func testHighRateMovesCoalesceToNewestAndRemainAtMost120Hz() {
        var sequencer = InputSequencer()
        XCTAssertEqual(sequencer.submit(.init(kind: .move, x: 0.1), now: 0).count, 1)
        for index in 1...7 { XCTAssertTrue(sequencer.submit(.init(kind: .move, x: Double(index) / 10), now: Double(index) / 1000).isEmpty) }
        XCTAssertTrue(sequencer.flush(now: 0.008).isEmpty)
        let flushed = sequencer.flush(now: 0.009)
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed.first?.x, 0.7)
        XCTAssertEqual(flushed.first?.sequence, 8)
        XCTAssertTrue(sequencer.flush(now: 0.02).isEmpty)
    }

    func testMoveOvertakingMouseDownWaitsAndLateDragCannotCrossMouseUp() throws {
        var sender = InputSequencer(), receiver = InputReceiver()
        let down = try XCTUnwrap(sender.submit(.init(kind: .mouseDown, x: 0.2, y: 0.3), now: 0).first)
        let drag = try XCTUnwrap(sender.submit(.init(kind: .move, x: 0.7, y: 0.8), now: 0.01).first)
        XCTAssertTrue(receiver.receive(drag).isEmpty)
        let joined = receiver.receive(down)
        XCTAssertEqual(joined.map(\.kind), [.mouseDown, .move])
        XCTAssertEqual(joined[0].x, 0.2)
        XCTAssertEqual(joined[1].x, 0.7)
        let up = try XCTUnwrap(sender.submit(.init(kind: .mouseUp, x: 0.9, y: 0.8), now: 0.02).first)
        XCTAssertEqual(receiver.receive(up).map(\.kind), [.mouseUp])
        XCTAssertTrue(receiver.receive(drag).isEmpty)
        XCTAssertTrue(receiver.receive(down).isEmpty)
        XCTAssertEqual(receiver.receive(try XCTUnwrap(sender.submit(.init(kind: .move, x: 0.1), now: 0.03).first)).first?.x, 0.1)
    }

    func testReliableKeysScrollAndReleaseRemainOrderedWhenPointersOvertake() throws {
        var sender = InputSequencer(), receiver = InputReceiver()
        let inputs: [RemoteInput] = [.init(kind: .keyDown, keyCode: 55), .init(kind: .keyDown, keyCode: 48),
                                    .init(kind: .keyUp, keyCode: 48), .init(kind: .scroll, deltaY: 18),
                                    .init(kind: .keyUp, keyCode: 55)]
        let reliable = inputs.enumerated().map { sender.submit($0.element, now: Double($0.offset) * 0.01)[0] }
        let futureMove = try XCTUnwrap(sender.submit(.init(kind: .move, x: 0.9), now: 0.1).first)
        XCTAssertTrue(receiver.receive(futureMove).isEmpty)
        var delivered: [RemoteInput] = []
        for event in reliable { delivered += receiver.receive(event) }
        XCTAssertEqual(delivered.map(\.kind), inputs.map(\.kind) + [.move])
        XCTAssertEqual(delivered[3].deltaY, 18)
        let release = sender.submit(.init(kind: .releaseAll), now: 0.2)[0]
        XCTAssertEqual(receiver.receive(release).map(\.kind), [.releaseAll])
        XCTAssertTrue(receiver.receive(futureMove).isEmpty)
        XCTAssertTrue(receiver.receive(.init(kind: .move)).isEmpty, "Untagged old input must not bypass sequence state")
    }

    func testReleaseClearsBufferedFutureMovementAndPendingSenderMove() {
        var receiver = InputReceiver()
        XCTAssertTrue(receiver.receive(.init(kind: .move, sequence: 50, interaction: 8)).isEmpty)
        XCTAssertEqual(receiver.receive(.init(kind: .releaseAll, sequence: 40, interaction: 7)).map(\.kind), [.releaseAll])
        XCTAssertEqual(receiver.receive(.init(kind: .mouseDown, sequence: 45, interaction: 8)).map(\.kind), [.mouseDown])
        var sender = InputSequencer()
        _ = sender.submit(.init(kind: .move), now: 0)
        XCTAssertTrue(sender.submit(.init(kind: .move, x: 1), now: 0.001).isEmpty)
        XCTAssertEqual(sender.submit(.init(kind: .releaseAll), now: 0.002).map(\.kind), [.releaseAll])
        XCTAssertTrue(sender.flush(now: 0.1).isEmpty)
    }

    func testLegacyInputDecodesAndSequencedFieldsRoundtrip() throws {
        let bytes = Data(#"{"kind":"move","x":0.2,"y":0.3,"button":0,"clickCount":1,"keyCode":0,"modifiers":0,"deltaX":0,"deltaY":0}"#.utf8)
        let legacy = try JSONDecoder().decode(RemoteInput.self, from: bytes)
        XCTAssertEqual(legacy.sequence, 0); XCTAssertEqual(legacy.interaction, 0)
        var receiver = InputReceiver()
        XCTAssertEqual(receiver.receive(legacy).count, 1)
        let input = RemoteInput(kind: .mouseDown, sequence: 7, interaction: 2)
        let decoded = try JSONDecoder().decode(RemoteInput.self, from: JSONEncoder().encode(input))
        XCTAssertEqual(decoded.sequence, 7); XCTAssertEqual(decoded.interaction, 2)
        XCTAssertFalse(RemoteInput(kind: .move, sequence: 1).isValid)
    }
}
