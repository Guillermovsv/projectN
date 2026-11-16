import Foundation
import NaturalLanguage

/// What the Assistant understood. Pure matching (no AI, no I/O) so it is fast, offline and unit-tested.
enum AssistantIntent: Equatable {
    case help
    case stopSpeaking
    /// "gracias", "eso es todo": ends conversation mode.
    case endConversation
    case repeatLast
    case status
    case pending
    case home
    case openProject(Project)
    case openWorkspace(id: UUID, name: String)
    case newSpace(Project?)
    case nextSpace
    case previousSpace
    case gotoSpace(Int)                     // 1-based, in the current workspace
    case newPane(Tool, Project?)
    case showPanel(RightPanelModel.Tab)
    case askAgent(id: UUID, name: String, instruction: String)
    case cancelAgent(id: UUID, name: String)
    case ambiguousProject([Project])
    case unknown(String)
}

enum AssistantLang: String { case es, en }

enum AssistantCommands {
    struct Context {
        var projects: [Project]
        var workspaces: [(id: UUID, name: String)] = []
        var agents: [AgentProfile] = []
    }

    static func parse(_ raw: String, _ ctx: Context) -> AssistantIntent {
        let text = stripWake(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let f = normalize(text)
        guard !f.isEmpty else { return .unknown(raw) }

        if matchesAny(f, exact: ["stop", "para", "silencio", "callate", "calla", "basta", "shh", "quiet", "shut up", "ya"]) { return .stopSpeaking }
        if matchesAny(f, exact: ["gracias", "muchas gracias", "eso es todo", "es todo", "nada mas", "adios", "hasta luego",
                                 "listo gracias", "ok gracias", "thanks", "thank you", "thats all", "that s all", "bye", "goodbye"]) { return .endConversation }
        if has(f, ["ayuda", "help", "que puedes hacer", "what can you do", "comandos", "commands"]) { return .help }
        if has(f, ["repite", "repitelo", "repeat", "otra vez", "say again", "say that again"]) { return .repeatLast }

        // "Developer, fix the login" / "pide a Developer que …" / "tell Developer to …"
        if let a = askAgent(text, ctx.agents) { return a }

        if let verb = firstWord(f), ["cancela", "cancelar", "deten", "detener", "cancel", "kill", "para", "stop"].contains(verb) {
            let rest = String(f.dropFirst(verb.count))
            if let a = ctx.agents.filter(\.enabled).sorted(by: { $0.name.count > $1.name.count })
                .first(where: { SlackRouter.containsPhrase(rest, $0.name.folded) }) {
                return .cancelAgent(id: a.id, name: a.name)
            }
        }

        if has(f, ["pendiente", "pendientes", "necesita", "necesitan", "needs input", "needs me", "waiting", "esperando", "aprobacion", "approval"]) { return .pending }
        if has(f, ["estado", "status", "que esta corriendo", "que hay corriendo", "whats running", "what is running", "resumen", "summary", "como va", "como van", "how is it going"]) { return .status }
        if matchesAny(f, exact: ["inicio", "home", "overview", "vista general", "ve al inicio", "go home"]) { return .home }

        // Right panel tabs.
        let opens = ["muestra", "mostrar", "abre", "abrir", "show", "open", "ve a", "go to"]
        if startsWithAny(f, opens) {
            if has(f, ["actividad", "activity"]) { return .showPanel(.activity) }
            if has(f, ["navegador", "browser"]) { return .showPanel(.browser) }
            if has(f, ["archivos", "files", "carpeta", "folder"]) { return .showPanel(.files) }
        }

        // Spaces.
        if has(f, ["siguiente espacio", "proximo espacio", "next space"]) { return .nextSpace }
        if has(f, ["espacio anterior", "previous space", "last space"]) { return .previousSpace }
        if has(f, ["nuevo espacio", "crea un espacio", "crear espacio", "crea espacio", "abre un espacio", "new space", "create a space", "open a new space", "open a space"]) {
            return .newSpace(project(in: f, ctx.projects))
        }
        if let n = spaceNumber(f) { return .gotoSpace(n) }

        // Panes: "abre un claude en web shop", "new terminal", "lanza codex".
        let paneVerbs = ["abre", "abrir", "nuevo", "nueva", "lanza", "lanzar", "inicia", "arranca", "open", "new", "launch", "start", "add", "agrega"]
        if startsWithAny(f, paneVerbs) {
            let tools: [(String, Tool)] = [("claude", .claude), ("codex", .codex), ("cursor", .cursor),
                                           ("terminal", .terminal), ("shell", .terminal), ("consola", .terminal)]
            if let t = tools.first(where: { SlackRouter.containsPhrase(f, $0.0) }) {
                return .newPane(t.1, project(in: f, ctx.projects))
            }
        }

        // Projects / workspaces: "abre web shop", "ve al proyecto landing", "switch to blog".
        let goVerbs = ["abre", "abrir", "ve a", "ve al", "ir a", "vamos a", "cambia a", "open", "go to", "switch to", "show me"]
        if startsWithAny(f, goVerbs) || has(f, ["proyecto", "project"]) {
            let hits = projects(in: f, ctx.projects)
            if hits.count == 1 { return .openProject(hits[0]) }
            if hits.count > 1 { return .ambiguousProject(hits) }
            if let w = ctx.workspaces.sorted(by: { $0.name.count > $1.name.count })
                .first(where: { SlackRouter.containsPhrase(f, normalize($0.name)) }) {
                return .openWorkspace(id: w.id, name: w.name)
            }
        }
        return .unknown(raw)
    }

    // MARK: Pieces

    private static func askAgent(_ text: String, _ agents: [AgentProfile]) -> AssistantIntent? {
        var t = text
        // "pide a X que …", "dile a X que …", "ask X to …", "tell X to …" → "X, …"
        let lead = #"(?i)^(?:pide(?:le)?\s+a(?:l)?|dile\s+a(?:l)?|pregunta(?:le)?\s+a(?:l)?|ask|tell)\s+"#
        if let r = t.range(of: lead, options: .regularExpression) {
            t = String(t[r.upperBound...])
            t = t.replacingOccurrences(of: #"(?i)^(\S+(?:\s+\S+){0,3}?)\s+(?:que|to)\s+"#, with: "$1, ", options: .regularExpression)
        }
        let m = SlackRouter.matchAgent(t, agents: agents, defaultID: nil)
        guard let a = m.agent, m.instruction != t, !m.instruction.isEmpty else { return nil }
        return .askAgent(id: a.id, name: a.name, instruction: m.instruction)
    }

    static func projects(in f: String, _ all: [Project]) -> [Project] {
        var hits = all.filter { p in
            Set([normalize(p.name), normalize(URL(fileURLWithPath: p.path).lastPathComponent)])
                .contains { !$0.isEmpty && SlackRouter.containsPhrase(f, $0) }
        }
        hits = hits.filter { h in !hits.contains { o in o.id != h.id && o.name.count > h.name.count && normalize(o.name).contains(normalize(h.name)) } }
        return hits
    }

    private static func project(in f: String, _ all: [Project]) -> Project? {
        let hits = projects(in: f, all)
        return hits.count == 1 ? hits[0] : nil
    }

    private static let numbers: [String: Int] = [
        "uno": 1, "una": 1, "one": 1, "dos": 2, "two": 2, "tres": 3, "three": 3, "cuatro": 4, "four": 4,
        "cinco": 5, "five": 5, "seis": 6, "six": 6, "siete": 7, "seven": 7, "ocho": 8, "eight": 8,
        "nueve": 9, "nine": 9, "diez": 10, "ten": 10,
        "primer": 1, "primero": 1, "first": 1, "segundo": 2, "second": 2, "tercer": 3, "tercero": 3, "third": 3,
    ]

    static func spaceNumber(_ f: String) -> Int? {
        let words = f.split(separator: " ").map(String.init)
        for (i, w) in words.enumerated() where w == "espacio" || w == "space" {
            for j in [i + 1, i - 1] where words.indices.contains(j) {
                if let n = Int(words[j]) ?? numbers[words[j]], n > 0 { return n }
            }
        }
        return nil
    }

    // MARK: Text helpers

    /// Lowercase, no accents, no punctuation, single spaces.
    static func normalize(_ s: String) -> String {
        s.folded
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func stripWake(_ s: String) -> String {
        s.replacingOccurrences(of: #"(?i)^(?:ok|okay|oye|hey|hola|hi|asistente|assistant|projectn|project n)[\s,.:!]+(?:(?:asistente|assistant|projectn|project n)[\s,.:!]+)?"#,
                               with: "", options: .regularExpression)
    }

    private static func has(_ f: String, _ phrases: [String]) -> Bool { phrases.contains { SlackRouter.containsPhrase(f, $0) } }
    private static func matchesAny(_ f: String, exact: [String]) -> Bool { exact.contains(f) }
    private static func startsWithAny(_ f: String, _ prefixes: [String]) -> Bool { prefixes.contains { f == $0 || f.hasPrefix($0 + " ") } }
    private static func firstWord(_ f: String) -> String? { f.split(separator: " ").first.map(String.init) }

    /// Spanish or English, for the reply.
    static func language(_ text: String, localeID: String? = nil) -> AssistantLang {
        if let l = localeID, !l.isEmpty { return l.lowercased().hasPrefix("en") ? .en : .es }
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.spanish, .english]
        r.processString(text)
        return r.dominantLanguage == .english ? .en : .es
    }

    /// Turns an agent's markdown answer into something worth hearing: no code, links or symbols, ~2 sentences.
    static func spoken(_ s: String, limit: Int = 260) -> String {
        var t = s.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"`[^`]*`"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?:~|\.{1,2})?/[\w./-]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[#*_>|•\-]{1,}\s?"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\p{Extended_Pictographic}"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard t.count > limit else { return t }
        // Cut at the last sentence end that fits.
        let head = String(t.prefix(limit))
        if let end = head.range(of: #"[.!?](?=[^.!?]*$)"#, options: .regularExpression), head.distance(from: head.startIndex, to: end.upperBound) > 40 {
            return String(head[..<end.upperBound])
        }
        return head.trimmingCharacters(in: .whitespaces) + "…"
    }
}
