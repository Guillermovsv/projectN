import AppKit
import Carbon.HIToolbox

/// Watches the fn (🌐) key system-wide with a listen-only CGEventTap.
/// Requires Accessibility / Input Monitoring permission.
final class HotkeyMonitor {
    var onFnDown: (() -> Void)?
    var onFnUp: (() -> Void)?
    /// Another key was pressed while fn was held (fn+arrow, fn+F1…) — not a dictation.
    var onFnChord: (() -> Void)?
    /// Escape pressed (used to cancel a dictation in progress).
    var onEscape: (() -> Void)?

    private(set) var shiftHeld = false
    private var fnDown = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

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
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        Self.tapRunning = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let flags = event.flags
            shiftHeld = flags.contains(.maskShift)
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            guard keycode == kVK_Function else { return }
            let isDown = flags.contains(.maskSecondaryFn)
            if isDown && !fnDown {
                fnDown = true
                DispatchQueue.main.async { self.onFnDown?() }
            } else if !isDown && fnDown {
                fnDown = false
                DispatchQueue.main.async { self.onFnUp?() }
            }
        case .keyDown:
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            if keycode == kVK_Escape {
                DispatchQueue.main.async { self.onEscape?() }
            } else if fnDown {
                DispatchQueue.main.async { self.onFnChord?() }
            }
        default:
            break
        }
    }

    /// Input Monitoring — required to *listen* to the keyboard (the fn key).
    static func hasInputMonitoring() -> Bool { CGPreflightListenEventAccess() }
    @discardableResult
    static func requestInputMonitoring() -> Bool { CGRequestListenEventAccess() }

    /// Accessibility — required to *post* ⌘V to paste into other apps.
    static func hasAccessibility(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
}
