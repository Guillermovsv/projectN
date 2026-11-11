import AppKit
import SwiftUI

// MARK: - Add Project from GitHub
//
// Lists your repositories with the GitHub CLI you're already signed in to (Settings → Accounts → GitHub),
// clones the one you pick into the projects folder (the same folder agents create projects in) and adds it
// as a project. A folder that already holds a clone of that repository is simply added.

/// `owner/repo`, parsed from what people paste: `owner/repo`, an https URL or an SSH remote.
struct GitHubRepoRef: Equatable {
    let owner: String
    let name: String

    var slug: String { "\(owner)/\(name)" }

    init?(owner: String, name: String) {
        guard Self.isValidOwner(owner), Self.isValidName(name) else { return nil }
        self.owner = owner
        self.name = name
    }

    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "ssh://", "git://"] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if s.lowercased().hasPrefix("git@github.com:") { s = String(s.dropFirst("git@github.com:".count)) }
        if s.lowercased().hasPrefix("git@github.com/") { s = String(s.dropFirst("git@github.com/".count)) }
        if s.lowercased().hasPrefix("www.github.com/") { s = String(s.dropFirst("www.".count)) }
        if s.lowercased().hasPrefix("github.com/") { s = String(s.dropFirst("github.com/".count)) }
        // Drop anything after the repository: /tree/main, /pull/3, ?tab=…, #readme
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<cut]) }
        let parts = s.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        var name = parts[1]
        if name.lowercased().hasSuffix(".git") { name = String(name.dropLast(4)) }
        self.init(owner: parts[0], name: name)
    }

    /// GitHub user/org names: letters, digits and single hyphens, up to 39 characters.
    static func isValidOwner(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 39, !s.hasPrefix("-"), !s.hasSuffix("-") else { return false }
        return s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" }
    }

    /// Repository names: letters, digits, `.`, `-`, `_`; never `.` or `..`.
    static func isValidName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 100, s != ".", s != ".." else { return false }
        return s.unicodeScalars.allSatisfy { (CharacterSet.alphanumerics.contains($0) && $0.isASCII) || "._-".unicodeScalars.contains($0) }
    }
}

/// One row of `gh repo list --json nameWithOwner,description,isPrivate,updatedAt`.
struct GitHubRepo: Decodable, Identifiable, Equatable {
    let nameWithOwner: String
    let description: String?
    let isPrivate: Bool
    let updatedAt: String?
    var id: String { nameWithOwner }
    var ref: GitHubRepoRef? { GitHubRepoRef(nameWithOwner) }
}

enum GitHubClone {
    enum ListResult: Equatable {
        case repos([GitHubRepo])
        case notInstalled
        case signedOut
        case failed(String)
    }

    /// What adding `repo` at `destination` will do.
    enum Plan: Equatable {
        case clone(destination: String)
        /// The folder already holds a clone of this repository: just add it.
        case addExisting(destination: String)
        /// Something else is in the way; nothing is touched.
        case blocked(String)
    }

    static let listCommand = "gh repo list --limit 200 --json nameWithOwner,description,isPrivate,updatedAt"

