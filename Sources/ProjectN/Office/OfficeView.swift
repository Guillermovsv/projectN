import SwiftUI

extension Store {
    /// Claude, Codex and Cursor panes that are running or asleep, as Office characters.
    var officeAgents: [OfficeAgent] {
        agents.compactMap { entry in
            let p = entry.pane
            let status: OfficeStatus
            if let rt = entry.runtime {
                if !rt.isRunning { status = .offline }
                else if rt.needsInput { status = .needsInput }
                else { status = rt.activity == .working ? .working : .idle }
            } else if sleptPaneIDs.contains(p.id) || hasPendingLaunch(p.id) {
                status = .offline
            } else {
                return nil
            }
            let quiet = entry.runtime.map { Date().timeIntervalSince($0.lastOutputAt) } ?? 0
            return OfficeAgent(id: p.id, workspaceID: entry.workspace.id, name: paneTitle(p),
                               project: project(p.projectID)?.name ?? "?", status: status,
                               resting: status == .idle && quiet >= OfficeAgent.sleepAfter)
        }
    }
}

/// Office view, center: the pixel-art office, and the clicked character's terminal in a floating window.
struct OfficeDetailView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavigationModel
    @Environment(\.sidebarVisible) private var sidebarVisible
    @Environment(\.showSidebar) private var showSidebar
    @Environment(\.modeActive) private var active
    @StateObject private var controller = OfficeController()
    /// The web view is only created once the Office is first opened.
    @State private var opened = false
    /// The character whose terminal floats over the office. Kept here because working/idle changes aren't
    /// published app-wide: the timer refreshes it.
    @State private var floating: OfficeAgent?
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            TopBar(leadingInset: !sidebarVisible) {
                if !sidebarVisible {
                    Button { showSidebar() } label: { Image(systemName: "sidebar.left") }.buttonStyle(ChromeButtonStyle())
                }
                Text("Office").font(.headline)
                Spacer()
            }
            Divider()
            GeometryReader { geo in
                ZStack {
                    if OfficeBundle.root == nil {
                        Text("The Office files are missing from this build.").foregroundStyle(.secondary)
                    } else if opened {
                        OfficeWebView(controller: controller, active: active)
                    }
                    // Only while shown: a terminal can be on screen in one place at a time.
                    if active, let agent = floating, agent.id == nav.officePaneID {
                        OfficeTerminalWindow(agent: agent, area: geo.size)
                            .id(agent.id)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .background(Color.appSurface)
        .onAppear {
            controller.agents = { [weak store] in store?.officeAgents ?? [] }
            controller.onSelect = { [weak nav] id in nav?.officePaneID = id }
            if active { activate() }
        }
        .onChange(of: active) { _, isActive in
            if isActive { activate() } else { store.focusOverride = nil }
        }
        .onChange(of: nav.officePaneID) { _, _ in syncTerminal() }
        .onReceive(refresh) { _ in
            guard active else { return }
            controller.push()
            guard let id = nav.officePaneID else { return }
            let current = store.officeAgents.first { $0.id == id }
            if current != floating { floating = current }
            // The pane was closed elsewhere.
            if current == nil { nav.officePaneID = nil }
        }
    }

    private func activate() {
        opened = true
        controller.push()
        syncTerminal()
    }

    /// Starts a sleeping pane and points the Files panel etc. at the open terminal.
    private func syncTerminal() {
        guard active else { return }
        floating = store.officeAgents.first { $0.id == nav.officePaneID }
        guard let agent = floating, let (_, pane) = store.pane(agent.id, in: agent.workspaceID) else {
            store.focusOverride = nil
            return
        }
        let id = agent.id
        if store.runtimes[id] == nil { store.ensureStarted(id, in: agent.workspaceID) }
        store.focusOverride = (id, pane.projectID)
    }
}

/// The floating terminal of one character: drag it by its title bar, resize it from the bottom-right corner.
private struct OfficeTerminalWindow: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavigationModel
    let agent: OfficeAgent
    let area: CGSize

    @AppStorage("officeTerminalWidth") private var width: Double = 720
    @AppStorage("officeTerminalHeight") private var height: Double = 460
    @AppStorage("officeTerminalX") private var offsetX: Double = 0
    @AppStorage("officeTerminalY") private var offsetY: Double = 0
    @State private var move: CGSize = .zero
    @State private var grow: CGSize = .zero

    private static let minSize = CGSize(width: 380, height: 240)

    /// Size and offset from the center, kept inside the Office area.
    private var frame: CGRect {
        let w = min(max(width + grow.width, Self.minSize.width), max(area.width - 16, 100))
        let h = min(max(height + grow.height, Self.minSize.height), max(area.height - 16, 100))
        // Resizing keeps the top-left corner still.
        let maxX = max((area.width - w) / 2, 0), maxY = max((area.height - h) / 2, 0)
        let x = min(max(offsetX + move.width + (w - clampedWidth) / 2, -maxX), maxX)
        let y = min(max(offsetY + move.height + (h - clampedHeight) / 2, -maxY), maxY)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private var clampedWidth: Double { min(max(width, Self.minSize.width), max(area.width - 16, 100)) }
    private var clampedHeight: Double { min(max(height, Self.minSize.height), max(area.height - 16, 100)) }

    var body: some View {
        let f = frame
        VStack(spacing: 0) {
            titleBar
            Divider()
            ZStack {
                Color.appTerminal
                if let runtime = store.runtimes[agent.id] {
                    TerminalHostView(session: runtime, focused: true)
                        .id(ObjectIdentifier(runtime))
                        .padding(.leading, 6)
                        .padding(.vertical, 3)
                } else {
                    ProgressView("Starting…").controlSize(.small)
                }
            }
        }
        .frame(width: f.width, height: f.height)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.15)))
        .overlay(alignment: .bottomTrailing) { resizeHandle }
        .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
        .offset(x: f.minX, y: f.minY)
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(agent.name).font(.headline).lineLimit(1)
            Text("\(agent.project) · \(agent.statusLabel)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button {
                let id = agent.id, workspace = agent.workspaceID
                nav.officePaneID = nil
                store.reveal(pane: id, in: workspace)
                nav.switchMode(.workspaces)
            } label: { Image(systemName: "arrow.up.forward.square") }
            .buttonStyle(ChromeButtonStyle())
            .help("Open in its workspace")
            Button { nav.officePaneID = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(ChromeButtonStyle())
                .help("Close this window (the agent keeps running)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 34)
        .contentShape(Rectangle())
        .gesture(DragGesture(coordinateSpace: .global)
            .onChanged { move = $0.translation }
            .onEnded { _ in
                let f = frame
                offsetX = f.minX
                offsetY = f.minY
                move = .zero
            })
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .gesture(DragGesture(coordinateSpace: .global)
                .onChanged { grow = $0.translation }
                .onEnded { _ in
                    let f = frame
                    width = f.width
                    height = f.height
                    offsetX = f.minX
                    offsetY = f.minY
                    grow = .zero
                })
            .help("Resize")
    }

    private var color: Color {
        switch agent.status {
        case .working: return .green
        case .needsInput: return .yellow
        case .idle: return .secondary
        case .offline: return .gray.opacity(0.5)
        }
    }
}

