import AppKit
import Carbon.HIToolbox

/// Inserts text at the cursor of the frontmost app by pasting (⌘V), then restores the clipboard.
enum TextInserter {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // Only restore if nobody else touched the clipboard meanwhile.
            guard pb.changeCount == changeCount else { return }
            pb.clearContents()
            pb.writeObjects(saved)
        }
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
