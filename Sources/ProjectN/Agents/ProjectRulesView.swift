import AppKit
import SwiftUI

/// Deliveries → "Reviews & Decisions": a project's review lists (what the verifier checks when certain files
/// change) and the decisions saved in its notes.
struct ProjectRulesSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var projectID: UUID?
    @State private var tab = 0
    @State private var refresh = 0

    private var projects: [Project] { store.state.projects.filter { $0.id != Store.coordinationProjectID && $0.exists } }
    private var project: Project? { projectID.flatMap { store.project($0) } ?? projects.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Reviews & Decisions").font(.title3.weight(.semibold))
                Spacer()
                Picker("Project", selection: Binding(get: { project?.id }, set: { projectID = $0 })) {
                    ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
                }
                .fixedSize()
            }
            Picker("", selection: $tab) {
                Text("Review lists").tag(0)
                Text("Decisions").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if let p = project {
                if tab == 0 { reviews(p) } else { decisions(p) }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 860, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .id(refresh)
    }

    // MARK: Review lists

    private func reviews(_ p: Project) -> some View {
        let lists = ReviewLists.load(projectPath: p.path)
        let folder = ReviewLists.folder(for: p.path)
        return VStack(alignment: .leading, spacing: 8) {
            Text("The verifier gets every list whose files changed in the request, and opens a finding for each point that fails. Lists in \(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")); lists in reviews/_all apply to every project.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if lists.isEmpty {
                Text("No review lists for \(p.name) yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(lists, columns: {
                    TableColumn("Review") { l in Text(l.name).fontWeight(.medium) }.width(min: 110, ideal: 140)
                    TableColumn("When these change") { l in
                        Text(l.patterns.isEmpty ? "always" : l.patterns.joined(separator: ", ")).font(.caption.monospaced())
                            .lineLimit(4).help(l.patterns.joined(separator: "\n"))
                    }.width(min: 150, ideal: 210)
                    TableColumn("Checks") { l in
                        Text(l.text).font(.caption).lineLimit(4).help(l.text)
                    }
                })
            }
            HStack {
                Button("Open Folder") {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                }
                Button("New List…") { newList(in: folder) }
                Button("Reload") { refresh += 1 }
            }
        }
    }

    private func newList(in folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent("nueva-revision.md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("nueva-revision-\(n).md"); n += 1 }
        let template = "when: src/**\n- Primer punto a revisar\n- Segundo punto a revisar\n"
        try? template.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(url)
        refresh += 1
    }

    // MARK: Decisions

    private struct Decision: Identifiable { let id: Int; let date: String; let text: String; let by: String }

    private func decisions(_ p: Project) -> some View {
        let rows: [Decision] = AgentStore.projectNoteList(p.id).enumerated().compactMap { i, line in
            var l = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
            guard l.folded.contains("decision") else { return nil }
            var by = "", date = ""
            if let m = l.firstMatch(of: #/\s*_\((.+), (\d{4}-\d{2}-\d{2})\)_\s*$/#) {
                by = String(m.1); date = String(m.2)
                l = String(l[..<m.range.lowerBound])
            }
            return Decision(id: i, date: date, text: l, by: by)
        }.reversed()
        return VStack(alignment: .leading, spacing: 8) {
            Text("Saved when you answer an agent's question, or when an agent records a decision. Every agent working on \(p.name) can find them (project_notes).")
                .font(.caption).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("No decisions saved for \(p.name) yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(rows, columns: {
                    TableColumn("Date") { d in Text(d.date).font(.caption.monospacedDigit()) }.width(min: 80, ideal: 90)
                    TableColumn("Decision") { d in Text(d.text).font(.callout).lineLimit(4).help(d.text) }
                    TableColumn("Origin") { d in Text(d.by).font(.caption).foregroundStyle(.secondary) }.width(min: 120, ideal: 170)
                })
            }
        }
    }
}