    static func parseList(_ json: String) -> [GitHubRepo]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([GitHubRepo].self, from: data)
            .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
    }

    /// POSIX single-quoting for a shell argument.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func cloneCommand(_ repo: GitHubRepoRef, destination: String) -> String {
        "gh repo clone \(quote(repo.slug)) \(quote(destination)) -- --quiet"
    }

    /// Does `remote` (as printed by `git remote get-url origin`) point at `repo`?
    static func remote(_ remote: String, matches repo: GitHubRepoRef) -> Bool {
        guard let r = GitHubRepoRef(remote) else { return false }
        return r.owner.lowercased() == repo.owner.lowercased() && r.name.lowercased() == repo.name.lowercased()
    }

    /// Pure decision (unit-tested): `existsKind` = nil when nothing is at the destination.
    static func plan(repo: GitHubRepoRef, folder: String, existsKind: ExistingFolder?) -> Plan {
        let destination = (folder as NSString).appendingPathComponent(repo.name)
        switch existsKind {
        case nil: return .clone(destination: destination)
        case .some(.cloneOf(let remote)) where self.remote(remote, matches: repo): return .addExisting(destination: destination)
        case .some(.cloneOf(let remote)):
            return .blocked("\(destination.abbreviatingWithTilde) is already a clone of \(remote). Pick another folder.")
        case .some(.file), .some(.folder):
            return .blocked("\(destination.abbreviatingWithTilde) already exists. Pick another folder, or add it with ⌘O.")
        }
    }

    enum ExistingFolder: Equatable { case file, folder, cloneOf(String) }

    /// Nil when the folder may receive clones, else why not (system folders, app data, credentials).
    static func checkFolder(_ folder: String) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
            return "The folder \(folder.abbreviatingWithTilde) doesn't exist."
        }
        let p = PathGuard.canonical(folder)
        for tree in PathGuard.forbiddenTrees().map(PathGuard.canonical) where p == tree || p.hasPrefix(tree + "/") {
            return "\(folder.abbreviatingWithTilde) is a protected folder."
        }
        if ["/", "/System", "/Library", "/Applications", "/usr", "/bin", "/private", "/etc", "/var", "/Users"].contains(p) {
            return "\(folder.abbreviatingWithTilde) is a system folder."
        }
        return nil
    }

    // MARK: Running gh (off the main thread)

    nonisolated static func list(shell: String, env: [String: String]) -> ListResult {
        guard AccountsModel.run(shell: shell, "command -v gh >/dev/null 2>&1", env: env).code == 0 else { return .notInstalled }
        let r = AccountsModel.run(shell: shell, listCommand + " 2>&1", env: env)
        if r.code != 0 {
            let lower = r.out.lowercased()
            if lower.contains("gh auth login") || lower.contains("not logged") { return .signedOut }
            return .failed(r.out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let repos = parseList(r.out) else { return .failed("Couldn't read the repository list from gh.") }
        return .repos(repos)
    }

    nonisolated static func inspect(_ path: String, shell: String, env: [String: String]) -> ExistingFolder? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        guard isDir.boolValue else { return .file }
        guard FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) else { return .folder }
        let r = AccountsModel.run(shell: shell, "git -C \(quote(path)) remote get-url origin 2>/dev/null", env: env)
        let remote = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return remote.isEmpty ? .folder : .cloneOf(remote)
    }

    /// Clones and returns nil, or returns gh's error text.
    nonisolated static func clone(_ repo: GitHubRepoRef, destination: String, shell: String, env: [String: String]) -> String? {
        var e = env
        e["GIT_TERMINAL_PROMPT"] = "0"   // never wait on a password prompt nobody can see
        let r = AccountsModel.run(shell: shell, cloneCommand(repo, destination: destination) + " 2>&1", env: e)
        guard r.code == 0 else {
            let msg = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return msg.isEmpty ? "gh repo clone failed (exit \(r.code))." : msg
        }
        return nil
    }
}

// MARK: - Sheet

