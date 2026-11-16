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
        var text: String
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
    /// Conversation mode: after answering, listen again on its own (ends after a few quiet seconds or "gracias").
    @Published var handsFree: Bool { didSet { d.set(handsFree, forKey: "assistant.handsFree") } }
    /// Chosen voice per language (identifier; empty = the most natural one installed).
    @Published var voiceES: String { didSet { d.set(voiceES, forKey: "assistant.voice.es") } }
    @Published var voiceEN: String { didSet { d.set(voiceEN, forKey: "assistant.voice.en") } }
    /// The Assistant's own AI (independent of NVoice's): Claude Haiku answers fastest.
    @Published var aiProvider: AIProvider {
        didSet {
            d.set(aiProvider.rawValue, forKey: "assistant.provider")
            if !aiProvider.models.contains(aiModel) { aiModel = aiProvider == .claude ? "haiku" : aiProvider.models[0] }
        }
    }
    @Published var aiModel: String { didSet { d.set(aiModel, forKey: "assistant.model") } }
    /// Keep a Claude session open while the Assistant is in use (answers start ~3 s sooner).
    @Published var keepWarm: Bool { didSet { d.set(keepWarm, forKey: "assistant.keepWarm"); if !keepWarm { AssistantBrain.shared.shutdown() } } }
    /// Opening the Assistant starts listening right away.
    @Published var autoListen: Bool { didSet { d.set(autoListen, forKey: "assistant.autoListen") } }
    /// Pause (seconds) that means you've finished talking.
    @Published var silenceSeconds: Double { didSet { d.set(silenceSeconds, forKey: "assistant.silence") } }
    /// Lives in its own floating window instead of the right panel.
    @Published var floating: Bool { didSet { d.set(floating, forKey: "assistant.floating") } }
    /// The floating window is on screen.
    @Published var floatingVisible = false
    /// Speaking speed, 0.8…1.3 × the voice's normal rate.
    @Published var speechSpeed: Double { didSet { d.set(speechSpeed, forKey: "assistant.speed") } }

    private let d = UserDefaults.standard
    private weak var store: Store?
    private weak var harness: AgentHarness?
    private weak var panel: RightPanelModel?
    private weak var nav: NavigationModel?
    private let synth = AVSpeechSynthesizer()
    private var voiceLists: [AssistantLang: [AVSpeechSynthesisVoice]] = [:]
    /// Tasks started from here, and the language to report them in.
    private var watched: [UUID: AssistantLang] = [:]
    private var lastReply: (text: String, lang: AssistantLang)?
    /// "Which project?" asked for an agent request: the next answer picks it.
    private var pendingAgent: (agentID: UUID, instruction: String, candidates: [Project], lang: AssistantLang)?
    private var aiTask: Task<Void, Never>?
    /// Mic operations (start, stop, cancel) run one after another, never overlapping: an old "cancel" can't close a
    /// newer recording, and a new recording never starts while the last one is still being closed.
    private var micQueue: Task<Void, Never>?
    /// The Assistant's recording is running (only changed inside mic operations).
    private var micOpen = false
    /// Bumped whenever a listening turn starts or is abandoned: late results of an old turn are ignored.
    private var listenGen = 0
    /// When the current turn's mic last sent a level (nil: no audio yet).
    private var lastLevelAt: Date?
    /// What you said is being turned into text.
    private var transcribing = false
    /// Turns in a row where nothing intelligible was heard (conversation mode stops after two).
    private var emptyTurns = 0
    private var vad = AssistantVAD()
    /// A spoken back-and-forth is going on (conversation mode keeps listening after each answer).
    private var conversation = false
    private var relisten: DispatchWorkItem?
    /// An AI answer is still being written.
    private var streaming = false
    /// Sentences handed to the synthesizer and not finished yet. Tracked here rather than with `synth.isSpeaking`,
    /// which can lag behind its own "finished" callback (that left the Assistant stuck on "Speaking").
    private var queued: [ObjectIdentifier: AVSpeechUtterance] = [:]
    private var speechCheck: DispatchWorkItem?
    private var speechMisses = 0
    /// Views showing the Assistant (side panel, floating window). It stops when the last one goes away.
    private var hosts = 0
    private let createdAt = Date()
    private var liveToken = UUID()
    private var liveSplit = AssistantAI.StreamSplitter()
    private var liveEntryID: UUID?
    private var liveSpoke = false
    /// Confirmations of actions the AI already announced aren't spoken again.
    private var suppressSpeech = false
    /// Panes the Assistant opened last: "diles a todos que…", "al último…".
    private var lastOpened: [Store.PaneRef] = []

    override init() {
        speakReplies = d.object(forKey: "assistant.speak") as? Bool ?? true
        useAI = d.object(forKey: "assistant.ai") as? Bool ?? true
        enhanceRequests = d.object(forKey: "assistant.enhance") as? Bool ?? false
        aiSummaries = d.object(forKey: "assistant.summaries") as? Bool ?? true
        handsFree = d.object(forKey: "assistant.handsFree") as? Bool ?? true
        voiceES = d.string(forKey: "assistant.voice.es") ?? ""
        voiceEN = d.string(forKey: "assistant.voice.en") ?? ""
        aiProvider = AIProvider(rawValue: d.string(forKey: "assistant.provider") ?? "") ?? .claude
        aiModel = d.string(forKey: "assistant.model") ?? "haiku"
        keepWarm = d.object(forKey: "assistant.keepWarm") as? Bool ?? true
        autoListen = d.object(forKey: "assistant.autoListen") as? Bool ?? true
        silenceSeconds = d.object(forKey: "assistant.silence") as? Double ?? 1.0
        speechSpeed = d.object(forKey: "assistant.speed") as? Double ?? 1.05
        floating = d.object(forKey: "assistant.floating") as? Bool ?? false
        super.init()
        synth.delegate = self
    }

    func attach(store: Store, harness: AgentHarness, panel: RightPanelModel, nav: NavigationModel) {
        self.store = store; self.harness = harness; self.panel = panel; self.nav = nav
        harness.observe("assistant") { [weak self] task, event in self?.taskEvent(task, event) }
    }

    // MARK: Listening

    var isListening: Bool { orb.phase == .listening }

    /// Click on the orb / ⌥⌘A: start talking when it's idle; otherwise stop everything (listening, thinking, speaking).
    func toggleListening() { orb.phase == .idle ? startListening() : stopAll() }

    /// The Assistant was shown (side panel tab or floating window): get the AI and the mic ready and, if wanted,
    /// start listening right away.
    func opened() {
        hosts += 1
        // Not when ProjectN starts with the Assistant already showing: only when you open it.
        // (This used to compare against a lazily-created static, so it skipped the first open of every launch.)
        guard Date().timeIntervalSince(createdAt) > 2 else { return }
        prewarm()
        NVoiceController.shared.assistantPrewarm()
        if autoListen, orb.phase == .idle { startListening() }
    }

    /// The Assistant was hidden. Moving it between the panel and the floating window hides one view and shows the
    /// other in no fixed order, so it only stops once no view is left.
    func closed() {
        hosts = max(0, hosts - 1)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hosts == 0 else { return }
            self.stopAll()
        }
    }

    func stopAll() {
        conversation = false
        relisten?.cancel()
        cancelAI()
        stopSpeaking()
        endTurn()
        orb.phase = .idle
    }

    func prewarm() {
        guard useAI, keepWarm, aiProvider == .claude else { return }
        AssistantBrain.shared.prewarm(model: aiModel, system: AssistantAI.systemPrompt())
    }

    /// `auto`: conversation mode opening the mic again after an answer.
    func startListening(auto: Bool = false) {
        guard !isListening else { return }
        relisten?.cancel()
        if !auto { conversation = true; emptyTurns = 0 }
        stopSpeaking()
        cancelAI()
        listenGen += 1
        let gen = listenGen
        transcribing = false
        vad = AssistantVAD()
        vad.silenceToEnd = silenceSeconds
        vad.giveUpAfter = auto ? 8 : 12
        lastLevelAt = nil
        orb.phase = .listening
        Diagnostics.log("assistant: listening\(auto ? " (conversation)" : "")")
        micOp { [weak self] in
            guard let self, gen == self.listenGen else { return }
            do {
                try await NVoiceController.shared.assistantStart { [weak self] l in self?.heard(level: l, gen: gen) }
                self.micOpen = true
            } catch {
                Diagnostics.log("assistant: mic didn't start — \(error.localizedDescription)")
                guard gen == self.listenGen else { return }
                self.conversation = false
                self.orb.phase = .idle
                self.reply(error.localizedDescription, Self.uiLang, speak: false)
                return
            }
            // Abandoned while the mic was starting.
            guard gen == self.listenGen, self.isListening else { self.closeMic(); return }
            self.watchForAudio(gen)
        }
    }

    /// Runs mic operations strictly in order (see `micQueue`).
    private func micOp(_ op: @escaping @MainActor () async -> Void) {
        let previous = micQueue
        micQueue = Task { @MainActor in
            await previous?.value
            await op()
        }
    }

    /// Inside a mic operation: closes the Assistant's recording without transcribing it.
    private func closeMic() {
        guard micOpen else { return }
        micOpen = false
        NVoiceController.shared.assistantCancel()
    }

    /// Drops the current turn: late audio, transcripts and errors from it are ignored, and the mic is closed.
    private func endTurn() {
        listenGen += 1
        transcribing = false
        micOp { [weak self] in self?.closeMic() }
    }

    /// The mic started but no audio comes in (a disconnected or silent input): say so instead of listening forever.
    private func watchForAudio(_ gen: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, gen == self.listenGen, self.isListening, self.lastLevelAt == nil else { return }
            Diagnostics.log("assistant: no audio from the mic 3 s after starting")
            self.conversation = false
            self.cancelListening()
            self.reply(Self.uiLang == .es ? "No me llega audio del micrófono. Revisa cuál está elegido en Ajustes › Voz."
                                          : "No audio is coming from the microphone. Check which one is chosen in Settings › Voice.",
                       Self.uiLang, speak: false)
        }
    }

    /// Mic levels while listening: drive the orb and notice when you've finished talking.
    private func heard(level l: Float, gen: Int) {
        guard isListening, gen == listenGen else { return }
        lastLevelAt = Date()
        orb.push(l)
        switch vad.push(l) {
        case .listening: break
        case .endOfSpeech: stopListening()
        case .nothingSaid:
            Diagnostics.log("assistant: nothing said, stopped listening")
            conversation = false
            cancelListening()
        }
    }

    /// You finished talking (pause, or a click): transcribe and answer.
    func stopListening() {
        guard isListening else { return }
        orb.phase = .thinking
        transcribing = true
        let gen = listenGen
        micOp { [weak self] in
            guard let self else { return }
            guard self.micOpen else {
                if gen == self.listenGen { self.transcribing = false; self.heardNothing() }
                return
            }
            self.micOpen = false
            let t0 = Date()
            do {
                // Bounded: a transcript that never comes must not leave the Assistant on "Thinking".
                let r = try await Self.within(12) { try await NVoiceController.shared.assistantStop() }
                guard gen == self.listenGen else { return }
                self.transcribing = false
                let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                Diagnostics.log(String(format: "assistant: heard %d characters (transcribed in %.1f s)", text.count, Date().timeIntervalSince(t0)))
                if text.isEmpty { self.heardNothing(); return }
                self.emptyTurns = 0
                self.handle(text, localeID: r.localeID)
            } catch {
                Diagnostics.log("assistant: transcription failed — \(error.localizedDescription)")
                guard gen == self.listenGen else { return }
                self.transcribing = false
                self.conversation = false
                self.orb.phase = .idle
                self.reply(error.localizedDescription, Self.uiLang, speak: false)
            }
        }
    }

    /// Sound but no words (a cough, a door): in conversation mode, just listen again — twice in a row ends it.
    private func heardNothing() {
        emptyTurns += 1
        if emptyTurns >= 2 { conversation = false }
        orb.phase = .idle
        settle()
    }

    func cancelListening() {
        guard isListening else { return }
        orb.phase = .idle
        endTurn()
    }

    /// Nothing more is being said or written: idle, and in conversation mode, listen again.
    private func settle() {
        guard !streaming, !transcribing, !isSpeaking, !isListening else { return }
        if aiTask == nil || aiTask?.isCancelled == true || orb.phase != .thinking { orb.phase = .idle }
        guard conversation, handsFree, orb.phase == .idle else { return }
        relisten?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.conversation, self.orb.phase == .idle, !self.isSpeaking else { return }
            self.startListening(auto: true)
        }
        relisten = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    /// The language for messages that don't come from something you said.
    private static let uiLang: AssistantLang = Locale.preferredLanguages.first?.hasPrefix("es") == true ? .es : .en

    private struct TimedOut: LocalizedError {
        var errorDescription: String? { "The transcription took too long. Try again." }
    }

    private final class RaceFlag { var done = false; var timer: Task<Void, Never>? }

    /// `op`'s result, or `TimedOut` after `seconds` even if `op` never returns.
    private static func within<T>(_ seconds: Double, _ op: @escaping @MainActor () async throws -> T) async throws -> T {
        let once = RaceFlag()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            once.timer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, !once.done else { return }
                once.done = true
                c.resume(throwing: TimedOut())
            }
            Task { @MainActor in
                let result: Result<T, Error>
                do { result = .success(try await op()) } catch { result = .failure(error) }
                guard !once.done else { return }
                once.done = true
                once.timer?.cancel()
                c.resume(with: result)
            }
        }
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

        lastOpened = lastOpened.filter { store.pane($0.paneID, in: $0.workspaceID) != nil }
        var models: [Tool: [LaunchCatalog.Choice]] = [
            .claude: LaunchCatalog.claudeModelChoices,
            .codex: LaunchCatalog.modelChoices(for: .codex, settings: store.settings),
        ]
        // Reading Cursor's list runs its CLI: only when Cursor is mentioned.
        if text.folded.contains("cursor") { models[.cursor] = LaunchCatalog.modelChoices(for: .cursor, settings: store.settings) }
        let ctx = AssistantCommands.Context(
            projects: store.state.projects,
            workspaces: store.state.workspaces.filter { !$0.agentHost }.map { ($0.id, $0.name) },
            agents: harness.profiles,
            panes: paneList(),
            lastOpened: lastOpened,
            models: models,
            efforts: [.claude: LaunchCatalog.claudeEfforts,
                      .codex: LaunchCatalog.efforts(for: .codex, model: nil, settings: store.settings)])
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
            conversation = false
            stopSpeaking(); orb.phase = .idle
        case .endConversation:
            conversation = false
            reply(L("De nada.", "You're welcome."), lang)
        case .repeatLast:
            if let r = lastReply { say(r.text, r.lang) } else { reply(L("Aún no he dicho nada.", "I haven't said anything yet."), lang) }
        case .help:
            reply(L("Puedo abrir proyectos y espacios, abrir varios paneles de Claude, Codex, Cursor o terminal con el modelo y el esfuerzo que digas y con un prompt para empezar, mandarle prompts a paneles abiertos, pedirle trabajo a tus agentes y decirte qué está corriendo. Por ejemplo: abre tres Claude en Opus 5.5 low que revisen el login; dile a Ada que corra los tests.",
                    "I can open projects and spaces, open several Claude, Codex, Cursor or terminal panes with the model and effort you say and a prompt to start on, send prompts to open panes, hand work to your agents and tell you what's running. Try: open three Claude in Opus 5.5 low to review the login; tell Ada to run the tests."), lang)
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
        case .newPane(let r):
            openPanes(r, lang: lang)
        case .sendToPanes(let refs, let names, let prompt):
            let live = refs.filter { store.pane($0.paneID, in: $0.workspaceID) != nil }
            guard !live.isEmpty else { reply(L("Ese panel ya no está abierto.", "That pane isn't open anymore."), lang); return }
            for r in live {
                store.updatePane(r.paneID, in: r.workspaceID) { $0.lastPrompt = prompt }
                store.deliver(prompt, to: r)
            }
            reply(live.count == 1 ? L("Se lo mandé a \(names.first ?? "ese panel").", "Sent it to \(names.first ?? "that pane").")
                                  : L("Se lo mandé a \(live.count) paneles.", "Sent it to \(live.count) panes."), lang)
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

    /// Opens `r.count` panes in the current space; when it fills up, the rest go to new spaces.
    private func openPanes(_ r: PaneRequest, lang: AssistantLang) {
        guard let store else { return }
        func L(_ es: String, _ en: String) -> String { lang == .es ? es : en }
        showWorkspaces()
        if let p = r.project, store.selectedWorkspace?.projectIDs.contains(p.id) != true { store.openProject(p) }
        guard let w = store.selectedWorkspace, var sid = store.selectedSpace?.id else {
            reply(L("Primero abre un proyecto.", "Open a project first."), lang); return
        }
        var effort = r.effort
        if let e = effort, !LaunchCatalog.efforts(for: r.tool, model: r.model, settings: store.settings).contains(e) { effort = nil }
        let options = LaunchOptions(model: r.tool == .terminal ? nil : r.model, effort: effort, permission: nil)
        var opened: [Pane] = []
        for _ in 0..<max(1, min(PaneRequest.maxCount, r.count)) {
            if store.space(sid, in: w.id)?.isFull != false {
                guard let s = store.newSpace(in: w.id) else { break }
                sid = s.id
            }
            guard let pane = store.addPane(tool: r.tool, projectID: r.project?.id, in: w.id, space: sid,
                                           options: options, prompt: r.prompt) else { break }
            opened.append(pane)
        }
        guard !opened.isEmpty else { reply(L("No pude abrir el panel.", "Couldn't open the pane."), lang); return }
        lastOpened = opened.map { Store.PaneRef(workspaceID: w.id, paneID: $0.id) }

        let first = opened[0]
        let how = r.tool == .terminal ? "" : [r.model.map { _ in LaunchCatalog.modelLabel(first.model ?? "", tool: r.tool) },
                                              effort.map { _ in first.effort ?? "" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        let names = opened.map(store.paneTitle)
        let list = names.count <= 6 ? names.joined(separator: ", ") : names.prefix(5).joined(separator: ", ") + L(" y \(names.count - 5) más", " and \(names.count - 5) more")
        var text: String
        if opened.count == 1 {
            text = L("Abrí \(r.tool.label)\(how.isEmpty ? "" : " en \(how)") como \(names[0])", "Opened \(r.tool.label)\(how.isEmpty ? "" : " on \(how)") as \(names[0])")
            text += r.prompt == nil ? "." : L(" y ya tiene el prompt.", " with your prompt.")
        } else {
            text = L("Abrí \(opened.count) \(r.tool.label)\(how.isEmpty ? "" : " en \(how)"): \(list)", "Opened \(opened.count) \(r.tool.label)\(how.isEmpty ? "" : " on \(how)"): \(list)")
            text += r.prompt == nil ? "." : L(", todos con el prompt.", ", all with your prompt.")
        }
        if opened.count < r.count { text += L(" No cupieron más.", " No room for more.") }
        if r.effort != nil, effort == nil { text += L(" Ese esfuerzo no aplica a este modelo; usé el de siempre.", " That effort doesn't apply to this model; used the default.") }
        reply(text, lang)
    }

    /// Every open pane by name, the current workspace's first.
    private func paneList() -> [(ref: Store.PaneRef, title: String)] {
        guard let store else { return [] }
        let cur = store.selectedWorkspace?.id
        let ws = store.state.workspaces.filter { !$0.agentHost }
        return (ws.filter { $0.id == cur } + ws.filter { $0.id != cur }).flatMap { w in
            w.spaces.flatMap { s in s.panes.map { (Store.PaneRef(workspaceID: w.id, paneID: $0.id), store.paneTitle($0)) } }
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
            let s = NVoiceSettings.shared
            let better = (try? await Enhancer.complete(system: s.enhancePrompt, input: instruction, settings: s, timeout: 45,
                                                       provider: self?.aiProvider, model: self?.aiModel)) ?? instruction
            guard !Task.isCancelled else { return }
            self?.aiTask = nil
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
                let s = (try? await Enhancer.complete(system: system, input: result, settings: NVoiceSettings.shared, timeout: 45,
                                                      provider: self?.aiProvider, model: self?.aiModel))
                self?.reply(head + (s.map { AssistantCommands.spoken($0) } ?? AssistantCommands.spoken(result)), lang)
            }
        default:
            break
        }
    }

    // MARK: AI fallback

    private func cancelAI() {
        aiTask?.cancel()
        aiTask = nil
        liveToken = UUID()
        streaming = false
    }

    /// Asks the AI and speaks its answer sentence by sentence while it's still being written.
    private func askAI(_ text: String, lang: AssistantLang) {
        cancelAI()
        orb.phase = .thinking
        let system = AssistantAI.systemPrompt()
        let input = AssistantAI.snapshot(store: store, harness: harness, panel: panel)
            + "\n\nRecent conversation:\n" + log.suffix(7).dropLast().map { ($0.fromUser ? "User: " : "Assistant: ") + $0.text }.joined(separator: "\n")
            + "\n\nUser request: \(text)"
        let token = UUID()
        liveToken = token
        liveSplit = AssistantAI.StreamSplitter()
        liveEntryID = nil
        liveSpoke = false
        streaming = true
        aiTask = Task { [weak self] in
            do {
                guard let self else { return }
                let onText: (String) -> Void = { [weak self] piece in self?.streamed(piece, token: token, lang: lang) }
                let raw: String
                if self.aiProvider == .claude && self.keepWarm {
                    raw = try await AssistantBrain.shared.ask(input, model: self.aiModel, system: system, onText: onText)
                } else {
                    raw = try await Enhancer.stream(system: system, input: input, settings: NVoiceSettings.shared, timeout: 60,
                                                    provider: self.aiProvider, model: self.aiModel, onText: onText)
                }
                self.streamDone(raw, token: token, lang: lang)
            } catch {
                guard let self, self.liveToken == token else { return }
                Diagnostics.log("assistant: AI failed — \(error.localizedDescription)")
                // Both cleared, or `settle` keeps the orb on "Thinking" forever and conversation mode never listens again.
                self.streaming = false
                self.aiTask = nil
                if error is CancellationError { self.settle(); return }
                self.reply((lang == .es ? "La IA no respondió: " : "The AI didn't answer: ") + error.localizedDescription, lang, speak: false)
            }
        }
    }

    private func streamed(_ piece: String, token: UUID, lang: AssistantLang) {
        guard token == liveToken else { return }
        let sentences = liveSplit.feed(piece)
        showLive(liveSplit.speakable)
        for s in sentences { speakLive(s, lang) }
    }

    private func streamDone(_ raw: String, token: UUID, lang: AssistantLang) {
        guard token == liveToken else { return }
        for s in liveSplit.finish() { speakLive(s, lang) }
        let plan = AssistantAI.parse(raw)
        if !liveSpoke, !plan.say.isEmpty { speakLive(plan.say, lang) }   // an answer that wasn't streamable (JSON)
        let said = liveEntryID.flatMap { id in log.first { $0.id == id }?.text } ?? ""
        if said.isEmpty, !plan.say.isEmpty { showLive(plan.say) }
        lastReply = (said.isEmpty ? plan.say : said, lang)
        streaming = false
        aiTask = nil
        for a in plan.actions { runAction(a, lang: lang, quiet: liveSpoke) }
        settle()
    }

    private func showLive(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let id = liveEntryID, let i = log.firstIndex(where: { $0.id == id }) {
            log[i].text = t
        } else {
            let e = Entry(fromUser: false, text: t)
            liveEntryID = e.id
            log.append(e)
        }
    }

    private func speakLive(_ sentence: String, _ lang: AssistantLang) {
        liveSpoke = true
        if speakReplies { say(sentence, lang) }
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
        case "new_pane":
            intent = Tool(rawValue: a.tool ?? "claude").map { tool in
                var r = PaneRequest(tool: tool, project: project, count: max(1, min(PaneRequest.maxCount, a.count ?? 1)),
                                    prompt: a.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty)
                if tool != .terminal, let m = a.model?.nonEmpty {
                    let said = AssistantCommands.digitize(AssistantCommands.normalize(m))
                    r.model = AssistantCommands.model(in: said, LaunchCatalog.modelChoices(for: tool, settings: store.settings))?.0
                        ?? (m.contains("-") ? m : nil)
                }
                if let e = a.effort?.nonEmpty {
                    r.effort = AssistantCommands.effort(in: AssistantCommands.normalize(e), allowed: [])
                }
                return .newPane(r)
            }
        case "send_to_pane":
            guard let prompt = a.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty, let target = a.pane?.folded else { return }
            let panes = paneList()
            let refs: [Store.PaneRef]
            switch target {
            case "last", "ultimo", "the last pane": refs = Array(lastOpened.suffix(1))
            case "all", "todos", "all of them": refs = lastOpened
            default: refs = panes.first { $0.title.folded == target }.map { [$0.ref] } ?? []
            }
            let names = refs.map { r in panes.first { $0.ref == r }?.title ?? "?" }
            intent = refs.isEmpty ? nil : .sendToPanes(refs, names: names, prompt: prompt)
        case "show_panel": intent = a.tab.flatMap { RightPanelModel.Tab(rawValue: $0) }.map { .showPanel($0) }
        case "home": intent = .home
        case "cancel_agent": intent = agent.map { .cancelAgent(id: $0.id, name: $0.name) }
        case "ask_agent":
            if let agent, let ins = a.instruction, !ins.isEmpty {
                suppressSpeech = quiet
                routeAgent(agent.id, instruction: ins, lang: lang, projectName: project?.name)
                suppressSpeech = false
            }
            return
        default: intent = nil
        }
        guard let intent else { return }
        suppressSpeech = quiet
        perform(intent, lang: lang)
        suppressSpeech = false
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
        if speak && speakReplies && !suppressSpeech { say(text, lang) } else { settle() }
    }

    func say(_ text: String, _ lang: AssistantLang) {
        let clean = AssistantCommands.spoken(text, limit: 600)
        guard !clean.isEmpty else { settle(); return }
        if isListening {
            // Something to report (an agent finished…) while the mic is open: the mic would hear it and take it
            // for you. If you're mid-sentence it stays in the conversation unspoken; otherwise listen again after.
            if vad.heardSpeech { return }
            cancelListening()
        }
        let u = AVSpeechUtterance(string: clean)
        u.voice = voice(lang)
        u.prefersAssistiveTechnologySettings = false
        u.rate = min(AVSpeechUtteranceMaximumSpeechRate, Float(Double(AVSpeechUtteranceDefaultSpeechRate) * speechSpeed))
        u.preUtteranceDelay = 0
        u.postUtteranceDelay = 0.05
        orb.phase = .speaking
        queued[ObjectIdentifier(u)] = u
        synth.speak(u)
        watchSpeech()
    }

    private var isSpeaking: Bool { !queued.isEmpty }

    func stopSpeaking() {
        queued.removeAll()
        speechCheck?.cancel()
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    /// Safety net for a "finished" callback that never comes (it happens with some voices): once the synthesizer
    /// has been silent for two checks in a row, the speech is over.
    private func watchSpeech() {
        speechCheck?.cancel()
        speechMisses = 0
        scheduleSpeechCheck()
    }

    private func scheduleSpeechCheck() {
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.isSpeaking else { return }
            if self.synth.isSpeaking { self.speechMisses = 0 } else { self.speechMisses += 1 }
            guard self.speechMisses >= 2 else { self.scheduleSpeechCheck(); return }
            Diagnostics.log("assistant: speech ended without a callback")
            self.queued.removeAll()
            self.finishedSpeaking()
        }
        speechCheck = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }

    func clear() { log.removeAll(); lastReply = nil; pendingAgent = nil }

    // MARK: Voices

    /// Installed voices for the language, most natural first (Siri › Premium › Enhanced › regular; novelty last).
    func availableVoices(_ lang: AssistantLang) -> [AVSpeechSynthesisVoice] {
        if let l = voiceLists[lang] { return l }
        let l = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(lang.rawValue) }
            .sorted { Self.naturalness($0) > Self.naturalness($1) }
        voiceLists[lang] = l
        return l
    }

    static func naturalness(_ v: AVSpeechSynthesisVoice) -> Int {
        let id = v.identifier.lowercased()
        var score = v.quality.rawValue * 10                        // default 1, enhanced 2, premium 3
        if id.contains("siri") { score += 25 }
        if v.voiceTraits.contains(.isPersonalVoice) { score += 5 }
        if id.contains("super-compact") { score -= 3 }
        if id.contains("eloquence") { score -= 15 }               // Eddy, Flo, Grandma…: robotic
        if id.contains("speech.synthesis.voice") || v.voiceTraits.contains(.isNoveltyVoice) { score -= 30 }
        if v.language == "es-MX" || v.language == "en-US" { score += 1 }
        return score
    }

    private func voice(_ lang: AssistantLang) -> AVSpeechSynthesisVoice? {
        let chosen = lang == .es ? voiceES : voiceEN
        let list = availableVoices(lang)
        return list.first { $0.identifier == chosen } ?? list.first ?? AVSpeechSynthesisVoice(language: lang == .es ? "es-MX" : "en-US")
    }

    /// The best voice installed is still a basic one: worth downloading a better one.
    func onlyBasicVoices(_ lang: AssistantLang) -> Bool {
        (availableVoices(lang).first.map(Self.naturalness) ?? 0) < 20
    }

    func preview(_ lang: AssistantLang) {
        stopSpeaking()
        voiceLists[lang] = nil
        say(lang == .es ? "Hola, así sueno. ¿En qué te ayudo con ProjectN?" : "Hi, this is how I sound. How can I help with ProjectN?", lang)
    }

    func refreshVoices() { voiceLists.removeAll() }
}

