import AppKit
import AVFoundation
import CoreMedia

/// Native aspect-fit H.264 viewer. All methods and callbacks run on the main thread.
public final class RemoteDesktopView: NSView {
    public var onInput: ((RemoteInput) -> Void)?
    public var onFrameEnqueued: (() -> Void)?
    public var onNeedsKeyframe: (() -> Void)?
    public var onDisconnect: (() -> Void)?
    /// Return true only after the authenticated transport admits the event.
    /// A false return leaves the physical event available to the local system.
    public var onCapturedKeyboardInput: ((RemoteInput) -> Bool)?
    public var onKeyboardCaptureStatus: ((RemoteKeyboardCaptureStatus) -> Void)? {
        didSet { onKeyboardCaptureStatus?(keyboardCaptureStatus) }
    }
    public private(set) var keyboardCaptureStatus: RemoteKeyboardCaptureStatus = .inactive
    public var systemShortcutsEnabled = true { didSet { refreshKeyboardCapture() } }
    public var inputEnabled = true { didSet { if !inputEnabled { releaseInput() } else { updateKeyboardCapture() } } }
    public private(set) var frameSize = CGSize.zero
    private let videoLayer = AVSampleBufferDisplayLayer()
    private let framePreparer = MediaFramePreparer()
    private var format: CMVideoFormatDescription?
    private var previousSPS = Data(), previousPPS = Data()
    private var awaitingKeyframe = true
    private var displayingDecoded = false
    private var tracking: NSTrackingArea?
    private var notificationTokens: [NSObjectProtocol] = []
    private var didRequestKeyframe = false
    private var hasImage = false
    private var keyboardFocusRequested = false
    private var keyboardCapture: RemoteKeyboardCapture?
    private var keyboardCaptureAttempted = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
        notificationTokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.releaseInput() })
        notificationTokens.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, notification.object as? NSWindow === self.window else { return }
            self.releaseInput()
        })
        notificationTokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshKeyboardCapture() })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { notificationTokens.forEach(NotificationCenter.default.removeObserver) }
    public override var acceptsFirstResponder: Bool { true }
    public override func becomeFirstResponder() -> Bool { refreshKeyboardCapture(); return true }
    public override func resignFirstResponder() -> Bool { releaseInput(); return true }
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { releaseInput() }
        super.viewWillMove(toWindow: newWindow)
    }
    public override func layout() { super.layout(); videoLayer.frame = bounds }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let item = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(item); tracking = item
    }

    @discardableResult public func display(_ frame: EncodedFrame) throws -> Bool {
        try display(framePreparer.prepare(frame))
    }

    @discardableResult public func display(_ prepared: PreparedMediaFrame) throws -> Bool {
        let frame = prepared.frame
        if prepared.isDecoded {
            // Pixel buffers no longer depend on previously presented frames.
            // Dropping a display backlog cannot invalidate the background codec.
            guard CMSampleBufferGetImageBuffer(prepared.sample) != nil else { throw MediaError.invalidFrame("decoded frame has no pixels") }
            if !displayingDecoded || videoLayer.status == .failed || !videoLayer.isReadyForMoreMediaData { videoLayer.flush() }
            displayingDecoded = true
            format = prepared.format; previousSPS = frame.sps; previousPPS = frame.pps
            frameSize = CGSize(width: Int(frame.width), height: Int(frame.height))
            videoLayer.enqueue(prepared.sample)
            awaitingKeyframe = false; didRequestKeyframe = false; hasImage = true
            updateKeyboardCapture(); onFrameEnqueued?()
            return true
        }
        if displayingDecoded {
            videoLayer.flush(); format = nil; awaitingKeyframe = true; displayingDecoded = false
        }
        if videoLayer.status == .failed {
            videoLayer.flush()
            awaitingKeyframe = true
        }
        let changed = previousSPS != frame.sps || previousPPS != frame.pps
        if changed { awaitingKeyframe = true }
        guard !awaitingKeyframe || frame.isKeyframe else { requestKeyframe(); return false }
        if !videoLayer.isReadyForMoreMediaData {
            // Dropping a compressed delta frame breaks later dependencies. Reset and
            // resume at an IDR instead of growing an unbounded display queue.
            videoLayer.flush()
            awaitingKeyframe = true
            guard frame.isKeyframe else { requestKeyframe(); return false }
        }
        if changed || format == nil {
            format = prepared.format
            previousSPS = frame.sps; previousPPS = frame.pps
        }
        frameSize = CGSize(width: Int(frame.width), height: Int(frame.height))
        videoLayer.enqueue(prepared.sample)
        awaitingKeyframe = false; didRequestKeyframe = false; hasImage = true
        updateKeyboardCapture()
        onFrameEnqueued?()
        return true
    }

    public func clear() {
        releaseInput()
        videoLayer.flushAndRemoveImage()
        format = nil; previousSPS = Data(); previousPPS = Data()
        displayingDecoded = false
        framePreparer.reset()
        frameSize = .zero; awaitingKeyframe = true; didRequestKeyframe = false; hasImage = false
    }
    public func releaseInput() {
        keyboardFocusRequested = false
        keyboardCaptureAttempted = false
        keyboardCapture?.stop(); keyboardCapture = nil
        setKeyboardCaptureStatus(systemShortcutsEnabled ? .inactive : .disabled)
        onInput?(RemoteInput(kind: .releaseAll))
    }
    public func releaseKeyboardFocus() { releaseInput(); if window?.firstResponder === self { window?.makeFirstResponder(nil) } }

    private var hasKeyboardScope: Bool {
        keyboardFocusRequested && inputEnabled && hasImage && NSApp.isActive && window?.isKeyWindow == true
            && window?.firstResponder === self && !isHiddenOrHasHiddenAncestor
    }

    public func refreshKeyboardCapture() {
        keyboardCaptureAttempted = false
        updateKeyboardCapture()
    }

    private func updateKeyboardCapture() {
        guard systemShortcutsEnabled else {
            let hadCapture = keyboardCapture != nil
            keyboardCapture?.stop(); keyboardCapture = nil
            if hadCapture { onInput?(RemoteInput(kind: .releaseAll)) }
            setKeyboardCaptureStatus(.disabled); return
        }
        guard hasKeyboardScope else {
            if keyboardCapture != nil {
                keyboardCapture?.stop(); keyboardCapture = nil
                onInput?(RemoteInput(kind: .releaseAll))
            }
            // An OS-disabled tap remains visibly unavailable until a fresh
            // click/explicit release; incoming frames must not hide the warning.
            if keyboardCaptureStatus != .unavailable { setKeyboardCaptureStatus(.inactive) }
            return
        }
        // A tap can be created with keyboard events stripped from its mask if
        // Accessibility is denied. Do not disable ordinary AppKit typing or
        // claim full capture on that partial success.
        guard InputInjector.accessibilityGranted else {
            let hadCapture = keyboardCapture != nil
            keyboardCapture?.stop(); keyboardCapture = nil
            if hadCapture { onInput?(RemoteInput(kind: .releaseAll)) }
            keyboardCaptureAttempted = true
            setKeyboardCaptureStatus(.permissionRequired)
            return
        }
        if keyboardCapture?.isActive == true { setKeyboardCaptureStatus(.capturing); return }
        // Permission/tap failure is retried only after a fresh click, explicit
        // refresh, or option change, not once per incoming video frame.
        guard !keyboardCaptureAttempted else { return }
        keyboardCaptureAttempted = true
        let capture = RemoteKeyboardCapture(shouldCapture: { [weak self] in
            self?.hasKeyboardScope == true && self?.systemShortcutsEnabled == true
        }, send: { [weak self] event in self?.onCapturedKeyboardInput?(event) ?? false }, localAction: { [weak self] action in
            guard let self else { return }
            self.releaseKeyboardFocus()
            if action == .endViewing { self.onDisconnect?() }
        }, unavailable: { [weak self] in
            self?.releaseInput(); self?.setKeyboardCaptureStatus(.unavailable)
        }, lostScope: { [weak self] in self?.releaseInput() })
        keyboardCapture = capture
        if capture.start() { setKeyboardCaptureStatus(.capturing) }
        else {
            capture.stop(); keyboardCapture = nil
            setKeyboardCaptureStatus(InputInjector.accessibilityGranted ? .unavailable : .permissionRequired)
        }
    }

    private func setKeyboardCaptureStatus(_ value: RemoteKeyboardCaptureStatus) {
        guard value != keyboardCaptureStatus else { return }
        keyboardCaptureStatus = value; onKeyboardCaptureStatus?(value)
    }
    private func requestKeyframe() { if !didRequestKeyframe { didRequestKeyframe = true; onNeedsKeyframe?() } }

    /// Public to support codec tests without a window or recording permission.
    public static func makeFormat(_ frame: EncodedFrame) throws -> CMVideoFormatDescription {
        try MediaFramePreparer.makeFormat(frame)
    }

    public static func makeSample(_ frame: EncodedFrame, format: CMVideoFormatDescription) throws -> CMSampleBuffer {
        try MediaFramePreparer.makeSample(frame, format: format)
    }

    private var videoRect: CGRect {
        guard frameSize.width > 0, frameSize.height > 0 else { return .zero }
        let scale = min(bounds.width / frameSize.width, bounds.height / frameSize.height)
        let width = frameSize.width * scale, height = frameSize.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }
    private func coordinates(_ event: NSEvent, clamp: Bool = false) -> CGPoint? {
        guard inputEnabled, hasImage else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let rect = videoRect
        guard rect.width > 0, rect.height > 0, clamp || rect.contains(point) else { return nil }
        return CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)), y: min(1, max(0, 1 - (point.y - rect.minY) / rect.height)))
    }
    private func pointer(_ event: NSEvent, kind: RemoteInput.Kind, clamp: Bool = false) {
        guard let point = coordinates(event, clamp: clamp) else { return }
        onInput?(RemoteInput(kind: kind, x: point.x, y: point.y, button: min(2, event.buttonNumber), clickCount: max(1, min(3, event.clickCount)), modifiers: UInt64(event.modifierFlags.rawValue) & RemoteInput.allowedModifiers))
    }
    private func focusRemoteKeyboard(_ event: NSEvent) {
        guard coordinates(event) != nil else { return }
        keyboardFocusRequested = true
        if window?.makeFirstResponder(self) != true { keyboardFocusRequested = false }
        refreshKeyboardCapture()
    }
    public override func mouseDown(with event: NSEvent) { focusRemoteKeyboard(event); pointer(event, kind: .mouseDown) }
    public override func rightMouseDown(with event: NSEvent) { focusRemoteKeyboard(event); pointer(event, kind: .mouseDown) }
    public override func otherMouseDown(with event: NSEvent) { focusRemoteKeyboard(event); pointer(event, kind: .mouseDown) }
    public override func mouseUp(with event: NSEvent) { pointer(event, kind: .mouseUp, clamp: true) }
    public override func rightMouseUp(with event: NSEvent) { pointer(event, kind: .mouseUp, clamp: true) }
    public override func otherMouseUp(with event: NSEvent) { pointer(event, kind: .mouseUp, clamp: true) }
    public override func mouseMoved(with event: NSEvent) { pointer(event, kind: .move) }
    public override func mouseDragged(with event: NSEvent) { pointer(event, kind: .move, clamp: true) }
    public override func rightMouseDragged(with event: NSEvent) { pointer(event, kind: .move, clamp: true) }
    public override func otherMouseDragged(with event: NSEvent) { pointer(event, kind: .move, clamp: true) }
    public override func mouseExited(with event: NSEvent) { releaseInput() }
    public override func scrollWheel(with event: NSEvent) {
        guard let point = coordinates(event) else { return }
        let scale = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        onInput?(RemoteInput(kind: .scroll, x: point.x, y: point.y, modifiers: UInt64(event.modifierFlags.rawValue) & RemoteInput.allowedModifiers, deltaX: max(-2000, min(2000, event.scrollingDeltaX * scale)), deltaY: max(-2000, min(2000, event.scrollingDeltaY * scale))))
    }
    public override func keyDown(with event: NSEvent) { key(event, kind: .keyDown) }
    public override func keyUp(with event: NSEvent) { key(event, kind: .keyUp) }
    public override func flagsChanged(with event: NSEvent) { key(event, kind: .flags) }
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard allowsAppKitFallback(event) else { return false }
        // Local escapes are never sent remotely, so control can always be released.
        if handleLocalShortcut(event) { return true }
        if event.type == .keyDown { key(event, kind: .keyDown); return true }
        return false
    }
    private func handleLocalShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 47 && event.modifierFlags.contains([.command, .shift]) {
            releaseKeyboardFocus(); onDisconnect?(); return true
        }
        if event.keyCode == 53 && event.modifierFlags.contains([.control, .option]) {
            releaseKeyboardFocus(); return true
        }
        return false
    }
    private func key(_ event: NSEvent, kind: RemoteInput.Kind) {
        guard allowsAppKitFallback(event) else { return }
        if handleLocalShortcut(event) { return }
        let input = RemoteInput(kind: kind, keyCode: event.keyCode, modifiers: UInt64(event.modifierFlags.rawValue) & RemoteInput.allowedModifiers)
        if input.isValid { onInput?(input) }
    }
    private func allowsAppKitFallback(_ event: NSEvent) -> Bool {
        KeyboardCaptureRouter.allowsAppKitFallback(hasScope: hasKeyboardScope,
            tapActive: keyboardCapture?.isActive == true,
            sourceMarker: event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0)
    }
}
