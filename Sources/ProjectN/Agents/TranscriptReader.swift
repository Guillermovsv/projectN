import Foundation

/// Reads what an agent session produced from the CLI's own transcript (no screen scraping):
///
/// - Claude Code (`<config>/projects/<dir>/<session>.jsonl`): one entry per content block. A turn is over when an
///   assistant message has `stop_reason: end_turn` and a `system` / `turn_duration` entry follows. The answer is the
///   text blocks of that last assistant message. A pending `ExitPlanMode` call means a plan awaits approval.
/// - Codex (`<home>/sessions/**/rollout-*-<id>.jsonl`): `event_msg` / `task_complete` carries `last_agent_message`;
///   `token_count` carries usage.
///
/// The harness reads every running task's transcript every 1.5 s. Those files grow to many MB (Codex rollouts hold
/// whole tool outputs), so reads are incremental: a `Cursor` keeps the parse state and the byte offset reached, and
/// each read only parses the lines appended since the previous one.
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
        /// Short updates the agent wrote while working (Codex `phase: commentary`), oldest first.
        var progress: [String] = []
    }

    static func claudeTranscript(sessionID: String, settings: AppSettings) -> URL? {
        SessionDiscovery.transcript(tool: .claude, id: sessionID, settings: settings)
    }

    static func codexTranscript(sessionID: String, settings: AppSettings) -> URL? {
        SessionDiscovery.transcript(tool: .codex, id: sessionID, settings: settings)
    }

    static func fileSize(_ url: URL?) -> UInt64 {
        guard let url, let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (a[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Where a task's transcript was read up to, and the parse state at that point.
    struct Cursor {
        let runtime: AgentRuntime
        let url: URL
        /// Where the task's part of the transcript starts (entries before it belong to earlier tasks).
        let start: UInt64
        /// Identity of the file read (a replaced file starts over).
        let fileNumber: UInt64?
        /// Bytes parsed so far: always the end of a complete line.
        var offset: UInt64
        var claude = ClaudeState()
        var codex = CodexState()

        init(runtime: AgentRuntime, url: URL, start: UInt64, fileNumber: UInt64?) {
            self.runtime = runtime
            self.url = url
            self.start = start
            self.fileNumber = fileNumber
            self.offset = start
        }

        /// Parses complete lines into the state; returns the trailing partial line (not consumed).
        mutating func consume(_ data: Data) -> Data {
            guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return data }
            let complete = data[data.startIndex..<lastNewline]
            if runtime == .claudeCode { claude.consume(complete) } else { codex.consume(complete) }
            offset += UInt64(lastNewline - data.startIndex + 1)
            return Data(data[(lastNewline + 1)...])
        }

        /// What the transcript says now. A trailing line without its newline yet is included when it's already
        /// complete JSON (some writers add the newline separately), without committing it to the state.
        func snapshot(pendingTail tail: Data) -> Snapshot {
            var snap: Snapshot
            if runtime == .claudeCode {
                var c = claude
                if !tail.isEmpty { c.consume(tail) }
                snap = c.snapshot()
            } else {
                var c = codex
                if !tail.isEmpty { c.consume(tail) }
                snap = c.snap
            }
            snap.size = offset + UInt64(tail.count)
            return snap
        }
    }

    /// Reads the transcript from `offset` (entries written before the task started are ignored).
    static func read(runtime: AgentRuntime, url: URL, offset: UInt64) -> Snapshot {
        var cursor: Cursor?
        return read(runtime: runtime, url: url, offset: offset, cursor: &cursor)
    }

    /// Incremental read: continues from `cursor` (updated in place) when it's for the same file and task; otherwise
    /// starts over from `offset`. Equivalent to parsing everything from `offset` each time.
    static func read(runtime: AgentRuntime, url: URL, offset: UInt64, cursor: inout Cursor?) -> Snapshot {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        let fileNumber = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        if let c = cursor, c.runtime != runtime || c.url != url || c.start != offset || c.fileNumber != fileNumber
            || (size.map { $0 < c.offset } ?? true) {
            cursor = nil
        }
        var c = cursor ?? Cursor(runtime: runtime, url: url, start: offset, fileNumber: fileNumber)
        guard let h = try? FileHandle(forReadingFrom: url) else { cursor = nil; return Snapshot() }
        defer { try? h.close() }
        do { try h.seek(toOffset: c.offset) } catch { cursor = nil; return Snapshot() }
        let data = (try? h.readToEnd()) ?? Data()
        let tail = c.consume(data)
        cursor = c
        return c.snapshot(pendingTail: tail)
    }

    // MARK: Claude

    static func parseClaude(_ data: Data) -> Snapshot {
        var state = ClaudeState()
        state.consume(data)
        return state.snapshot()
    }

    /// Everything `parseClaude` tracks while walking the lines, so parsing can resume where it stopped.
    struct ClaudeState {
        var snap = Snapshot()
        var usage = TokenUsage()
        var countedMessages = Set<String>()
        var lastMessageID: String?
        var lastTexts: [String] = []
        var lastStop: String?
        var endTurnText: String?
        var plan: String?
        var apiError: String?

        mutating func consume(_ data: Data) {
            for line in data.split(separator: UInt8(ascii: "\n")) { consumeLine(line) }
        }

        private mutating func consumeLine(_ line: Data.SubSequence) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return }
            let type = o["type"] as? String
            if o["isSidechain"] as? Bool == true { return }
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

        /// The state as a snapshot (doesn't change the state: more lines may follow).
        func snapshot() -> Snapshot {
            var snap = self.snap
            // Some versions don't write turn_duration: an end_turn as the very last assistant entry also counts.
            if !snap.finished, let t = endTurnText, lastStop == "end_turn", !t.isEmpty {
                snap.finished = true
                snap.result = t
            }
            // The CLI gave up on an API error (usage limit, overload…): the turn is over, without an answer.
            if let e = apiError {
                snap.error = e
                snap.usageLimit = TranscriptReader.isUsageLimit(e)
                if !snap.finished { snap.finished = true; snap.result = nil }
            }
            if !snap.finished, let plan { snap.pendingPlan = plan }
            snap.usage = countedMessages.isEmpty ? nil : usage
            return snap
        }
    }

    static func isUsageLimit(_ message: String) -> Bool {
        let m = message.lowercased()
        return ["usage limit", "hit your limit", "limit reached", "usage_limit", "rate_limit_error", "out of extra usage"]
            .contains { m.contains($0) }
    }

    // MARK: Codex

    static func parseCodex(_ data: Data) -> Snapshot {
        var state = CodexState()
        state.consume(data)
        return state.snap
    }

    /// Everything `parseCodex` tracks while walking the lines, so parsing can resume where it stopped.
    struct CodexState {
        var snap = Snapshot()
        var lastAssistant: String?

        mutating func consume(_ data: Data) {
            for line in data.split(separator: UInt8(ascii: "\n")) { consumeLine(line) }
        }

        private mutating func consumeLine(_ line: Data.SubSequence) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let p = o["payload"] as? [String: Any] else { return }
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
                    snap.usageLimit = info.contains("usage_limit") || TranscriptReader.isUsageLimit(message)
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
                // "Voy a…", "Ya tengo…": what it tells you between steps (the final answer is phase final_answer).
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if p["phase"] as? String == "commentary", !trimmed.isEmpty { snap.progress.append(trimmed) }
            }
        }
    }
}
