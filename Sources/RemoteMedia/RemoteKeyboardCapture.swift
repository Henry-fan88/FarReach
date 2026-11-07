import AppKit
import ApplicationServices

public enum RemoteKeyboardCaptureStatus: Equatable {
    case disabled, inactive, capturing, permissionRequired, unavailable
}

/// Small, side-effect-free routing state shared by the event tap and its tests.
/// A key-up is only sent if this capture scope admitted its key-down. This
/// prevents releases/repeats held over a focus or session change entering the
/// next remote session. Modifiers remain attached to every admitted event.
struct KeyboardCaptureRouter {
    struct Event {
        let kind: RemoteInput.Kind
        let keyCode: UInt16
        let modifiers: UInt64
        var isRepeat = false
        var sourceMarker: Int64 = 0
    }
    enum Action {
        case passThrough
        case forward(RemoteInput)
        case releaseFocus
        case endViewing
    }

    private(set) var pressedKeys = Set<UInt16>()

    static func allowsAppKitFallback(hasScope: Bool, tapActive: Bool, sourceMarker: Int64) -> Bool {
        hasScope && !tapActive && sourceMarker != RemoteInput.injectedEventMarker
    }

    func action(for event: Event, capturing: Bool) -> Action {
        guard capturing, event.sourceMarker != RemoteInput.injectedEventMarker,
              event.keyCode <= 127 else { return .passThrough }
        let flags = CGEventFlags(rawValue: event.modifiers)
        switch event.kind {
        case .keyDown:
            if event.keyCode == 47 && flags.contains([.maskCommand, .maskShift]) { return .endViewing }
            if event.keyCode == 53 && flags.contains([.maskControl, .maskAlternate]) { return .releaseFocus }
            if event.isRepeat && !pressedKeys.contains(event.keyCode) { return .passThrough }
        case .keyUp:
            guard pressedKeys.contains(event.keyCode) else { return .passThrough }
        case .flags:
            guard [54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(event.keyCode) else { return .passThrough }
        default: return .passThrough
        }
        let input = RemoteInput(kind: event.kind, keyCode: event.keyCode,
                                modifiers: event.modifiers & RemoteInput.allowedModifiers)
        guard input.isValid else { return .passThrough }
        return .forward(input)
    }

    mutating func admitted(_ input: RemoteInput) {
        if input.kind == .keyDown { pressedKeys.insert(input.keyCode) }
        if input.kind == .keyUp { pressedKeys.remove(input.keyCode) }
    }

    mutating func reset() { pressedKeys.removeAll() }
}

/// A filtering tap at the start of the logged-in user's event stream. Unlike
/// NSView's responder methods, this observes Command-Tab and screenshot keys
/// before the local system consumes them. It is installed only for an explicit
/// focused remote-view scope, never to monitor typing elsewhere in the system.
/// All state/callbacks run on the main run loop; no input is logged or retained.
final class RemoteKeyboardCapture {
    enum LocalAction { case releaseFocus, endViewing }
    let shouldCapture: () -> Bool
    let send: (RemoteInput) -> Bool
    let localAction: (LocalAction) -> Void
    let unavailable: () -> Void
    let lostScope: () -> Void

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var router = KeyboardCaptureRouter()
    var isActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    init(shouldCapture: @escaping () -> Bool, send: @escaping (RemoteInput) -> Bool,
         localAction: @escaping (LocalAction) -> Void, unavailable: @escaping () -> Void,
         lostScope: @escaping () -> Void) {
        self.shouldCapture = shouldCapture; self.send = send; self.localAction = localAction
        self.unavailable = unavailable; self.lostScope = lostScope
    }

    func start() -> Bool {
        guard tap == nil, shouldCapture() else { return isActive }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<RemoteKeyboardCapture>.fromOpaque(context).takeUnretainedValue()
                return owner.receive(type: type, event: event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return false }
        tap = port; source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return isActive
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil; router.reset()
    }

    private func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let original = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stop()
            // Release held input and require an intentional refocus. Never
            // automatically override an OS/user-disabled tap or a stalled UI.
            unavailable()
            return original
        }
        guard shouldCapture() else {
            stop(); lostScope(); return original
        }
        let kind: RemoteInput.Kind
        switch type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flags
        default: return original
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard (0...127).contains(code) else { return original }
        let value = KeyboardCaptureRouter.Event(kind: kind, keyCode: UInt16(code), modifiers: event.flags.rawValue,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            sourceMarker: event.getIntegerValueField(.eventSourceUserData))
        switch router.action(for: value, capturing: isActive) {
        case .passThrough: return original
        case .forward(let input):
            guard send(input) else { return original }
            // A failed/closed transport can synchronously release this scope.
            if tap != nil { router.admitted(input) }
            return nil
        case .releaseFocus: localAction(.releaseFocus); return nil
        case .endViewing: localAction(.endViewing); return nil
        }
    }

    deinit { stop() }
}
