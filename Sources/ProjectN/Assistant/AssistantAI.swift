import Foundation

/// The AI fallback: a one-shot call to NVoice's provider with what ProjectN looks like right now. It answers
/// questions about ProjectN and your projects, and may return actions that run through the same executor as the
/// local commands. It has no tools and no web access.
enum AssistantAI {
    struct Action: Equatable {
        var kind: String
        var project: String?
        var agent: String?
        var instruction: String?
        var tool: String?
        var tab: String?
        var n: Int?
        var count: Int?
        var model: String?
        var effort: String?
        var prompt: String?
        var pane: String?
        var space: String?
        var workspace: String?
    }

    struct Plan: Equatable {
        var say: String
        var actions: [Action]
    }

    static func systemPrompt() -> String {
        """
        You are the voice assistant built into ProjectN, a macOS app for running coding agents side by side.
        You only help with ProjectN: using the app, the user's projects, spaces, panes and agents, and what those agents are doing or reported.
        You cannot browse the web or read files; if asked for something outside ProjectN, say briefly that you only handle ProjectN.

        How ProjectN works:
        - Projects are folders. Opening a project opens its workspace. A workspace holds spaces; a space holds up to 8 panes.
        - A pane runs Claude, Codex, Cursor or a terminal in a project. ⌘0 is the overview; ⌃⌘1 workspaces view, ⌃⌘2 agents view.
        - The right panel has tabs: Assistant (you), Files, Activity (what's running and what needs input), Browser. ⌥⌘0 toggles it.
        - Agents are named profiles (e.g. Developer, Project Manager) that take tasks in a project; coordinators delegate to other agents.
          They also answer from Slack. NVoice is the built-in dictation (hold fn).

        Your reply is read aloud as you write it. Format:
        1. First, what to say: 1–3 short, natural spoken sentences in the language of the user's request (Spanish or English). Plain text only:
           no markdown, lists, code, paths or URLs. Start with the answer itself, no preamble.
        2. Then, only if the user asked for something to be done, one line per action, each starting with ACTION and a JSON object
           (use exact names from the snapshot):
        ACTION {"do":"open_project","project":"<name>"}
        ACTION {"do":"new_space","project":"<name, optional>"}
        ACTION {"do":"open_workspace","workspace":"<workspace name>"}
        ACTION {"do":"goto_space","n":<1-based number in the current workspace>}   (or "space":"<space name>","workspace":"<its workspace>" instead of n; any workspace)
        ACTION {"do":"agents_view"}
        ACTION {"do":"new_pane","tool":"claude|codex|cursor|terminal","project":"<name, optional>","count":<1-16, optional>,"model":"<optional>","effort":"<optional>","prompt":"<first message, optional>"}
        ACTION {"do":"send_to_pane","pane":"<pane name from the snapshot, or last (the pane you opened last), or all (every pane you opened last)>","prompt":"<message to type into it>"}
        ACTION {"do":"close_pane","pane":"<exact pane name, focused, last, all, all Claude, or all Codex>"}
        ACTION {"do":"configure_pane","pane":"<same targets as close_pane>","model":"<optional model from snapshot>","effort":"<optional effort>"}
        ACTION {"do":"show_panel","tab":"files|activity|browser"}
        ACTION {"do":"home"}
        ACTION {"do":"ask_agent","agent":"<agent name>","project":"<name, optional>","instruction":"<clear task for the agent>"}
        ACTION {"do":"cancel_agent","agent":"<agent name>"}
        Saying you'll do something does nothing by itself: whenever you say you're opening, creating, showing, asking or stopping
        something, the matching ACTION line MUST follow. Example reply:
        Abro Blog y le pido a Developer que revise el login.
        ACTION {"do":"open_project","project":"Blog"}
        ACTION {"do":"ask_agent","agent":"Developer","project":"Blog","instruction":"Review the login flow and fix any bugs you find."}
        Panes: new_pane opens `count` panes (default 1) in the current space, spilling into new spaces when one fills up.
        model and effort are optional (names from the snapshot, e.g. "Opus 5.5" and "low"); leave them out to use the defaults.
        prompt is what the new pane starts working on; with count > 1 every pane gets the same prompt, so for different tasks
        add one new_pane per task. For a terminal, prompt is a shell command. To give work to a pane that is already open, use
        send_to_pane with its name. When the user asks for panes/terminals by name ("five Claudes", "a Codex that…") use
        new_pane/send_to_pane, not ask_agent; use ask_agent when they name an agent or don't ask for a pane.
        For existing panes, close_pane closes their sessions; configure_pane changes model and/or effort using the app controls.
        Use these actions for closing or changing settings, never new_pane, ask_agent or send_to_pane.
        Exact pane names may refer to any workspace; duplicate names require clarification. focused means the focused pane
        in the current space; last means the last pane you opened; all means the panes you opened last.
        all Claude and all Codex target only the current space. A bare Claude or Codex target requires exactly one match there.
        Only ordinary Claude and Codex panes can be closed or configured this way, not agent-task panes.
        Claude changes model/effort live. Codex restarts and resumes; a busy session asks for confirmation in the app.
        The app validates settings and reports the actual outcome. Do not claim settings have already been changed.
        For work on code (fix, build, review, write…), use ask_agent with the best-suited agent and a well-written instruction.
        The request comes from speech recognition, so names are often slightly off ("cloud" or "code" for Claude,
        "solar debs" for Solar Devs, "aire dinamica" for Airedinamica, "doctor Sergio" for dr-sergio, "aseo cap" for SEO Core App,
        "bible boys" for Vibevoice): map them to the name in the snapshot that sounds most like it, using "How names are said".
        The user often says "espacio" for a workspace. "This space" / "here" means the current space, where new panes open anyway.
        If two names are equally close, ask which one (say both names) and add no actions. If none is close, say so and name
        the closest ones.
        """
    }

