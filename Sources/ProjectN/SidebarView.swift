import AppKit
import SwiftUI

/// Always-visible navigation: Workspaces (parents) → Spaces (children), then declared Projects.
struct SidebarView: View {
    @EnvironmentObject var store: Store
    var onHide: () -> Void

    @State private var showNewWorkspace = false
    @State private var newWorkspacePreselect: Set<UUID> = []
    @EnvironmentObject var nav: NavigationModel
    @EnvironmentObject var panel: RightPanelModel
    @State private var renaming: RenameTarget?
    @State private var confirmDelete: Workspace?
    @State private var editProjects: IDBox?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    overviewRow
                        .padding(.bottom, 8)
                    workspacesSection
                    projectsSection
                        .padding(.top, 14)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
            footer
        }
        .background(Color.appSidebar)
        .sheet(isPresented: $showNewWorkspace) { NewWorkspaceSheet(preselected: newWorkspacePreselect) }
        .sheet(item: $renaming) { t in RenameSheet(title: t.title, initial: t.initial, onSave: t.save) }
        .sheet(item: $editProjects) { box in WorkspaceProjectsSheet(workspaceID: box.id) }
        .alert("Remove “\(confirmDelete?.name ?? "")” from ProjectN?",
               isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Remove", role: .destructive) { if let w = confirmDelete { store.deleteWorkspace(w.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the workspace is removed from the app (its spaces and panes are closed). Your project folders and files are not deleted.")
        }
    }

    // MARK: Top bar (traffic lights live on the left)

    private var topBar: some View {
        HStack(spacing: 4) {
            Spacer().frame(width: Chrome.trafficLightsWidth)
            ViewModeSwitch()
            Spacer()
            Button(action: onHide) { Image(systemName: "sidebar.left") }
                .buttonStyle(ChromeButtonStyle())
                .help("Hide sidebar")
            Menu {
                Button("New Workspace…") { openNewWorkspace([]) }
                Button("Add Project Folder…") { _ = store.pickProjectFolders() }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .hoverHighlight()
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 26, height: 24)
            .help("New workspace or project")
        }
        .padding(.trailing, 10)
        .frame(height: Chrome.topBarHeight)
        .background(WindowDragArea())
    }

    private var overviewRow: some View {
        SidebarRow(isSelected: store.state.ui.selectedSpaceID == nil, indent: 0) {
            Image(systemName: "square.grid.2x2").frame(width: 16).foregroundStyle(.secondary)
            Text("Overview")
            Spacer()
        }
        .onTapGesture { store.goHome() }
    }

    // MARK: Workspaces

    private var workspacesSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(title: "Workspaces") {
                Button { openNewWorkspace([]) } label: { Image(systemName: "plus") }
                    .buttonStyle(.hover)
                    .help("New workspace")
            }
            if store.state.workspaces.isEmpty {
                Text("No workspaces yet")
                    .font(.callout).foregroundStyle(.tertiary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            ForEach(store.state.workspaces) { w in
                workspaceRow(w)
                if w.expanded {
                    ForEach(w.spaces) { s in spaceRow(s, in: w) }
                }
            }
        }
    }

    private func workspaceRow(_ w: Workspace) -> some View {
        let running = store.runningCount(in: w)
        let containsSelection = store.state.ui.selectedWorkspaceID == w.id
        return SidebarRow(isSelected: false, indent: 0) {
            Image(systemName: "chevron.right")
                .font(.caption2.bold())
                .rotationEffect(.degrees(w.expanded ? 90 : 0))
                .frame(width: 10)
                .foregroundStyle(.secondary)
            Image(systemName: containsSelection ? "rectangle.3.group.fill" : "rectangle.3.group")
                .foregroundStyle(Color.appAccent)
            Text(w.name).fontWeight(.semibold).lineLimit(1)
            Spacer()
            if running > 0 { CountBadge(count: running) }
            Menu {
                Button { store.newSpace(in: w.id) } label: { Label("Add Space", systemImage: "plus.rectangle") }
                Button { editProjects = IDBox(id: w.id) } label: { Label("Projects…", systemImage: "folder") }
                Button {
                    renaming = RenameTarget(title: "Rename Workspace", initial: w.name) { n in store.updateWorkspace(w.id) { $0.name = n } }
                } label: { Label("Rename…", systemImage: "pencil") }
                Divider()
                Button(role: .destructive) { confirmDelete = w } label: { Label("Remove from App…", systemImage: "trash") }
            } label: {
                Image(nsImage: .verticalEllipsis)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .hoverHighlight()
            .help("Workspace options")
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) { store.updateWorkspace(w.id) { $0.expanded.toggle() } }
        }
        .contextMenu {
            Button("Open") { store.selectWorkspace(w.id) }
            Button("Add Space") { store.newSpace(in: w.id) }
            Button("Projects…") { editProjects = IDBox(id: w.id) }
            Divider()
            Button("Rename…") {
                renaming = RenameTarget(title: "Rename Workspace", initial: w.name) { n in store.updateWorkspace(w.id) { $0.name = n } }
            }
            Divider()
            Button("Remove from App…", role: .destructive) { confirmDelete = w }
        }
    }

    private func spaceRow(_ s: Space, in w: Workspace) -> some View {
        let selected = store.state.ui.selectedSpaceID == s.id
        return SidebarRow(isSelected: selected, indent: 1) {
            Text(s.name).lineLimit(1)
            Spacer(minLength: 4)
            if store.spaceNeedsInput(s) {
                Circle().fill(Color.yellow).frame(width: 7, height: 7).help("A pane here needs your input")
            }
            PaneDots(space: s)
            Text("\(s.panes.count)/\(Space.maxPanes)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(selected ? Color.onAccent.opacity(0.75) : Color.secondary.opacity(0.6))
        }
        .onTapGesture { store.selectSpace(s.id, in: w.id) }
        .contextMenu {
            Button("Rename…") {
                renaming = RenameTarget(title: "Rename Space", initial: s.name) { n in store.updateSpace(s.id, in: w.id) { $0.name = n } }
            }
            Divider()
            Button("Close Space", role: .destructive) { store.deleteSpace(s.id, in: w.id) }
        }
    }

    // MARK: Projects

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(title: "Projects", collapsed: !store.state.ui.projectsExpanded,
                          onToggle: { store.state.ui.projectsExpanded.toggle() }) {
                Button { _ = store.pickProjectFolders() } label: { Image(systemName: "plus") }
                    .buttonStyle(.hover)
                    .help("Add project folder (⌘O)")
            }
            if store.state.ui.projectsExpanded {
                if store.state.projects.isEmpty {
                    Text("Add or drop a folder here")
                        .font(.callout).foregroundStyle(.tertiary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
                ForEach(store.state.projects) { p in
                    SidebarRow(isSelected: false, indent: 0) {
                        Image(systemName: p.exists ? "folder" : "exclamationmark.triangle")
                            .frame(width: 16)
                            .foregroundStyle(p.exists ? Color.appAccent : .orange)
                        Text(p.name).lineLimit(1)
                        Spacer()
                    }
                    .help(p.path)
                    .onTapGesture(count: 2) { store.openProject(p) }
                    .contextMenu {
                        Button("Open in Workspace") { store.openProject(p) }
                        Button("New Workspace with This Project…") { openNewWorkspace([p.id]) }
                        Divider()
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)]) }
                        Button("Rename…") {
                            renaming = RenameTarget(title: "Rename Project", initial: p.name) { n in store.renameProject(p.id, to: n) }
                        }
                        Divider()
                        Button("Remove Project", role: .destructive) { store.removeProject(p.id) }
                    }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            var added = false
            for u in urls where (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                store.addProject(url: u); added = true
            }
            return added
        }
    }

    private var footer: some View { SidebarFooter() }

    private func openNewWorkspace(_ preselect: Set<UUID>) {
        newWorkspacePreselect = preselect
        showNewWorkspace = true
    }
}

