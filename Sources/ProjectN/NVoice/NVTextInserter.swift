import AppKit
import Carbon.HIToolbox

/// Inserts text at the cursor of the frontmost app by pasting (⌘V), then restores the clipboard.
enum TextInserter {
    /// How long the dictated text stays on the clipboard before the previous contents come back.
    /// Electron apps (Slack, WhatsApp, Chrome, VS Code…) read the pasteboard asynchronously; when they're busy
    /// they can take well over half a second to handle ⌘V, and restoring earlier makes them paste the *old*
    /// clipboard — or nothing — and the dictation is lost from the clipboard too.
    static let restoreDelay: TimeInterval = 2.5

    static func insert(_ text: String, restoreClipboard: Bool) {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = restoreClipboard ? (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } : []

        pb.clearContents()
        pb.setString(text, forType: .string)
        let changeCount = pb.changeCount

        pressCmdV()

        guard restoreClipboard, !saved.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            // Only restore if nobody else touched the clipboard meanwhile.
            guard pb.changeCount == changeCount else { return }
            pb.clearContents()
            pb.writeObjects(saved)
        }
    }

    /// Brings `app` to the front and waits (up to `timeout`) until macOS reports it frontmost, so ⌘V lands
    /// in it and not in whatever had focus. `activate()` is asynchronous; a fixed short sleep isn't enough
    /// when the app is busy or when focus moved during a long dictation. Returns whether it got there.
    @MainActor
    static func bringToFront(_ app: NSRunningApplication?, timeout: TimeInterval = 1.0) async -> Bool {
        guard let app, !app.isTerminated else { return false }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return true }
        app.activate()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(30))
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                // Give the app a beat to restore keyboard focus to its text field after activating.
                try? await Task.sleep(for: .milliseconds(80))
                return true
            }
        }
        return false
    }

    private static func pressCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
