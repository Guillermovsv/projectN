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
    /// One or more panes, optionally with a model, an effort and a first prompt.
    case newPane(PaneRequest)
    /// A prompt typed into panes that already exist ("dile a Ada que …", "diles a todos que …").
    case sendToPanes([Store.PaneRef], names: [String], prompt: String)
    case showPanel(RightPanelModel.Tab)
    case askAgent(id: UUID, name: String, instruction: String)
    case cancelAgent(id: UUID, name: String)
    case ambiguousProject([Project])
    case unknown(String)
}

enum AssistantLang: String { case es, en }

/// "abre cinco Claude en Opus 5.5 low en web shop que revisen el login"
struct PaneRequest: Equatable {
    var tool: Tool
    var project: Project?
    var count = 1
    var model: String?
    var effort: String?
    var prompt: String?

    static let maxCount = 16
}

enum AssistantCommands {
    struct Context {
        var projects: [Project]
        var workspaces: [(id: UUID, name: String)] = []
        var agents: [AgentProfile] = []
        /// Open panes by name, for "dile a Ada que …".
        var panes: [(ref: Store.PaneRef, title: String)] = []
        /// The panes the Assistant opened last ("diles a todos…", "al último…").
        var lastOpened: [Store.PaneRef] = []
        /// Models / efforts per tool (Claude's are built in when missing).
        var models: [Tool: [LaunchCatalog.Choice]] = [:]
        var efforts: [Tool: [String]] = [:]
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
        // "dile a Ada que …", "diles a todos que …", "tell the last pane to …"
        if let m = paneMessage(text, ctx) { return m }

        if let verb = firstWord(f), ["cancela", "cancelar", "deten", "detener", "cancel", "kill", "para", "stop"].contains(verb) {
            let rest = String(f.dropFirst(verb.count))
            if let a = ctx.agents.filter(\.enabled).sorted(by: { $0.name.count > $1.name.count })
                .first(where: { SlackRouter.containsPhrase(rest, $0.name.folded) }) {
                return .cancelAgent(id: a.id, name: a.name)
            }
        }

        // Panes first, so a prompt that mentions spaces or projects stays part of the prompt:
        // "abre 5 claude en opus 5.5 low que …", "nueva terminal", "lanza codex en blog".
        let paneVerbs = ["abre", "abrir", "nuevo", "nueva", "nuevos", "nuevas", "lanza", "lanzar", "inicia", "arranca",
                         "crea", "crear", "open", "new", "launch", "start", "add", "create", "agrega", "pon"]
        if startsWithAny(f, paneVerbs), let r = paneRequest(text, ctx) { return .newPane(r) }

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

    private static let toolWords: [(String, Tool)] = [
        ("claudes", .claude), ("claude", .claude), ("codex", .codex), ("cursores", .cursor), ("cursors", .cursor),
        ("cursor", .cursor), ("terminales", .terminal), ("terminals", .terminal), ("terminal", .terminal),
        ("shells", .terminal), ("shell", .terminal), ("consolas", .terminal), ("consola", .terminal),
    ]

