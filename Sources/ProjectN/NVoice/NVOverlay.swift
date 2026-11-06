import AppKit
import SwiftUI

enum DictationPhase: Equatable {
    case idle, recording, transcribing, enhancing, done, error(String)
}

final class OverlayModel: ObservableObject {
    static let barCount = 22
    @Published var phase: DictationPhase = .idle
    @Published var levels: [CGFloat] = Array(repeating: 0, count: barCount)
    @Published var enhance = false
    @Published var hovering = false
    @Published var message: String?

    func push(level: Float) {
        // Smooth + keep a rolling window so the wave scrolls.
        let last = levels.last ?? 0
        let v = CGFloat(level)
        let smoothed = v > last ? v : last * 0.6 + v * 0.4
        levels.removeFirst()
        levels.append(smoothed)
    }

    func resetLevels() { levels = Array(repeating: 0, count: Self.barCount) }
}

// MARK: - Window

final class OverlayController {
    let model = OverlayModel()
    private var panel: NSPanel!
    var onClick: (() -> Void)?

    init() {
        let size = NSSize(width: 260, height: 64)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView: OverlayView(model: model, onClick: { [weak self] in self?.onClick?() }))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        reposition()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reposition()
        }
    }

    func setVisible(_ visible: Bool) {
        if visible { reposition(); panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    func reposition() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = NVoiceSettings.shared.widgetPosition == .bottom ? frame.minY + 10 : frame.maxY - size.height - 6
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - View

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    var onClick: () -> Void
    @State private var spin = false

    private var isActive: Bool { model.phase != .idle }
    private var accent: [Color] {
        model.enhance
            ? [Color(red: 0.62, green: 0.36, blue: 1.0), Color(red: 1.0, green: 0.35, blue: 0.7), Color(red: 1.0, green: 0.62, blue: 0.3)]
            : [Color(red: 0.2, green: 0.85, blue: 1.0), Color(red: 0.35, green: 0.55, blue: 1.0), Color(red: 0.65, green: 0.4, blue: 1.0)]
    }

    private var pillWidth: CGFloat {
        switch model.phase {
        case .idle: return model.hovering ? 92 : 46
        case .recording: return 170
        case .transcribing, .enhancing: return 150
        case .done: return 60
        case .error: return 240
        }
    }
    private var pillHeight: CGFloat { model.phase == .idle ? (model.hovering ? 22 : 10) : 34 }

    var body: some View {
        ZStack {
            pill
                .frame(width: pillWidth, height: pillHeight)
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: model.phase)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.hovering)
                .onHover { model.hovering = $0 }
                .onTapGesture { onClick() }
                .help(model.enhance ? "Enhance prompt: ON (click to turn off)" : "Enhance prompt: OFF (click to turn on)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var pill: some View {
        let shape = Capsule(style: .continuous)
        ZStack {
            shape.fill(.black.opacity(isActive ? 0.82 : 0.55))
            shape.strokeBorder(
                isActive ? AnyShapeStyle(LinearGradient(colors: accent, startPoint: .leading, endPoint: .trailing))
                         : AnyShapeStyle(Color.white.opacity(0.25)),
                lineWidth: isActive ? 1.5 : 1)
            content.padding(.horizontal, 12)
        }
        .shadow(color: isActive ? accent[1].opacity(0.55) : .black.opacity(0.25), radius: isActive ? 12 : 4)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            if model.hovering {
                HStack(spacing: 5) {
                    Image(systemName: model.enhance ? "sparkles" : "mic.fill").font(.system(size: 9, weight: .bold))
                    Text("fn").font(.system(size: 10, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(model.enhance ? AnyShapeStyle(LinearGradient(colors: accent, startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(Color.white.opacity(0.7)))
            } else {
                HStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { _ in Circle().fill(Color.white.opacity(0.45)).frame(width: 2.5, height: 2.5) }
                }
            }
        case .recording:
            HStack(spacing: 8) {
                if model.enhance {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(LinearGradient(colors: accent, startPoint: .top, endPoint: .bottom))
                }
                Waveform(levels: model.levels, colors: accent)
            }
        case .transcribing, .enhancing:
            HStack(spacing: 8) {
                Circle()
                    .trim(from: 0.1, to: 0.8)
                    .stroke(LinearGradient(colors: accent, startPoint: .leading, endPoint: .trailing), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 13, height: 13)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
                    .onDisappear { spin = false }
                Text(model.phase == .enhancing ? "Enhancing…" : "Transcribing…")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }
        case .done:
            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                .foregroundStyle(LinearGradient(colors: accent, startPoint: .leading, endPoint: .trailing))
        case .error(let msg):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(msg).lineLimit(1).truncationMode(.tail)
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

struct Waveform: View {
    let levels: [CGFloat]
    let colors: [Color]
    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { i in
                // Taper the edges so the wave looks centred.
                let pos = Double(i) / Double(max(levels.count - 1, 1))
                let taper = 0.45 + 0.55 * sin(pos * .pi)
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .bottom, endPoint: .top))
                    .frame(width: 3, height: max(3, 22 * levels[i] * taper))
            }
        }
        .animation(.easeOut(duration: 0.08), value: levels)
        .frame(height: 24)
    }
}
