import Foundation
import AppKit
import ApplicationServices
import IOKit.pwr_mgt

public struct RemoteInput: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case move, mouseDown, mouseUp, scroll, keyDown, keyUp, flags, releaseAll }
    public var kind: Kind
    public var x: Double
    public var y: Double
    public var button: Int
    public var clickCount: Int
    public var keyCode: UInt16
    public var modifiers: UInt64
    public var deltaX: Double
    public var deltaY: Double
    public var sequence: UInt64
    public var interaction: UInt64
    public init(kind: Kind, x: Double = 0, y: Double = 0, button: Int = 0, clickCount: Int = 1, keyCode: UInt16 = 0, modifiers: UInt64 = 0, deltaX: Double = 0, deltaY: Double = 0,
                sequence: UInt64 = 0, interaction: UInt64 = 0) {
        self.kind = kind; self.x = x; self.y = y; self.button = button; self.clickCount = clickCount; self.keyCode = keyCode
        self.modifiers = modifiers; self.deltaX = deltaX; self.deltaY = deltaY
        self.sequence = sequence; self.interaction = interaction
    }
    private enum CodingKeys: String, CodingKey { case kind, x, y, button, clickCount, keyCode, modifiers, deltaX, deltaY, sequence, interaction }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(Kind.self, forKey: .kind)
        x = try values.decode(Double.self, forKey: .x); y = try values.decode(Double.self, forKey: .y)
        button = try values.decode(Int.self, forKey: .button); clickCount = try values.decode(Int.self, forKey: .clickCount)
        keyCode = try values.decode(UInt16.self, forKey: .keyCode); modifiers = try values.decode(UInt64.self, forKey: .modifiers)
        deltaX = try values.decode(Double.self, forKey: .deltaX); deltaY = try values.decode(Double.self, forKey: .deltaY)
        sequence = try values.decodeIfPresent(UInt64.self, forKey: .sequence) ?? 0
        interaction = try values.decodeIfPresent(UInt64.self, forKey: .interaction) ?? 0
    }
    public var isValid: Bool {
        x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) &&
        (0...2).contains(button) && (1...3).contains(clickCount) && keyCode <= 127 && deltaX.isFinite && deltaY.isFinite &&
        abs(deltaX) <= 2000 && abs(deltaY) <= 2000 && (modifiers & ~Self.allowedModifiers) == 0 &&
        ((sequence == 0 && interaction == 0) || (sequence > 0 && interaction > 0))
    }
    public static let allowedModifiers = CGEventFlags.maskAlphaShift.rawValue | CGEventFlags.maskShift.rawValue |
        CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue |
        CGEventFlags.maskNumericPad.rawValue | CGEventFlags.maskHelp.rawValue | CGEventFlags.maskSecondaryFn.rawValue
    /// Identifies this app's injected input so a local viewer never captures it
    /// again. This is a loop-prevention marker, not an authentication secret.
    public static let injectedEventMarker: Int64 = 0x4652524541434801
}

/// Use on one serial session queue. Moves are replaceable; all other events
/// advance a reliable boundary. Keep this instance through pause/resume and
/// reset only after replacing the authenticated transport.
public struct InputSequencer {
    private var nextSequence: UInt64 = 0
    private var interaction: UInt64 = 1
    private var pendingMove: RemoteInput?
    private var lastMoveTime: TimeInterval?
    public let maximumMovesPerSecond: Double
    public init(maximumMovesPerSecond: Double = 120) {
        self.maximumMovesPerSecond = maximumMovesPerSecond.isFinite ? min(120, max(1, maximumMovesPerSecond)) : 120
    }
    public mutating func submit(_ input: RemoteInput, now: TimeInterval) -> [RemoteInput] {
        guard input.isValid, now.isFinite, nextSequence < UInt64.max, interaction < UInt64.max else { return [] }
        nextSequence += 1
        var event = input; event.sequence = nextSequence
        if input.kind == .move {
            event.interaction = interaction
            pendingMove = event
            return flush(now: now)
        }
        // Buttons carry their own absolute position. Never let a pending move
        // from the previous gesture travel after a button/key/release boundary.
        pendingMove = nil
        interaction += 1; event.interaction = interaction
        return [event]
    }
    public mutating func flush(now: TimeInterval) -> [RemoteInput] {
        guard now.isFinite, let event = pendingMove,
              lastMoveTime.map({ now - $0 >= 1 / maximumMovesPerSecond }) ?? true else { return [] }
        pendingMove = nil; lastMoveTime = now
        return [event]
    }
    public mutating func reset() { self = InputSequencer(maximumMovesPerSecond: maximumMovesPerSecond) }
}

