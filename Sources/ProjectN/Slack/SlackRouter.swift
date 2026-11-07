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

    /// `conversationProjectID`: the project this conversation has been about. "project X" where X isn't a project
    /// ("add it to the project npm install …") then keeps that project instead of asking.
    static func resolveProject(_ text: String, allowed: [Project], selectedProjectID: UUID?,
                               conversationProjectID: UUID? = nil) -> ProjectResolution {
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
        let conversation = conversationProjectID.flatMap { id in allowed.first { $0.id == id } }
        if let word = wordAfterProjectKeyword(text) {
            let w = word.folded
            if !selectedWords.contains(w) && !fillerWords.contains(w) {
                if let conversation { return .project(conversation) }
                return .notFound(name: word, candidates: allowed)
            }
        }

        // 3. The conversation's project, the project selected in ProjectN, or the only allowed one.
        if let conversation { return .project(conversation) }
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

    /// "sesión nueva", "desde cero", "new session": start over instead of continuing the project's session.
    static func wantsNewSession(_ text: String) -> Bool {
        let f = text.folded
        return ["sesion nueva", "nueva sesion", "desde cero", "new session", "fresh session", "start over", "empieza de cero"]
            .contains { f.contains($0) }
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

    // MARK: Agent channels

    /// Slack channel name for an agent: its name, lowercase, accents removed, words joined by "-" (max 80).
    static func channelName(for agentName: String) -> String {
        let f = agentName.folded
        let slug = f.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }.joined()
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((slug.isEmpty ? "agente" : slug).prefix(80))
    }

    // MARK: Formatting

    /// Markdown (as agents write it) → Slack mrkdwn: headings, bold / italic / strike, links and images,
    /// bullet / numbered / task lists (nested ones indented), tables (as lists) and separators.
    static func toSlack(_ md: String) -> String {
        var out: [String] = []
        var inCode = false
        var table: [[String]] = []

        func flushTable() {
            guard !table.isEmpty else { return }
            out += tableLines(table)
            table = []
        }

        for raw in md.components(separatedBy: "\n") {
            var line = raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { flushTable(); inCode.toggle(); out.append("```"); continue }
            if inCode { out.append(line); continue }
            if trimmed.hasPrefix("|") && trimmed.count > 1 {
                let cells = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                // The |---|:---:| row under the header.
                if !cells.allSatisfy({ $0.range(of: #"^:?-{2,}:?$"#, options: .regularExpression) != nil }) {
                    table.append(cells.map(inline))
                }
                continue
            }
            flushTable()
            if trimmed.range(of: #"^([-*_])(\s*\1){2,}$"#, options: .regularExpression) != nil {
                out.append("──────────")
                continue
            }
            if let r = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let title = String(line[r.upperBound...]).replacingOccurrences(of: "**", with: "")
                if let last = out.last, !last.isEmpty { out.append("") }
                out.append("*" + inline(title).trimmingCharacters(in: .whitespaces) + "*")
                continue
            }
            line = inline(line)
            // Lists: task items, bullets (nested ones get ◦), numbered items.
            line = line.replacingOccurrences(of: #"^(\s*)[-*+] \[ \]"#, with: "$1☐", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^(\s*)[-*+] \[x\]"#, with: "$1☑", options: [.regularExpression, .caseInsensitive])
            if let m = line.range(of: #"^(\s*)[-*+] "#, options: .regularExpression) {
                let indent = line[m].prefix { $0 == " " || $0 == "\t" }.count
                line = (indent >= 2 ? "      ◦ " : "• ") + line[m.upperBound...]
            } else if let m = line.range(of: #"^\s{2,}\d+[.)] "#, options: .regularExpression) {
                line = "      " + line[m].trimmingCharacters(in: .whitespaces) + line[m.upperBound...]
            }
            out.append(line)
        }
        flushTable()
        // At most one blank line in a row, none at the ends.
        var compact: [String] = []
        for l in out where !(l.trimmingCharacters(in: .whitespaces).isEmpty && (compact.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)) {
            compact.append(l)
        }
        while compact.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { compact.removeLast() }
        return compact.joined(separator: "\n")
    }

    /// Inline Markdown → mrkdwn (outside code spans).
    static func inline(_ s: String) -> String {
        // Split on `code` spans so their contents stay as written.
        let parts = s.components(separatedBy: "`")
        return parts.enumerated().map { i, part in
            guard i % 2 == 0 else { return part }
            var l = part
            l = l.replacingOccurrences(of: #"!\[([^\]]*)\]\((https?://[^)\s]+)\)"#, with: "<$2|$1>", options: .regularExpression)
            l = l.replacingOccurrences(of: #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#, with: "<$2|$1>", options: .regularExpression)
            l = l.replacingOccurrences(of: #"(?<![*\w])\*(?![\s*])(.+?)(?<![\s*])\*(?![*\w])"#, with: "_$1_", options: .regularExpression)
            l = l.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "*$1*", options: .regularExpression)
            l = l.replacingOccurrences(of: #"__(.+?)__"#, with: "*$1*", options: .regularExpression)
            l = l.replacingOccurrences(of: #"~~(.+?)~~"#, with: "~$1~", options: .regularExpression)
            return l
        }.joined(separator: "`")
    }

    /// A Markdown table as a list (Slack can't show tables): one bullet per row, labelled by the header.
    static func tableLines(_ rows: [[String]]) -> [String] {
        guard rows.count > 1 else { return rows.map { "• " + $0.filter { !$0.isEmpty }.joined(separator: " · ") } }
        let header = rows[0]
        return rows.dropFirst().map { row in
            let first = row.first ?? ""
            let rest = row.dropFirst().enumerated().compactMap { i, cell -> String? in
                guard !cell.isEmpty else { return nil }
                let h = i + 1 < header.count ? header[i + 1] : ""
                return header.count == 2 || h.isEmpty ? cell : "\(h): \(cell)"
            }
            let head = first.isEmpty ? "" : "*\(first.replacingOccurrences(of: "*", with: ""))*"
            return "• " + ([head].filter { !$0.isEmpty } + [rest.joined(separator: " · ")].filter { !$0.isEmpty })
                .joined(separator: header.count == 2 ? ": " : " — ")
        }
    }

    // MARK: Questions in an answer

    private static let questionHeading = #"^\s*(#{1,6}\s*)?(\*\*)?\s*(preguntas?|dudas?|questions?|open questions|necesito (de ti|saber)|pendiente de ti|para decidir|decisiones( pendientes)?|antes de seguir)\b[^\n]*$"#

    /// Separates the questions an agent ends its answer with — a "Preguntas" / "Questions" section, or the
    /// trailing lines that end in "?" — from the rest, so they can be shown as a numbered list.
    static func splitQuestions(_ md: String) -> (body: String, questions: [String]) {
        var lines = md.components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty, !md.contains("```") || !lines.last!.hasPrefix("```") else { return (md, []) }

        func strip(_ l: String) -> String {
            l.replacingOccurrences(of: #"^\s*([-*+•]|\d+[.)])\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        // 1. A questions section at the end (no heading after it).
        if let h = lines.lastIndex(where: { $0.range(of: questionHeading, options: [.regularExpression, .caseInsensitive]) != nil
                                            && ($0.hasPrefix("#") || $0.hasPrefix("**") || $0.trimmingCharacters(in: .whitespaces).hasSuffix(":")) }),
           !lines[(h + 1)...].contains(where: { $0.hasPrefix("#") }) {
            var qs: [String] = []
            for l in lines[(h + 1)...] where !l.trimmingCharacters(in: .whitespaces).isEmpty {
                let isItem = l.range(of: #"^([-*+•]|\d+[.)])\s+"#, options: .regularExpression) != nil
                if !isItem, l.first == " " || l.first == "\t", !qs.isEmpty {
                    qs[qs.count - 1] += "\n" + l   // sub-options of the previous question
                } else if l.range(of: #"^\s+([-*+•]|\d+[.)]|[a-z][.)])\s+"#, options: .regularExpression) != nil, !qs.isEmpty {
                    qs[qs.count - 1] += "\n" + l
                } else {
                    qs.append(strip(l))
                }
            }
            if !qs.isEmpty {
                let body = lines[..<h].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return (body, qs)
            }
        }
        // 2. Trailing lines ending in "?".
        var i = lines.count
        var qs: [String] = []
        while i > 0 {
            let l = lines[i - 1]
            let t = strip(l)
            if t.isEmpty { i -= 1; continue }
            guard t.hasSuffix("?") || t.hasSuffix("?*") || t.hasSuffix("?**") else { break }
            qs.insert(t, at: 0)
            i -= 1
        }
        guard !qs.isEmpty, i > 0 else { return (md, []) }   // a reply that is only questions stays as written
        return (lines[..<i].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), qs)
    }

    /// Questions as a numbered mrkdwn list (sub-options indented under each one).
    static func numberedQuestions(_ qs: [String]) -> String {
        qs.enumerated().map { i, q in
            let parts = q.components(separatedBy: "\n")
            let head = "*\(i + 1).* " + inline(parts[0])
            let subs = parts.dropFirst().map { l -> String in
                let t = l.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: #"^([-*+•])\s+"#, with: "", options: .regularExpression)
                return "      ◦ " + inline(t)
            }
            return ([head] + subs).joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// mrkdwn split into section blocks (Slack caps a section's text at 3000 characters).
    static func sections(_ mrkdwn: String) -> [[String: Any]] {
        chunks(mrkdwn, limit: 2900).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map {
            ["type": "section", "text": ["type": "mrkdwn", "text": $0]]
        }
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
