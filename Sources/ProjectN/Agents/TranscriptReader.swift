import Foundation

/// Reads what an agent session produced from the CLI's own transcript (no screen scraping):
///
/// - Claude Code (`<config>/projects/<dir>/<session>.jsonl`): one entry per content block. A turn is over when an
///   assistant message has `stop_reason: end_turn` and a `system` / `turn_duration` entry follows. The answer is the
///   text blocks of that last assistant message. A pending `ExitPlanMode` call means a plan awaits approval.
/// - Codex (`<home>/sessions/**/rollout-*-<id>.jsonl`): `event_msg` / `task_complete` carries `last_agent_message`;
///   `token_count` carries usage.
enum TranscriptReader {
    struct Snapshot: Equatable {
        /// The turn finished; `result` holds the final answer.
        var finished = false
        var result: String?
        /// Plan proposed in plan mode, waiting for approval (Claude ExitPlanMode).
        var pendingPlan: String?
        var usage: TokenUsage?
        /// The turn ended on an error instead of an answer (usage limit, API error…).
        var error: String?
        /// The error is the account's usage limit: nothing more can run on this CLI until it resets.
        var usageLimit = false
        /// Bytes read (so later reads/resumes can start after them).
        var size: UInt64 = 0
        /// User prompts (not tool results) seen: tells whether a message typed in has reached the transcript yet.
        var prompts = 0
    }