/// Joins the reliable input stream and the unordered pointer stream. A pointer
/// for a future interaction waits for its reliable boundary, with at most one
/// retained event. Late movement cannot re-enter a finished drag.
public struct InputReceiver {
    private var interaction: UInt64 = 1
    private var lastReliableSequence: UInt64 = 0
    private var lastMoveSequence: UInt64 = 0
    private var futureMove: RemoteInput?
    private var sequenced = false
    public init() {}
    public mutating func receive(_ event: RemoteInput) -> [RemoteInput] {
        guard event.isValid else { return [] }
        if event.sequence == 0 {
            // Compatibility for the original reliable LAN protocol only. Once
            // sequenced input is observed, an old untagged event is stale.
            return sequenced ? [] : [event]
        }
        sequenced = true
        if event.kind == .move {
            guard event.sequence > max(lastReliableSequence, lastMoveSequence), event.interaction >= interaction else { return [] }
            if event.interaction > interaction {
                if futureMove.map({ event.sequence > $0.sequence }) ?? true { futureMove = event }
                return []
            }
            lastMoveSequence = event.sequence
            return [event]
        }
        guard event.sequence > lastReliableSequence, event.interaction > interaction else { return [] }
        lastReliableSequence = event.sequence; interaction = event.interaction
        var result = [event]
        if event.kind == .releaseAll {
            futureMove = nil
            lastMoveSequence = max(lastMoveSequence, event.sequence)
        } else if let move = futureMove {
            if move.interaction == interaction && move.sequence > max(event.sequence, lastMoveSequence) {
                lastMoveSequence = move.sequence; result.append(move); futureMove = nil
            } else if move.interaction <= interaction || move.sequence <= event.sequence {
                futureMove = nil
            }
        }
        return result
    }
    public mutating func reset() { self = InputReceiver() }
}

/// Invoke only for the authenticated, locally approved session. No permissions are
/// requested here, and no input is injected when Accessibility is unavailable.
public final class InputInjector {
    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    /// Call only for an explicit authenticated remote-user action. This requests
    /// display activity; it neither unlocks macOS nor enters a password.
    @discardableResult public static func wakeDisplay() -> Bool { RemoteDisplayWake.shared.wake() }
    /// Ends this app's short remote-activity assertion early when a session ends.
    public static func endRemoteActivity() { RemoteDisplayWake.shared.end() }
    public let displayID: CGDirectDisplayID
    private let source = CGEventSource(stateID: .privateState)
    private var pressedKeys = Set<UInt16>()
    private var pressedButtons = Set<Int>()
    private var pressedModifiers = Set<UInt16>()
    private var position = CGPoint.zero
    private let canPostEvents: () -> Bool
    private let displayIsActive: () -> Bool
    private let displayBounds: () -> CGRect
    private let postEvent: (CGEvent) -> Void

    public convenience init(displayID: CGDirectDisplayID = CGMainDisplayID()) {
        self.init(displayID: displayID,
                  canPostEvents: { Self.accessibilityGranted },
                  displayIsActive: { CGDisplayIsActive(displayID) != 0 },
                  displayBounds: { CGDisplayBounds(displayID) },
                  postEvent: { $0.post(tap: .cghidEventTap) })
    }

    /// A test seam for inspecting real CGEvent fields without posting input or
    /// obtaining Accessibility access. Production uses the public initializer.
    init(displayID: CGDirectDisplayID, canPostEvents: @escaping () -> Bool,
         displayIsActive: @escaping () -> Bool, displayBounds: @escaping () -> CGRect,
         postEvent: @escaping (CGEvent) -> Void) {
        self.displayID = displayID
        self.canPostEvents = canPostEvents
        self.displayIsActive = displayIsActive
        self.displayBounds = displayBounds
        self.postEvent = postEvent
    }

