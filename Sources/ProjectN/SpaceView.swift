import AppKit
import SwiftUI

/// A space: up to 8 panes tiled in a grid. A single pane fills the area; more panes split it.
struct SpaceView: View {
    @EnvironmentObject var store: Store
    @Environment(\.sidebarVisible) private var sidebarVisible
    @Environment(\.showSidebar) private var showSidebar
    let workspaceID: UUID
    let spaceID: UUID

    @State private var mouseMonitor: Any?
    @State private var keyMonitor: Any?
    @State private var renamingPane: Pane?
    @State private var renamingSpace = false

    private var workspace: Workspace? { store.workspace(workspaceID) }
    private var space: Space? { store.space(spaceID, in: workspaceID) }

    var body: some View {
        if let w = workspace, let s = space {
            VStack(spacing: 0) {
                topBar(w, s)
                if s.panes.isEmpty {
                    EmptySpaceView(workspace: w, space: s, projectID: store.defaultProjectID(in: w.id, space: s.id))
                } else {
                    PaneGrid(workspace: w, space: s, onRename: { renamingPane = $0 })
                        .padding(8)
                }
            }
            .background(Color.appSurface)
            .sheet(item: $renamingPane) { p in
                RenameSheet(title: "Rename Pane", initial: store.paneTitle(p)) { store.renamePane(p.id, in: w.id, to: $0) }
            }
            .sheet(isPresented: $renamingSpace) {
                RenameSheet(title: "Rename Space", initial: s.name) { n in store.updateSpace(s.id, in: w.id) { $0.name = n } }
            }
            .onAppear { installMouseMonitor(); installKeyMonitor() }
            .onDisappear(perform: removeMouseMonitor)
        }
    }

    // MARK: Top bar

    private func topBar(_ w: Workspace, _ s: Space) -> some View {
        TopBar(leadingInset: !sidebarVisible) {
            if !sidebarVisible {
                Button(action: showSidebar) { Image(systemName: "sidebar.left") }
                    .buttonStyle(ChromeButtonStyle()).help("Show sidebar")
            }
            HStack(spacing: 6) {
                Text(w.name).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Text(s.name).fontWeight(.semibold)
                    .onTapGesture(count: 2) { renamingSpace = true }
                    .help("Double-click to rename")
            }
            .font(.headline)
            .lineLimit(1)
            Text("\(s.panes.count)/\(Space.maxPanes)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            Spacer()

            UsageMeters(tool: store.activeAgentTool)

            ActiveCounts()
            AddPaneMenu(workspace: w, space: s)
        }
    }

    private func shortcutLetter(_ t: Tool) -> String {
        switch t { case .claude: return "T"; case .codex: return "Y"; case .cursor: return "I"; case .terminal: return "U" }
    }

    // Clicking inside a terminal (which swallows mouse events) focuses that pane.
    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [store, workspaceID, spaceID] event in
            guard let s = store.space(spaceID, in: workspaceID) else { return event }
            for p in s.panes {
                guard let v = store.runtimes[p.id]?.view, v.window === event.window, v.superview != nil else { continue }
                if v.bounds.contains(v.convert(event.locationInWindow, from: nil)) {
                    store.focusPane(p.id, in: workspaceID)
                    break
                }
            }
            return event
        }
    }

    private func removeMouseMonitor() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        mouseMonitor = nil
        if let k = keyMonitor { NSEvent.removeMonitor(k) }
        keyMonitor = nil
    }

    /// ⇧⏎ inside a Claude/Codex terminal sends ESC+CR (what ⌥⏎ sends), which both treat as a new line.
    /// Without this SwiftTerm sends a plain CR, indistinguishable from ⏎, so it submitted.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [store] event in
            guard event.keyCode == 36 || event.keyCode == 76,
                  event.modifierFlags.intersection([.shift, .option, .control, .command]) == .shift,
                  let fr = event.window?.firstResponder as? NSView else { return event }
            guard let rt = store.runtimes.values.first(where: { $0.view === fr }), rt.shiftReturnInsertsNewline else { return event }
            rt.send("\u{1b}\r")
            return nil
        }
    }
}

/// The single "+" in the top bar: Claude / Codex / Terminal (grouped by project when the workspace has several).
struct AddPaneMenu: View {
    @EnvironmentObject var store: Store
    let workspace: Workspace
    let space: Space

