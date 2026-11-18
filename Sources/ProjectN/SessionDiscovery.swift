import Foundation

/// Finds the on-disk conversations of Claude and Codex so panes can resume exactly where they left off.
enum SessionDiscovery {
    /// Read once: the app's own environment doesn't change while it runs, and `ProcessInfo.processInfo.environment`
    /// builds a fresh dictionary on every call (it showed up in samples of the transcript scans).
    private static let inheritedClaudeConfigDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
    private static let inheritedCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    // MARK: Claude

    static func claudeConfigDir(_ settings: AppSettings) -> URL {
        if settings.isolateClaudeConfig { return AppHome.claudeConfigDir }
        if let dir = inheritedClaudeConfigDir, !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".claude")
    }

    /// True if Claude has a saved transcript for this session id (i.e. the conversation actually started).
    static func claudeTranscriptExists(id: String, settings: AppSettings) -> Bool {
        transcript(tool: .claude, id: id, settings: settings) != nil
    }

    // MARK: Codex

    static func codexHome(_ settings: AppSettings) -> URL {
        if settings.isolateCodexHome { return AppHome.codexHomeDir }
        if let dir = inheritedCodexHome, !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".codex")
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

    // MARK: Transcript files

    private static let lock = NSLock()
    nonisolated(unsafe) private static var located: [String: URL] = [:]
    /// Codex sessions whose file wasn't found, and when: walking `sessions/` (every rollout ever written) is only
    /// repeated after a few seconds. Claude's lookup is a single folder listing, so it isn't throttled.
    nonisolated(unsafe) private static var missing: [String: Date] = [:]
    static var missingRetryInterval: TimeInterval = 5

    /// The transcript of a Claude (`<config>/projects/*/<id>.jsonl`) or Codex (`<home>/sessions/**/rollout-*-<id>.jsonl`)
    /// session. Remembered once found (checked with one `stat` afterwards): the agent harness and the prompt
    /// tracker ask every second or two for every running session.
    static func transcript(tool: Tool, id: String, settings: AppSettings) -> URL? {
        guard tool == .claude || tool == .codex, !id.isEmpty else { return nil }
        let fm = FileManager.default
        let home = tool == .claude ? claudeConfigDir(settings) : codexHome(settings)
        let key = "\(tool.rawValue):\(home.path):\(id)"
        lock.lock()
        let known = located[key]
        let missedAt = missing[key]
        lock.unlock()
        if let known {
            if fm.fileExists(atPath: known.path) { return known }
            lock.lock(); located.removeValue(forKey: key); lock.unlock()
        }
        if tool == .codex, let missedAt, Date().timeIntervalSince(missedAt) < missingRetryInterval { return nil }

        var found: URL?
        if tool == .claude {
            let root = home.appendingPathComponent("projects")
            for d in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
                let u = root.appendingPathComponent(d).appendingPathComponent("\(id).jsonl")
                if fm.fileExists(atPath: u.path) { found = u; break }
            }
        } else {
            let root = home.appendingPathComponent("sessions")
            if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let u as URL in e where u.pathExtension == "jsonl" && u.lastPathComponent.contains(id) { found = u; break }
            }
        }
        lock.lock()
        if let found { located[key] = found; missing.removeValue(forKey: key) } else { missing[key] = Date() }
        lock.unlock()
        return found
    }
}
