import AppKit
import Foundation

/// What the Deliveries view reads out of a request: the coordinator's questions and suggested commands, the
/// evidence folder, which findings the running step works on, the branch, and the task tree.
enum DeliveryInsights {
    struct Question: Equatable {
        var number: String
        var text: String
        var options: [Option]
        struct Option: Equatable { var key: String; var text: String }
    }

    /// Numbered questions with lettered choices in a coordinator's answer:
    ///   `1. ¿Qué hacemos con él?` followed by `- a) Retomarlo …` / `- b) Dejarlo cerrado`.
    static func questions(in text: String) -> [Question] {
        var out: [Question] = []
        var current: Question?
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let m = line.firstMatch(of: #/^[-*•]?\s*\**([a-e])\)\**\s+(.+)$/#) {
                if current == nil { current = Question(number: "", text: "", options: []) }
                current?.options.append(.init(key: String(m.1), text: clean(String(m.2))))
            } else if let m = line.firstMatch(of: #/^\**(\d+)[.)]\**\s+(.+)$/#) {
                if let q = current, q.options.count >= 2 { out.append(q) }
                current = Question(number: String(m.1), text: clean(String(m.2)), options: [])
            } else if !line.isEmpty, current?.options.isEmpty == false {
                if let q = current, q.options.count >= 2 { out.append(q) }
                current = nil
            }
        }
        if let q = current, q.options.count >= 2 { out.append(q) }
        return out
    }

    /// `gh …` / `git …` commands in backticks that the coordinator suggests the user run (not pushes to main,
    /// not force or deletions: those stay in a terminal you type yourself).
    static func commands(in text: String) -> [String] {
        var out: [String] = []
        for m in text.matches(of: #/`((?:gh|git) [^`\n]{2,160})`/#) {
            let c = String(m.1).trimmingCharacters(in: .whitespaces)
            let lower = c.lowercased()
            let risky = ["--force", " -f ", " -d ", "--delete", "reset --hard", "clean", "push origin main", "push origin master", " rm "]
            guard !risky.contains(where: { lower.contains($0) || lower.hasSuffix($0.trimmingCharacters(in: .whitespaces)) }) else { continue }
            if !out.contains(c) { out.append(c) }
        }
        return Array(out.prefix(3))
    }

    /// `.agentes/<task>` folders mentioned by the request (instructions, evidence, anchors).
    static func evidenceFolder(_ d: Delivery, projectPath: String) -> URL? {
        var texts = d.tasks.map(\.instruction) + d.tasks.compactMap(\.result)
        if let r = d.record { texts += r.criteria.compactMap(\.evidence) + r.findings.map(\.anchor) }
        for t in texts {
            for m in t.matches(of: #/\.agentes\/([A-Za-z0-9._-]+)/#) {
                let name = String(m.1)
                guard !name.hasSuffix(".md") else { continue }
                let url = URL(fileURLWithPath: projectPath).appendingPathComponent(".agentes").appendingPathComponent(name)
                var dir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), dir.boolValue { return url }
            }
        }
        return nil
    }

    static func fileCount(_ dir: URL) -> Int {
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
        var n = 0
        while let f = e?.nextObject() as? URL { if (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { n += 1 } }
        return n
    }

    /// Finding ids a cycle step's instruction lists (`- P4 [P2]: …`).
    static func findingIDs(inStep instruction: String) -> [String] {
        instruction.matches(of: #/(?m)^- ([A-Z]+\d+)(?: \[|:)/#).map { String($0.1) }
    }

    /// The branch of the request's work: a worktree's branch, else the PR's.
    static func branch(_ r: DeliveryRecord?) -> String? {
        if let b = r?.ship?.branch, !b.isEmpty { return b }
        for wt in r?.worktrees ?? [] where FileManager.default.fileExists(atPath: wt) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", wt, "rev-parse", "--abbrev-ref", "HEAD"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            p.waitUntilExit()
            if !out.isEmpty, out != "HEAD" { return out }
        }
        return nil
    }

    /// How deep a task sits in the request's tree (the coordinator's turns at 0, what they delegated below).
    static func depth(_ t: AgentTask, in d: Delivery) -> Int {
        var n = 0
        var cur = t
        while let p = cur.origin.parentTaskID, let parent = d.tasks.first(where: { $0.id == p }), n < 4 {
            n += 1
            cur = parent
        }
        return n
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
    }
}

extension AgentHarness {
    /// The project a request works in (not the coordination folder).
    func projectPath(of d: Delivery) -> String? {
        let id = d.record?.cycle?.projectID ?? d.record?.ship?.projectID
            ?? d.tasks.last { $0.projectID != Store.coordinationProjectID }?.projectID
        return id.flatMap { store?.project($0)?.path }
    }

    func projectID(of d: Delivery) -> UUID? {
        d.record?.cycle?.projectID ?? d.record?.ship?.projectID ?? d.tasks.last { $0.projectID != Store.coordinationProjectID }?.projectID
    }

    /// Runs a command the coordinator suggested, in the project folder, through your login shell.
    func runSuggested(_ command: String, in dir: String) async -> (ok: Bool, output: String) {
        guard let store else { return (false, "ProjectN isn't ready.") }
        let shell = store.settings.shell.isEmpty ? "/bin/zsh" : store.settings.shell
        let env = AccountsModel.environment(settings: store.settings)
        let full = "cd \(Shell.quote(dir)) && \(command) 2>&1"
        AuditLog.record("delivery.command", ["command": command, "dir": dir])
        let r = await Task.detached { AccountsModel.run(shell: shell, full, env: env) }.value
        return (r.code == 0, r.out.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