/// Office view sidebar: the same characters as a list.
struct OfficeSidebar: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavigationModel
    @Environment(\.modeActive) private var active
    var onHide: () -> Void
    @State private var agents: [OfficeAgent] = []
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Spacer().frame(width: Chrome.trafficLightsWidth)
                ViewModeSwitch()
                Spacer()
                Button(action: onHide) { Image(systemName: "sidebar.left") }
                    .buttonStyle(ChromeButtonStyle())
                    .help("Hide sidebar")
            }
            .padding(.trailing, 10)
            .frame(height: Chrome.topBarHeight)
            .background(WindowDragArea())

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    Text("IN THE OFFICE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                    if agents.isEmpty {
                        Text("Nobody here yet. Open a Claude or Codex pane and it walks in.")
                            .font(.callout).foregroundStyle(.secondary).padding(8)
                    }
                    ForEach(agents) { row($0) }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
            SidebarFooter()
        }
        .background(Color.appSidebar)
        .onChange(of: active) { _, isActive in if isActive { agents = store.officeAgents } }
        .onAppear { agents = store.officeAgents }
        .onReceive(refresh) { _ in
            guard active else { return }
            let new = store.officeAgents
            if new != agents { agents = new }
        }
    }

    private func row(_ agent: OfficeAgent) -> some View {
        Button { nav.officePaneID = agent.id } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name).lineLimit(1)
                    Text(agent.project).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(agent.statusLabel).font(.caption2)
                    .foregroundStyle(agent.status == .needsInput ? Color.yellow : Color.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(nav.officePaneID == agent.id ? Color.primary.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
