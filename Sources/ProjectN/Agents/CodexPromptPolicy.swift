import Foundation

/// Codex has no PreToolUse hook: it asks in its own terminal (command, MCP tool call, edits, Computer Use).
/// This reads what such a prompt asks for and judges it with the same ApprovalPolicy as Claude agents, so an
/// agent in Auto mode (or High autonomy) doesn't send routine prompts to Slack. Pure: screen lines → tier.
enum CodexPromptPolicy {
    enum Ask: Equatable {
        /// "Allow the <server> MCP server to run tool "<tool>"?"
        case mcp(server: String, tool: String)
        /// "$ <command>" (wrapped lines joined). `collapsed`: Codex hid part of it ("[… 28 lines]").
        case command(String, collapsed: Bool)
        /// "Would you like to make the following edits?"
        case edits(deletes: Bool)
        /// Anything else ("Allow Computer Use to use "App"?", network access, …): the question itself.
        case other(String)
    }

    private static let frame = CharacterSet(charactersIn: " │┃║╭╮╰╯─━")

    static func parse(screen lines: [String], question: String) -> Ask {
        let rows = lines.map { $0.trimmingCharacters(in: frame) }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)

        if let m = firstMatch(#"Allow the (.+?) MCP server to run tool "([^"]+)""#, in: ([q] + rows.reversed()).joined(separator: "\n")) {
            return .mcp(server: m[0], tool: m[1])
        }
        // The last "$ " block on screen is the command being asked about.
        if let start = rows.lastIndex(where: { $0.hasPrefix("$ ") }) {
            var parts: [String] = []
            var collapsed = false
            for (i, r) in rows[start...].enumerated() {
                if isOptionRow(r) || r.hasPrefix("Reason:") || r.hasPrefix("Would you like") || r.hasPrefix("Allow ") { break }
                if r.contains("[…") && r.contains("line") { collapsed = true; continue }
                if r.isEmpty { if i > 0 { break } else { continue } }
                parts.append(i == 0 ? String(r.dropFirst(2)) : r)
            }
            let cmd = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !cmd.isEmpty { return .command(cmd, collapsed: collapsed) }
        }
        let all = ([q] + rows).joined(separator: "\n")
        if all.range(of: "following edits", options: .caseInsensitive) != nil
            || all.range(of: "apply this patch", options: .caseInsensitive) != nil {
            let deletes = rows.contains { $0.range(of: #"^(D |Delete(d)? (file)?)|\(deleted\)"#, options: .regularExpression) != nil }
            return .edits(deletes: deletes)
        }
        return .other(q)
    }

    /// The verdict for a Codex prompt, after the agent's autonomy / Auto mode (ApprovalPolicy.decide).
    static func decide(_ ask: Ask, _ ctx: ApprovalPolicy.Context) -> ApprovalTier {
        switch ask {
        case .mcp(let server, let tool):
            return ApprovalPolicy.decide(tool: "mcp__\(server)__\(tool)", input: [:], ctx)
        case .command(let cmd, let collapsed):
            // A command Codex collapsed on screen can't be read in full: it could hide an `rm`.
            if collapsed { return .user("Deletes? The command is collapsed on screen: \(ApprovalPolicy.clip(cmd))") }
            return ApprovalPolicy.decide(tool: "Bash", input: ["command": cmd], ctx)
        case .edits(let deletes):
            if deletes { return .user("Deletes files in a patch") }
            return ApprovalPolicy.decide(tool: "Edit", input: [:], ctx)
        case .other(let q):
            let words = q.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            if words.contains(where: ApprovalPolicy.deleteWords.contains) { return .user("Deletes: \(ApprovalPolicy.clip(q))") }
            if words.contains(where: { ["sudo", "administrator", "admin", "root"].contains($0) }) {
                return .user("Needs administrator rights: \(ApprovalPolicy.clip(q))")
            }
            return ApprovalPolicy.decide(tool: "CodexPrompt", input: [:], ctx)   // gray area ("Uses CodexPrompt")
        }
    }

    static func describe(_ ask: Ask) -> String {
        switch ask {
        case .mcp(let s, let t): return "\(s) · \(t)"
        case .command(let c, _): return ApprovalPolicy.clip(c)
        case .edits: return "file edits"
        case .other(let q): return ApprovalPolicy.clip(q)
        }
    }

    private static func isOptionRow(_ r: String) -> Bool {
        r.range(of: #"^(›|>)?\s*\d+\.\s"#, options: .regularExpression) != nil
    }

    private static func firstMatch(_ pattern: String, in s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
    }
}
