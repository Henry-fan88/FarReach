import XCTest
import AppKit
@testable import FarReach
import RemoteCore
import RemoteMedia

/// Real authenticated transport with a synthetic host; never posts keys to macOS.
final class KeyboardSessionTests: XCTestCase {
    @MainActor
    func testKeyboardAdmissionRequiresAuthenticatedViewingAndPreservesShortcutEvents() async throws {
        _ = NSApplication.shared
        let model = AppModel(pairingStore: InMemoryPairingStore())
        let host = try SyntheticSessionHost()
        let key = try PairingInvitation.generateKey()
        let listener = try SecureListener(key: key, port: 0)
        defer { model.shutdown(); host.close(); listener.stop() }
        let command = CGEventFlags.maskCommand.rawValue
        let shifted = command | CGEventFlags.maskShift.rawValue
        let events: [RemoteInput] = [
            .init(kind: .flags, keyCode: 55, modifiers: command),
            .init(kind: .keyDown, keyCode: 48, modifiers: command),
            .init(kind: .keyUp, keyCode: 48, modifiers: command),
            .init(kind: .flags, keyCode: 55),
            .init(kind: .flags, keyCode: 55, modifiers: command),
            .init(kind: .flags, keyCode: 56, modifiers: shifted),
            .init(kind: .keyDown, keyCode: 21, modifiers: shifted),
            .init(kind: .keyUp, keyCode: 21, modifiers: shifted),
            .init(kind: .keyDown, keyCode: 23, modifiers: shifted),
            .init(kind: .keyUp, keyCode: 23, modifiers: shifted),
            .init(kind: .flags, keyCode: 56, modifiers: command),
            .init(kind: .flags, keyCode: 55),
            .init(kind: .keyDown, keyCode: 123), // Arrow navigation on any focused remote app.
            .init(kind: .keyDown, keyCode: 123), // Key repeat keeps its ordering.
            .init(kind: .keyUp, keyCode: 123)
        ]
        XCTAssertFalse(model.desktop.onCapturedKeyboardInput?(events[0]) ?? true)
        let listening = expectation(description: "listener ready")
        let frame = expectation(description: "current authenticated remote frame")
        let received = expectation(description: "keyboard sequence delivered")
        received.expectedFulfillmentCount = events.count
        var port: UInt16 = 0
        var hasFrame = false
        var index = 0
        model.desktop.onFrameEnqueued = { if !hasFrame { hasFrame = true; frame.fulfill() } }
        host.onInput = { input in
            guard input.kind != .releaseAll else { return }
            guard index < events.count else { XCTFail("Duplicate keyboard event"); return }
            XCTAssertEqual(input.kind, events[index].kind)
            XCTAssertEqual(input.keyCode, events[index].keyCode)
            XCTAssertEqual(input.modifiers, events[index].modifiers)
            index += 1; received.fulfill()
        }
        listener.onReady = { port = $0; listening.fulfill() }
        listener.onError = { XCTFail("Listener failed: \($0)") }
        listener.onConnection = { peer in
            do { try host.attach(peer) } catch { XCTFail("Host authentication failed: \(error)"); peer.close() }
        }
        listener.start()
        await fulfillment(of: [listening], timeout: 5)
        model.pastedInvitation = try PairingInvitation(host: "127.0.0.1", port: port, key: key).urlString
        model.connect()
        await fulfillment(of: [frame], timeout: 8)
        XCTAssertTrue(model.isViewing)
        for event in events { XCTAssertTrue(model.desktop.onCapturedKeyboardInput?(event) ?? false) }
        await fulfillment(of: [received], timeout: 5)
        XCTAssertFalse(model.desktop.onCapturedKeyboardInput?(.init(kind: .keyDown, keyCode: 255)) ?? true)
        model.endViewing()
        XCTAssertFalse(model.desktop.onCapturedKeyboardInput?(events[1]) ?? true)
        XCTAssertTrue(model.desktop.onCapturedKeyboardInput?(.init(kind: .releaseAll)) ?? false)
        model.disconnect()
        XCTAssertFalse(model.desktop.onCapturedKeyboardInput?(events[1]) ?? true)
    }
}