    var body: some View {
        Menu {
            if space.isFull {
                Text("This space is full (\(Space.maxPanes) panes)")
                Button("New Space") { store.newSpace(in: workspace.id) }
            } else if workspace.projectIDs.isEmpty {
                Text("Add a project to this workspace first")
            } else if workspace.projectIDs.count == 1 {
                items(projectID: workspace.projectIDs[0])
            } else {
                let def = store.defaultProjectID(in: workspace.id, space: space.id)
                ForEach(workspace.projectIDs, id: \.self) { pid in
                    if let p = store.project(pid) {
                        Section(p.name + (pid == def ? "  (current)" : "")) { items(projectID: pid) }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
            .hoverHighlight()
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 28, height: 24)
        .help(space.isFull ? "Space is full" : "Add pane — ⌘T Claude · ⌘Y Codex · ⌘I Cursor · ⌘U Terminal")
    }

    @ViewBuilder
    private func items(projectID: UUID) -> some View {
        ForEach(Tool.allCases) { t in
            Button {
                store.addPane(tool: t, projectID: projectID, in: workspace.id, space: space.id)
            } label: {
                Label(t.label, systemImage: t.symbol)
            }
        }
    }
}

// MARK: - Grid

struct PaneGrid: View {
    @EnvironmentObject var store: Store
    let workspace: Workspace
    let space: Space
    let onRename: (Pane) -> Void

    /// 1 → 1×1, 2 → 2×1, 3 → 3×1, 4 → 2×2, 5–6 → 3×2, 7–8 → 4×2.
    static func columns(for n: Int) -> Int {
        switch n {
        case ...3: return max(n, 1)
        case 4: return 2
        case 5, 6: return 3
        default: return 4
        }
    }

    var body: some View {
        let n = space.panes.count
        // Only honor a maximized pane that still exists and when there's something to hide.
        let maxID = store.maximizedPanes[space.id].flatMap { id in n > 1 && space.panes.contains { $0.id == id } ? id : nil }
        let maxIndex = maxID.flatMap { id in space.panes.firstIndex { $0.id == id } }
        PaneTileLayout(columns: Self.columns(for: n), maximizedIndex: maxIndex) {
            // Keep each pane under the same parent when the column count changes.
            ForEach(Array(space.panes.enumerated()), id: \.element.id) { index, p in
                PaneView(pane: p, workspaceID: workspace.id,
                         index: index,
                         isFocused: p.id == space.focusedPaneID || (space.focusedPaneID == nil && p.id == space.panes.first?.id),
                         showFocusRing: n > 1 && maxID == nil,
                         canMaximize: n > 1,
                         isMaximized: p.id == maxID,
                         onToggleMaximize: { store.toggleMaximize(p.id, inSpace: space.id) },
                         onRename: { onRename(p) })
                    .opacity(maxID == nil || p.id == maxID ? 1 : 0)
                    .allowsHitTesting(maxID == nil || p.id == maxID)
            }
        }
    }
}

/// Panes divide the available space equally; their terminal/menu contents do not
/// determine their size. Nested flexible stacks repeatedly measured those contents,
/// especially the responsive composer menus, when the grid gained its second row.
struct PaneTileLayout: Layout {
    let columns: Int
    var maximizedIndex: Int? = nil
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        let height = proposal.height ?? 600
        return CGSize(width: width.isFinite ? max(0, width) : 800,
                      height: height.isFinite ? max(0, height) : 600)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        if let m = maximizedIndex, subviews.indices.contains(m) {
            // Hidden panes keep a real size (so their terminals aren't resized to 0) but sit off-screen.
            let off = ProposedViewSize(width: bounds.width, height: bounds.height)
            for (index, subview) in subviews.enumerated() {
                let origin = index == m ? bounds.origin : CGPoint(x: bounds.maxX + 20_000, y: bounds.minY)
                subview.place(at: origin, anchor: .topLeading, proposal: off)
            }
            return
        }
        let cols = max(1, columns)
        let rows = (subviews.count + cols - 1) / cols
        let height = max(0, (bounds.height - CGFloat(rows - 1) * spacing) / CGFloat(rows))
        for (index, subview) in subviews.enumerated() {
            // Preserve the old grid's full-width final row when it is incomplete.
            let rowColumns = min(cols, subviews.count - (index / cols) * cols)
            let width = max(0, (bounds.width - CGFloat(rowColumns - 1) * spacing) / CGFloat(rowColumns))
            let cell = ProposedViewSize(width: width, height: height)
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(index % cols) * (width + spacing),
                                     y: bounds.minY + CGFloat(index / cols) * (height + spacing)),
                          anchor: .topLeading, proposal: cell)
        }
    }
}

struct PaneView: View {
    @EnvironmentObject var store: Store
    let pane: Pane
    let workspaceID: UUID
    let index: Int
    let isFocused: Bool
    let showFocusRing: Bool
    var canMaximize = false
    var isMaximized = false
    var onToggleMaximize: () -> Void = {}
    let onRename: () -> Void
    @State private var dropTargeted = false