struct IDBox: Identifiable { let id: UUID }

extension SidebarView {
    struct RenameTarget: Identifiable {
        let id = UUID()
        let title: String
        let initial: String
        let save: (String) -> Void
    }
}

// MARK: - Building blocks

struct SidebarRow<Content: View>: View {
    let isSelected: Bool
    let indent: Int
    @ViewBuilder var content: () -> Content
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) { content() }
            .padding(.leading, 8 + CGFloat(indent) * 18)
            .padding(.trailing, 8)
            .frame(height: 28)
            .foregroundStyle(isSelected ? Color.onAccent : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.appAccent : (hover ? Color.primary.opacity(0.06) : .clear))
            )
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .handCursor()
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    var collapsed: Bool = false
    var onToggle: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 4) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if onToggle != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            trailing().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .contentShape(Rectangle())
        .handCursor(onToggle != nil)
        .onTapGesture { onToggle?() }
    }
}

struct CountBadge: View {
    let count: Int
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(Color.green).frame(width: 6, height: 6)
            Text("\(count)").font(.caption2.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .help("\(count) running")
    }
}

/// Tiny tool icons for the panes in a space.
struct PaneDots: View {
    @EnvironmentObject var store: Store
    let space: Space

    var body: some View {
        HStack(spacing: 2) {
            ForEach(space.panes.prefix(Space.maxPanes)) { p in
                Image(systemName: p.tool.symbol)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(store.runtimes[p.id]?.needsInput == true ? Color.yellow
                                     : (store.runtimes[p.id]?.isRunning == true ? toolColor(p.tool) : Color.secondary.opacity(0.5)))
            }
        }
    }
}