    static func claudeTranscript(sessionID: String, settings: AppSettings) -> URL? {
        let root = SessionDiscovery.claudeConfigDir(settings).appendingPathComponent("projects")
        let fm = FileManager.default
        for d in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let u = root.appendingPathComponent(d).appendingPathComponent("\(sessionID).jsonl")
            if fm.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    static func codexTranscript(sessionID: String, settings: AppSettings) -> URL? {
        let root = SessionDiscovery.codexHome(settings).appendingPathComponent("sessions")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let u as URL in e where u.pathExtension == "jsonl" && u.lastPathComponent.contains(sessionID) { return u }
        return nil
    }

    static func fileSize(_ url: URL?) -> UInt64 {
        guard let url, let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (a[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Reads the transcript from `offset` (entries written before the task started are ignored).
    static func read(runtime: AgentRuntime, url: URL, offset: UInt64) -> Snapshot {
        guard let h = try? FileHandle(forReadingFrom: url) else { return Snapshot() }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        let data = (try? h.readToEnd()) ?? Data()
        var snap = runtime == .claudeCode ? parseClaude(data) : parseCodex(data)
        snap.size = offset + UInt64(data.count)
        return snap
    }

    // MARK: Claude

    static func parseClaude(_ data: Data) -> Snapshot {
        var snap = Snapshot()
        var usage = TokenUsage()
        var countedMessages = Set<String>()
        var lastMessageID: String?
        var lastTexts: [String] = []
        var lastStop: String?
        var endTurnText: String?
        var plan: String?
        var apiError: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let type = o["type"] as? String
            if o["isSidechain"] as? Bool == true { continue }
            if type == "assistant", let m = o["message"] as? [String: Any] {
                let mid = (m["id"] as? String) ?? UUID().uuidString
                if mid != lastMessageID { lastMessageID = mid; lastTexts = [] }
                lastStop = m["stop_reason"] as? String
                if let u = m["usage"] as? [String: Any], !countedMessages.contains(mid) {
                    countedMessages.insert(mid)
                    usage.inputTokens += (u["input_tokens"] as? Int) ?? 0
                    usage.outputTokens += (u["output_tokens"] as? Int) ?? 0
                    usage.cacheReadTokens += (u["cache_read_input_tokens"] as? Int) ?? 0
                    usage.cacheWriteTokens += (u["cache_creation_input_tokens"] as? Int) ?? 0
                    usage.contextTokens = ((u["input_tokens"] as? Int) ?? 0) + ((u["cache_read_input_tokens"] as? Int) ?? 0)
                        + ((u["cache_creation_input_tokens"] as? Int) ?? 0)
                }
                for part in (m["content"] as? [[String: Any]]) ?? [] {
                    switch part["type"] as? String {
                    case "text":
                        if let t = part["text"] as? String { lastTexts.append(t) }
                    case "tool_use":
                        if part["name"] as? String == "ExitPlanMode" {
                            plan = ((part["input"] as? [String: Any])?["plan"] as? String) ?? plan
                        }
                    default: break
                    }
                }
                if lastStop == "end_turn" { endTurnText = lastTexts.joined(separator: "\n\n") }
                if (o["isApiErrorMessage"] as? Bool) == true || (o["error"] != nil && lastTexts.isEmpty == false) {
                    let text = lastTexts.joined(separator: "\n")
                    apiError = text.isEmpty ? "\(o["error"] ?? "API error")" : text
                } else if !lastTexts.isEmpty {
                    apiError = nil   // it recovered and kept going
                }
            } else if type == "user", let m = o["message"] as? [String: Any] {
                // A new prompt (not a tool result) starts a new turn: the previous end_turn no longer counts.
                let isToolResult = ((m["content"] as? [[String: Any]]) ?? []).contains { $0["type"] as? String == "tool_result" }
                if !isToolResult, o["isMeta"] as? Bool != true {
                    snap.prompts += 1
                    endTurnText = nil
                    snap.finished = false
                    snap.error = nil
                    apiError = nil
                    plan = nil
                }
                if isToolResult { plan = nil }
            } else if type == "system", o["subtype"] as? String == "turn_duration" {
                if let t = endTurnText { snap.finished = true; snap.result = t }
            }
        }
        // Some versions don't write turn_duration: an end_turn as the very last assistant entry also counts.
        if !snap.finished, let t = endTurnText, lastStop == "end_turn", !t.isEmpty {
            snap.finished = true
            snap.result = t
        }
        // The CLI gave up on an API error (usage limit, overload…): the turn is over, without an answer.
        if let e = apiError {
            snap.error = e
            snap.usageLimit = isUsageLimit(e)
            if !snap.finished { snap.finished = true; snap.result = nil }
        }
        if !snap.finished, let plan { snap.pendingPlan = plan }
        snap.usage = countedMessages.isEmpty ? nil : usage
        return snap
    }

    static func isUsageLimit(_ message: String) -> Bool {
        let m = message.lowercased()
        return ["usage limit", "hit your limit", "limit reached", "usage_limit", "rate_limit_error", "out of extra usage"]
            .contains { m.contains($0) }
    }

    // MARK: Codex

    static func parseCodex(_ data: Data) -> Snapshot {
        var snap = Snapshot()
        var lastAssistant: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let p = o["payload"] as? [String: Any] else { continue }
            let type = o["type"] as? String
            let ptype = p["type"] as? String
            if type == "event_msg", ptype == "task_started" {
                snap.prompts += 1
                snap.finished = false
                snap.error = nil
                snap.usageLimit = false
                lastAssistant = nil
            } else if type == "event_msg", ptype == "task_complete" {
                snap.finished = true
                snap.result = (p["last_agent_message"] as? String) ?? lastAssistant
                snap.error = nil
                snap.usageLimit = false
                if let e = p["error"], !(e is NSNull) {
                    // {"message": "You've hit your usage limit… try again at 12:54 PM.", "codex_error_info": "usage_limit_exceeded"}
                    let d = e as? [String: Any]
                    let message = (d?["message"] as? String) ?? (e as? String) ?? "\(e)"
                    let info = d?["codex_error_info"] as? String ?? ""
                    snap.error = message
                    snap.usageLimit = info.contains("usage_limit") || isUsageLimit(message)
                }
            } else if type == "event_msg", ptype == "token_count",
                      let info = p["info"] as? [String: Any], let t = info["total_token_usage"] as? [String: Any] {
                var u = TokenUsage()
                u.inputTokens = (t["input_tokens"] as? Int) ?? 0
                u.cacheReadTokens = (t["cached_input_tokens"] as? Int) ?? 0
                u.outputTokens = (t["output_tokens"] as? Int) ?? 0
                if let last = info["last_token_usage"] as? [String: Any] { u.contextTokens = last["input_tokens"] as? Int }
                snap.usage = u
            } else if type == "response_item", ptype == "message", p["role"] as? String == "assistant" {
                let parts = (p["content"] as? [[String: Any]]) ?? []
                let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                if !text.isEmpty { lastAssistant = text }
            }
        }
        return snap
    }
}
