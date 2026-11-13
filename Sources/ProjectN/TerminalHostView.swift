import AppKit
import SwiftUI

/// Hosts a long-lived terminal NSView. The view is re-parented into whichever container is on screen,
/// so processes keep running while you navigate away and come back.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession
    var focused: Bool
    /// false while this host sits in the hidden one of Workspaces / Agents (both stay mounted). An inactive host
    /// hides itself (AppKit skips drawing it) and never takes the terminal, so the same session can be shown by
    /// the Agents view and by its pane in the Agents workspace without the two pulling it back and forth.
    @Environment(\.modeActive) private var active

    final class Coordinator {
        var wasFocused = false
        /// Hiding waits for the mode cross-fade to finish, so the terminal fades out with its view.
        var hideWork: DispatchWorkItem?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = TerminalContainer()
        container.wantsLayer = true
        container.isHidden = !active
        if active {
            container.attach(session.view)
            if focused { session.focus() }
        }
        context.coordinator.wasFocused = focused && active
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? TerminalContainer else { return }
        let coordinator = context.coordinator
        guard active else {
            if let w = container.window, let fr = w.firstResponder as? NSView, fr.isDescendant(of: container) {
                w.makeFirstResponder(nil)
            }
            coordinator.wasFocused = false
            if !container.isHidden, coordinator.hideWork == nil {
                let work = DispatchWorkItem { [weak container, weak coordinator] in
                    coordinator?.hideWork = nil
                    container?.isHidden = true
                }
                coordinator.hideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + NavigationModel.switchDuration + 0.05, execute: work)
            }
            return
        }
        coordinator.hideWork?.cancel()
        coordinator.hideWork = nil
        container.isHidden = false
        container.attach(session.view)
        // Take keyboard focus only when the pane *becomes* focused (or shown again), so we don't steal it from the chat box.
        if focused && !context.coordinator.wasFocused { session.focus() }
        context.coordinator.wasFocused = focused
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.hideWork?.cancel()
        // Detach but keep the terminal alive (the Store owns it).
        (nsView as? TerminalContainer)?.detach()
    }
}

/// Container that applies size changes to the terminal only once the layout has settled.
///
/// Every terminal resize makes Claude/Codex redraw their entire screen (it looks like a reload). SwiftUI often
/// lays a pane out in several quick passes (e.g. 43 rows, then 48), so we coalesce those into a single resize.
final class TerminalContainer: NSView {
    private weak var terminal: NSView?
    private var pending: DispatchWorkItem?
    private var pendingSize: NSSize?
    private static let settleDelay: TimeInterval = 0.12

    override var isFlipped: Bool { true }

    func attach(_ view: NSView) {
        if terminal !== view {
            cancelPendingResize()
            if let old = terminal, old.superview === self { old.removeFromSuperview() }
            terminal = view
        }
        if view.superview !== self {
            view.removeFromSuperview()
            view.autoresizingMask = []          // we size it ourselves (debounced)
            addSubview(view)
        }
        clipsToBounds = true
        sizeTerminal(immediately: view.frame.width < 20 || view.frame.height < 20)
    }

    func detach() {
        cancelPendingResize()
        subviews.forEach { $0.removeFromSuperview() }
        terminal = nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard frame.size != newSize else { return }
        super.setFrameSize(newSize)
        sizeTerminal(immediately: false)
    }

    override func layout() {
        super.layout()
        sizeTerminal(immediately: false)
    }

    private func sizeTerminal(immediately: Bool) {
        guard let t = terminal, t.superview === self, bounds.width >= 20, bounds.height >= 20 else {
            cancelPendingResize()
            return
        }
        let pixels = convertToBacking(bounds.size)
        let target = convertFromBacking(NSSize(width: pixels.width.rounded(), height: pixels.height.rounded()))
        if t.frame.origin != .zero { t.setFrameOrigin(.zero) }
        guard t.frame.size != target else { cancelPendingResize(); return }
        // Repeated SwiftUI updates at the same size must not keep postponing the
        // resize forever while the user types or moves between panes.
        guard pendingSize != target else { return }
        cancelPendingResize()
        if immediately {
            t.setFrameSize(target)
            return
        }
        pendingSize = target
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingSize == target,
                  let t = self.terminal, t.superview === self else { return }
            self.pending = nil
            self.pendingSize = nil
            if t.frame.size != target { t.setFrameSize(target) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func cancelPendingResize() {
        pending?.cancel()
        pending = nil
        pendingSize = nil
    }
}
