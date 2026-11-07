import XCTest
import CoreGraphics
@testable import RemoteMedia

final class KeyboardCaptureTests: XCTestCase {
    private let command = CGEventFlags.maskCommand.rawValue
    private let shift = CGEventFlags.maskShift.rawValue

    @discardableResult
    private func forward(_ event: KeyboardCaptureRouter.Event, through router: inout KeyboardCaptureRouter,
                         file: StaticString = #filePath, line: UInt = #line) -> RemoteInput? {
        guard case .forward(let input) = router.action(for: event, capturing: true) else {
            XCTFail("Expected this physical key to be forwarded", file: file, line: line); return nil
        }
        router.admitted(input)
        XCTAssertTrue(input.isValid, file: file, line: line)
        return input
    }

    private func assertPass(_ action: KeyboardCaptureRouter.Action,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard case .passThrough = action else { XCTFail("Event must stay local", file: file, line: line); return }
    }

    func testCommandTabKeepsModifierAndRepeatUntilPhysicalRelease() {
        var router = KeyboardCaptureRouter()
        forward(.init(kind: .flags, keyCode: 55, modifiers: command), through: &router)
        let down = forward(.init(kind: .keyDown, keyCode: 48, modifiers: command), through: &router)
        XCTAssertEqual(down?.keyCode, 48); XCTAssertEqual(down?.modifiers, command)
        let repeated = forward(.init(kind: .keyDown, keyCode: 48, modifiers: command, isRepeat: true), through: &router)
        XCTAssertEqual(repeated?.kind, .keyDown)
        forward(.init(kind: .keyUp, keyCode: 48, modifiers: command), through: &router)
        let released = forward(.init(kind: .flags, keyCode: 55, modifiers: 0), through: &router)
        XCTAssertEqual(released?.modifiers, 0)
        XCTAssertTrue(router.pressedKeys.isEmpty)
    }

    func testScreenshotAndOrdinaryShortcutsAreNotAnAllowlist() {
        for key: UInt16 in [21, 23, 0, 8, 9, 36, 51, 53, 115, 116, 117, 119, 121, 123, 124, 125, 126] {
            var router = KeyboardCaptureRouter()
            let down = forward(.init(kind: .keyDown, keyCode: key, modifiers: command | shift), through: &router)
            XCTAssertEqual(down?.keyCode, key)
            XCTAssertEqual(down?.modifiers, command | shift)
            forward(.init(kind: .keyUp, keyCode: key, modifiers: command | shift), through: &router)
        }
    }

    func testLeftAndRightModifierEventsKeepAggregateFlags() {
        var router = KeyboardCaptureRouter()
        for (key, flags): (UInt16, UInt64) in [(55, command), (54, command), (55, command), (54, 0)] {
            let input = forward(.init(kind: .flags, keyCode: key, modifiers: flags), through: &router)
            XCTAssertEqual(input?.keyCode, key); XCTAssertEqual(input?.modifiers, flags)
        }
    }

    func testOnlyAdmittedKeyDownsOwnTheirKeyUpsAndRepeats() {
        var router = KeyboardCaptureRouter()
        let down = KeyboardCaptureRouter.Event(kind: .keyDown, keyCode: 0, modifiers: 0)
        // Merely routing a rejected transport send must not claim this key.
        guard case .forward = router.action(for: down, capturing: true) else { return XCTFail("Expected admission candidate") }
        assertPass(router.action(for: .init(kind: .keyUp, keyCode: 0, modifiers: 0), capturing: true))
        assertPass(router.action(for: .init(kind: .keyDown, keyCode: 0, modifiers: 0, isRepeat: true), capturing: true))
        forward(down, through: &router)
        router.reset() // focus/session ended; do not carry this key to the next scope.
        assertPass(router.action(for: .init(kind: .keyUp, keyCode: 0, modifiers: 0), capturing: true))
        assertPass(router.action(for: .init(kind: .keyDown, keyCode: 0, modifiers: 0, isRepeat: true), capturing: true))
        forward(down, through: &router)
        XCTAssertEqual(router.pressedKeys, [0])
    }

    func testLocalEscapesAreNeverSentAsRemoteKeyDowns() {
        let router = KeyboardCaptureRouter()
        guard case .endViewing = router.action(for: .init(kind: .keyDown, keyCode: 47, modifiers: command | shift), capturing: true) else {
            return XCTFail("Command-Shift-period must end viewing locally")
        }
        let releaseFlags = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        guard case .releaseFocus = router.action(for: .init(kind: .keyDown, keyCode: 53, modifiers: releaseFlags), capturing: true) else {
            return XCTFail("Control-Option-Escape must release focus locally")
        }
        assertPass(router.action(for: .init(kind: .keyUp, keyCode: 47, modifiers: 0), capturing: true))
        assertPass(router.action(for: .init(kind: .keyUp, keyCode: 53, modifiers: 0), capturing: true))
    }

    func testScopeAndInjectionTagPreventBackgroundCaptureAndFeedback() {
        let router = KeyboardCaptureRouter()
        let key = KeyboardCaptureRouter.Event(kind: .keyDown, keyCode: 48, modifiers: command)
        assertPass(router.action(for: key, capturing: false))
        var injected = key; injected.sourceMarker = RemoteInput.injectedEventMarker
        assertPass(router.action(for: injected, capturing: true))
        assertPass(router.action(for: .init(kind: .keyDown, keyCode: 255, modifiers: 0), capturing: true))
        assertPass(router.action(for: .init(kind: .flags, keyCode: 0, modifiers: command), capturing: true))
    }

    func testAppKitFallbackCannotDuplicateTapOrReforwardSyntheticInput() {
        XCTAssertFalse(KeyboardCaptureRouter.allowsAppKitFallback(hasScope: true, tapActive: true, sourceMarker: 0))
        XCTAssertTrue(KeyboardCaptureRouter.allowsAppKitFallback(hasScope: true, tapActive: false, sourceMarker: 0))
        XCTAssertFalse(KeyboardCaptureRouter.allowsAppKitFallback(hasScope: false, tapActive: false, sourceMarker: 0))
        XCTAssertFalse(KeyboardCaptureRouter.allowsAppKitFallback(hasScope: true, tapActive: false, sourceMarker: RemoteInput.injectedEventMarker))
    }
}
