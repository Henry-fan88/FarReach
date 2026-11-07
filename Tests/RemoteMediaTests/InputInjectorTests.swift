import XCTest
import CoreGraphics
@testable import RemoteMedia

/// Inspects CGEvent objects at the posting boundary. These tests never post
/// input to macOS, open the screenshot UI, switch apps, or require permissions.
final class InputInjectorTests: XCTestCase {
    private final class Recorder {
        var events: [CGEvent] = []
        var allowed = true
        var active = true
        lazy var injector = InputInjector(displayID: 1,
            canPostEvents: { [weak self] in self?.allowed ?? false },
            displayIsActive: { [weak self] in self?.active ?? false },
            displayBounds: { CGRect(x: 0, y: 0, width: 1920, height: 1080) },
            postEvent: { [weak self] event in self?.events.append(event) })

        @discardableResult func apply(_ kind: RemoteInput.Kind, _ key: UInt16 = 0, _ flags: CGEventFlags = []) -> Bool {
            injector.apply(RemoteInput(kind: kind, keyCode: key, modifiers: flags.rawValue))
        }
    }

    func testCommandTabPreservesCommandUntilPhysicalReleaseAndMarksEveryEvent() throws {
        let recorder = Recorder()
        XCTAssertTrue(recorder.apply(.flags, 55, .maskCommand))
        XCTAssertTrue(recorder.apply(.keyDown, 48, .maskCommand))
        XCTAssertTrue(recorder.apply(.keyUp, 48, .maskCommand))
        XCTAssertTrue(recorder.apply(.keyDown, 48, .maskCommand))
        XCTAssertTrue(recorder.apply(.keyUp, 48, .maskCommand))
        XCTAssertTrue(recorder.apply(.flags, 55))
        XCTAssertEqual(recorder.events.map(\.type), [.flagsChanged, .keyDown, .keyUp, .keyDown, .keyUp, .flagsChanged])
        XCTAssertEqual(recorder.events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [55, 48, 48, 48, 48, 55])
        XCTAssertTrue(recorder.events.dropLast().allSatisfy { $0.flags.contains(.maskCommand) })
        XCTAssertTrue(try XCTUnwrap(recorder.events.last).flags.isEmpty)
        XCTAssertTrue(recorder.events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == RemoteInput.injectedEventMarker })
        let count = recorder.events.count
        recorder.injector.releaseAll()
        XCTAssertEqual(recorder.events.count, count, "Completed key-up sequence must leave no stuck modifier")
    }

    func testScreenshotChordsRetainKeycodesAndCombinedModifiers() {
        let recorder = Recorder()
        let chord: CGEventFlags = [.maskCommand, .maskShift]
        XCTAssertTrue(recorder.apply(.flags, 56, .maskShift))
        XCTAssertTrue(recorder.apply(.flags, 55, chord))
        for key: UInt16 in [21, 23] { // Physical 4 and 5, not text insertion.
            XCTAssertTrue(recorder.apply(.keyDown, key, chord))
            XCTAssertTrue(recorder.apply(.keyUp, key, chord))
        }
        XCTAssertTrue(recorder.apply(.flags, 55, .maskShift))
        XCTAssertTrue(recorder.apply(.flags, 56))
        let keys = recorder.events.filter { $0.type == .keyDown || $0.type == .keyUp }
        XCTAssertEqual(keys.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [21, 21, 23, 23])
        XCTAssertTrue(keys.allSatisfy { $0.flags == chord })
        let count = recorder.events.count
        recorder.injector.releaseAll()
        XCTAssertEqual(recorder.events.count, count)
    }

    func testNavigationEditingFunctionAndCommandKeysRemainPhysicalEvents() {
        let recorder = Recorder()
        let keys: [UInt16] = [123, 124, 125, 126, 48, 51, 117, 53, 36, 122, 111, 0, 8]
        for key in keys {
            let flags: CGEventFlags = key == 0 || key == 8 ? .maskCommand : key == 122 ? .maskSecondaryFn : []
            XCTAssertTrue(recorder.apply(.keyDown, key, flags))
            XCTAssertTrue(recorder.apply(.keyUp, key, flags))
        }
        XCTAssertEqual(recorder.events.count, keys.count * 2)
        XCTAssertEqual(recorder.events.filter { $0.type == .keyDown }.map { UInt16($0.getIntegerValueField(.keyboardEventKeycode)) }, keys)
        XCTAssertEqual(recorder.events.filter { $0.type == .keyUp }.map { UInt16($0.getIntegerValueField(.keyboardEventKeycode)) }, keys)
        XCTAssertTrue(recorder.events.first { $0.getIntegerValueField(.keyboardEventKeycode) == 122 }!.flags.contains(.maskSecondaryFn))
    }

    func testKeyRepeatResetsAfterRelease() {
        let recorder = Recorder()
        XCTAssertTrue(recorder.apply(.keyDown, 123))
        XCTAssertTrue(recorder.apply(.keyDown, 123))
        XCTAssertTrue(recorder.apply(.keyUp, 123))
        XCTAssertTrue(recorder.apply(.keyDown, 123))
        XCTAssertEqual(recorder.events.map { $0.getIntegerValueField(.keyboardEventAutorepeat) }, [0, 1, 0, 0])
    }

    func testReleasingOneSideKeepsOnlyTheOtherPhysicalModifierHeld() {
        for (left, right, mask): (UInt16, UInt16, CGEventFlags) in [
            (55, 54, .maskCommand), (56, 60, .maskShift),
            (59, 62, .maskControl), (58, 61, .maskAlternate)
        ] {
            let recorder = Recorder()
            XCTAssertTrue(recorder.apply(.flags, left, mask))
            XCTAssertTrue(recorder.apply(.flags, right, mask))
            // Aggregate flag remains present after the left key is released.
            XCTAssertTrue(recorder.apply(.flags, left, mask))
            recorder.events.removeAll()
            recorder.injector.releaseAll()
            XCTAssertEqual(recorder.events.count, 1)
            XCTAssertEqual(recorder.events.first?.type, .flagsChanged)
            XCTAssertEqual(recorder.events.first?.getIntegerValueField(.keyboardEventKeycode), Int64(right))
            XCTAssertEqual(recorder.events.first?.flags, [])
        }
    }

    func testReleaseAllClearsKeysButtonsAndModifiersIncludingAlreadyHeldModifiers() {
        let recorder = Recorder()
        let chord: CGEventFlags = [.maskCommand, .maskShift]
        // A modifier may already be held when the viewer gains keyboard focus.
        XCTAssertTrue(recorder.apply(.keyDown, 21, chord))
        XCTAssertTrue(recorder.injector.apply(RemoteInput(kind: .mouseDown, x: 0.25, y: 0.75, button: 0, modifiers: chord.rawValue)))
        recorder.events.removeAll()
        recorder.injector.releaseAll()
        XCTAssertEqual(recorder.events.map(\.type), [.keyUp, .flagsChanged, .flagsChanged, .leftMouseUp])
        XCTAssertEqual(recorder.events.prefix(3).map { $0.getIntegerValueField(.keyboardEventKeycode) }, [21, 55, 56])
        XCTAssertTrue(recorder.events.allSatisfy { $0.flags.isEmpty })
        XCTAssertTrue(recorder.events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == RemoteInput.injectedEventMarker })
        let count = recorder.events.count
        recorder.injector.releaseAll()
        XCTAssertEqual(recorder.events.count, count, "Repeated cleanup must not inject duplicate releases")
    }

    func testInvalidOrUnauthorizedInputNeverPostsAndRevokedCleanupDropsState() {
        let recorder = Recorder()
        XCTAssertFalse(recorder.injector.apply(RemoteInput(kind: .keyDown, keyCode: 255)))
        XCTAssertFalse(recorder.injector.apply(RemoteInput(kind: .keyDown, modifiers: UInt64.max)))
        recorder.allowed = false
        XCTAssertFalse(recorder.apply(.keyDown, 48, .maskCommand))
        XCTAssertTrue(recorder.events.isEmpty)
        recorder.allowed = true
        XCTAssertTrue(recorder.apply(.keyDown, 48, .maskCommand))
        recorder.events.removeAll()
        recorder.allowed = false
        XCTAssertFalse(recorder.apply(.releaseAll))
        XCTAssertTrue(recorder.events.isEmpty)
        recorder.allowed = true
        recorder.injector.releaseAll()
        XCTAssertTrue(recorder.events.isEmpty, "Permission restoration must not post stale releases from a previous session")
    }

    func testInactiveDisplayReleasesHeldInputWithoutPostingNewKey() {
        let recorder = Recorder()
        XCTAssertTrue(recorder.apply(.keyDown, 48, .maskCommand))
        recorder.events.removeAll()
        recorder.active = false
        XCTAssertFalse(recorder.apply(.keyDown, 0))
        XCTAssertEqual(recorder.events.map(\.type), [.keyUp, .flagsChanged])
        XCTAssertTrue(recorder.events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == RemoteInput.injectedEventMarker })
    }
}
