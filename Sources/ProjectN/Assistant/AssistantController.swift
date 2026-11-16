import AVFoundation
import SwiftUI

/// What the orb shows. Kept apart from the conversation so ~20 level updates per second redraw only the orb.
@MainActor
final class AssistantOrbModel: ObservableObject {
    enum Phase: Equatable { case idle, listening, thinking, speaking }
    @Published var phase: Phase = .idle
    /// Last level (0…1) and when it came in; the orb decays it itself, so nothing ticks while idle.
    @Published private(set) var level: Float = 0
    private(set) var levelAt = Date()

    func push(_ l: Float) { level = l; levelAt = Date() }
}

/// ProjectN's assistant: listens (or reads what you type), runs ProjectN commands, answers out loud.
/// Known commands are matched locally (instant, offline). Anything else goes to NVoice's AI provider (the locally
/// logged-in Claude / Codex CLI, no tools, no web) with a snapshot of ProjectN, and it answers or acts.
@MainActor
final class AssistantController: NSObject, ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let fromUser: Bool
        let text: String
    }

    let orb = AssistantOrbModel()
    @Published private(set) var log: [Entry] = []
    @Published var speakReplies: Bool { didSet { d.set(speakReplies, forKey: "assistant.speak") } }
    /// Questions the commands don't cover go to the AI.
    @Published var useAI: Bool { didSet { d.set(useAI, forKey: "assistant.ai") } }
    /// Requests sent to agents are first polished with NVoice's enhance prompt.
    @Published var enhanceRequests: Bool { didSet { d.set(enhanceRequests, forKey: "assistant.enhance") } }
    /// Finished agent results are summarized by the AI before being read (otherwise: trimmed locally).
    @Published var aiSummaries: Bool { didSet { d.set(aiSummaries, forKey: "assistant.summaries") } }

    private let d = UserDefaults.standard
    private weak var store: Store?
    private weak var harness: AgentHarness?
    private weak var panel: RightPanelModel?
    private weak var nav: NavigationModel?
    private let synth = AVSpeechSynthesizer()
    private var voices: [AssistantLang: AVSpeechSynthesisVoice] = [:]
    /// Tasks started from here, and the language to report them in.
    private var watched: [UUID: AssistantLang] = [:]
    private var lastReply: (text: String, lang: AssistantLang)?
    /// "Which project?" asked for an agent request: the next answer picks it.
    private var pendingAgent: (agentID: UUID, instruction: String, candidates: [Project], lang: AssistantLang)?
    private var aiTask: Task<Void, Never>?
    private var listenStart: Task<Void, Never>?

    override init() {
        speakReplies = d.object(forKey: "assistant.speak") as? Bool ?? true
        useAI = d.object(forKey: "assistant.ai") as? Bool ?? true
        enhanceRequests = d.object(forKey: "assistant.enhance") as? Bool ?? false
        aiSummaries = d.object(forKey: "assistant.summaries") as? Bool ?? true
        super.init()
        synth.delegate = self
    }

    func attach(store: Store, harness: AgentHarness, panel: RightPanelModel, nav: NavigationModel) {
        self.store = store; self.harness = harness; self.panel = panel; self.nav = nav
        harness.observe("assistant") { [weak self] task, event in self?.taskEvent(task, event) }
    }

    // MARK: Listening

    var isListening: Bool { orb.phase == .listening }

    func toggleListening() { isListening ? stopListening() : startListening() }

    func startListening() {
        guard !isListening else { return }
        stopSpeaking()
        aiTask?.cancel()
        orb.phase = .listening
        listenStart = Task { [weak self] in
            do {
                try await NVoiceController.shared.assistantStart { [weak self] l in self?.orb.push(l) }
            } catch {
                guard let self else { return }
                self.orb.phase = .idle
                self.reply(error.localizedDescription, .es, speak: false)
            }
        }
    }

    func stopListening() {
        guard isListening else { return }
        orb.phase = .thinking
        Task { [weak self] in
            await self?.listenStart?.value
            do {
                let r = try await NVoiceController.shared.assistantStop()
                let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let self else { return }
                if text.isEmpty { self.orb.phase = .idle; return }
                self.handle(text, localeID: r.localeID)
            } catch {
                self?.orb.phase = .idle
                self?.reply(error.localizedDescription, .es, speak: false)
            }
        }
    }

    func cancelListening() {
        guard isListening else { return }
        NVoiceController.shared.assistantCancel()
        orb.phase = .idle
    }

    // MARK: Requests

    /// What you said or typed.
    func handle(_ text: String, localeID: String? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let store, let harness else { return }
        log.append(Entry(fromUser: true, text: text))
        let lang = AssistantCommands.language(text, localeID: localeID)

        // Answering "which project?".
        if let p = pendingAgent {
            pendingAgent = nil
            if let project = SlackRouter.pickFromReply(text, candidates: p.candidates) {
                submitAgent(p.agentID, project: project, instruction: p.instruction, lang: p.lang)
                return
            }
        }

        let ctx = AssistantCommands.Context(
            projects: store.state.projects,
            workspaces: store.state.workspaces.filter { !$0.agentHost }.map { ($0.id, $0.name) },
            agents: harness.profiles)
        let intent = AssistantCommands.parse(text, ctx)
        if case .unknown = intent, useAI {
            askAI(text, lang: lang)
        } else {
            perform(intent, lang: lang)
        }
    }

    private func perform(_ intent: AssistantIntent, lang: AssistantLang) {
        guard let store, let harness else { return }
        func L(_ es: String, _ en: String) -> String { lang == .es ? es : en }

        switch intent {
        case .stopSpeaking:
            stopSpeaking(); orb.phase = .idle
        case .repeatLast:
            if let r = lastReply { say(r.text, r.lang) } else { reply(L("Aún no he dicho nada.", "I haven't said anything yet."), lang) }
        case .help:
            reply(L("Puedo abrir proyectos y espacios, crear paneles de Claude, Codex o terminal, mostrar actividad, archivos o el navegador, pedirle trabajo a tus agentes, decirte qué está corriendo y qué necesita tu atención. Por ejemplo: abre web shop, nuevo Claude, Developer arregla el login.",
                    "I can open projects and spaces, add Claude, Codex or terminal panes, show activity, files or the browser, hand work to your agents, and tell you what's running and what needs you. Try: open web shop, new Claude, Developer fix the login."), lang)
        case .status:
            reply(statusText(lang), lang)
        case .pending:
            reply(pendingText(lang), lang)
        case .home:
            showWorkspaces(); store.goHome()
            reply(L("Listo, vista general.", "Overview."), lang)
        case .openProject(let p):
            showWorkspaces(); store.openProject(p)
            reply(L("Abriendo \(p.name).", "Opening \(p.name)."), lang)
        case .openWorkspace(let id, let name):
            showWorkspaces(); store.selectWorkspace(id)
            reply(L("Abriendo \(name).", "Opening \(name)."), lang)
        case .newSpace(let p):
            showWorkspaces()
            if let p { store.openProject(p) }
            guard let w = store.selectedWorkspace, let s = store.newSpace(in: w.id) else {
                reply(L("Primero abre un proyecto.", "Open a project first."), lang); return
            }
            reply(L("Nuevo espacio: \(s.name).", "New space: \(s.name)."), lang)
        case .nextSpace, .previousSpace:
            showWorkspaces()
            store.cycleSpace(intent == .nextSpace ? 1 : -1)
            reply(store.selectedSpace.map { "\($0.name)." } ?? L("No hay espacios.", "No spaces."), lang)
        case .gotoSpace(let n):
            showWorkspaces()
            guard let w = store.selectedWorkspace, w.spaces.indices.contains(n - 1) else {
                reply(L("No existe el espacio \(n).", "There's no space \(n)."), lang); return
            }
            store.selectSpace(w.spaces[n - 1].id, in: w.id)
            reply(L("Espacio \(n).", "Space \(n)."), lang)
        case .newPane(let tool, let p):
            showWorkspaces()
            if let p, store.selectedWorkspace?.projectIDs.contains(p.id) != true { store.openProject(p) }
            guard let w = store.selectedWorkspace, let s = store.selectedSpace else {
                reply(L("Primero abre un proyecto.", "Open a project first."), lang); return
            }
            guard let pane = store.addPane(tool: tool, projectID: p?.id, in: w.id, space: s.id) else {
                reply(L("Este espacio está lleno.", "This space is full."), lang); return
            }
            reply(L("Abrí \(tool.label) como \(store.paneTitle(pane)).", "Opened \(tool.label) as \(store.paneTitle(pane))."), lang)
        case .showPanel(let tab):
            panel?.show(tab)
            reply(tab.label + ".", lang)
        case .askAgent(let id, _, let instruction):
            routeAgent(id, instruction: instruction, lang: lang)
        case .cancelAgent(let id, let name):
            let active = harness.tasks.filter { $0.agentID == id && $0.status.isActive }
            active.forEach { harness.cancel($0.id) }
            reply(active.isEmpty ? L("\(name) no está trabajando en nada.", "\(name) isn't working on anything.")
                                 : L("Detuve a \(name).", "Stopped \(name)."), lang)
        case .ambiguousProject(let list):
            reply(L("¿Cuál? ", "Which one? ") + list.map(\.name).joined(separator: ", ") + "?", lang)
        case .unknown:
            reply(L("No entendí. Di ayuda para ver lo que puedo hacer.", "I didn't get that. Say help to hear what I can do."), lang)
        }
    }

    private func showWorkspaces() {
        guard let nav else { return }
        if nav.settingsOpen, let panel { nav.closeSettings(panel: panel) }
        if nav.mode != .workspaces { nav.switchMode(.workspaces) }
    }

    // MARK: Agents

    private func routeAgent(_ id: UUID, instruction: String, lang: AssistantLang, projectName: String? = nil) {
        guard let store, let harness, let agent = harness.profile(id) else { return }
        if agent.worksOutsideProjects {
            submitAgent(id, project: store.coordinationProject, instruction: instruction, lang: lang); return
        }
        let allowed = store.state.projects.filter { agent.mayAccess($0.id) }
        let hint = projectName.map { "\($0) \(instruction)" } ?? instruction
        switch SlackRouter.resolveProject(hint, allowed: allowed, selectedProjectID: store.focusedProjectID) {
        case .project(let p):
            submitAgent(id, project: p, instruction: instruction, lang: lang)
        case .ambiguous(let list), .notFound(_, let list), .unspecified(let list):
            guard !list.isEmpty else {
                reply(lang == .es ? "\(agent.name) no tiene proyectos asignados." : "\(agent.name) has no projects.", lang); return
            }
            pendingAgent = (id, instruction, list, lang)
            reply((lang == .es ? "¿En qué proyecto? " : "Which project? ") + list.prefix(6).map(\.name).joined(separator: ", ") + "?", lang)
        }
    }

    private func submitAgent(_ id: UUID, project: Project, instruction: String, lang: AssistantLang) {
        guard let harness else { return }
        let name = harness.profile(id)?.name ?? "Agent"
        let go: (String) -> Void = { [weak self] text in
            guard let self, let harness = self.harness else { return }
            switch harness.submit(AgentTaskRequest(agentID: id, projectID: project.id, instruction: text, origin: .local)) {
            case .success(let t):
                self.watched[t.id] = lang
                self.reply(lang == .es ? "Listo, \(name) está en \(project.name). Te aviso cuando termine."
                                       : "On it, \(name) is working in \(project.name). I'll tell you when it's done.", lang)
            case .failure(let e):
                self.reply((lang == .es ? "No pude: " : "Couldn't: ") + e.description, lang)
            }
        }
        guard enhanceRequests else { go(instruction); return }
        orb.phase = .thinking
        aiTask = Task { [weak self] in
            let better = (try? await Enhancer.enhance(instruction, settings: NVoiceSettings.shared)) ?? instruction
            guard !Task.isCancelled else { return }
            go(better)
        }
    }

    private func taskEvent(_ t: AgentTask, _ event: AgentHarness.Event) {
        guard let lang = watched[t.id] else { return }
        func L(_ es: String, _ en: String) -> String { lang == .es ? es : en }
        switch event {
        case .approvalNeeded:
            reply(L("\(t.agentName) necesita tu aprobación en \(t.projectName).", "\(t.agentName) needs your approval in \(t.projectName)."), lang)
        case .finished:
            watched[t.id] = nil
            guard t.status == .completed else {
                reply(L("\(t.agentName) no terminó en \(t.projectName)", "\(t.agentName) didn't finish in \(t.projectName)")
                      + (t.error.map { ": \(AssistantCommands.spoken($0, limit: 140))" } ?? "."), lang)
                return
            }
            let head = L("\(t.agentName) terminó en \(t.projectName). ", "\(t.agentName) finished in \(t.projectName). ")
            let result = t.result ?? ""
            guard aiSummaries, result.count > 200 else {
                reply(head + AssistantCommands.spoken(result), lang); return
            }
            Task { [weak self] in
                let system = """
                Summarize this coding agent's report so it can be read aloud: 1–2 short sentences in \(lang == .es ? "Spanish" : "English"), \
                what was done and anything the user must do. No markdown, code, file paths or URLs. Reply with the summary only.
                """
                let s = (try? await Enhancer.complete(system: system, input: result, settings: NVoiceSettings.shared, timeout: 45))
                self?.reply(head + (s.map { AssistantCommands.spoken($0) } ?? AssistantCommands.spoken(result)), lang)
            }
        default:
            break
        }
    }

    // MARK: AI fallback

    private func askAI(_ text: String, lang: AssistantLang) {
        orb.phase = .thinking
        let system = AssistantAI.systemPrompt(lang: lang)
        let input = AssistantAI.snapshot(store: store, harness: harness, panel: panel)
            + "\n\nRecent conversation:\n" + log.suffix(7).dropLast().map { ($0.fromUser ? "User: " : "Assistant: ") + $0.text }.joined(separator: "\n")
            + "\n\nUser request: \(text)"
        aiTask?.cancel()
        aiTask = Task { [weak self] in
            do {
                let raw = try await Enhancer.complete(system: system, input: input, settings: NVoiceSettings.shared, timeout: 60)
                guard !Task.isCancelled, let self else { return }
                let plan = AssistantAI.parse(raw)
                if !plan.say.isEmpty { self.reply(plan.say, lang) }
                for a in plan.actions { self.runAction(a, lang: lang, quiet: !plan.say.isEmpty) }
                if plan.say.isEmpty && plan.actions.isEmpty { self.orb.phase = .idle }
            } catch {
                guard !Task.isCancelled else { return }
                self?.reply((lang == .es ? "La IA no respondió: " : "The AI didn't answer: ") + error.localizedDescription, lang, speak: false)
            }
        }
    }

    /// Runs one action the AI chose. With `quiet`, the AI already said what it's doing: confirmations aren't spoken.
    private func runAction(_ a: AssistantAI.Action, lang: AssistantLang, quiet: Bool) {
        guard let store, let harness else { return }
        let project = a.project.flatMap { AssistantAI.findProject($0, store.state.projects) }
        let agent = a.agent.flatMap { n in harness.profiles.first { $0.enabled && $0.name.folded == n.folded } }
        let intent: AssistantIntent?
        switch a.kind {
        case "open_project": intent = project.map { .openProject($0) }
        case "new_space": intent = .newSpace(project)
        case "goto_space": intent = a.n.map { .gotoSpace($0) }
        case "new_pane": intent = Tool(rawValue: a.tool ?? "claude").map { .newPane($0, project) }
        case "show_panel": intent = a.tab.flatMap { RightPanelModel.Tab(rawValue: $0) }.map { .showPanel($0) }
        case "home": intent = .home
        case "cancel_agent": intent = agent.map { .cancelAgent(id: $0.id, name: $0.name) }
        case "ask_agent":
            if let agent, let ins = a.instruction, !ins.isEmpty {
                routeAgent(agent.id, instruction: ins, lang: lang, projectName: project?.name)
            }
            return
        default: intent = nil
        }
        guard let intent else { return }
        let wasMuted = speakReplies
        if quiet { speakReplies = false }
        perform(intent, lang: lang)
        if quiet { speakReplies = wasMuted }
    }

    // MARK: Status text

    private func statusText(_ lang: AssistantLang) -> String {
        guard let store, let harness else { return "" }
        let running = store.runtimes.values.filter(\.isRunning).count
        let active = harness.tasks.filter { $0.status.isActive }
        let needs = store.needsInputCount
        var parts: [String] = []
        if lang == .es {
            parts.append(running == 0 ? "No hay terminales corriendo." : "Hay \(running) \(running == 1 ? "terminal" : "terminales") corriendo.")
            if !active.isEmpty { parts.append("Agentes trabajando: " + active.map { "\($0.agentName) en \($0.projectName)" }.joined(separator: ", ") + ".") }
            if needs > 0 { parts.append("\(needs) \(needs == 1 ? "necesita" : "necesitan") tu atención.") }
        } else {
            parts.append(running == 0 ? "Nothing is running." : "\(running) \(running == 1 ? "terminal is" : "terminals are") running.")
            if !active.isEmpty { parts.append("Agents working: " + active.map { "\($0.agentName) in \($0.projectName)" }.joined(separator: ", ") + ".") }
            if needs > 0 { parts.append("\(needs) \(needs == 1 ? "needs" : "need") you.") }
        }
        return parts.joined(separator: " ")
    }

    private func pendingText(_ lang: AssistantLang) -> String {
        guard let store, let harness else { return "" }
        let waitingAgents = harness.tasks.filter { $0.status == .needsApproval || $0.status == .waitingForUser }.map(\.agentName)
        let panes = store.state.workspaces.flatMap { $0.spaces.flatMap(\.panes) }
            .filter { store.needsInputIDs.contains($0.id) }.map(store.paneTitle)
        let names = Array(Set(waitingAgents + panes)).sorted()
        if names.isEmpty { return lang == .es ? "Nada te está esperando." : "Nothing is waiting on you." }
        return (lang == .es ? "Te esperan: " : "Waiting on you: ") + names.joined(separator: ", ") + "."
    }

    // MARK: Speaking

    private func reply(_ text: String, _ lang: AssistantLang, speak: Bool = true) {
        log.append(Entry(fromUser: false, text: text))
        if log.count > 80 { log.removeFirst(log.count - 80) }
        lastReply = (text, lang)
        if speak && speakReplies { say(text, lang) } else if orb.phase != .listening { orb.phase = .idle }
    }

    func say(_ text: String, _ lang: AssistantLang) {
        let u = AVSpeechUtterance(string: AssistantCommands.spoken(text, limit: 600))
        u.voice = voice(lang)
        u.prefersAssistiveTechnologySettings = false
        if orb.phase != .listening { orb.phase = .speaking }
        synth.speak(u)
    }

    func stopSpeaking() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    func clear() { log.removeAll(); lastReply = nil; pendingAgent = nil }

    /// The best installed voice for the language (Premium › Enhanced › default).
    private func voice(_ lang: AssistantLang) -> AVSpeechSynthesisVoice? {
        if let v = voices[lang] { return v }
        let all = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang.rawValue) }
        let v = all.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: lang == .es ? "es-MX" : "en-US")
        voices[lang] = v
        return v
    }
}

extension AssistantController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance: AVSpeechUtterance) {
        // A beat per word makes the orb "talk".
        let l = Float.random(in: 0.55...1)
        Task { @MainActor [weak self] in if self?.orb.phase == .speaking { self?.orb.push(l) } }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.speechEnded() }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.speechEnded() }
    }

    private func speechEnded() {
        if !synth.isSpeaking, orb.phase == .speaking { orb.phase = .idle }
    }
}
