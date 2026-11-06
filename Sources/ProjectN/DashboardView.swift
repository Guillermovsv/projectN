import AppKit
import SwiftUI

/// Shown when no space is selected: all workspaces as cards.
struct DashboardView: View {
    @EnvironmentObject var store: Store
    @Environment(\.sidebarVisible) private var sidebarVisible
    @Environment(\.showSidebar) private var showSidebar
    @State private var showNewWorkspace = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar(leadingInset: !sidebarVisible) {
                if !sidebarVisible {
                    Button(action: showSidebar) { Image(systemName: "sidebar.left") }
                        .buttonStyle(ChromeButtonStyle()).help("Show sidebar")
                }
                Text("Overview").font(.headline)
                Spacer()
                UsageMeters(tool: store.activeAgentTool)
                Button { showNewWorkspace = true } label: { Label("New Workspace", systemImage: "plus") }
                    .controlSize(.small)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Workspaces").font(.largeTitle.bold())
                        Text("Each workspace holds spaces of up to \(Space.maxPanes) panes — Claude, Codex or a terminal. Everything is restored when you reopen the app.")
                            .foregroundStyle(.secondary)
                    }
                    if store.state.workspaces.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                            ForEach(store.state.workspaces.sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }) { w in
                                WorkspaceCard(workspace: w)
                                    .onTapGesture { store.selectWorkspace(w.id) }
                            }
                            NewWorkspaceTile { showNewWorkspace = true }
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $showNewWorkspace) { NewWorkspaceSheet(preselected: []) }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.3.group").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No workspaces yet").font(.title2.bold())
            Text(store.state.projects.isEmpty
                 ? "Add a project folder, then create a workspace."
                 : "Create a workspace, or double-click a project in the sidebar.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Add Project Folder") { _ = store.pickProjectFolders() }
                Button("New Workspace") { showNewWorkspace = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.state.projects.isEmpty)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

/// The bar across the top of the detail area (same height as the sidebar's, draggable).
struct TopBar<Content: View>: View {
    /// When the sidebar is hidden the traffic lights sit over the detail area, so leave room for them.
    var leadingInset: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 10) { content() }
            .padding(.leading, leadingInset ? Chrome.trafficLightsWidth : 16)
            .padding(.trailing, 12)
            .frame(height: Chrome.topBarHeight)
            .frame(maxWidth: .infinity)
            .background(WindowDragArea())
            .overlay(alignment: .bottom) { Divider() }
    }
}

struct WorkspaceCard: View {
    @EnvironmentObject var store: Store
    let workspace: Workspace
    @State private var hover = false

    var body: some View {
        let running = store.runningCount(in: workspace)
        let panes = workspace.spaces.flatMap(\.panes)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "rectangle.3.group.fill").foregroundStyle(Color.appAccent)
                Text(workspace.name).font(.headline).lineLimit(1)
                Spacer()
                if running > 0 { CountBadge(count: running) }
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(workspace.projectIDs.prefix(3), id: \.self) { pid in
                    if let p = store.project(pid) {
                        Label(p.name, systemImage: "folder").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if workspace.projectIDs.count > 3 {
                    Text("+\(workspace.projectIDs.count - 3) more").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Label("\(workspace.spaces.count) space\(workspace.spaces.count == 1 ? "" : "s")", systemImage: "rectangle.split.2x2")
                Label("\(panes.count) pane\(panes.count == 1 ? "" : "s")", systemImage: "terminal")
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(height: 160)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.appElevated))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hover ? Color.appAccent : Color.secondary.opacity(0.2), lineWidth: hover ? 2 : 1))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .handCursor()
    }
}

struct NewWorkspaceTile: View {
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.title)
                Text("New Workspace")
            }
            .foregroundStyle(hover ? Color.appAccent : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(.secondary.opacity(0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .handCursor()
    }
}

struct ProjectRow: View {
    let project: Project

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: project.exists ? "folder.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(project.exists ? Color.appAccent : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name).lineLimit(1)
                Text(project.path.abbreviatingWithTilde)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
        .help(project.path)
    }
}

struct NewWorkspaceSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<UUID>

    init(preselected: Set<UUID>) {
        _selected = State(initialValue: preselected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Workspace").font(.title2.bold())
            TextField("Name", text: $name, prompt: Text(suggestedName))
                .textFieldStyle(.roundedBorder)
            Text("Projects").font(.headline)
            List {
                ForEach(store.state.projects) { p in
                    Toggle(isOn: Binding(
                        get: { selected.contains(p.id) },
                        set: { if $0 { selected.insert(p.id) } else { selected.remove(p.id) } })) {
                        ProjectRow(project: p)
                    }
                }
            }
            .frame(minHeight: 180)
            .overlay {
                if store.state.projects.isEmpty { Text("No projects declared yet").foregroundStyle(.secondary) }
            }
            HStack {
                Button { selected.formUnion(store.pickProjectFolders().map(\.id)) } label: {
                    Label("Add Folder…", systemImage: "folder.badge.plus")
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let ordered = store.state.projects.map(\.id).filter(selected.contains)
                    let w = store.createWorkspace(name: name.isEmpty ? suggestedName : name, projectIDs: ordered)
                    dismiss()
                    store.selectWorkspace(w.id)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480, height: 460)
    }

    private var suggestedName: String {
        let names = store.state.projects.filter { selected.contains($0.id) }.map(\.name)
        switch names.count {
        case 0: return "Workspace \(store.state.workspaces.count + 1)"
        case 1: return names[0]
        default: return names.prefix(2).joined(separator: " + ") + (names.count > 2 ? " +\(names.count - 2)" : "")
        }
    }
}

struct WorkspaceProjectsSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let workspaceID: UUID

    var body: some View {
        let w = store.workspace(workspaceID)
        let inUse = Set(w?.spaces.flatMap { $0.panes.map(\.projectID) } ?? [])
        VStack(alignment: .leading, spacing: 12) {
            Text("Projects in “\(w?.name ?? "")”").font(.title3.bold())
            List {
                ForEach(store.state.projects) { p in
                    Toggle(isOn: Binding(
                        get: { w?.projectIDs.contains(p.id) ?? false },
                        set: { on in
                            store.updateWorkspace(workspaceID) { ws in
                                if on { if !ws.projectIDs.contains(p.id) { ws.projectIDs.append(p.id) } }
                                else { ws.projectIDs.removeAll { $0 == p.id } }
                            }
                        })) {
                        ProjectRow(project: p)
                    }
                    .disabled(inUse.contains(p.id))
                    .help(inUse.contains(p.id) ? "Used by open panes" : "")
                }
            }
            .frame(minHeight: 220)
            HStack {
                Button {
                    let added = store.pickProjectFolders()
                    store.updateWorkspace(workspaceID) { ws in
                        for p in added where !ws.projectIDs.contains(p.id) { ws.projectIDs.append(p.id) }
                    }
                } label: { Label("Add Folder…", systemImage: "folder.badge.plus") }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 420)
    }
}

struct RenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State var text: String
    let onSave: (String) -> Void

    init(title: String, initial: String, onSave: @escaping (String) -> Void) {
        self.title = title
        _text = State(initialValue: initial)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $text).textFieldStyle(.roundedBorder).frame(width: 320)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { onSave(t) }
        dismiss()
    }
}

extension String {
    var abbreviatingWithTilde: String { (self as NSString).abbreviatingWithTildeInPath }
}
