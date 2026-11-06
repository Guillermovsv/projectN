import AppKit
import SwiftUI

/// Lazily-loaded directory tree. Expanded folders are re-listed every few seconds while visible.
@MainActor
final class FileTreeModel: ObservableObject {
    struct Entry: Hashable {
        let url: URL
        let name: String
        let isDir: Bool
    }

    @Published private(set) var root: URL?
    @Published var expanded: Set<URL> = []
    @Published var selection: URL?
    @Published var showHidden = false { didSet { cache.removeAll(); objectWillChange.send() } }
    @Published private var cache: [URL: [Entry]] = [:]

    /// Expanded folders per root, so switching projects keeps each tree's state.
    private var expandedByRoot: [URL: Set<URL>] = [:]

    func setRoot(_ url: URL?) {
        guard url != root else { return }
        if let root { expandedByRoot[root] = expanded }
        root = url
        expanded = url.flatMap { expandedByRoot[$0] } ?? []
        selection = nil
        cache.removeAll()
    }

    func children(_ dir: URL) -> [Entry] {
        if let c = cache[dir] { return c }
        let c = list(dir)
        DispatchQueue.main.async { self.cache[dir] = c }
        return c
    }

    private func list(_ dir: URL) -> [Entry] {
        let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: opts) else { return [] }
        return urls.compactMap { u -> Entry? in
            let name = u.lastPathComponent
            if name == ".DS_Store" { return nil }
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let isDir = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
            return Entry(url: u, name: name, isDir: isDir)
        }
        .sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Flattened visible rows (entry, depth).
    func rows() -> [(Entry, Int)] {
        guard let root else { return [] }
        var out: [(Entry, Int)] = []
        func walk(_ dir: URL, _ depth: Int) {
            for e in children(dir) {
                out.append((e, depth))
                if e.isDir && expanded.contains(e.url) && out.count < 5000 { walk(e.url, depth + 1) }
            }
        }
        walk(root, 0)
        return out
    }

    func toggle(_ url: URL) {
        if expanded.contains(url) { expanded.remove(url) } else { expanded.insert(url) }
    }

    func collapseAll() { expanded.removeAll() }

    /// Re-list the root and expanded folders; publishes only on change.
    func refresh() {
        guard let root else { return }
        var next = cache
        for dir in [root] + Array(expanded) {
            let fresh = list(dir)
            if next[dir] != fresh { next[dir] = fresh }
        }
        // Forget folders that disappeared.
        expanded = expanded.filter { FileManager.default.fileExists(atPath: $0.path) }
        if next != cache { cache = next }
    }
}

struct FileTreeView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var panel: RightPanelModel
    @StateObject private var model = FileTreeModel()
    @State private var pickedProjectID: UUID?
    private let refreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    /// Projects offered in the picker: the workspace's, or all projects on the Overview.
    private var candidates: [Project] {
        let ids = store.selectedWorkspace?.projectIDs ?? store.state.projects.map(\.id)
        return ids.compactMap(store.project)
    }

    private var project: Project? {
        if let id = pickedProjectID, let p = candidates.first(where: { $0.id == id }) { return p }
        return store.focusedProjectID.flatMap(store.project) ?? candidates.first
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let project, project.exists {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.rows(), id: \.0.url) { entry, depth in
                            FileRow(entry: entry, depth: depth,
                                    expanded: model.expanded.contains(entry.url),
                                    selected: model.selection == entry.url,
                                    root: project.path)
                                .onTapGesture(count: 2) {
                                    if !entry.isDir { NSWorkspace.shared.open(entry.url) }
                                }
                                .simultaneousGesture(TapGesture().onEnded {
                                    model.selection = entry.url
                                    if entry.isDir { model.toggle(entry.url) }
                                })
                                .contextMenu { menu(for: entry, root: project.path) }
                                .onDrag { NSItemProvider(object: entry.url as NSURL) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                placeholder(project == nil ? "No project selected" : "Folder not found")
            }
        }
        .onAppear { model.setRoot(project.map { URL(fileURLWithPath: $0.path) }) }
        .onChange(of: project?.path) { _, path in model.setRoot(path.map { URL(fileURLWithPath: $0) }) }
        .onReceive(refreshTimer) { _ in model.refresh() }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Follow focused pane") { pickedProjectID = nil }
                Divider()
                ForEach(candidates) { p in
                    Button { pickedProjectID = p.id } label: {
                        if p.id == project?.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                    }
                }
            } label: {
                Label(project?.name ?? "Project", systemImage: "folder.fill")
            }
            .menuStyle(.borderlessButton)
            .hoverHighlight()
            .fixedSize()
            .help(project?.path ?? "")
            Spacer()
            Toggle(isOn: $model.showHidden) { Image(systemName: model.showHidden ? "eye" : "eye.slash") }
                .toggleStyle(.button)
                .buttonStyle(.hover)
                .help("Show hidden files")
            Button { model.collapseAll() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                .buttonStyle(.hover).help("Collapse all")
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.hover).help("Refresh")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    @ViewBuilder
    private func menu(for entry: FileTreeModel.Entry, root: String) -> some View {
        if !entry.isDir {
            Button("Open") { NSWorkspace.shared.open(entry.url) }
        }
        if ["html", "htm", "svg", "pdf", "png", "jpg", "jpeg", "gif", "md", "txt", "json"].contains(entry.url.pathExtension.lowercased()) {
            Button("Open in Browser Panel") { panel.open(url: entry.url) }
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        Divider()
        Button("Insert Path into Focused Pane") {
            store.focusedRuntime?.send(Shell.quote(relative(entry.url.path, to: root)) + " ")
            store.focusedRuntime?.focus()
        }
        .disabled(store.focusedRuntime == nil)
        Button("Copy Path") { copy(entry.url.path) }
        Button("Copy Relative Path") { copy(relative(entry.url.path, to: root)) }
        if entry.isDir {
            Divider()
            Button("Open Terminal Pane Here") {
                guard let w = store.selectedWorkspace, let s = store.selectedSpace, !s.isFull else { return }
                if let p = store.addPane(tool: .terminal, in: w.id, space: s.id) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        store.runtimes[p.id]?.send("cd \(Shell.quote(entry.url.path))\r")
                    }
                }
            }
            .disabled(store.selectedSpace?.isFull ?? true)
        }
    }

    private func relative(_ path: String, to root: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "folder").font(.largeTitle).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FileRow: View {
    let entry: FileTreeModel.Entry
    let depth: Int
    let expanded: Bool
    let selected: Bool
    let root: String
    @State private var hover = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .opacity(entry.isDir ? 0.6 : 0)
                .frame(width: 10)
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
            Text(entry.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, 8 + CGFloat(depth) * 14)
        .padding(.trailing, 8)
        .frame(height: 24)
        .background(selected ? Color.appAccent.opacity(0.25) : (hover ? Color.primary.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .handCursor()
        .help(entry.url.path)
    }

    private var icon: NSImage { NSWorkspace.shared.icon(forFile: entry.url.path) }
}