    @discardableResult public func apply(_ input: RemoteInput) -> Bool {
        guard input.isValid else { return false }
        if input.kind == .releaseAll {
            let permitted = canPostEvents()
            releaseAll()
            return permitted
        }
        guard canPostEvents() else { return false }
        guard displayIsActive() else { releaseAll(); return false }
        let bounds = displayBounds()
        let point = CGPoint(x: bounds.minX + input.x * max(0, bounds.width - 1), y: bounds.minY + input.y * max(0, bounds.height - 1))
        let flags = CGEventFlags(rawValue: input.modifiers)
        updateModifierState(flags: flags, changedKey: input.kind == .flags ? input.keyCode : nil)
        var event: CGEvent?
        switch input.kind {
        case .move:
            position = point
            let active = pressedButtons.sorted().first
            let type: CGEventType = active == 0 ? .leftMouseDragged : active == 1 ? .rightMouseDragged : active == 2 ? .otherMouseDragged : .mouseMoved
            event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: mouseButton(active ?? 0))
        case .mouseDown, .mouseUp:
            position = point
            let down = input.kind == .mouseDown
            if down { pressedButtons.insert(input.button) } else { pressedButtons.remove(input.button) }
            let type: CGEventType = input.button == 0 ? (down ? .leftMouseDown : .leftMouseUp) : input.button == 1 ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp)
            event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: mouseButton(input.button))
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(input.clickCount))
        case .scroll:
            position = point
            event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(input.deltaY.rounded()), wheel2: Int32(input.deltaX.rounded()), wheel3: 0)
            event?.location = point
        case .keyDown, .keyUp:
            let down = input.kind == .keyDown
            let repeated = pressedKeys.contains(input.keyCode)
            if modifierMask(input.keyCode) == nil {
                if down { pressedKeys.insert(input.keyCode) } else { pressedKeys.remove(input.keyCode) }
            }
            event = CGEvent(keyboardEventSource: source, virtualKey: input.keyCode, keyDown: down)
            event?.setIntegerValueField(.keyboardEventAutorepeat, value: down && repeated ? 1 : 0)
        case .flags:
            let down = pressedModifiers.contains(input.keyCode)
            event = CGEvent(keyboardEventSource: source, virtualKey: input.keyCode, keyDown: down)
            event?.type = .flagsChanged
        case .releaseAll: break
        }
        event?.flags = flags
        if let event { post(event) }
        return event != nil
    }

    public func releaseAll() {
        defer { pressedKeys.removeAll(); pressedButtons.removeAll(); pressedModifiers.removeAll() }
        guard canPostEvents() else { return }
        for key in pressedKeys.sorted() {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            event?.flags = []; if let event { post(event) }
        }
        for key in pressedModifiers.sorted() {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            event?.type = .flagsChanged; event?.flags = []; if let event { post(event) }
        }
        for button in pressedButtons.sorted() {
            let type: CGEventType = button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: mouseButton(button))
            event?.flags = []; if let event { post(event) }
        }
    }
    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: RemoteInput.injectedEventMarker)
        postEvent(event)
    }

    /// The protocol carries aggregate modifier flags plus the physical key that
    /// changed. If both Command keys are down, releasing the left key still has
    /// the Command flag set; toggle that physical key rather than treating the
    /// aggregate flag as a new key-down. Ordinary events also reconcile missing
    /// flags (for example when entering the viewer with a modifier already held)
    /// so releaseAll can always clear the inferred remote state.
    private func updateModifierState(flags: CGEventFlags, changedKey: UInt16?) {
        let groups: [(CGEventFlags, [UInt16])] = [
            (.maskCommand, [55, 54]), (.maskShift, [56, 60]),
            (.maskControl, [59, 62]), (.maskAlternate, [58, 61]),
            (.maskAlphaShift, [57]), (.maskSecondaryFn, [63])
        ]
        for (mask, keys) in groups {
            guard flags.contains(mask) else {
                keys.forEach { pressedModifiers.remove($0) }
                continue
            }
            if let changedKey, keys.contains(changedKey), keys.count > 1 {
                if pressedModifiers.contains(changedKey) { pressedModifiers.remove(changedKey) }
                else { pressedModifiers.insert(changedKey) }
                // If a release is the first physical modifier event seen, an
                // aggregate flag can still represent the other side being held.
                if !keys.contains(where: pressedModifiers.contains) {
                    pressedModifiers.insert(keys.first(where: { $0 != changedKey })!)
                }
            } else if !keys.contains(where: pressedModifiers.contains) {
                pressedModifiers.insert(keys[0])
            }
        }
    }
    private func mouseButton(_ value: Int) -> CGMouseButton { value == 0 ? .left : value == 1 ? .right : .center }
    private func modifierMask(_ key: UInt16) -> CGEventFlags? {
        switch key {
        case 56, 60: return .maskShift
        case 59, 62: return .maskControl
        case 58, 61: return .maskAlternate
        case 54, 55: return .maskCommand
        case 57: return .maskAlphaShift
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }
}

/// Serializes one short-lived power assertion. Repeated wake requests renew the
/// same assertion instead of retaining an unbounded set of assertions.
private final class RemoteDisplayWake {
    static let shared = RemoteDisplayWake()
    private let queue = DispatchQueue(label: "FarReach.remote-display-wake")
    private var assertion: IOPMAssertionID = 0
    private var releaseWork: DispatchWorkItem?

    func wake() -> Bool {
        queue.sync {
            var id = assertion
            let result = IOPMAssertionDeclareUserActivity("FarReach remote user requested display activity" as CFString,
                                                        kIOPMUserActiveRemote, &id)
            guard result == kIOReturnSuccess else { return false }
            assertion = id
            releaseWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.release() }
            releaseWork = work
            queue.asyncAfter(deadline: .now() + 5, execute: work)
            return true
        }
    }
    func end() { queue.async { [self] in release() } }
    private func release() {
        releaseWork?.cancel(); releaseWork = nil
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    }
}