struct AddFromGitHubSheet: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var agents: AgentHarness
    @EnvironmentObject var nav: NavigationModel
    @EnvironmentObject var panel: RightPanelModel
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable { case loading, ready, notInstalled, signedOut, failed(String) }

    @State private var phase: Phase = .loading
    @State private var repos: [GitHubRepo] = []
    @State private var query = ""
    @State private var selection: String?
    @State private var folder = ""
    @State private var working = false
    @State private var error: String?

    private var filtered: [GitHubRepo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return repos }
        return repos.filter { $0.nameWithOwner.lowercased().contains(q) || ($0.description ?? "").lowercased().contains(q) }
    }

    /// The selected row, or what was typed/pasted (`owner/repo` or a GitHub URL).
    private var target: GitHubRepoRef? {
        if let s = selection, let r = GitHubRepoRef(s) { return r }
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.contains("/") ? GitHubRepoRef(q) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.purple)
                Text("Add Project from GitHub").font(.headline)
            }
            TextField("Search your repositories, or paste owner/repo or a GitHub URL", text: $query)
                .textFieldStyle(.roundedBorder)
                .onChange(of: query) { _, _ in
                    if let s = selection, !filtered.contains(where: { $0.id == s }) { selection = nil }
                }
            content
                .frame(height: 300)
            destinationRow
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text("Cloning \(target?.slug ?? "")…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Project", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(target == nil || working || folder.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            if folder.isEmpty { folder = agents.projectsFolder }
            load()
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            VStack { Spacer(); ProgressView("Loading your repositories…"); Spacer() }.frame(maxWidth: .infinity)
        case .notInstalled:
            message("The GitHub CLI isn't installed.", detail: "Install it with `brew install gh`, then sign in from Settings → Accounts.")
        case .signedOut:
            message("You're not signed in to GitHub.", detail: "Sign in from Settings → Accounts → GitHub, then try again.",
                    action: ("Open Accounts", { dismiss(); nav.openSettings(.accounts, panel: panel) }))
        case .failed(let why):
            message("Couldn't list your repositories.", detail: why, action: ("Try Again", load))
        case .ready:
            if filtered.isEmpty {
                message(target != nil ? "Not in your list — it will be cloned as typed." : "No repositories match.",
                        detail: target.map { "github.com/\($0.slug)" } ?? "")
            } else {
                List(filtered, selection: $selection) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: r.isPrivate ? "lock" : "book.closed").foregroundStyle(.secondary).frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.nameWithOwner).font(.body.weight(.medium))
                            if let d = r.description, !d.isEmpty {
                                Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if store.state.projects.contains(where: { ($0.path as NSString).lastPathComponent == r.ref?.name }) {
                            Text("Added").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(r.id)
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            }
        }
    }

    private var destinationRow: some View {
        HStack(spacing: 8) {
            Text("Clone into").foregroundStyle(.secondary)
            Text(((folder as NSString).appendingPathComponent(target?.name ?? "…")).abbreviatingWithTilde)
                .lineLimit(1).truncationMode(.middle)
                .help("Same folder agents create new projects in (Settings → Agents → Autonomy)")
            Spacer()
            Button("Change…", action: chooseFolder)
        }
        .font(.callout)
    }

    private func message(_ title: String, detail: String, action: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Text(title).font(.body.weight(.medium))
            if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            if let action { Button(action.0, action: action.1) }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    private func load() {
        phase = .loading
        let shell = store.settings.shell.isEmpty ? "/bin/zsh" : store.settings.shell
        let env = AccountsModel.environment(settings: store.settings)
        Task.detached {
            let result = GitHubClone.list(shell: shell, env: env)
            await MainActor.run {
                switch result {
                case .repos(let r): repos = r; phase = .ready
                case .notInstalled: phase = .notInstalled
                case .signedOut: phase = .signedOut
                case .failed(let why): phase = .failed(why)
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder to clone into"
        panel.directoryURL = URL(fileURLWithPath: folder)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func add() {
        guard let repo = target, !working else { return }
        error = nil
        if let why = GitHubClone.checkFolder(folder) { error = why; return }
        working = true
        let shell = store.settings.shell.isEmpty ? "/bin/zsh" : store.settings.shell
        let env = AccountsModel.environment(settings: store.settings)
        let base = folder
        Task.detached {
            let dest = (base as NSString).appendingPathComponent(repo.name)
            let plan = GitHubClone.plan(repo: repo, folder: base, existsKind: GitHubClone.inspect(dest, shell: shell, env: env))
            var failure: String?
            var path: String?
            switch plan {
            case .blocked(let why): failure = why
            case .addExisting(let d): path = d
            case .clone(let d):
                if let err = GitHubClone.clone(repo, destination: d, shell: shell, env: env) { failure = err } else { path = d }
            }
            let failed = failure, added = path
            await MainActor.run {
                working = false
                if let failed { error = failed; return }
                if let path = added {
                    store.addProject(url: URL(fileURLWithPath: path))
                    store.state.ui.projectsExpanded = true
                    AuditLog.record("project.cloned", ["repo": repo.slug, "path": path])
                    dismiss()
                }
            }
        }
    }
}
