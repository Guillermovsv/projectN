import AppKit
import SwiftUI

/// The ⋮ menu in a pane's header: Auto options (currently: Complete) plus pane actions.
struct AutoMenu: View {
    @EnvironmentObject var store: Store
    let pane: Pane
    let workspaceID: UUID
    var onRename: () -> Void = {}

    private var supported: Bool { pane.tool != .terminal }

    var body: some View {
        Menu {
            Section("Auto") {
                Toggle(isOn: Binding(
                    get: { pane.isAutoComplete },
                    set: { store.setAutoComplete($0, pane: pane.id, in: workspaceID) })) {
                    Text("Complete")
                    Text(supported
                         ? "Answers Yes to yes/no prompts and picks the recommended option"
                         : "Available in Claude and Codex panes")
                }
                .disabled(!supported)
            }
            Section {
                if supported {
                    Button("Restart & Resume Conversation") { store.start(pane, in: workspaceID, resume: true) }
                }
                Button(supported ? "Restart with New Conversation" : "Restart Shell") { store.start(pane, in: workspaceID, resume: false) }
                if supported {
                    let c = store.composer(pane.id)
                    Button(c.hidden ? "Show Chat Input" : "Hide Chat Input") { c.hidden.toggle(); store.objectWillChange.send() }
                }
                Button("Rename…", action: onRename)
                if let p = store.project(pane.projectID) {
                    Button("Reveal \(p.name) in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)]) }
                }
            }
            Section {
                Button("Close Pane", role: .destructive) { store.closePane(pane.id, in: workspaceID) }
            }
        } label: {
            Image(nsImage: .verticalEllipsis)
        }
        .menuStyle(.borderlessButton)
            .hoverHighlight()
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 22)
        .help("Pane options · Auto")
    }
}

/// Small "AUTO" capsule shown in the header while Complete is on; flashes the last answer it gave.
struct AutoBadge: View {
    @ObservedObject var runtime: TerminalSession
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            Label("AUTO", systemImage: "bolt.fill")
                .font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.yellow.opacity(0.22)))
                .foregroundStyle(.yellow)
                .help("Auto · Complete is on — \(runtime.autoAnswerCount) prompt(s) answered")
            if let last = runtime.lastAutoAnswer, now.timeIntervalSince(last.at) < 4 {
                Text("answered “\(last.label)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: runtime.autoAnswerCount)
        .onReceive(tick) { now = $0 }
        .onChange(of: runtime.autoAnswerCount) { now = Date() }
    }
}

extension NSImage {
    /// ⋮ drawn as a template image (there's no vertical-ellipsis SF Symbol on every macOS version).
    static let verticalEllipsis: NSImage = {
        let size = NSSize(width: 14, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            let d: CGFloat = 3
            for i in 0..<3 {
                let y = rect.midY - d / 2 + CGFloat(i - 1) * 5
                NSBezierPath(ovalIn: NSRect(x: rect.midX - d / 2, y: y, width: d, height: d)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }()
}