extension AssistantController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance: AVSpeechUtterance) {
        // A beat per word makes the orb "talk".
        let l = Float.random(in: 0.55...1)
        Task { @MainActor [weak self] in if self?.orb.phase == .speaking { self?.orb.push(l) } }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.speechEnded(id) }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.speechEnded(id) }
    }

    /// One sentence ended. Ones dropped by `stopSpeaking` are already gone and change nothing.
    private func speechEnded(_ id: ObjectIdentifier) {
        guard queued.removeValue(forKey: id) != nil, queued.isEmpty else { return }
        finishedSpeaking()
    }

    private func finishedSpeaking() {
        speechCheck?.cancel()
        // Between streamed sentences the answer may still be coming: back to "Thinking" until the next one.
        if orb.phase == .speaking { orb.phase = streaming || transcribing ? .thinking : .idle }
        settle()
    }
}

/// Notices when you've finished talking, from the mic level alone (cheap: no extra audio processing).
/// It learns the room's background level first, then ends after a short silence once you've said something.
/// Thresholds are relative to that background, so a fan or a noisy room doesn't count as speech (which used to
/// keep it listening until the 45 s limit), and a lone click or key press doesn't either.
struct AssistantVAD {
    enum Result: Equatable { case listening, endOfSpeech, nothingSaid }