    @MainActor
    static func snapshot(store: Store?, harness: AgentHarness?, panel: RightPanelModel?) -> String {
        guard let store else { return "ProjectN state: unavailable." }
        var out = ["ProjectN right now:"]
        out.append("Projects: " + (store.state.projects.map(\.name).joined(separator: ", ").nonEmpty ?? "none"))
        let current = store.selectedWorkspace?.id
        for w in store.state.workspaces where !w.agentHost {
            let spaces = w.spaces.map { s -> String in
                let panes = s.panes.map { p in
                    let state = store.needsInputIDs.contains(p.id) ? "needs input" : (store.runtimes[p.id]?.isRunning == true ? "running" : "stopped")
                    let launch = p.tool == .terminal ? "" : ", " + [LaunchCatalog.modelLabel(p.model ?? "", tool: p.tool), p.effort ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: " ")
                    let focused = s.id == store.selectedSpace?.id && p.id == s.focusedPaneID ? " [focused]" : ""
                    return "\(store.paneTitle(p))\(focused) (\(p.tool.label)\(launch), \(store.project(p.projectID)?.name ?? "?"), \(state))"
                }
                let sel = s.id == store.state.ui.selectedSpaceID ? " [current]" : ""
                return "  - \(s.name)\(sel): " + (panes.joined(separator: "; ").nonEmpty ?? "empty")
            }
            out.append("Workspace \(w.name)\(w.id == current ? " [open]" : ""):\n" + spaces.joined(separator: "\n"))
        }
        if store.selectedWorkspace == nil { out.append("The user is on the overview (no workspace open).") }
        if let agents = store.state.workspaces.first(where: \.agentHost) {
            out.append("Agents view (where agents' own panes run): \(agents.spaces.flatMap(\.panes).count) panes.")
        }
        let claude = LaunchCatalog.claudeModels.filter { !$0.older }.map(\.label).joined(separator: ", ")
        out.append("Claude models: \(claude) (efforts: \(LaunchCatalog.claudeEfforts.joined(separator: ", ")))")
        let codex = LaunchCatalog.codexModels(settings: store.settings).map(\.slug)
        if !codex.isEmpty {
            out.append("Codex models: \(codex.joined(separator: ", ")) (efforts: \(LaunchCatalog.efforts(for: .codex, model: nil, settings: store.settings).joined(separator: ", ")))")
        }
        if let panel { out.append("Right panel: " + (panel.visible ? panel.tab.label : "hidden")) }
        if let said = spokenNames(store) { out.append(said) }
        if let harness {
            let agents = harness.profiles.filter(\.enabled).map { a in
                "\(a.name) — \(a.role)" + (a.worksOutsideProjects ? " (coordinator)" : "")
            }
            out.append("Agents: " + (agents.joined(separator: "; ").nonEmpty ?? "none"))
            let recent = harness.tasks.suffix(8).reversed().map { t -> String in
                var line = "- \(t.agentName) in \(t.projectName): \(t.status.rawValue) — “\(t.instruction.prefix(120))”"
                if let r = t.result, t.status.isFinished { line += " → \(AssistantCommands.spoken(r, limit: 200))" }
                if let e = t.error { line += " (error: \(e.prefix(120)))" }
                return line
            }
            if !recent.isEmpty { out.append("Recent agent tasks (newest first):\n" + recent.joined(separator: "\n")) }
        }
        return out.joined(separator: "\n")
    }

    /// "Vibevoice ← Vibe Voice, bible boys": how names are said (split as spoken, and what the user confirmed before).
    @MainActor
    static func spokenNames(_ store: Store, learned: [AssistantAliases.Alias]? = nil) -> String? {
        let learned = learned ?? AssistantAliases.shared.all
        let ws = store.state.workspaces.filter { !$0.agentHost }
        var seen = Set<String>()
        let names = (store.state.projects.map { ($0.id, $0.name) } + ws.map { ($0.id, $0.name) }
            + ws.flatMap(\.spaces).filter { !AssistantCommands.isNumberedSpace($0.name) }.map { ($0.id, $0.name) })
            .filter { seen.insert($0.1.folded).inserted }
        let lines = names.compactMap { id, name -> String? in
            let heard = learned.filter { $0.id == id || $0.name.folded == name.folded }.map(\.heard)
            let forms = SpokenNames.forms(name) + heard
            return forms.isEmpty ? nil : "\(name) ← " + forms.map { "\"\($0)\"" }.joined(separator: ", ")
        }
        return lines.isEmpty ? nil : "How names are said (heard → name):\n" + lines.joined(separator: "\n")
    }

