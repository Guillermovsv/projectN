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
    }

    struct Plan: Equatable {
        var say: String
        var actions: [Action]
    }

    static func systemPrompt(lang: AssistantLang) -> String {
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

        Reply with JSON only, no code fences:
        {"say": "<what to say aloud>", "actions": [ ... ]}
        "say": 1–3 short spoken sentences in \(lang == .es ? "Spanish" : "English"); no markdown, lists, code, paths or URLs.
        "actions" (optional, only when the user asks for something to be done; use exact names from the snapshot):
          {"do":"open_project","project":"<name>"}
          {"do":"new_space","project":"<name, optional>"}
          {"do":"goto_space","n":<1-based number in the current workspace>}
          {"do":"new_pane","tool":"claude|codex|cursor|terminal","project":"<name, optional>"}
          {"do":"show_panel","tab":"files|activity|browser"}
          {"do":"home"}
          {"do":"ask_agent","agent":"<agent name>","project":"<name, optional>","instruction":"<clear task for the agent>"}
          {"do":"cancel_agent","agent":"<agent name>"}
        For work on code (fix, build, review, write…), use ask_agent with the best-suited agent and a well-written instruction.
        If something is ambiguous, ask in "say" and return no actions.
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
                    return "\(store.paneTitle(p)) (\(p.tool.label), \(store.project(p.projectID)?.name ?? "?"), \(state))"
                }
                let sel = s.id == store.state.ui.selectedSpaceID ? " [current]" : ""
                return "  - \(s.name)\(sel): " + (panes.joined(separator: "; ").nonEmpty ?? "empty")
            }
            out.append("Workspace \(w.name)\(w.id == current ? " [open]" : ""):\n" + spaces.joined(separator: "\n"))
        }
        if store.selectedWorkspace == nil { out.append("The user is on the overview (no workspace open).") }
        if let panel { out.append("Right panel: " + (panel.visible ? panel.tab.label : "hidden")) }
        if let harness {
            let agents = harness.profiles.filter(\.enabled).map { a in
                "\(a.name) — \(a.role)" + (a.worksOutsideProjects ? " (coordinator)" : "")
            }
            out.append("Agents: " + (agents.joined(separator: "; ").nonEmpty ?? "none"))
            let recent = harness.tasks.suffix(12).reversed().map { t -> String in
                var line = "- \(t.agentName) in \(t.projectName): \(t.status.rawValue) — “\(t.instruction.prefix(120))”"
                if let r = t.result, t.status.isFinished { line += " → \(AssistantCommands.spoken(r, limit: 300))" }
                if let e = t.error { line += " (error: \(e.prefix(120)))" }
                return line
            }
            if !recent.isEmpty { out.append("Recent agent tasks (newest first):\n" + recent.joined(separator: "\n")) }
        }
        return out.joined(separator: "\n")
    }

    /// Reads the model's JSON (tolerates code fences or text around it). Plain text becomes something to say.
    static func parse(_ raw: String) -> Plan {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}"), start < end,
              let obj = try? JSONSerialization.jsonObject(with: Data(t[start...end].utf8)) as? [String: Any] else {
            return Plan(say: AssistantCommands.spoken(t, limit: 400), actions: [])
        }
        let actions = (obj["actions"] as? [[String: Any]] ?? []).compactMap { a -> Action? in
            guard let kind = (a["do"] ?? a["action"]) as? String else { return nil }
            return Action(kind: kind, project: a["project"] as? String, agent: a["agent"] as? String,
                          instruction: a["instruction"] as? String, tool: (a["tool"] as? String)?.lowercased(),
                          tab: (a["tab"] as? String)?.lowercased(), n: (a["n"] as? Int) ?? (a["n"] as? String).flatMap(Int.init))
        }
        return Plan(say: (obj["say"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines), actions: actions)
    }

    static func findProject(_ name: String, _ all: [Project]) -> Project? {
        let n = AssistantCommands.normalize(name)
        if let exact = all.first(where: { AssistantCommands.normalize($0.name) == n }) { return exact }
        let hits = AssistantCommands.projects(in: n, all)
        return hits.count == 1 ? hits[0] : nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