    var silenceToEnd: TimeInterval = 0.9
    var giveUpAfter: TimeInterval = 7
    var maxLength: TimeInterval = 45
    /// How long the background level is measured before speech can be detected.
    static let calibration: TimeInterval = 0.4
    private var began: Date?
    private var calibrating: [(level: Float, at: Date)] = []
    private var calibrated = false
    private var floor: Float = 0
    private var loudRun = 0
    private(set) var heardSpeech = false
    private var lastLoud = Date.distantPast

    init() {}

    /// Speech starts above this…
    private var startLevel: Float { max(0.3, floor + 0.18) }
    /// …and goes on while above this.
    private var keepLevel: Float { max(0.22, floor + 0.1) }

    mutating func push(_ level: Float, now: Date = Date()) -> Result {
        if began == nil { began = now }
        let t = now.timeIntervalSince(began!)
        if !calibrated {
            calibrating.append((level, now))
            guard t >= Self.calibration else { return .listening }
            // The quiet moments are the room: even someone who starts talking at once pauses between syllables.
            // A low percentile, not the minimum: the first buffers of a starting mic can be pure silence.
            let sorted = calibrating.map(\.level).sorted()
            floor = sorted[min(sorted.count - 1, sorted.count / 5)]
            calibrated = true
            for s in calibrating.dropLast() { loudness(s.level, at: s.at) }
            calibrating = []
        }
        loudness(level, at: now)
        if t > maxLength { return heardSpeech ? .endOfSpeech : .nothingSaid }
        if heardSpeech { return now.timeIntervalSince(lastLoud) > silenceToEnd ? .endOfSpeech : .listening }
        return t > giveUpAfter ? .nothingSaid : .listening
    }

    private mutating func loudness(_ level: Float, at now: Date) {
        if level > (heardSpeech ? keepLevel : startLevel) {
            loudRun += 1
            if loudRun >= 2 { heardSpeech = true }       // two buffers in a row (~40 ms): not a click
            if heardSpeech { lastLoud = now }
        } else {
            loudRun = 0
            // Before you speak, follow the room: down quickly, up slowly.
            if !heardSpeech { floor += (level - floor) * (level < floor ? 0.3 : 0.02) }
        }
    }
}