    /// Reads the model's reply: spoken text followed by `ACTION {json}` lines. Also accepts a single
    /// {"say": …, "actions": […]} object, and plain text (just something to say).
    static func parse(_ raw: String) -> Plan {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = t.components(separatedBy: "\n")
        let actionLines = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("ACTION") }
        if !actionLines.isEmpty {
            let say = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("ACTION") }.joined(separator: "\n")
            let actions = actionLines.compactMap { l -> Action? in
                guard let a = l.firstIndex(of: "{"), let b = l.lastIndex(of: "}"), a < b,
                      let obj = try? JSONSerialization.jsonObject(with: Data(l[a...b].utf8)) as? [String: Any] else { return nil }
                return action(obj)
            }
            return Plan(say: AssistantCommands.spoken(say, limit: 600), actions: actions)
        }
        if t.hasPrefix("{") || t.hasPrefix("```"), let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}"), start < end,
           let obj = try? JSONSerialization.jsonObject(with: Data(t[start...end].utf8)) as? [String: Any] {
            return Plan(say: (obj["say"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                        actions: (obj["actions"] as? [[String: Any]] ?? []).compactMap(action))
        }
        return Plan(say: AssistantCommands.spoken(t, limit: 600), actions: [])
    }

    private static func action(_ a: [String: Any]) -> Action? {
        guard let kind = (a["do"] ?? a["action"]) as? String else { return nil }
        return Action(kind: kind, project: a["project"] as? String, agent: a["agent"] as? String,
                      instruction: a["instruction"] as? String, tool: (a["tool"] as? String)?.lowercased(),
                      tab: (a["tab"] as? String)?.lowercased(), n: int(a["n"]), count: int(a["count"]),
                      model: a["model"] as? String, effort: (a["effort"] as? String)?.lowercased(),
                      prompt: a["prompt"] as? String, pane: a["pane"] as? String,
                      space: a["space"] as? String, workspace: a["workspace"] as? String)
    }

    private static func int(_ v: Any?) -> Int? {
        (v as? Int) ?? (v as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Cuts a reply that is still being written into sentences to speak right away. Never lets ACTION lines
    /// (or JSON) through, and holds back a last line that could still turn out to be one.
    struct StreamSplitter {
        private(set) var full = ""
        private var spokenUpTo = 0          // characters of the speakable part already handed out
        private var minChars: Int

        init(minChars: Int = 18) { self.minChars = minChars }

        /// The part of the reply meant to be spoken, as far as it's known.
        var speakable: String {
            var lines = full.components(separatedBy: "\n")
            var cut = false
            if let i = lines.firstIndex(where: { Self.isActionish($0) }) { lines = Array(lines[..<i]); cut = true }
            else if let last = lines.last, !last.isEmpty, Self.couldBecomeAction(last) { lines.removeLast(); cut = true }
            // Text before a (possible) action line is a finished line: end it so its last sentence goes out now.
            return lines.joined(separator: "\n") + (cut && !lines.isEmpty ? "\n" : "")
        }

        mutating func feed(_ piece: String) -> [String] {
            full += piece
            return take(final: false)
        }

        mutating func finish() -> [String] { take(final: true) }

        private mutating func take(final: Bool) -> [String] {
            let text = speakable
            guard text.count > spokenUpTo else { return [] }
            let rest = String(text.dropFirst(spokenUpTo))
            var out: [String] = []
            var consumed = 0, current = ""
            var i = rest.startIndex
            while i < rest.endIndex {
                let c = rest[i]
                current.append(c)
                consumed += 1
                let next = rest.index(after: i)
                let boundary = c == "\n" || ((".!?…".contains(c)) && (next == rest.endIndex ? final : rest[next].isWhitespace))
                if boundary, current.trimmingCharacters(in: .whitespacesAndNewlines).count >= minChars || c == "\n" {
                    let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { out.append(s) }
                    spokenUpTo += consumed; consumed = 0; current = ""
                }
                i = next
            }
            if final {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { out.append(s) }
                spokenUpTo += consumed
            }
            return out
        }

        private static func isActionish(_ line: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("ACTION") || t.hasPrefix("{") || t.hasPrefix("```")
        }

        private static func couldBecomeAction(_ line: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            return "ACTION".hasPrefix(t) || t.hasPrefix("`")
        }
    }

    static func findProject(_ name: String, _ all: [Project]) -> Project? {
        let n = AssistantCommands.normalize(name)
        if let exact = all.first(where: { AssistantCommands.normalize($0.name) == n }) { return exact }
        let hits = AssistantCommands.projects(in: n, all)
        return hits.count == 1 ? hits[0] : nil
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
