import Foundation

/// Finds the on-disk conversations of Claude and Codex so panes can resume exactly where they left off.
enum SessionDiscovery {
    // MARK: Claude

    static func claudeConfigDir(_ settings: AppSettings) -> URL {
        if settings.isolateClaudeConfig { return AppHome.claudeConfigDir }
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    /// True if Claude has a saved transcript for this session id (i.e. the conversation actually started).
    static func claudeTranscriptExists(id: String, settings: AppSettings) -> Bool {
        let projects = claudeConfigDir(settings).appendingPathComponent("projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else { return false }
        return dirs.contains { FileManager.default.fileExists(atPath: projects.appendingPathComponent($0).appendingPathComponent("\(id).jsonl").path) }
    }

    // MARK: Codex

    static func codexHome(_ settings: AppSettings) -> URL {
        if settings.isolateCodexHome { return AppHome.codexHomeDir }
        if let dir = ProcessInfo.processInfo.environment["CODEX_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    struct CodexSession {
        let id: String
        let cwd: String
        let created: Date
    }

    /// Codex sessions (rollout files) created since `since`, oldest first.
    static func codexSessions(since: Date, settings: AppSettings) -> [CodexSession] {
        let root = codexHome(settings).appendingPathComponent("sessions")
        let fm = FileManager.default
        let cal = Calendar.current
        var days: [Date] = []
        var d = cal.startOfDay(for: since.addingTimeInterval(-60))
        while d <= Date() { days.append(d); d = cal.date(byAdding: .day, value: 1, to: d)! }

        var out: [CodexSession] = []
        for day in days.suffix(3) {
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                let created = (try? f.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                guard created >= since.addingTimeInterval(-3), let meta = readMeta(f) else { continue }
                out.append(CodexSession(id: meta.id, cwd: meta.cwd, created: created))
            }
        }
        return out.sorted { $0.created < $1.created }
    }

    private static func readMeta(_ url: URL) -> (id: String, cwd: String)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 64 * 1024)) ?? Data()
        let firstLine = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first.map { Data($0) } ?? data
        guard let obj = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let id = (payload["id"] as? String) ?? (payload["session_id"] as? String),
              let cwd = payload["cwd"] as? String else { return nil }
        return (id, cwd)
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().standardizedFileURL.path
            == URL(fileURLWithPath: b).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
