import AppKit
import Carbon.HIToolbox

/// Watches the dictation shortcut system-wide. A single modifier key (fn, right ⌘…) is heard with a
/// listen-only CGEventTap, since pressing it types nothing. Any other key (A, ⌃⌥D, F13…) is registered
/// as a Carbon hot key, which consumes it so it doesn't also type into the frontmost app.
/// The tap also reports Shift and Esc. Requires Accessibility / Input Monitoring permission.
final class HotkeyMonitor {
    var onHotkeyDown: (() -> Void)?
    var onHotkeyUp: (() -> Void)?
    /// Another key was pressed while a single-modifier shortcut was held (fn+arrow, fn+F1…) — not a dictation.
    var onHotkeyChord: (() -> Void)?
    /// Escape pressed (used to cancel a dictation in progress).
    var onEscape: (() -> Void)?

    private(set) var shiftHeld = false
    private var hotkey = DictationHotkey.fn
    private var active = false
    private var suspended = false
    private var hotkeyDown = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var carbonHandler: EventHandlerRef?
    private var carbonHotkey: EventHotKeyRef?

    var isRunning: Bool { tap != nil }
    /// For the Settings diagnostics panel.
    static var tapRunning = false

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let ref = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, ref in
                guard let ref else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(ref).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: ref
        ) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Self.tapRunning = true
        return true
    }

    func stop() {
        active = false
        _ = refreshHotkey()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        Self.tapRunning = false
    }

    /// Starts listening for this shortcut. Returns false if macOS refused to register it.
    @discardableResult
    func configure(_ hotkey: DictationHotkey) -> Bool {
        self.hotkey = hotkey
        active = true
        return refreshHotkey()
    }

    /// While the user records a new shortcut, the current one must not fire (or swallow the key being recorded).
    func setSuspended(_ suspended: Bool) {
        self.suspended = suspended
        _ = refreshHotkey()
    }

    private func refreshHotkey() -> Bool {
        if let carbonHotkey { UnregisterEventHotKey(carbonHotkey); self.carbonHotkey = nil }
        hotkeyDown = false
        guard active, !suspended, !hotkey.isModifierOnly else { return true }
        return registerCarbonHotkey()
    }

    private func registerCarbonHotkey() -> Bool {
        if carbonHandler == nil {
            let specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                         EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, ref in
                guard let event, let ref else { return OSStatus(eventNotHandledErr) }
                Unmanaged<HotkeyMonitor>.fromOpaque(ref).takeUnretainedValue().handleCarbon(event)
                return noErr
            }, specs.count, specs, Unmanaged.passUnretained(self).toOpaque(), &carbonHandler)
            guard status == noErr else {
                Diagnostics.log("could not install the hot key handler: \(status)")
                return false
            }
        }
        let id = EventHotKeyID(signature: OSType(0x4E56_6F69), id: 1)   // 'NVoi'
        let status = RegisterEventHotKey(UInt32(hotkey.keyCode), UInt32(hotkey.modifiers), id,
                                         GetEventDispatcherTarget(), 0, &carbonHotkey)
        guard status == noErr else {
            Diagnostics.log("could not register \(hotkey.displayName): \(status)")
            carbonHotkey = nil
            return false
        }
        return true
    }

    private func handleCarbon(_ event: EventRef) {
        setHotkeyDown(GetEventKind(event) == UInt32(kEventHotKeyPressed))
    }

    private func setHotkeyDown(_ isDown: Bool) {
        guard isDown != hotkeyDown else { return }
        hotkeyDown = isDown
        DispatchQueue.main.async { isDown ? self.onHotkeyDown?() : self.onHotkeyUp?() }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let flags = event.flags
            shiftHeld = flags.contains(.maskShift)
            let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard !suspended, hotkey.isModifierOnly, keycode == hotkey.keyCode else { return }
            setHotkeyDown(DictationHotkey.isPressed(modifierKey: keycode, flags: flags.rawValue))
        case .keyDown:
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            if keycode == kVK_Escape {
                DispatchQueue.main.async { self.onEscape?() }
            } else if hotkeyDown && hotkey.isModifierOnly {
                DispatchQueue.main.async { self.onHotkeyChord?() }
            }
        default:
            break
        }
    }

    /// Input Monitoring — required to *listen* to the keyboard.
    static func hasInputMonitoring() -> Bool { CGPreflightListenEventAccess() }
    @discardableResult
    static func requestInputMonitoring() -> Bool { CGRequestListenEventAccess() }

    /// Accessibility — required to *post* ⌘V to paste into other apps.
    static func hasAccessibility(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
}
