import AppKit
import SwiftUI

enum Chrome {
    /// Height of the top bars; the window's traffic lights sit vertically centred in it.
    static let topBarHeight: CGFloat = 40
    /// Horizontal room reserved for the traffic lights at the top-left of the sidebar.
    static let trafficLightsWidth: CGFloat = 86
}

/// An area that drags the window (and zooms on double-click), used behind the custom top bars.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.zoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Positions the standard window buttons so they're vertically centred in our top bar.
struct TrafficLightsAligner: NSViewRepresentable {
    final class Probe: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.align() }
                })
            }
            DispatchQueue.main.async { self.align() }
        }

        func align() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let container = close.superview else { return }
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            let h = close.frame.height
            // The titlebar view's top edge is the window's top edge; centre the buttons at topBarHeight/2 below it,
            // without letting them leave the titlebar view (they'd be clipped).
            let containerHeight = container.frame.height
            let y = max(0, containerHeight - Chrome.topBarHeight / 2 - h / 2)
            // Keep the system's horizontal positions; only shift vertically.
            for type in buttons {
                guard let b = window.standardWindowButton(type), b.frame.origin.y != y else { continue }
                b.setFrameOrigin(NSPoint(x: b.frame.origin.x, y: y))
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Probe)?.align()
    }
}
