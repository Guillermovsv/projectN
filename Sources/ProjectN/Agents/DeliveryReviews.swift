import Foundation

// MARK: - Review lists
//
// What to check when certain files change, written once per project and applied every time:
//
//   ~/.projectn/reviews/<project folder name>/<name>.md     for one project
//   ~/.projectn/reviews/_all/<name>.md                      for every project
//
// The first line may say which files trigger it: `when: saas/src/**, saas/migraciones/**` (no line = always).
// The rest is the checklist. The verifier gets the lists that match what changed, and any agent can ask for them
// with `review_lists`.

struct ReviewList: Equatable {
    var name: String
    var patterns: [String]
    var text: String
}

enum ReviewLists {
    static var root: URL { AppHome.root.appendingPathComponent("reviews") }

    static func folder(for projectPath: String) -> URL {
        root.appendingPathComponent(URL(fileURLWithPath: projectPath).lastPathComponent.folded)
    }

    static func load(projectPath: String) -> [ReviewList] {
        var out: [ReviewList] = []
        for dir in [folder(for: projectPath), root.appendingPathComponent("_all")] {
            let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for f in files {
                guard let raw = try? String(contentsOf: f, encoding: .utf8) else { continue }
                out.append(parse(name: f.deletingPathExtension().lastPathComponent, raw))
            }
        }
        return out
    }

    static func parse(name: String, _ raw: String) -> ReviewList {
        var lines = raw.components(separatedBy: "\n")
        var patterns: [String] = []
        if let first = lines.first, first.lowercased().hasPrefix("when:") || first.lowercased().hasPrefix("cuando:") {
            patterns = first.split(separator: ":", maxSplits: 1).last.map(String.init)?
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
            lines.removeFirst()
        }
        return ReviewList(name: name, patterns: patterns, text: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The lists whose patterns match any of the changed files (lists without patterns always apply).
    static func matching(_ lists: [ReviewList], changed: [String]) -> [ReviewList] {
        lists.filter { l in l.patterns.isEmpty || changed.contains { f in l.patterns.contains { glob($0, matches: f) } } }
    }

    /// `**` any folders, `*` anything but `/`, `?` one character. A pattern ending in `/` matches the folder's contents.
    static func glob(_ pattern: String, matches path: String) -> Bool {
        var p = pattern.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("./") { p.removeFirst(2) }
        if p.hasSuffix("/") { p += "**" }
        var re = "^"
        var chars = Array(p)[...]
        while let c = chars.first {
            chars = chars.dropFirst()
            switch c {
            case "*":
                if chars.first == "*" {
                    chars = chars.dropFirst()
                    if chars.first == "/" { chars = chars.dropFirst(); re += "(?:.*/)?" } else { re += ".*" }
                } else { re += "[^/]*" }
            case "?": re += "[^/]"
            default: re += NSRegularExpression.escapedPattern(for: String(c))
            }
        }
        re += "$"
        return path.range(of: re, options: .regularExpression) != nil
    }

    /// Files changed in a checkout: commits since it left origin's default branch, plus uncommitted changes.
    nonisolated static func changedFiles(in dir: String) -> [String] {
        func git(_ args: [String]) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir] + args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) ?? "" : ""
        }
        var base = git(["rev-parse", "--abbrev-ref", "origin/HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "origin/main" }
        var files = Set(git(["diff", "--name-only", "\(base)...HEAD"]).split(separator: "\n").map(String.init))
        for line in git(["status", "--porcelain"]).split(separator: "\n") where line.count > 3 {
            let path = String(line.dropFirst(3))
            files.insert(path.components(separatedBy: " -> ").last ?? path)
        }
        return files.sorted()
    }

    static func instructionBlock(_ lists: [ReviewList]) -> String {
        guard !lists.isEmpty else { return "" }
        return "\n\nReview lists for what changed — apply every point; open a finding (finding_open) for each one that fails:\n"
            + lists.map { "### \($0.name)\n\($0.text)" }.joined(separator: "\n\n")
    }
}

extension AgentHarness {
    /// The changed files of a request: in its worktrees, else in the project folder.
    func changedFiles(delivery id: UUID, projectID: UUID) -> [String] {
        let wts = deliveryRecord(id).worktrees.filter { FileManager.default.fileExists(atPath: $0) }
        let dirs = wts.isEmpty ? [store?.project(projectID)?.path].compactMap { $0 } : wts
        return Array(Set(dirs.flatMap(ReviewLists.changedFiles(in:)))).sorted()
    }

    func reviewLists(delivery id: UUID, projectID: UUID, paths: [String]? = nil) -> [ReviewList] {
        guard let path = store?.project(projectID)?.path else { return [] }
        let changed = (paths?.isEmpty == false) ? paths! : changedFiles(delivery: id, projectID: projectID)
        return ReviewLists.matching(ReviewLists.load(projectPath: path), changed: changed)
    }

    // MARK: Decisions

    /// You answered an agent's question: the answer is a decision about the project. Saved as a project note
    /// (every agent working there finds it) and listed in the request's delivery.
    func rememberDecision(_ r: AgentRequest) {
        guard r.kind == .question, r.status == .answered, r.route == .user,
              let answer = r.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty,
              let t = task(r.taskID) else { return }
        let id = Delivery.key(t)
        guard let projectID = decisionProject(for: t) else { return }
        let day = Date().formatted(.dateTime.day().month(.abbreviated).year())
        let note = "Decisión (\(day)): \(PromptComposer.oneLine(r.summary, 300)) → \(PromptComposer.oneLine(answer, 400))"
        _ = AgentStore.addProjectNote(projectID, note, by: "Usuario (respuesta a \(t.agentName))")
        mutateDelivery(id) { $0.decisions.append(note) }
        AuditLog.record("decision.saved", ["delivery": id.uuidString, "agent": t.agentName, "note": note])
    }

    /// An agent saved a note that records a decision: list it in the delivery too.
    func noteDecisionSaved(_ note: String, task t: AgentTask) {
        let n = note.trimmingCharacters(in: .whitespaces).folded
        guard n.hasPrefix("decision") else { return }
        mutateDelivery(Delivery.key(t)) { if !$0.decisions.contains(note) { $0.decisions.append(note) } }
    }

    /// The project a decision is about: the task's own, or — for coordinators working outside the projects — the
    /// project the request's other tasks worked in.
    func decisionProject(for t: AgentTask) -> UUID? {
        if t.projectID != Store.coordinationProjectID { return t.projectID }
        let key = Delivery.key(t)
        return tasks.last { Delivery.key($0) == key && $0.projectID != Store.coordinationProjectID }?.projectID
    }
}