    static func paneRequest(_ text: String, _ ctx: Context) -> PaneRequest? {
        var (cmd, prompt) = splitPrompt(text, promptSeparators)
        var f = normalize(cmd)
        guard !has(f, ["espacio", "space"]),
              let tool = toolWords.first(where: { SlackRouter.containsPhrase(f, $0.0) })?.1 else { return nil }
        if tool == .terminal {
            // A terminal's "prompt" is a shell command: only take one that is clearly introduced.
            (cmd, prompt) = splitPrompt(text, commandSeparators)
            f = normalize(cmd)
        }
        var r = PaneRequest(tool: tool, project: project(in: f, ctx.projects), prompt: prompt)
        var d = digitize(f)
        let words = toolWords.map(\.0).joined(separator: "|")
        if let m = d.range(of: #"(?:^|\s)(\d{1,2})\s+(?:(?:nuevos?|nuevas?|new)\s+)?(?:"# + words + #")(?=\s|$)"#, options: .regularExpression),
           let n = Int(d[m].filter(\.isNumber)) {
            r.count = max(1, min(PaneRequest.maxCount, n))
        }
        guard tool != .terminal else { return r }
        if let (value, phrase) = model(in: d, ctx.models[tool] ?? (tool == .claude ? LaunchCatalog.claudeModelChoices : [])) {
            r.model = value
            d = d.replacingOccurrences(of: phrase, with: " ")
        }
        r.effort = effort(in: d, allowed: ctx.efforts[tool] ?? (tool == .claude ? LaunchCatalog.claudeEfforts : []))
        return r
    }

    /// Best (longest) model whose name or id is said in `f` (normalized + digitized): (id, matched phrase).
    static func model(in f: String, _ choices: [LaunchCatalog.Choice]) -> (String, String)? {
        let named = choices.flatMap { c in [normalize(c.label), normalize(c.value)].map { (c.value, $0) } }
            .filter { !$0.1.isEmpty }
            .sorted { $0.1.count > $1.1.count }
        return named.first { SlackRouter.containsPhrase(f, $0.1) }
    }

    private static let effortWords: [(String, String)] = [
        ("extra alto", "xhigh"), ("extra alta", "xhigh"), ("muy alto", "xhigh"), ("muy alta", "xhigh"),
        ("extra high", "xhigh"), ("x high", "xhigh"), ("xhigh", "xhigh"),
        ("maximo", "max"), ("maxima", "max"), ("maximum", "max"), ("max", "max"),
        ("minimo", "minimal"), ("minima", "minimal"), ("minimal", "minimal"),
        ("low", "low"), ("bajo", "low"), ("baja", "low"),
        ("medium", "medium"), ("medio", "medium"), ("media", "medium"),
        ("high", "high"), ("alto", "high"), ("alta", "high"),
    ]

    static func effort(in f: String, allowed: [String]) -> String? {
        guard let e = effortWords.first(where: { SlackRouter.containsPhrase(f, $0.0) })?.1 else { return nil }
        return allowed.isEmpty || allowed.contains(e) ? e : nil
    }

    /// "cinco claude en opus cinco punto cinco" → "5 claude en opus 5 5" (versions are compared without dots).
    static func digitize(_ f: String) -> String {
        f.split(separator: " ").compactMap { w -> String? in
            let s = String(w)
            if ["punto", "point", "dot", "coma"].contains(s) { return nil }
            if s == "un" { return "1" }
            return numbers[s].map(String.init) ?? s
        }.joined(separator: " ")
    }

    private static let promptSeparators = [
        " y dile que ", " y diles que ", " y pidele que ", " y pideles que ", " y que ", " para que ",
        " con el prompt ", " con prompt ", " con la tarea ", " que ",
        " and tell it to ", " and tell them to ", " and ask it to ", " and ask them to ",
        " with the prompt ", " with prompt ", " to ", ": ",
    ]
    private static let commandSeparators = [
        " y ejecuta ", " y ejecute ", " y corre ", " y corra ", " con el comando ", " and run ", " with the command ", ": ",
    ]

    /// Splits "abre un claude en blog que revise el login" into the command and the prompt (original casing).
    static func splitPrompt(_ text: String, _ separators: [String]) -> (command: String, prompt: String?) {
        let folded = text.folded
        var best: Range<String.Index>?
        for sep in separators {
            guard let r = folded.range(of: sep) else { continue }
            if best == nil || r.lowerBound < best!.lowerBound
                || (r.lowerBound == best!.lowerBound && r.upperBound > best!.upperBound) { best = r }
        }
        guard let r = best else { return (text, nil) }
        let start = folded.distance(from: folded.startIndex, to: r.lowerBound)
        let end = folded.distance(from: folded.startIndex, to: r.upperBound)
        let src = folded.count == text.count ? text : folded
        let cmd = String(src.prefix(start))
        let prompt = String(src.dropFirst(end)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (cmd, prompt.isEmpty ? nil : prompt)
    }

    private static func paneMessage(_ text: String, _ ctx: Context) -> AssistantIntent? {
        guard !ctx.panes.isEmpty || !ctx.lastOpened.isEmpty else { return nil }
        let folded = text.folded
        let lead = #"^(?:dile|diles|pidele|pideles|escribele|escribeles|escribe|mandale|mandales|manda|enviale|enviales|envia|tell|ask|send|write)\s+(?:al?\s+|to\s+)?(?:(?:el|la|the)\s+)?(?:(?:panel|pane|terminal)\s+)?"#
        guard let l = folded.range(of: lead, options: .regularExpression) else { return nil }
        let rest = folded[l.upperBound...]
        func said(_ w: String) -> Bool {
            guard rest.hasPrefix(w) else { return false }
            let next = rest.dropFirst(w.count).first
            return next == nil || next == " " || next == "," || next == ":"
        }
        var refs: [Store.PaneRef] = []
        var used = 0
        if let w = ["todos ellos", "todas ellas", "todos", "todas", "all of them", "each of them", "everyone", "all"].first(where: said),
           !ctx.lastOpened.isEmpty {
            refs = ctx.lastOpened; used = w.count
        } else if let w = ["ultimo panel", "ultimo", "ultima", "last pane", "last one", "last"].first(where: said),
                  let last = ctx.lastOpened.last {
            refs = [last]; used = w.count
        } else if let p = ctx.panes.sorted(by: { $0.title.count > $1.title.count }).first(where: { said($0.title.folded) }) {
            refs = [p.ref]; used = p.title.folded.count
        }
        guard !refs.isEmpty else { return nil }
        let after = rest.dropFirst(used)
        guard let glue = after.range(of: #"^\s*[,:]?\s*(?:que\s+|to\s+)?"#, options: .regularExpression) else { return nil }
        let offset = folded.distance(from: folded.startIndex, to: glue.upperBound)
        let src = folded.count == text.count ? text : folded
        let prompt = String(src.dropFirst(offset)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        let names = refs.map { r in ctx.panes.first { $0.ref == r }?.title ?? "?" }
        return .sendToPanes(refs, names: names, prompt: prompt)
    }

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
