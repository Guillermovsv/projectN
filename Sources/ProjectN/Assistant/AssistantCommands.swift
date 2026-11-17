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
    /// A space of the open workspace, by its name ("ve a Videos").
    case selectSpace(id: UUID, name: String)
    /// The Agents view (⌃⌘2).
    case agentsView
    case newSpace(Project?)
    case nextSpace
    case previousSpace
    case gotoSpace(Int)                     // 1-based, in the current workspace
    /// One or more panes, optionally with a model, an effort and a first prompt.
    case newPane(PaneRequest)
    /// A prompt typed into panes that already exist ("dile a Ada que …", "diles a todos que …").
    case sendToPanes([Store.PaneRef], names: [String], prompt: String)
    /// Existing panes only; settings text is validated against each pane's catalog before execution.
    case controlPanes(target: String, settings: String?)
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
        /// Spaces of the open workspace.
        var spaces: [(id: UUID, name: String)] = []
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
        let f = misheard(normalize(text))
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

        if let control = paneControl(f) { return control }

        // Panes first, so a prompt that mentions spaces or projects stays part of the prompt:
        // "abre 5 claude en opus 5.5 low que …", "nueva terminal", "lanza codex en blog".
        let paneVerbs = ["abre", "abrir", "nuevo", "nueva", "nuevos", "nuevas", "lanza", "lanzar", "inicia", "arranca",
                         "crea", "crear", "open", "new", "launch", "start", "add", "create", "agrega", "pon", "dame", "give me"]
        if startsWithAny(f, paneVerbs), let r = paneRequest(text, ctx) { return .newPane(r) }

        if has(f, ["pendiente", "pendientes", "necesita", "necesitan", "needs input", "needs me", "waiting", "esperando", "aprobacion", "approval"]) { return .pending }
        if has(f, ["estado", "status", "que esta corriendo", "que hay corriendo", "whats running", "what is running", "resumen", "summary", "como va", "como van", "how is it going"]) { return .status }
        if matchesAny(f, exact: ["inicio", "home", "overview", "vista general", "ve al inicio", "go home"]) { return .home }
        if has(f, ["agents view", "agent view", "vista de agentes", "vista agentes", "agentes view"])
            || matchesAny(f, exact: ["agents", "agentes", "los agentes", "the agents"])
            || (startsWithAny(f, goVerbs) && matchesAny(stripLead(f), exact: ["agents", "agentes", "proyecto agents", "proyecto agentes",
                                                                             "agents project", "workspace agents", "los agentes", "the agents"])) {
            return .agentsView
        }

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

        // Projects / workspaces / spaces: "abre web shop", "ve al proyecto landing", "switch to blog", "cambia a Videos".
        // Names are matched loosely (speech gets them slightly wrong): "aire dinamica" → Airedinamica,
        // "solar debs" → Solar Devs, "doctor sergio" → dr-sergio, "seo app" → SEO Core App.
        let named = startsWithAny(f, goVerbs) || has(f, ["proyecto", "project", "workspace", "espacio", "space"])
        let lead = stripLead(f)
        if named || lead.split(separator: " ").count <= 4 {
            let hits = projects(in: lead, ctx.projects)
            // Without a verb, only when what you said is basically just the name ("Hotel system").
            let bare = !named && hits.count == 1 && Self.coversMost(lead, normalize(hits[0].name))
            if named || bare {
                if hits.count == 1 { return .openProject(hits[0]) }
                if hits.count > 1 { return .ambiguousProject(hits) }
            }
            let names = ctx.workspaces.map { (key: $0.id, names: [$0.name]) }
            if let id = bestNames(in: lead, names).first, let w = ctx.workspaces.first(where: { $0.id == id }),
               named || Self.coversMost(lead, normalize(w.name)) {
                return .openWorkspace(id: w.id, name: w.name)
            }
            let spaces = ctx.spaces.filter { !normalize($0.name).hasPrefix("space ") && !normalize($0.name).hasPrefix("espacio ") }
            if let id = bestNames(in: lead, spaces.map { (key: $0.id, names: [$0.name]) }).first,
               let s = spaces.first(where: { $0.id == id }), named || Self.coversMost(lead, normalize(s.name)) {
                return .selectSpace(id: s.id, name: s.name)
            }
        }
        return .unknown(raw)
    }

    /// Deliberately separate from new-pane parsing so changes never create a replacement pane.
    static func paneControl(_ text: String) -> AssistantIntent? {
        if let r = text.range(of: #"^(?:close|cierra|cerrar)\s+"#, options: .regularExpression) {
            return .controlPanes(target: String(text[r.upperBound...]), settings: nil)
        }
        guard let verb = text.range(of: #"^(?:change|set|switch|cambia|cambiar|ajusta)\s+"#, options: .regularExpression) else { return nil }
        let rest = String(text[verb.upperBound...])
        guard let separator = rest.range(of: #"\s+(?:to|a|en)\s+"#, options: .regularExpression) else { return nil }
        var target = String(rest[..<separator.lowerBound])
        target = target.replacingOccurrences(of: #"^(?:(?:el|the)\s+)?(?:model|modelo|effort|esfuerzo)\b(?:\s+(?:of|de))?\s*"#, with: "", options: .regularExpression)
        target = target.replacingOccurrences(of: #"\s+(?:model|modelo|effort|esfuerzo)$"#, with: "", options: .regularExpression)
        let settings = String(rest[separator.upperBound...])
        return .controlPanes(target: target.isEmpty ? "focused" : target, settings: settings)
    }

    struct ControlPane {
        var ref: Store.PaneRef
        var title: String
        var tool: Tool
        var inCurrentSpace: Bool
    }

    /// Exact names only for actions that close or reconfigure sessions. Tool groups stay in this space.
    static func controlTargets(_ target: String, panes: [ControlPane], focused: Store.PaneRef?, last: [Store.PaneRef]) -> [Store.PaneRef] {
        var t = misheard(normalize(target))
        t = t.replacingOccurrences(of: #"^(?:(?:el|la|los|las|the)\s+)?(?:(?:panel|pane)\s+)?"#, with: "", options: .regularExpression)
        if ["focused", "focused pane", "current", "current pane", "this pane", "actual", "enfocado", "este panel"].contains(t) {
            return focused.map { [$0] } ?? []
        }
        if ["last", "last pane", "ultimo", "ultimo panel"].contains(t) { return Array(last.suffix(1)).filter { r in panes.contains { $0.ref == r } } }
        if ["all", "todos", "all of them", "todos ellos"].contains(t) { return last.filter { r in panes.contains { $0.ref == r } } }
        let names = panes.filter { normalize($0.title) == t }
        if !names.isEmpty { return names.count == 1 ? names.map(\.ref) : [] }
        let group = t.replacingOccurrences(of: #"^(?:all|todos|todas)(?:\s+(?:the|los|las))?\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(?:panes|paneles)$"#, with: "", options: .regularExpression)
        guard let tool = [("claude", Tool.claude), ("claudes", .claude), ("codex", .codex)].first(where: { $0.0 == group })?.1 else { return [] }
        let hits = panes.filter { $0.inCurrentSpace && $0.tool == tool }
        let plural = group == "claudes" || t.hasPrefix("all ") || t.hasPrefix("todos ") || t.hasPrefix("todas ")
        return hits.count == 1 || plural ? hits.map(\.ref) : []
    }

    /// Reject unknown words instead of silently applying only the recognized part of a setting.
    static func controlOptions(_ text: String, choices: [LaunchCatalog.Choice], efforts: [String], current: LaunchOptions) -> LaunchOptions? {
        var rest = digitize(normalize(text))
        var options = current
        var changed = false
        if let (value, phrase) = model(in: rest, choices) {
            options.model = value
            rest = rest.replacingOccurrences(of: phrase, with: " ")
            changed = true
        }
        let fillers = #"\b(?:model|modelo|effort|esfuerzo|reasoning|razonamiento|level|nivel|with|con|and|y|on|in|en|at|a|to|el|the)\b"#
        rest = rest.replacingOccurrences(of: fillers, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        if !rest.isEmpty {
            // Matching the whole remaining phrase prevents 'high nonsense' from becoming 'high'.
            guard let e = effortWords.first(where: { $0.0 == rest })?.1, efforts.contains(e) else { return nil }
            options.effort = e
            changed = true
        }
        return changed ? options : nil
    }

    private static let goVerbs = ["abre", "abrir", "ve a", "ve al", "vete a", "ir a", "vamos a", "cambia", "cambiate", "cambiame",
                                  "pasa a", "pasate a", "llevame a", "muestrame", "selecciona", "open", "go to", "switch", "change",
                                  "show me", "take me to", "move to", "jump to", "select"]

    /// Drops the leading verb and filler ("cambia al proyecto …", "switch to the …") so only the name is left.
    static func stripLead(_ f: String) -> String {
        var t = f
        let filler = #"^(?:(?:abre|abrir|ve|vete|ir|vamos|cambia|cambiate|cambiame|pasa|pasate|llevame|muestrame|selecciona|open|go|switch|change|show|take|move|jump|select|me|a|al|to|the|el|la|los|las|de|del|over|on|en|proyecto|project|workspace|espacio|space)\s+)+"#
        if let r = t.range(of: filler, options: .regularExpression) { t.removeSubrange(r) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// What speech recognition usually makes of the words commands use: "cloud" for Claude, "tree" for three,
    /// "lounge" for launch. Only for recognizing the command; the prompt keeps what you said.
    static func misheard(_ f: String) -> String {
        var t = " " + f + " "
        let fixes: [(String, String)] = [
            (#" (?:claude|cloud|clod|clad|claud|clout) code(?=\s)"#, " claude"),
            (#" (?:clouds|clods|clouts|clauds)(?=\s)"#, " claudes"),
            (#" (?:cloud|clod|clout|claud|klaud|clawed)(?=\s)"#, " claude"),
            (#" code(?= (?:agents?|agentes?|panes?|paneles?|terminals?|terminales?|sessions?|sesiones?) )"#, " claude"),
            (#" (?:codecs|codes|codec|codexs)(?=\s)"#, " codex"),
            (#" (?:lounge|lunch|lancha|lanch|lance)(?=\s)"#, " launch"),
            (#" tree(?=\s)"#, " three"),
            // "in this space": the current one, which is where new panes go anyway.
            (#" (?:in|on|at|en|a) (?:this|the current|este|esta|el) (?:space|espacio|page|pagina|workspace)(?=\s)"#, " "),
        ]
        for (pattern, with) in fixes { t = t.replacingOccurrences(of: pattern, with: with, options: .regularExpression) }
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Pieces

    private static let toolWords: [(String, Tool)] = [
        ("claudes", .claude), ("claude", .claude), ("codex", .codex), ("cursores", .cursor), ("cursors", .cursor),
        ("cursor", .cursor), ("terminales", .terminal), ("terminals", .terminal), ("terminal", .terminal),
        ("shells", .terminal), ("shell", .terminal), ("consolas", .terminal), ("consola", .terminal),
    ]

    static func paneRequest(_ text: String, _ ctx: Context) -> PaneRequest? {
        var (cmd, prompt) = splitPrompt(text, promptSeparators)
        var f = misheard(normalize(cmd))
        guard !has(f, ["espacio", "space"]),
              let tool = toolWords.first(where: { SlackRouter.containsPhrase(f, $0.0) })?.1 else { return nil }
        if tool == .terminal {
            // A terminal's "prompt" is a shell command: only take one that is clearly introduced.
            (cmd, prompt) = splitPrompt(text, commandSeparators)
            f = misheard(normalize(cmd))
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
        let ids = bestNames(in: f, all.map { p in (key: p.id, names: [p.name, URL(fileURLWithPath: p.path).lastPathComponent]) })
        var hits = all.filter { ids.contains($0.id) }
        hits = hits.filter { h in !hits.contains { o in o.id != h.id && o.name.count > h.name.count && normalize(o.name).contains(normalize(h.name)) } }
        return hits
    }

    // MARK: Loose name matching

    /// The candidates named in `f`, best match level only: said exactly, then said with the spaces or a letter or
    /// two off ("aire dinamica", "solar debs"), then said in part ("seo app" for SEO Core App).
    static func bestNames<K: Hashable>(in f: String, _ candidates: [(key: K, names: [String])]) -> [K] {
        let said = canonical(f)
        let words = said.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var best = Int.max
        var out: [K] = []
        for c in candidates {
            let levels = c.names.map(canonical).filter { !$0.isEmpty }.compactMap { matchLevel(said, words, $0) }
            guard let l = levels.min() else { continue }
            if l < best { best = l; out = [c.key] } else if l == best, !out.contains(c.key) { out.append(c.key) }
        }
        return out
    }

    /// 0 exact phrase, 1 same letters ignoring spaces, 2 a letter or two off, 3 several of its words in order,
    /// 4 one of its words said alone. nil: not said.
    private static func matchLevel(_ said: String, _ words: [String], _ name: String) -> Int? {
        if SlackRouter.containsPhrase(said, name) { return 0 }
        let compact = name.replacingOccurrences(of: " ", with: "")
        let nameWords = name.split(separator: " ").map(String.init)
        let span = min(words.count, max(1, nameWords.count + 2))
        var level: Int?
        for len in 1...span {
            for i in 0...(words.count - len) {
                let window = words[i..<(i + len)].joined()
                if window == compact, compact.count >= 4 { return 1 }
                if len == 1, genericWords.contains(window) { continue }
                let allowed = compact.count >= 9 ? 2 : (compact.count >= 5 ? 1 : 0)
                if allowed > 0, abs(window.count - compact.count) <= allowed, editDistance(window, compact) <= allowed { level = 2 }
            }
        }
        if level != nil { return level }
        // Part of a longer name: at least two of its words, in order, as the whole of a stretch of what was said.
        if nameWords.count >= 3 {
            let meaningful = words.filter { !stopwords.contains($0) }
            if meaningful.count >= 2, isSubsequence(meaningful, of: nameWords) { return 3 }
        }
        // Just one distinctive word of the name, said on its own: "cambia a CRM" → CRM 4VMarketing.
        if nameWords.count >= 2, words.count == 1, words[0].count >= 3, !genericWords.contains(words[0]),
           !stopwords.contains(words[0]), nameWords.contains(words[0]) { return 4 }
        return nil
    }

    /// Words commands use all the time: never taken for a slightly misheard name ("project" isn't projectN).
    private static let genericWords: Set<String> = ["project", "proyecto", "projects", "proyectos", "space", "espacio", "workspace",
                                                    "claude", "claudes", "codex", "cursor", "terminal", "terminales", "terminals",
                                                    "agent", "agents", "agente", "agentes", "open", "abre", "nuevo", "nueva"]

    private static let stopwords: Set<String> = ["el", "la", "los", "las", "de", "del", "a", "al", "en", "y", "the", "of", "to", "and", "in", "on"]

    /// Normalized, with the spellings speech and people use interchangeably made the same.
    static func canonical(_ s: String) -> String {
        let swaps = ["doctor": "dr", "doctora": "dra", "senor": "sr", "senora": "sra", "and": "y"]
        return normalize(s).split(separator: " ").map { swaps[String($0)] ?? String($0) }.joined(separator: " ")
    }

    /// True when `name` accounts for most of what was said (so a bare name counts as "open it").
    static func coversMost(_ said: String, _ name: String) -> Bool {
        let s = said.split(separator: " ").filter { !stopwords.contains(String($0)) }.count
        let n = name.split(separator: " ").count
        return s > 0 && s <= n + 1
    }

    private static func isSubsequence(_ a: [String], of b: [String]) -> Bool {
        var i = 0
        for w in b where i < a.count && a[i] == w { i += 1 }
        return i == a.count
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
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
