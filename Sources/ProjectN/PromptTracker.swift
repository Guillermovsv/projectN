import Foundation

/// Finds the latest prompt the user gave each agent by reading the tail of its transcript
/// (Claude: ~/.claude/projects/*/<session>.jsonl, Codex: ~/.codex/sessions/**/rollout-*-<id>.jsonl),
/// so prompts typed directly into the terminal show up in the sticky header too.
enum PromptTracker {
    private static let lock = NSLock()
    private struct CachedPrompt {
        let modified: Date
        let size: UInt64
        let fileNumber: UInt64?
        /// Bytes already looked at: always the end of a complete line. Growth after it is all that's read next time.
        let scanned: UInt64
        let text: String?
    }
    nonisolated(unsafe) private static var prompts: [URL: CachedPrompt] = [:]
    /// How far back a fresh read looks for the latest prompt.
    private static let tailWindow: UInt64 = 512 * 1024

    static func lastPrompt(tool: Tool, sessionID: String, settings: AppSettings) -> String? {
        guard let url = SessionDiscovery.transcript(tool: tool, id: sessionID, settings: settings),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        lock.lock(); let cached = prompts[url]; lock.unlock()
        if let cached, cached.modified == modified, cached.size == size, cached.fileNumber == fileNumber {
            return cached.text
        }
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        // The same file grew (an agent working writes to it constantly): only the appended lines can hold a newer
        // prompt, so read just those. Anything else (first read, replaced, truncated, rewritten) reads the tail.
        let appended = cached.map { $0.fileNumber == fileNumber && size > $0.scanned && size - $0.scanned <= tailWindow } ?? false
        let from: UInt64 = appended ? cached!.scanned : (size > tailWindow ? size - tailWindow : 0)
        try? h.seek(toOffset: from)
        guard let data = try? h.read(upToCount: Int(size - from)) else { return nil }
        // Complete lines are remembered as scanned. A last line without its newline yet counts only if it's already
        // whole (then it's the newest), and is looked at again next time.
        let end = data.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? data.startIndex
        let found = latestPrompt(in: data[end...], tool: tool) ?? latestPrompt(in: data[data.startIndex..<end], tool: tool)
        let text = found ?? (appended ? cached?.text : nil)
        lock.lock()
        prompts[url] = CachedPrompt(modified: modified, size: size, fileNumber: fileNumber,
                                    scanned: from + UInt64(end - data.startIndex), text: text)
        lock.unlock()
        return text
    }

    /// The last user prompt among these lines (newest first; stops at the first one found).
    private static func latestPrompt(in data: Data, tool: Tool) -> String? {
        // Most lines are assistant output and tool results; a prompt line always contains "user" (`"type":"user"`,
        // `"role":"user"`), so the others aren't parsed at all.
        let marker = Data("\"user\"".utf8)
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard line.range(of: marker) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let text = tool == .claude ? claudeUserText(obj) : codexUserText(obj) { return text }
        }
        return nil
    }

    private static func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Skip system-inserted messages (command caveats, reminders, environment context…).
        guard !t.isEmpty, !t.hasPrefix("<") else { return nil }
        return t
    }

    private static func claudeUserText(_ o: [String: Any]) -> String? {
        guard o["type"] as? String == "user", o["isMeta"] as? Bool != true, o["isSidechain"] as? Bool != true,
              let msg = o["message"] as? [String: Any] else { return nil }
        if let s = msg["content"] as? String { return clean(s) }
        guard let parts = msg["content"] as? [[String: Any]],
              !parts.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
        return clean(parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n"))
    }

    private static func codexUserText(_ o: [String: Any]) -> String? {
        guard o["type"] as? String == "response_item", let p = o["payload"] as? [String: Any],
              p["type"] as? String == "message", p["role"] as? String == "user",
              let parts = p["content"] as? [[String: Any]] else { return nil }
        return clean(parts.compactMap { $0["type"] as? String == "input_text" ? $0["text"] as? String : nil }.joined(separator: "\n"))
    }
}

extension Store {
    /// Every few seconds (off the main thread): pick up prompts typed directly into agent terminals.
    func refreshLastPrompts() {
        guard !promptRefreshInFlight else { return }
        struct Job {
            let wid: UUID
            let pane: UUID
            let tool: Tool
            let session: String
            let current: String?
            let startedAt: Date
        }
        var jobs: [Job] = []
        for w in state.workspaces { for s in w.spaces { for p in s.panes where runtimes[p.id]?.isRunning == true {
            guard let rt = runtimes[p.id], p.tool == .claude || p.tool == .codex,
                  let id = p.tool == .claude ? p.claudeSessionID : p.codexSessionID else { continue }
            jobs.append(Job(wid: w.id, pane: p.id, tool: p.tool, session: id, current: p.lastPrompt, startedAt: rt.startedAt))
        } } }
        guard !jobs.isEmpty else { return }
        promptRefreshInFlight = true
        let settings = self.settings
        let snapshot = jobs
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = snapshot.compactMap { j -> (Job, String)? in
                guard let t = PromptTracker.lastPrompt(tool: j.tool, sessionID: j.session, settings: settings),
                      t != j.current else { return nil }
                return (j, t)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.promptRefreshInFlight = false
                for (job, text) in found {
                    guard let rt = self.runtimes[job.pane], rt.isRunning, rt.startedAt == job.startedAt,
                          let (_, pane) = self.pane(job.pane, in: job.wid), pane.lastPrompt == job.current,
                          (job.tool == .claude ? pane.claudeSessionID : pane.codexSessionID) == job.session else { continue }
                    self.updatePane(job.pane, in: job.wid) { $0.lastPrompt = text }
                }
            }
        }
    }
}