struct ChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration) }

    private struct StyledBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(configuration.isPressed ? 0.16 : (hovering ? 0.09 : 0))))
                .onHover { hovering = $0 }
                .handCursor()
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

func toolColor(_ t: Tool) -> Color {
    switch t {
    case .claude: return .orange
    case .codex: return .teal
    case .cursor: return .purple
    case .terminal: return .secondary
    }
}


/// Bottom of both sidebars: Settings, theme, version.
struct SidebarFooter: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavigationModel
    @EnvironmentObject var panel: RightPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
            Button { nav.openSettings(.appearance, panel: panel) } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.hover)
            .help("Settings: appearance, accounts & connections, MCP servers, tools")
            Spacer()
            // Appearance, right beside Settings.
            Menu {
                Section("Appearance") {
                    ForEach(AppTheme.all) { t in
                        Button { store.settings.theme = t.id } label: {
                            if t.id == store.settings.theme { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                        }
                    }
                }
                Divider()
                Button("Appearance Settings…") { nav.openSettings(.appearance, panel: panel) }
            } label: {
                Label(AppTheme.current.name, systemImage: "paintpalette")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .hoverHighlight()
            .help("Appearance")
        }
        VersionTag().padding(.leading, 2)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Workspaces | Agents switch at the top of the sidebar (⌃⌘1 / ⌃⌘2).
struct ViewModeSwitch: View {
    @EnvironmentObject var nav: NavigationModel
    @EnvironmentObject var agents: AgentHarness

    var body: some View {
        HStack(spacing: 2) {
            ForEach(NavigationModel.Mode.allCases) { m in
                Button { nav.switchMode(m) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: m.symbol)
                        if m == .agents, !agents.pendingUserRequests().isEmpty {
                            Circle().fill(Color.yellow).frame(width: 6, height: 6)
                        }
                    }
                    .frame(width: 34, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(nav.mode == m ? Color.primary.opacity(0.12) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(nav.mode == m ? .primary : .secondary)
                .help("\(m.label) view (⌃⌘\(m == .workspaces ? 1 : 2))")
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}
