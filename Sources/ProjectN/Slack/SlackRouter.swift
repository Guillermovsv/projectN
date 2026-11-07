import Foundation

/// Pure message routing: which agent, which project, explicit resume. No I/O, so it is unit-tested directly.
enum SlackRouter {
    /// Removes `<@U…>` mentions and Slack link markup, collapses whitespace.
    static func clean(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"<@[A-Z0-9]+(\|[^>]*)?>"#, with: " ", options: .regularExpression)
        // <https://x|label> → label, <https://x> → https://x, <#C1|chan> → #chan
        t = t.replacingOccurrences(of: #"<#[A-Z0-9]+\|([^>]*)>"#, with: "#$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<([^|>]+)\|([^>]*)>"#, with: "$2", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<([^>]+)>"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
        return t.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Agent

    /// The agent named at the start of the message ("Project Manager, …", "@Developer …", "hola SEO: …"),
    /// else the default agent. Returns the instruction without the agent's name.
    static func matchAgent(_ text: String, agents: [AgentProfile], defaultID: UUID?) -> (agent: AgentProfile?, instruction: String) {
        let enabled = agents.filter(\.enabled).sorted { $0.name.count > $1.name.count }
        var body = Substring(text)
        // Optional greeting.
        for g in ["hola ", "hey ", "hi ", "hello ", "oye ", "buenas "] where body.folded.hasPrefix(g) {
            body = body.dropFirst(g.count)
            break
        }
        let candidate = body.drop { $0 == "@" || $0 == " " }
        for a in enabled {
            let n = a.name.folded
            guard candidate.count >= n.count, String(candidate.prefix(n.count)).folded == n else { continue }
            let after = candidate.dropFirst(n.count)
            if let c = after.first, !(c == "," || c == ":" || c == " " || c == "-" || c == "—" || c == "\n" || c == ";") { continue }
            let rest = after.drop { ",:;-— \n".contains($0) }
            return (a, String(rest).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let def = enabled.first { $0.id == defaultID } ?? (defaultID == nil ? enabled.sorted { $0.createdAt < $1.createdAt }.first : nil)
        return (def, text)
    }

    // MARK: Project

    enum ProjectResolution: Equatable {
        case project(Project)
        /// Several projects match: ask which one.
        case ambiguous([Project])
        /// The message names a project that doesn't exist (or isn't allowed).
        case notFound(name: String, candidates: [Project])
        /// No project mentioned and nothing selected: ask.
        case unspecified(candidates: [Project])
    }

    /// Words after "proyecto"/"project" that refer to the project open in ProjectN rather than a name.
    static let selectedWords: Set<String> = ["seleccionado", "selected", "actual", "current", "activo", "active",
                                              "abierto", "open", "este", "this", "focused", "enfocado"]
    static let fillerWords: Set<String> = ["de", "del", "el", "la", "en", "the", "a", "an", "of", "in", "que", "y", "and",
                                            "para", "for", "con", "with", "llamado", "named", "called", "manager"]

    static func resolveProject(_ text: String, allowed: [Project], selectedProjectID: UUID?) -> ProjectResolution {
        let folded = text.folded
        // 1. Project names (or folder names) written in the message.
        var hits: [Project] = []
        for p in allowed {
            let names = Set([p.name.folded, URL(fileURLWithPath: p.path).lastPathComponent.folded]).filter { !$0.isEmpty }
            if names.contains(where: { containsPhrase(folded, $0) }) { hits.append(p) }
        }
        // "web" and "web shop" both match "web shop": keep the longer one.
        hits = hits.filter { h in !hits.contains { o in o.id != h.id && o.name.count > h.name.count && o.name.folded.contains(h.name.folded) } }
        if hits.count == 1 { return .project(hits[0]) }
        if hits.count > 1 { return .ambiguous(hits) }

        // 2. "proyecto X" / "project X" where X isn't a project.
        if let word = wordAfterProjectKeyword(text) {
            let w = word.folded
            if !selectedWords.contains(w) && !fillerWords.contains(w) {
                return .notFound(name: word, candidates: allowed)
            }
        }

        // 3. The project selected in ProjectN, or the only allowed one.
        if let sel = selectedProjectID, let p = allowed.first(where: { $0.id == sel }) { return .project(p) }
        if allowed.count == 1 { return .project(allowed[0]) }
        return .unspecified(candidates: allowed)
    }

    /// A reply to a clarification: a project name, or its number in the list we sent.
    static func pickFromReply(_ text: String, candidates: [Project]) -> Project? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int(t.trimmingCharacters(in: CharacterSet(charactersIn: ".)#"))), candidates.indices.contains(n - 1) { return candidates[n - 1] }
        if case .project(let p) = resolveProject(t, allowed: candidates, selectedProjectID: nil) { return p }
        return candidates.first { $0.name.folded == t.folded }
    }

    static func containsPhrase(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: needle) + "(?![\\p{L}\\p{N}_])"
        return haystack.range(of: pattern, options: .regularExpression) != nil
    }

    static func wordAfterProjectKeyword(_ text: String) -> String? {
        let pattern = #"(?i)\b(?:proyecto|project)\s+(?:(?:llamado|named|called|de|del)\s+)?["“'«`]?([^\s"”'»`,.;:!?¿¡()]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let w = ns.substring(with: m.range(at: 1))
            if fillerWords.contains(w.folded) { continue }
            return w
        }
        return nil
    }

    // MARK: New projects

    /// "crea el proyecto Landing García y …", "create a new project called “Shop”", "nuevo proyecto: Blog X".
    /// Returns the requested name, or nil if the message isn't asking to create a project.
    static func createProjectName(_ text: String) -> String? {
        let pattern = #"(?i)(?:\b(?:cr[eé](?:a|ar|ame|e|en)|create|make\s+(?:me\s+)?(?:a|an)\s+new|set\s+up\s+(?:a|an)\s+new)\s+(?:me\s+)?(?:un|una|el|la|a|an|the)?\s*(?:nuevo\s+|nueva\s+|new\s+)?(?:proyecto|project)|\b(?:nuevo|nueva)\s+proyecto|\bnew\s+project)\s*(?:nuevo\s+|new\s+)?(?:llamado|llamada|named|called|de\s+nombre|:)?\s*"#
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        var rest = text[r.upperBound...].trimmingCharacters(in: .whitespaces)
        // Quoted name wins.
        for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'"), ("«", "»"), ("`", "`"), ("*", "*")] where rest.hasPrefix(open) {
            let inner = rest.dropFirst(open.count)
            if let end = inner.range(of: close) { return String(inner[..<end.lowerBound]).trimmingCharacters(in: .whitespaces) }
        }
        // Otherwise up to punctuation or a connecting word, at most 6 words.
        if let cut = rest.range(of: #"[,.;:!?\n]|\s(?:y|e|and|para|for|con|with|que|that|en|in|donde|where|sobre|about)\s"#, options: [.regularExpression, .caseInsensitive]) {
            rest = String(rest[..<cut.lowerBound])
        }
        let words = rest.split(separator: " ").prefix(6)
        let name = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    // MARK: Resume

    /// Only an explicit request continues an earlier session ("reanuda la sesión", "resume session", "--resume").
    static func wantsResume(_ text: String) -> Bool {
        let f = text.folded
        let phrases = ["reanuda la sesion", "reanudar la sesion", "reanuda sesion", "reanudar sesion", "continua la sesion",
                       "continuar la sesion", "continua en la misma sesion", "misma sesion", "resume session", "resume the session",
                       "continue the session", "continue session", "same session", "--resume"]
        return phrases.contains { f.contains($0) } || f.hasPrefix("resume:") || f.hasPrefix("reanudar:")
    }

    // MARK: Formatting

    /// Markdown (as agents write it) → Slack mrkdwn.
    static func toSlack(_ md: String) -> String {
        var out: [String] = []
        var inCode = false
        for raw in md.components(separatedBy: "\n") {
            var line = raw
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); out.append("```"); continue }
            if inCode { out.append(line); continue }
            if let r = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                line = "*" + line[r.upperBound...].replacingOccurrences(of: "**", with: "") + "*"
            } else {
                line = line.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "*$1*", options: .regularExpression)
                line = line.replacingOccurrences(of: #"__(.+?)__"#, with: "*$1*", options: .regularExpression)
            }
            line = line.replacingOccurrences(of: #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#, with: "<$2|$1>", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^(\s*)[-*] \[ \]"#, with: "$1☐", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^(\s*)[-*] \[x\]"#, with: "$1☑", options: [.regularExpression, .caseInsensitive])
            line = line.replacingOccurrences(of: #"^(\s*)[-*] "#, with: "$1• ", options: .regularExpression)
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// Splits long text into Slack-sized messages at line boundaries.
    static func chunks(_ text: String, limit: Int = 3500) -> [String] {
        guard text.count > limit else { return [text] }
        var parts: [String] = []
        var cur = ""
        for line in text.components(separatedBy: "\n") {
            if cur.count + line.count + 1 > limit, !cur.isEmpty { parts.append(cur); cur = "" }
            if line.count > limit {
                var rest = Substring(line)
                while rest.count > limit { parts.append(String(rest.prefix(limit))); rest = rest.dropFirst(limit) }
                cur = String(rest)
            } else {
                cur += (cur.isEmpty ? "" : "\n") + line
            }
        }
        if !cur.isEmpty { parts.append(cur) }
        return parts
    }
}

private extension Substring {
    var folded: String { String(self).folded }
}
