import AppKit
import SwiftUI

/// The Assistant in its own small window that floats above everything (other apps and full-screen spaces too),
/// instead of in the right panel. Which of the two it uses is `AssistantController.floating`.
@MainActor
final class FloatingAssistant: NSObject, NSWindowDelegate {
    static let shared = FloatingAssistant()

    private var window: NSPanel?
    /// The Assistant view currently in the window (nil while it's closed).
    private var host: NSView?
    private weak var assistant: AssistantController?
    private weak var panel: RightPanelModel?
    private var makeContent: (() -> AnyView)?

    func configure(assistant: AssistantController, panel: RightPanelModel, content: @escaping () -> AnyView) {
        self.assistant = assistant
        self.panel = panel
        makeContent = content
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        guard let makeContent else { return }
        let w = window ?? makeWindow()
        window = w
        // A fresh view each time: closing removes it, so the Assistant stops listening when the window goes away.
        // (Not `contentView == nil`: a new window already has an empty content view, which left the first one blank.)
        if host == nil {
            let h = NSHostingView(rootView: makeContent())
            h.sizingOptions = []
            w.contentView = h
            host = h
        }
        w.makeKeyAndOrderFront(nil)
        assistant?.floatingVisible = true
    }

    func close() { window?.close() }

    func toggle() { isVisible ? close() : show() }

    /// Moves the Assistant between the floating window and the right panel.
    func setFloating(_ on: Bool) {
        guard let assistant, let panel else { return }
        assistant.floating = on
        if on {
            if panel.visible && panel.tab == .assistant { panel.toggle() }
            DispatchQueue.main.async { self.show() }
        } else {
            close()
            panel.show(.assistant)
        }
    }

    private func makeWindow() -> NSPanel {
        let w = AssistantPanelWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 560),
                                     styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        w.title = "Assistant"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isFloatingPanel = true
        w.level = .floating
        w.hidesOnDeactivate = false
        w.becomesKeyOnlyIfNeeded = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.minSize = NSSize(width: 290, height: 380)
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.delegate = self
        if !w.setFrameUsingName(Self.frameName) {
            if let screen = NSScreen.main?.visibleFrame {
                w.setFrameOrigin(NSPoint(x: screen.maxX - 380, y: screen.maxY - 600))
            }
        }
        w.setFrameAutosaveName(Self.frameName)
        return w
    }

    private static let frameName = "ProjectNFloatingAssistant"

    func windowWillClose(_ notification: Notification) {
        window?.contentView = NSView()
        host = nil
        assistant?.floatingVisible = false
    }
}

/// Takes the keyboard (for typing a question) without bringing the whole app forward.
private final class AssistantPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