    var body: some View {
        let runtime = store.runtimes[pane.id]
        let composer = store.composer(pane.id)
        VStack(spacing: 0) {
            PaneHeader(pane: pane, workspaceID: workspaceID, index: index, runtime: runtime, isFocused: isFocused,
                       canMaximize: canMaximize, isMaximized: isMaximized, onToggleMaximize: onToggleMaximize,
                       onRename: onRename)
            if pane.tool != .terminal { LastPromptBar(prompt: pane.lastPrompt) }
            ZStack {
                Color.appTerminal
                if let runtime {
                    TerminalHostView(session: runtime, focused: isFocused)
                        .padding(.leading, 6)
                        .padding(.top, 4)
                        .padding(.bottom, 2)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if pane.tool != .terminal {
                ComposerSlot(state: composer, pane: pane, workspaceID: workspaceID, runtime: runtime)
            }
        }
        // Equal-width columns: a pane never grows past its share because of its contents.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appTerminal)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.appAccent.opacity(0.12))
                    .overlay(
                        Label(pane.tool == .terminal ? "Drop to paste paths" : "Drop to attach · drop a pane to tag it",
                              systemImage: "tray.and.arrow.down")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Capsule().fill(.regularMaterial))
                    )
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: PaneDrop.types, isTargeted: $dropTargeted) { providers in
            PaneDrop.handle(providers, pane: pane, workspaceID: workspaceID, store: store)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor(runtime), lineWidth: (runtime?.needsInput == true || (isFocused && showFocusRing)) ? 1.5 : 1)
        )
        .task(id: pane.id) {
            // After a relaunch the pane exists but its process doesn't: start it and resume.
            store.ensureStarted(pane.id, in: workspaceID)
        }
    }
}

extension PaneView {
    func borderColor(_ runtime: TerminalSession?) -> Color {
        if runtime?.needsInput == true { return .yellow }
        return isFocused && showFocusRing ? Color.appAccent.opacity(0.9) : Color.primary.opacity(0.1)
    }
}

/// Shows the chat box unless the user hid it for this pane.
struct ComposerSlot: View {
    @ObservedObject var state: Store.ComposerState
    let pane: Pane
    let workspaceID: UUID
    let runtime: TerminalSession?

    var body: some View {
        if !state.hidden {
            ComposerView(state: state, pane: pane, workspaceID: workspaceID, runtime: runtime)
                .equatable()
                .background(Color.appWindow)
        }
    }
}

struct PaneHeader: View {
    @EnvironmentObject var store: Store
    let pane: Pane
    let workspaceID: UUID
    let index: Int
    let runtime: TerminalSession?
    let isFocused: Bool
    var canMaximize = false
    var isMaximized = false
    var onToggleMaximize: () -> Void = {}
    let onRename: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: pane.tool.symbol)
                .font(.caption)
                .foregroundStyle(toolColor(pane.tool))
            Text(store.paneTitle(pane))
                .font(.callout.weight(isFocused ? .semibold : .regular))
                .lineLimit(1)
                .onTapGesture(count: 2, perform: onRename)
                .onDrag {
                    NSItemProvider(object: PaneDrag.encode(Store.PaneRef(workspaceID: workspaceID, paneID: pane.id)) as NSString)
                }
                .help("Double-click to rename · drag onto another agent's pane to tag this one")
            StatusDot(runtime: runtime)
            if pane.isAutoComplete, let runtime { AutoBadge(runtime: runtime) }
            if runtime?.needsInput == true {
                Text("Needs input")
                    .fixedSize()
                    .font(.caption2.bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.yellow))
            }
            Spacer(minLength: 4)
            if index < 9 {
                Text("⌘\(index + 1)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            AutoMenu(pane: pane, workspaceID: workspaceID, onRename: onRename)
            if canMaximize {
                Button(action: onToggleMaximize) {
                    Image(systemName: isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(ChromeButtonStyle())
                .help(isMaximized ? "Restore split view" : "Expand pane")
            }
            Button { store.closePane(pane.id, in: workspaceID) } label: {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
            }
            .buttonStyle(ChromeButtonStyle())
            .help("Close pane")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(runtime?.needsInput == true ? Color.yellow.opacity(0.16)
                    : (isFocused ? Color.appAccent.opacity(0.12) : Color.appWindow))
        .contentShape(Rectangle())
        .onTapGesture { store.focusPane(pane.id, in: workspaceID) }
    }
}

struct StatusDot: View {
    let runtime: TerminalSession?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .help(help)
    }

    private var color: Color {
        guard let r = runtime else { return .gray.opacity(0.5) }
        switch r.status {
        case .running: return .green
        case .exited(let c): return c == 0 ? .gray : .red
        }
    }

    private var help: String {
        guard let r = runtime else { return "Starting…" }
        switch r.status {
        case .running: return "Running"
        case .exited(let c): return "Exited (\(c.map(String.init) ?? "signal"))"
        }
    }
}

struct EmptySpaceView: View {
    @EnvironmentObject var store: Store
    let workspace: Workspace
    let space: Space
    let projectID: UUID?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "rectangle.split.2x2").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("\(space.name) is empty").font(.title2.bold())
            if workspace.projectIDs.isEmpty {
                Text("Add a project to this workspace first (right-click it in the sidebar → Projects…).")
                    .foregroundStyle(.secondary)
            } else {
                Text("Open up to \(Space.maxPanes) panes here\(projectName.map { " in \($0)" } ?? "").")
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(Tool.allCases) { t in
                        Button {
                            store.addPane(tool: t, projectID: projectID, in: workspace.id, space: space.id)
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: t.symbol).font(.title2).foregroundStyle(toolColor(t))
                                Text(t.label)
                            }
                            .frame(width: 110, height: 80)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: 10, inset: 0)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.appElevated))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var projectName: String? { projectID.flatMap { store.project($0)?.name } }
}
