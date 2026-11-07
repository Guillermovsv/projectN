import Foundation

/// Creating new projects: from your own Slack request ("crea el proyecto X …") directly, or by an agent through
/// ProjectN's `create_project` tool after you approve. Folders are only ever created inside the configured
/// projects folder, as a new, empty folder with a README, and are added to ProjectN as projects.
extension AgentHarness {
    enum ProjectCreationError: Error, Equatable, CustomStringConvertible {
        case disabled, invalidName(String), exists(String), unsafeFolder(String), failed(String)
        var description: String {
            switch self {
            case .disabled: return "Creating projects is turned off (Settings → Agents → Autonomy)."
            case .invalidName(let n): return "“\(n)” isn't a valid project name (letters, numbers, spaces, - _ . — no slashes)."
            case .exists(let p): return "A folder already exists at \(p). Add it in ProjectN (⌘O) if it should be a project."
            case .unsafeFolder(let p): return "The projects folder \(p) isn't allowed (system or protected location)."
            case .failed(let e): return "Couldn't create the folder: \(e)"
            }
        }
    }

    /// The folder new projects go in.
    var projectsFolder: String {
        let configured = (policy.newProjectsFolder as NSString).expandingTildeInPath
        if !configured.isEmpty { return configured }
        let parents = (store?.state.projects ?? []).map { ($0.path as NSString).deletingLastPathComponent }
        let counts = Dictionary(parents.map { ($0, 1) }, uniquingKeysWith: +)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let best = counts.max(by: { $0.value < $1.value })?.key,
           !PathGuard.forbiddenTrees().map(PathGuard.canonical).contains(where: { PathGuard.canonical(best) == $0 || PathGuard.canonical(best).hasPrefix($0 + "/") }),
           PathGuard.canonical(best) != PathGuard.canonical(home), best != "/" {
            return best
        }
        return home + "/Documents"
    }

    static func sanitizeProjectName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”«»`*_")))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !name.isEmpty, name.count <= 80, name != ".", name != "..", !name.hasPrefix("."),
              name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || " -_.()&".unicodeScalars.contains($0) })
        else { return nil }
        return name
    }

    /// Where a project with this name would be created (for approval messages).
    func plannedProjectPath(_ name: String) -> String? {
        Self.sanitizeProjectName(name).map { (projectsFolder as NSString).appendingPathComponent($0) }
    }

    /// Creates the folder (+ README) and adds it to ProjectN. `allowAgent`: also give this agent access when it's
    /// limited to specific projects.
    func createProject(name raw: String, description: String?, by: String, allowAgent: UUID? = nil) -> Result<Project, ProjectCreationError> {
        guard policy.allowProjectCreation else { return .failure(.disabled) }
        guard let store else { return .failure(.failed("ProjectN isn't ready")) }
        guard let name = Self.sanitizeProjectName(raw) else { return .failure(.invalidName(raw)) }
        let base = projectsFolder
        // The base itself must be a normal folder you own (not a system folder or app data).
        if PathGuard.forbiddenTrees().map(PathGuard.canonical).contains(where: { PathGuard.canonical(base) == $0 || PathGuard.canonical(base).hasPrefix($0 + "/") })
            || ["/", "/System", "/Library", "/Applications", "/usr", "/bin", "/private", "/etc", "/var"].contains(PathGuard.canonical(base)) {
            return .failure(.unsafeFolder(base))
        }
        let path = (base as NSString).appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: path) else { return .failure(.exists(path)) }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            let about = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let readme = "# \(name)\n\n" + (about.isEmpty ? "" : about + "\n\n")
                + "_Created by ProjectN on \(Date().formatted(date: .abbreviated, time: .omitted)) (requested by \(by))._\n"
            try readme.write(toFile: (path as NSString).appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
        if let e = PathGuard.checkWorkingDirectory(path) {
            return .failure(.unsafeFolder("\(path): \(e)"))
        }
        let project = store.addProject(url: URL(fileURLWithPath: path))
        if let aid = allowAgent, var p = profile(aid), !p.mayAccess(project.id) {
            p.projectIDs.append(project.id)
            saveProfile(p)
        }
        AuditLog.record("project.created", ["name": name, "path": path, "by": by])
        return .success(project)
    }
}
