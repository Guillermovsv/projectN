import AppKit
import SwiftUI

/// Multi-line chat input: Return sends, ⇧⏎ / ⌥⏎ insert a new line at the cursor.
/// Fixed height (`lines` tall, longer text scrolls) so the terminal above never resizes while you type.
struct PromptInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var lines: Int = 4
    var focusTrigger: Int = 0
    var onSubmit: () -> Void
    var onAt: () -> Void
    var onFocus: () -> Void
    var onBlur: () -> Void = {}

    static let fontSize: CGFloat = 13
    static func height(lines: Int) -> CGFloat {
        let f = NSFont.systemFont(ofSize: fontSize)
        return ceil(NSLayoutManager().defaultLineHeight(for: f)) * CGFloat(lines) + 2
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let tv = InputTextView()
        tv.delegate = context.coordinator
        tv.coordinator = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: Self.fontSize)
        tv.textColor = .labelColor
        tv.textContainerInset = NSSize(width: 0, height: 1)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.placeholder = placeholder
        tv.string = text
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? InputTextView else { return }
        if tv.string != text { tv.string = text; tv.needsDisplay = true }
        if tv.placeholder != placeholder { tv.placeholder = placeholder; tv.needsDisplay = true }
        if focusTrigger != context.coordinator.lastFocusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptInput
        var lastFocusTrigger = 0
        init(_ p: PromptInput) { parent = p; lastFocusTrigger = p.focusTrigger }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            // Typing "@" opens the agent picker (the "@" itself isn't kept).
            if tv.string.count == parent.text.count + 1, tv.string.hasSuffix("@") {
                tv.string.removeLast()
                parent.onAt()
            }
            parent.text = tv.string
        }

        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) {
                let mods = NSApp.currentEvent?.modifierFlags.intersection([.shift, .option, .control]) ?? []
                if !mods.isEmpty { tv.insertText("\n", replacementRange: tv.selectedRange()); return true }
                parent.onSubmit()
                return true
            }
            // ⌥⏎ / ⌃⏎ arrive as these selectors.
            if sel == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) || sel == #selector(NSResponder.insertLineBreak(_:)) {
                tv.insertText("\n", replacementRange: tv.selectedRange())
                return true
            }
            return false
        }
    }

    final class InputTextView: NSTextView {
        weak var coordinator: Coordinator?
        var placeholder = ""

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { coordinator?.parent.onFocus() }
            return ok
        }

        override func resignFirstResponder() -> Bool {
            let ok = super.resignFirstResponder()
            if ok { coordinator?.parent.onBlur() }
            return ok
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !placeholder.isEmpty else { return }
            let attrs: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor]
            (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attrs)
        }
    }
}

/// Latest prompt given to an agent, pinned above its terminal. Click to see it in full.
struct LastPromptBar: View {
    let prompt: String?
    @State private var showFull = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.bubble").font(.caption2).foregroundStyle(.secondary)
            Text(prompt.map { $0.replacingOccurrences(of: "\n", with: " ") } ?? "No prompt yet")
                .font(.caption)
                .foregroundStyle(prompt == nil ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.05))
        .contentShape(Rectangle())
        .onTapGesture { if prompt != nil { showFull = true } }
        .help(prompt ?? "")
        .popover(isPresented: $showFull, arrowEdge: .bottom) {
            ScrollView {
                Text(prompt ?? "").font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .frame(width: 420).frame(maxHeight: 320)
        }
    }
}
