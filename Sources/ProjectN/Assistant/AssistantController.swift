import AVFoundation
import NaturalLanguage
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
///
/// Audio: a conversation opens the microphone once and keeps it open until it ends — while you talk, while it thinks
/// and while it answers — and each turn is transcribed on that open mic. (Opening and closing it for every turn and
/// every answer cost time each time, cut off first words and kept switching the mic indicator on and off.)
/// Answers play through `AssistantSpeaker`, which reports what it is saying at every moment, so talking over an
/// answer is told apart from the answer's own echo.
@MainActor
final class AssistantController: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let fromUser: Bool
        var text: String
        /// What you're saying, shown while it's still being heard.
        var provisional = false
        /// A status message (a mic problem, an AI error): shown small, never spoken.
        var notice = false
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
    @Published var voiceES: String { didSet { d.set(voiceES, forKey: "assistant.voice.es"); prewarmVoices() } }
    @Published var voiceEN: String { didSet { d.set(voiceEN, forKey: "assistant.voice.en"); prewarmVoices() } }
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
    /// Talking over an answer stops it and becomes your turn.
    @Published var bargeIn: Bool { didSet { d.set(bargeIn, forKey: "assistant.bargeIn") } }
    @Published var wakeWordEnabled: Bool {
        didSet { d.set(wakeWordEnabled, forKey: "assistant.wakeWord"); updateWakeListening() }
    }
    @Published private(set) var wakeWordStatus = "Off"
    /// How close to your recordings a sound must be before it's transcribed to confirm “Hey N”.
    @Published var wakeSensitivity: WakeWordDetector.Sensitivity {
        didSet { d.set(wakeSensitivity.rawValue, forKey: "assistant.wakeSensitivity"); wakeListener.reload() }
    }
    @Published private(set) var wakeSampleCount = 0
    @Published private(set) var recordingWakeSample = false
    @Published private(set) var wakeSampleMessage = ""
    /// The microphone is open for a conversation (shown in the view).
    @Published private(set) var micOn = false
    private var wakeSamples: [[Float]] = []
    static let wakeSamplesNeeded = 3
    private static let wakeSamplesKept = 6

    private let d = UserDefaults.standard
    private weak var store: Store?
    private weak var harness: AgentHarness?
    private weak var panel: RightPanelModel?
    private weak var nav: NavigationModel?
    let speaker = AssistantSpeaker()
    private var voiceLists: [AssistantLang: [AVSpeechSynthesisVoice]] = [:]
    /// Tasks started from here, and the language to report them in.
    private var watched: [UUID: AssistantLang] = [:]
    private var lastReply: (text: String, lang: AssistantLang)?
    /// "Which project?" asked for an agent request: the next answer picks it.
    private var pendingAgent: (agentID: UUID, instruction: String, candidates: [Project], lang: AssistantLang)?
    /// "¿Quisiste decir Vibevoice?": where each answer goes, and what was heard (learned when you say yes).
    private var pendingChoice: (heard: String, options: [AssistantIntent], lang: AssistantLang)?
    private var aiTask: Task<Void, Never>?
    /// Turns in a row where nothing intelligible was heard (conversation mode stops after two).
    private var emptyTurns = 0
    private var vad = AssistantVAD()
    /// A spoken back-and-forth is going on: the mic stays open until it ends.
    private var conversation = false
    private var relisten: DispatchWorkItem?
    /// An AI answer is still being written.
    private var streaming = false
    /// Views showing the Assistant (side panel, floating window). It stops when the last one goes away.
    private var hosts = 0
    private let createdAt = Date()
    /// You opened the Assistant yourself just now (rail button, menu): only then does it start listening on its own.
    private var userOpenedAt: Date?
    private var liveToken = UUID()
    private var liveSplit = AssistantAI.StreamSplitter()
    private var liveEntryID: UUID?
    private var liveSpoke = false
    /// Confirmations of actions the AI already announced aren't spoken again.
    private var suppressSpeech = false
    /// Panes the Assistant opened last: "diles a todos que…", "al último…".
    private var lastOpened: [Store.PaneRef] = []
    /// Everything spoken for the current request: an interruption's transcript may start with its echo.
    private var spokenTurn = ""
    /// This turn began by interrupting an answer: what was being said, to remove from the transcript.
    private var echoText: String?
    private let wakeListener = AssistantWakeListener()
    private var wakeCapture = false

    // Microphone (one recording for the whole conversation)
    private enum Mic { case closed, opening, open }
    private var mic: Mic = .closed { didSet { if (mic == .open) != micOn { micOn = mic == .open } } }
    /// Bumped whenever the mic closes or reopens: levels from an older recording are ignored.
    private var micGen = 0
    private var micOpenedAt: Date?
    private var lastLevelAt: Date?
    private var micWatch: Timer?
    private var micRestarts = 0
    private var fastestLevel: TimeInterval = 1
    private var levelLateness: TimeInterval = 0

    // The current turn's transcript, running on the open mic
    private var turnOpen = false
    /// Bumped for every new turn: late text from an older one is ignored.
    private var turnGen = 0
    private var turnPreroll = 0.0
    /// Live text per recognition language; the best fitting one is shown.
    private var partials: [String: String] = [:]
    private var partialLane: String?
    private var liveText = ""
    private var lastPartialKey = ""
    private var liveUserEntryID: UUID?
    /// Transcripts of ended turns still being finalized.
    private var finishing = 0
    private var turnEndedAt: Date?
    /// The last turn's final text: if you go on talking while it thinks, it becomes the start of your turn.
    private var lastHeard: (gen: Int, text: String, entryID: UUID?)?
    /// The ended turn waiting for its final transcript (nil once handled, or when it was stopped or replaced).
    private var pendingTurn: Int?
    private var continuingFrom: Int?
    private var continuation: String?

    // Talking over an answer
    private enum Interrupt: Equatable { case none, watching, suspected(since: Date) }
    private var interrupt: Interrupt = .none
    private var bargeDetector = AssistantBargeIn()
    private var suspectFromGen = 0
    private var suspectLoud: TimeInterval = 0
    private var suspectLastAt: Date?
    private var speakingMeter: Timer?

    init() {
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
        silenceSeconds = d.object(forKey: "assistant.silence") as? Double ?? 0.9
        speechSpeed = d.object(forKey: "assistant.speed") as? Double ?? 1.05
        floating = d.object(forKey: "assistant.floating") as? Bool ?? false
        bargeIn = d.object(forKey: "assistant.bargeIn") as? Bool ?? true
        wakeWordEnabled = d.object(forKey: "assistant.wakeWord") as? Bool ?? true
        wakeSensitivity = WakeWordDetector.Sensitivity(rawValue: d.string(forKey: "assistant.wakeSensitivity") ?? "") ?? .normal
        speaker.onFinished = { [weak self] in self?.speechFinished() }
    }

    func attach(store: Store, harness: AgentHarness, panel: RightPanelModel, nav: NavigationModel) {
        self.store = store; self.harness = harness; self.panel = panel; self.nav = nav
        harness.observe("assistant") { [weak self] task, event in self?.taskEvent(task, event) }
        configureWakeListening()
        guard !AppHome.isTestProcess else { return }
        upgradeBasicVoices()
        // The first answer shouldn't wait for the voice to load (a Siri voice takes ~4 s the first time).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.prewarmVoices() }
    }

    private func configureWakeListening() {
        // Unit tests must never request permission or activate a microphone.
        guard !AppHome.isTestProcess else { return }
        wakeListener.canListen = { [weak self] in
            guard let self else { return false }
            return self.orb.phase == .idle && self.mic == .closed && !self.conversation && !self.streaming
                && self.finishing == 0 && !self.speaker.isSpeaking && !self.recordingWakeSample
        }
        wakeSamples = WakeWordSamples.load()
        wakeSampleCount = wakeSamples.count
        wakeListener.makeDetector = { [weak self] in
            guard let self else { return nil }
            return WakeWordDetector(samples: self.wakeSamples, sensitivity: self.wakeSensitivity)
        }
        wakeListener.vocabulary = { [weak self] in self?.vocabulary() ?? [] }
        wakeListener.onStatus = { [weak self] in self?.wakeWordStatus = $0 }
        wakeListener.onWake = { [weak self] prompt, floor in self?.wokeUp(prompt: prompt, floor: floor) }
        // fn always wins: dictation gets the mic right away, even in the middle of a conversation.
        NVoiceController.shared.onDictationWillStart = { [weak self] in self?.yieldToDictation() }
        updateWakeListening()
    }

    private func updateWakeListening() {
        guard store != nil, !AppHome.isTestProcess else { return }
        wakeListener.setEnabled(wakeWordEnabled)
    }

    private func yieldToDictation() {
        wakeListener.pause()
        guard mic != .closed || orb.phase != .idle || speaker.isSpeaking else { return }
        stopAll(reason: "dictation took the microphone")
    }

    // MARK: Your “Hey N” recordings

    /// Records one sample of you saying “Hey N” (2.5 s window, trimmed to the speech in it).
    func recordWakeSample() {
        guard !recordingWakeSample, !AppHome.isTestProcess else { return }
        guard orb.phase == .idle, mic == .closed else {
            wakeSampleMessage = "Stop the Assistant first."
            return
        }
        recordingWakeSample = true
        wakeListener.pause()
        wakeSampleMessage = "Say “Hey N” now…"
        let box = SampleBox()
        Task { @MainActor in
            defer { self.recordingWakeSample = false }
            do {
                try await NVoiceController.shared.assistantStartWakeListening(onAudio: { box.append($0) }, onLevel: { _ in })
            } catch {
                self.wakeSampleMessage = "Couldn't use the microphone: \(error.localizedDescription)"
                return
            }
            try? await Task.sleep(for: .milliseconds(2500))
            NVoiceController.shared.assistantCancel()
            try? await Task.sleep(for: .milliseconds(150))   // audio already queued for conversion
            guard let clip = WakeWordDetector.trimToSpeech(box.samples) else {
                self.wakeSampleMessage = "Didn't hear it clearly. Try again, a little closer to the mic."
                return
            }
            self.wakeSamples.append(clip)
            if self.wakeSamples.count > Self.wakeSamplesKept { self.wakeSamples.removeFirst() }
            WakeWordSamples.save(self.wakeSamples)
            self.wakeSampleCount = self.wakeSamples.count
            let left = Self.wakeSamplesNeeded - self.wakeSamples.count
            self.wakeSampleMessage = left > 0 ? "Got it. Record \(left) more." : "Got it. “Hey N” is ready."
            Diagnostics.log("assistant: recorded a “Hey N” sample (\(self.wakeSamples.count) kept)")
            self.wakeListener.reload()
        }
    }

    func clearWakeSamples() {
        wakeSamples = []
        WakeWordSamples.save([])
        wakeSampleCount = 0
        wakeSampleMessage = ""
        wakeListener.reload()
    }

    /// “Hey N” confirmed: the wake recording (already transcribing, “Hey N” included) becomes this conversation's
    /// open mic and first turn, so a request said in the same breath isn't cut.
    private func wokeUp(prompt: String, floor: Float) {
        Diagnostics.log("assistant: woke on Hey N")
        relisten?.cancel()
        speaker.stop()
        cancelAI()
        conversation = true
        emptyTurns = 0
        micRestarts = 0
        interrupt = .none
        echoText = nil
        continuation = nil; continuingFrom = nil
        micGen += 1
        let gen = micGen
        mic = .open
        micOpenedAt = Date()
        lastLevelAt = Date()
        fastestLevel = 1
        NVoiceController.shared.assistantStopWakeMatcher()
        NVoiceController.shared.assistantSetLevelHandler { [weak self] in self?.micLevel($0, age: $1, gen: gen) }
        turnGen += 1
        let tg = turnGen
        turnOpen = true
        partials = [:]; partialLane = nil; lastPartialKey = ""
        liveText = prompt
        liveUserEntryID = nil
        NVoiceController.shared.assistantSetTranscriptHandler { [weak self] locale, text in
            self?.heardPartial(text, locale: locale, gen: tg)
        }
        wakeCapture = true
        vad = AssistantVAD()
        vad.silenceToEnd = silenceSeconds
        vad.giveUpAfter = 12
        if !prompt.isEmpty {
            vad.startSpeaking(floor: min(floor, 0.2))
            showLiveUser(prompt)
        }
        orb.phase = .listening
        watchMic(gen)
        prewarmVoices()
        speaker.prepare()
        if floating {
            FloatingAssistant.shared.show()
        } else {
            panel?.show(.assistant)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Opening and closing

    var isListening: Bool { orb.phase == .listening }

    /// Click on the orb / ⌥⌘A: start talking when it's idle; while you talk, finish your turn now; while it answers,
    /// cut the answer short and listen; while it thinks, stop.
    func toggleListening() {
        switch orb.phase {
        case .idle: startListening()
        case .speaking:
            Diagnostics.log("assistant: answer cut short (click)")
            startListening()
        case .listening:
            if vad.heardSpeech || !liveText.isEmpty { finishTurn() } else { stopAll(reason: "click") }
        case .thinking: stopAll(reason: "click")
        }
    }

    /// You opened the Assistant (rail button, menu, floating window). The view that appears next may start listening.
    func userOpened() { userOpenedAt = Date() }

    /// The Assistant was shown (side panel tab or floating window): get the AI, the mic and the voice ready and, if
    /// you opened it yourself, start listening.
    func opened() {
        hosts += 1
        // Not when ProjectN starts with the Assistant already showing: only when you open it.
        guard Date().timeIntervalSince(createdAt) > 2 else { return }
        prewarm()
        NVoiceController.shared.assistantPrewarm()
        prewarmVoices()
        // Only when you just opened it: the panel also reappears on its own (closing Settings, showing the panel for
        // another tab), and that used to switch the mic on when you didn't mean to talk.
        let asked = userOpenedAt.map { Date().timeIntervalSince($0) < 2 } ?? false
        userOpenedAt = nil
        if autoListen, asked, orb.phase == .idle { startListening() }
    }

    /// The Assistant was hidden. Moving it between the panel and the floating window hides one view and shows the
    /// other in no fixed order, so it only stops once no view is left.
    func closed() {
        hosts = max(0, hosts - 1)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hosts == 0 else { return }
            self.stopAll(reason: "hidden")
        }
    }

    /// Ends everything: answer, AI, listening and the microphone.
    func stopAll(reason: String? = nil) {
        if let reason, orb.phase != .idle || mic != .closed { Diagnostics.log("assistant: stopped (\(reason))") }
        conversation = false
        interrupt = .none
        pendingTurn = nil
        continuation = nil; continuingFrom = nil
        relisten?.cancel()
        cancelAI()
        speaker.stop()
        stopSpeakingMeter()
        abortTurn()
        closeMic()
        orb.phase = .idle
    }

    func prewarm() {
        guard useAI, keepWarm, aiProvider == .claude else { return }
        AssistantBrain.shared.prewarm(model: aiModel, system: AssistantAI.systemPrompt())
    }

    private func prewarmVoices() {
        guard !AppHome.isTestProcess else { return }
        speaker.prewarm([voice(.es), voice(.en)].compactMap { $0 })
    }

    // MARK: Listening

    /// `auto`: conversation mode listening again after an answer (the mic is already open).
    func startListening(auto: Bool = false) {
        guard !isListening else { return }
        let cutShort = orb.phase == .speaking
        relisten?.cancel()
        wakeListener.pause()
        pendingTurn = nil
        if !auto {
            conversation = true
            emptyTurns = 0
            micRestarts = 0
            prewarmVoices()
            speaker.prepare()
        }
        speaker.stop()
        cancelAI()
        stopSpeakingMeter()
        interrupt = .none
        echoText = nil
        wakeCapture = false
        continuation = nil; continuingFrom = nil
        vad = AssistantVAD()
        vad.silenceToEnd = silenceSeconds
        vad.giveUpAfter = auto ? 8 : 12
        orb.phase = .listening
        Diagnostics.log("assistant: listening\(auto ? " (conversation)" : "")")
        // Right after (or instead of) an answer, nothing from before belongs to your turn: it would be its echo.
        beginTurn(preroll: auto || cutShort ? 0 : 0.3)
    }

    /// What you're likely to name, so speech recognition gets it right: "Claude" instead of "cloud",
    /// "Solar Devs" instead of "solar debs", "Vibe Voice" (how Vibevoice is said) instead of "Bible Boys".
    /// Places first: they're what dictation most often gets wrong.
    func vocabulary() -> [String] {
        let tools = ["Claude", "Claude Code", "Codex", "Cursor", "Opus", "Sonnet", "Haiku", "Fable", "terminal", "ProjectN", "NVoice"]
        guard let store else { return tools }
        let ws = store.state.workspaces.filter { !$0.agentHost }
        let places = store.state.projects.map(\.name) + ws.map(\.name)
            + ws.flatMap(\.spaces).map(\.name).filter { !AssistantCommands.isNumberedSpace($0) }
        var out = places + places.flatMap { SpokenNames.forms($0) }
        out += (harness?.profiles ?? []).filter(\.enabled).map(\.name)
        out += paneList().map(\.title)
        out += tools
        var seen = Set<String>()
        return out.filter { !$0.isEmpty && seen.insert($0.folded).inserted }
    }

    /// Spaces of the workspaces that aren't open (the open one's are in the context already).
    private func otherSpaces() -> [(id: UUID, name: String, workspaceID: UUID)] {
        guard let store else { return [] }
        let cur = store.selectedWorkspace?.id
        return store.state.workspaces.filter { !$0.agentHost && $0.id != cur }.flatMap { w in w.spaces.map { ($0.id, $0.name, w.id) } }
    }

    /// How a place is named when asking "¿Quisiste decir …?".
    private func placeLabel(_ intent: AssistantIntent, _ lang: AssistantLang) -> String {
        switch intent {
        case .agentsView: return lang == .es ? "la vista de agentes" : "the Agents view"
        case .selectSpace(_, let name, let wid?):
            guard let w = store?.workspace(wid) else { return name }
            return lang == .es ? "\(name) de \(w.name)" : "\(name) in \(w.name)"
        default: return intent.placeName ?? ""
        }
    }

    /// "Lista los espacios": the names, said so you know what to ask for.
    private func listText(_ kind: AssistantListKind, _ lang: AssistantLang) -> String {
        guard let store, let harness else { return "" }
        func L(_ es: String, _ en: String) -> String { lang == .es ? es : en }
        func join(_ xs: [String]) -> String {
            guard let last = xs.last else { return "" }
            return xs.count == 1 ? last : xs.dropLast().joined(separator: ", ") + L(" y ", " and ") + last
        }
        let ws = store.state.workspaces.filter { !$0.agentHost }
        let cur = store.selectedWorkspace
        switch kind {
        case .projects:
            let names = store.state.projects.map(\.name)
            return names.isEmpty ? L("Aún no tienes proyectos.", "You have no projects yet.")
                : L("Tus \(names.count) proyectos: ", "Your \(names.count) projects: ") + join(names) + "."
        case .workspaces:
            let names = ws.map(\.name)
            return names.isEmpty ? L("Aún no tienes workspaces.", "You have no workspaces yet.")
                : L("Tus \(names.count) workspaces: ", "Your \(names.count) workspaces: ") + join(names) + "."
        case .spaces:
            var parts: [String] = []
            if let cur { parts.append(L("En \(cur.name): ", "In \(cur.name): ") + join(cur.spaces.map(\.name)) + ".") }
            let named = ws.filter { $0.id != cur?.id }.flatMap { w in
                w.spaces.filter { !AssistantCommands.isNumberedSpace($0.name) }.map { L("\($0.name) de \(w.name)", "\($0.name) in \(w.name)") }
            }
            if !named.isEmpty { parts.append(L("Espacios con nombre: ", "Named spaces: ") + join(named) + ".") }
            let others = ws.filter { $0.id != cur?.id }.map(\.name)
            if !others.isEmpty { parts.append(L(cur == nil ? "Workspaces: " : "Otros workspaces: ", cur == nil ? "Workspaces: " : "Other workspaces: ") + join(others) + ".") }
            return parts.isEmpty ? L("Aún no hay espacios.", "There are no spaces yet.") : parts.joined(separator: " ")
        case .panes:
            let panes = ws.flatMap { w in w.spaces.flatMap { s in s.panes.map { p in
                "\(store.paneTitle(p)) (\(p.tool.label)\(w.id == cur?.id ? "" : L(", en \(w.name)", ", in \(w.name)")))"
            } } }
            guard !panes.isEmpty else { return L("No hay paneles abiertos.", "No panes are open.") }
            let shown = panes.count <= 12 ? join(panes) : panes.prefix(10).joined(separator: ", ") + L(" y \(panes.count - 10) más", " and \(panes.count - 10) more")
            return L("\(panes.count) \(panes.count == 1 ? "panel" : "paneles"): ", "\(panes.count) \(panes.count == 1 ? "pane" : "panes"): ") + shown + "."
        case .agents:
            let names = harness.profiles.filter(\.enabled).map(\.name)
            return names.isEmpty ? L("No tienes agentes activos.", "You have no active agents.")
                : L("Tus agentes: ", "Your agents: ") + join(names) + "."
        }
    }

    /// A new turn: transcribe what you say from now on (plus `preroll` seconds already heard).
    private func beginTurn(preroll: Double) {
        if turnOpen { NVoiceController.shared.assistantEndTranscript(); turnOpen = false }
        turnGen += 1
        partials = [:]; partialLane = nil; lastPartialKey = ""
        liveText = ""
        liveUserEntryID = nil
        turnPreroll = preroll
        if mic == .open { startTranscript() } else { openMic() }   // starts once the mic is open
    }

    private func startTranscript() {
        guard mic == .open, !turnOpen else { return }
        if NVoiceController.shared.assistantTranscribing { NVoiceController.shared.assistantEndTranscript() }
        turnOpen = true
        let gen = turnGen
        NVoiceController.shared.assistantBeginTranscript(vocabulary: vocabulary(), preroll: turnPreroll) { [weak self] locale, text in
            self?.heardPartial(text, locale: locale, gen: gen)
        }
    }

    /// Drops the turn in progress (its transcript and the bubble showing it); the mic stays as it is.
    private func abortTurn() {
        if turnOpen { NVoiceController.shared.assistantEndTranscript(); turnOpen = false }
        turnGen += 1
        if let id = liveUserEntryID { log.removeAll { $0.id == id && $0.provisional } }
        liveUserEntryID = nil
        liveText = ""
        wakeCapture = false
    }

    private func openMic() {
        guard mic == .closed else { return }
        mic = .opening
        micGen += 1
        let gen = micGen
        lastLevelAt = nil
        fastestLevel = 1
        wakeListener.pause()
        Task { @MainActor [weak self] in
            do {
                try await NVoiceController.shared.assistantOpenMic(shouldStart: { [weak self] in
                    self?.micGen == gen && self?.mic == .opening
                }) { [weak self] l, age in self?.micLevel(l, age: age, gen: gen) }
            } catch {
                guard let self, gen == self.micGen else { return }
                self.mic = .closed
                self.micFailed(error)
                return
            }
            guard let self else { return }
            guard gen == self.micGen, self.mic == .opening else {
                NVoiceController.shared.assistantCancel()      // closed while it was opening
                return
            }
            self.mic = .open
            self.micOpenedAt = Date()
            Diagnostics.log("assistant: microphone on")
            self.watchMic(gen)
            if self.isListening { self.startTranscript() }
        }
    }

    private func closeMic() {
        micWatch?.invalidate(); micWatch = nil
        micGen += 1
        turnOpen = false
        let was = mic
        mic = .closed
        guard was == .open else { return }
        NVoiceController.shared.assistantCancel()
        Diagnostics.log("assistant: microphone off")
    }

    private func micFailed(_ error: Error) {
        guard !(error is CancellationError) else { return }
        Diagnostics.log("assistant: microphone didn't start — \(error.localizedDescription)")
        conversation = false
        interrupt = .none
        turnOpen = false
        if isListening { orb.phase = .idle }
        notice(error.localizedDescription)
        settle()
    }

    /// The mic must keep sending levels (~50 a second). One that goes silent (a device change mid-conversation, a
    /// stalled audio system) is reopened instead of leaving the Assistant deaf.
    private func watchMic(_ gen: Int) {
        micWatch?.invalidate()
        micWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, gen == self.micGen, self.mic == .open else { return }
                let since = self.lastLevelAt ?? self.micOpenedAt ?? Date()
                guard Date().timeIntervalSince(since) > 2.5 else { return }
                self.micStalled()
            }
        }
    }

    private func micStalled() {
        micRestarts += 1
        let listening = isListening
        Diagnostics.log("assistant: no audio from the microphone — \(micRestarts > 2 ? "giving up" : "reopening it")")
        abortTurn()
        closeMic()
        guard micRestarts <= 2 else {
            stopAll()
            notice(Self.uiLang == .es ? "No me llega audio del micrófono. Revisa cuál está elegido en Ajustes › Voz."
                                      : "No audio is coming from the microphone. Check which one is chosen in Settings › Voice.")
            return
        }
        guard conversation else { return }
        if listening { beginTurn(preroll: 0) } else { openMic() }
    }

    /// Mic levels (main thread, ~10 a second) for the whole conversation. `age`: how long ago that audio was
    /// captured; the quickest delivery seen is the normal delay, anything beyond is the main thread being busy.
    private func micLevel(_ l: Float, age: TimeInterval, gen: Int) {
        guard gen == micGen, mic == .open else { return }
        lastLevelAt = Date()
        fastestLevel = min(fastestLevel, age)
        levelLateness = max(0, age - fastestLevel)
        switch orb.phase {
        case .listening:
            orb.push(l)
            switch vad.push(l) {
            case .listening: break
            case .endOfSpeech: finishTurn()
            case .nothingSaid:
                Diagnostics.log("assistant: nothing said — conversation over")
                abortTurn()
                conversation = false
                orb.phase = .idle
                settle()
            }
        case .speaking, .thinking:
            watchInterruption(level: l)
        case .idle:
            break
        }
    }

    private func heardPartial(_ text: String, locale: String, gen: Int) {
        guard gen == turnGen, turnOpen else { return }
        partials[locale] = text
        var shown = bestPartial().text
        if wakeCapture { shown = AssistantWakeCommand.prompt(in: shown) ?? "" }
        if let prefix = continuation, !prefix.isEmpty { shown = prefix + " " + shown }
        shown = shown.trimmingCharacters(in: .whitespacesAndNewlines)
        switch orb.phase {
        case .listening:
            let key = shown.folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
            if !key.isEmpty, key != lastPartialKey {
                lastPartialKey = key
                vad.recognizedSpeech()
            }
            // Finished sentences end the turn sooner; "…and", "…que" give you a moment more.
            vad.silenceToEnd = AssistantVAD.endpoint(after: shown, base: silenceSeconds)
            liveText = shown
            showLiveUser(shown)
        case .speaking, .thinking:
            liveText = shown
            if case .suspected = interrupt { confirmByWords(shown) }
        case .idle:
            break
        }
    }

    /// Each language transcribes the same audio; show the one whose text reads most like that language (with a
    /// little stickiness, so the bubble doesn't flip between two versions).
    private func bestPartial() -> (text: String, locale: String) {
        guard partials.count > 1 else { return partials.first.map { ($0.value, $0.key) } ?? ("", "") }
        var scores: [(locale: String, text: String, score: Double)] = []
        for (locale, text) in partials {
            let code = Locale(identifier: locale).language.languageCode?.identifier ?? ""
            let r = NLLanguageRecognizer()
            r.processString(text)
            var score = r.languageHypotheses(withMaximum: 4)[NLLanguage(rawValue: code)] ?? 0
            if locale == partialLane { score += 0.15 }
            scores.append((locale, text, score))
        }
        let best = scores.max { $0.score < $1.score }!
        partialLane = best.locale
        return (best.text, best.locale)
    }

    private func showLiveUser(_ text: String) {
        guard !text.isEmpty else { return }
        if let id = liveUserEntryID, let i = log.firstIndex(where: { $0.id == id }) {
            if log[i].text != text { log[i].text = text }
        } else {
            let e = Entry(fromUser: true, text: text, provisional: true)
            liveUserEntryID = e.id
            log.append(e)
        }
    }

    /// You finished talking (a pause, or a click): finalize the transcript and answer. The mic stays open.
    private func finishTurn() {
        guard isListening else { return }
        orb.phase = .thinking
        let gen = turnGen
        let fromWake = wakeCapture
        let echo = echoText
        let live = (text: liveText, locale: bestPartial().locale)
        let entryID = liveUserEntryID
        let prefix = continuation
        wakeCapture = false
        echoText = nil
        continuation = nil
        continuingFrom = nil
        turnOpen = false
        turnEndedAt = Date()
        pendingTurn = gen
        finishing += 1
        // Keep listening while it thinks: you may not have finished (see `watchInterruption`).
        bargeDetector = AssistantBargeIn(coupling: bargeDetector.coupling)
        interrupt = conversation && bargeIn ? .watching : .none
        let t0 = Date()
        Task { @MainActor [weak self] in
            var heard: (text: String, localeID: String)
            do {
                // The final text normally takes a few tenths of a second; never wait long for it.
                heard = try await Self.within(2.5) {
                    try await NVoiceController.shared.assistantFinishTranscript { raw in
                        Self.cleanTurn(raw, fromWake: fromWake, echo: echo)
                    }
                }
            } catch {
                Diagnostics.log("assistant: final transcript late (\(error.localizedDescription)) — using the live one")
                heard = (echo.map { AssistantBargeIn.stripEcho(live.text, spoken: $0) } ?? live.text, live.locale)
                if let prefix, heard.text.hasPrefix(prefix) { heard.text = String(heard.text.dropFirst(prefix.count)) }
            }
            guard let self else { return }
            self.finishing -= 1
            var text = heard.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let prefix, !prefix.isEmpty { text = (prefix + " " + text).trimmingCharacters(in: .whitespaces) }
            if self.continuingFrom == gen {
                // You went on talking before this was transcribed: it is the start of the turn in progress.
                self.continuation = text
                if let id = entryID { self.log.removeAll { $0.id == id } }
                return
            }
            // Stopped, or replaced by a new turn, while it was being transcribed.
            guard self.pendingTurn == gen else { self.settle(); return }
            self.pendingTurn = nil
            Diagnostics.log(String(format: "assistant: heard \"%@\" (%.1f s after you stopped)", String(text.prefix(140)), Date().timeIntervalSince(t0)))
            guard !text.isEmpty else {
                if let id = entryID { self.log.removeAll { $0.id == id } }
                self.liveUserEntryID = nil
                self.heardNothing()
                return
            }
            self.emptyTurns = 0
            self.lastHeard = (gen, text, entryID)
            self.liveUserEntryID = nil
            self.handle(text, localeID: heard.localeID, entryID: entryID)
        }
    }

    /// The turn's text: what followed “Hey N”, without the answer's own echo at the start.
    private static func cleanTurn(_ raw: String, fromWake: Bool, echo: String?) -> String {
        var text = raw
        if fromWake {
            // The final text may spell the wake phrase differently from the live one that confirmed it.
            text = AssistantWakeCommand.prompt(in: raw)
                ?? raw.replacingOccurrences(of: #"^\W*(?:hey|hei|ey|ei|jey)\W+(?:n|en|ene|and|an)?\b\W*"#, with: "",
                                            options: [.regularExpression, .caseInsensitive])
        }
        if let echo {
            let clean = AssistantBargeIn.stripEcho(text, spoken: echo)
            if clean != text { Diagnostics.log("assistant: removed its own voice from the start of what it heard") }
            text = clean
        }
        return text
    }

    /// Sound but no words (a cough, a door): in conversation mode, just listen again — twice in a row ends it.
    private func heardNothing() {
        emptyTurns += 1
        if emptyTurns >= 2 { conversation = false }
        orb.phase = .idle
        settle()
    }

    /// Nothing more is being said or written: idle, and in conversation mode, listen again; otherwise the mic closes.
    private func settle() {
        guard !streaming, finishing == 0, !speaker.isSpeaking, !isListening else { return }
        if case .suspected = interrupt { return }
        if aiTask == nil || aiTask?.isCancelled == true || orb.phase != .thinking { orb.phase = .idle }
        guard orb.phase == .idle else { return }
        stopSpeakingMeter()
        interrupt = .none
        guard conversation, handsFree else {
            conversation = false
            closeMic()
            return
        }
        relisten?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.conversation, self.orb.phase == .idle, !self.speaker.isSpeaking else { return }
            self.startListening(auto: true)
        }
        relisten = w
        // A beat for the room to stop ringing with the answer's last word.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    // MARK: Talking over it

    /// While it answers (and right after your turn, while it thinks) the open mic listens for you: talking over the
    /// answer lowers it at once; if it's really you (more voice, or words that aren't its own) it stops and listens.
    private func watchInterruption(level l: Float) {
        guard conversation, bargeIn else { return }
        let speaking = orb.phase == .speaking
        if !speaking {
            // While it thinks, only just after your turn ended: you hadn't finished. Later talk isn't for it.
            let justEnded = turnEndedAt.map { Date().timeIntervalSince($0) < 2.5 } ?? false
            guard justEnded, aiTask != nil || finishing > 0 else {
                if case .suspected = interrupt { dismissInterruption() }
                return
            }
        }
        let fired = bargeDetector.push(mic: l, ref: speaking ? speaker.referenceLevel(late: levelLateness) : 0)
        switch interrupt {
        case .none, .watching:
            if fired { suspectInterruption() }
        case .suspected(let since):
            let now = Date()
            // The first quarter second the mic still hears the answer at full volume (it was lowered ~0.1 s ago
            // and the reference already counts it lowered): only what comes after shows it's you.
            if bargeDetector.loudNow, now.timeIntervalSince(since) > 0.25 {
                suspectLoud += now.timeIntervalSince(suspectLastAt ?? now)
            }
            suspectLastAt = now
            if speaking, suspectLoud >= 0.45 {
                confirmInterruption(why: "your voice over the answer")
            } else if now.timeIntervalSince(since) > (speaking ? 1.3 : 1.8) {
                dismissInterruption()
            }
        }
    }

    private func suspectInterruption() {
        interrupt = .suspected(since: Date())
        suspectLoud = 0
        suspectLastAt = Date()
        if orb.phase == .speaking { speaker.duck(0.3) }
        // Transcribe from just before it started, so your first words are kept.
        suspectFromGen = turnGen
        beginTurn(preroll: 0.7)
    }

    /// The words heard are yours, not the answer's: "stop" / "espera", or words it didn't say. Its own voice comes
    /// back slightly garbled, so over an answer that takes three new words, or two plus a voice above the echo.
    private func confirmByWords(_ heard: String) {
        let speaking = orb.phase == .speaking
        let spoken = speaking ? spokenTurn : ""
        if AssistantBargeIn.isStopRequest(heard, spoken: spoken) { confirmInterruption(why: "a stop word"); return }
        let fresh = AssistantBargeIn.newWords(heard, spoken: spoken)
        if fresh >= 3 || (fresh >= 2 && (!speaking || suspectLoud >= 0.1)) { confirmInterruption(why: "your words") }
    }

    private func confirmInterruption(why: String) {
        guard case .suspected = interrupt else { return }
        let wasSpeaking = orb.phase == .speaking
        Diagnostics.log("assistant: interrupted — \(why)")
        interrupt = .none
        relisten?.cancel()
        if wasSpeaking {
            echoText = spokenTurn
            speaker.stop()
            stopSpeakingMeter()
        } else {
            // You went on with your last turn: it starts that turn over, with what you said before.
            continuingFrom = suspectFromGen
            pendingTurn = nil
            if let h = lastHeard, h.gen == suspectFromGen {
                continuation = h.text
                if let id = h.entryID { log.removeAll { $0.id == id } }
            }
        }
        cancelAI()
        conversation = true
        emptyTurns = 0
        vad = AssistantVAD()
        vad.silenceToEnd = silenceSeconds
        vad.startSpeaking(floor: bargeDetector.room)
        orb.phase = .listening
        if !liveText.isEmpty { showLiveUser(liveText) }
    }

    private func dismissInterruption() {
        guard case .suspected = interrupt else { return }
        interrupt = conversation && bargeIn ? .watching : .none
        if orb.phase == .speaking { speaker.duck(1) }
        if turnOpen { NVoiceController.shared.assistantEndTranscript(); turnOpen = false }
        partials = [:]
        liveText = ""
        settle()
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
    /// `entryID`: the bubble that showed it live while you said it (it becomes the final text).
    func handle(_ text: String, localeID: String? = nil, entryID: UUID? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let store, let harness else { return }
        if let entryID, let i = log.firstIndex(where: { $0.id == entryID }) {
            log[i].text = text
            log[i].provisional = false
            // Anything said meanwhile (an agent's report) goes above it: the request stays last.
            if i != log.count - 1 { log.append(log.remove(at: i)) }
        } else {
            log.append(Entry(fromUser: true, text: text))
        }
        spokenTurn = ""
        let lang = AssistantCommands.language(text, localeID: localeID)

        // Answering "which project?".
        if let p = pendingAgent {
            pendingAgent = nil
            if let project = SlackRouter.pickFromReply(text, candidates: p.candidates) {
                submitAgent(p.agentID, project: project, instruction: p.instruction, lang: p.lang)
                return
            }
        }

        // Answering "¿Quisiste decir …?".
        if let choice = pendingChoice {
            pendingChoice = nil
            if let pick = AssistantCommands.pick(text, from: choice.options) {
                if let id = pick.placeID, let name = pick.placeName {
                    AssistantAliases.shared.learn(heard: choice.heard, id: id, name: name)
                    Diagnostics.log("assistant: learned \"\(choice.heard)\" → \(name)")
                }
                perform(pick, lang: choice.lang)
                return
            }
            if AssistantCommands.isNo(text) {
                reply(lang == .es ? "Vale." : "Okay.", lang)
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
            spaces: store.selectedWorkspace?.spaces.map { ($0.id, $0.name) } ?? [],
            otherSpaces: otherSpaces(),
            learned: AssistantAliases.shared.all,
            agents: harness.profiles,
            panes: paneList(),
            lastOpened: lastOpened,
            models: models,
            efforts: [.claude: LaunchCatalog.claudeEfforts,
                      .codex: LaunchCatalog.efforts(for: .codex, model: nil, settings: store.settings)])
        let intent = AssistantCommands.parse(text, ctx)
        let kind = Mirror(reflecting: intent).children.first?.label ?? "\(intent)"
        // A name that only sounds close: the AI (when on) decides with the whole picture; without it, ask.
        var toAI = false
        switch intent {
        case .unknown, .didYouMean: toAI = useAI
        default: break
        }
        Diagnostics.log("assistant: request → \(toAI ? "AI (\(aiProvider.rawValue) \(aiModel))" : kind == "unknown" ? "not a command, AI is OFF" : kind)")
        if toAI {
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
            speaker.stop()
            orb.phase = .idle
            settle()
        case .endConversation:
            conversation = false
            reply(L("De nada.", "You're welcome."), lang)
        case .repeatLast:
            if let r = lastReply { say(r.text, r.lang) } else { reply(L("Aún no he dicho nada.", "I haven't said anything yet."), lang) }
        case .help:
            reply(L("Puedo abrir proyectos y espacios, abrir varios paneles de Claude, Codex, Cursor o terminal con el modelo y el esfuerzo que digas y con un prompt para empezar, cerrar paneles abiertos o cambiar su modelo y esfuerzo, mandarles prompts, pedirle trabajo a tus agentes, decirte qué está corriendo y leerte los nombres de tus proyectos, espacios o paneles. Por ejemplo: abre tres Claude en Opus 5.5 low que revisen el login; dile a Ada que corra los tests.",
                    "I can open projects and spaces, open several Claude, Codex, Cursor or terminal panes with the model and effort you say and a prompt to start on, close open panes or change their model and effort, send them prompts, hand work to your agents, tell you what's running and read you the names of your projects, spaces or panes. Try: open three Claude in Opus 5.5 low to review the login; tell Ada to run the tests."), lang)
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
        case .selectSpace(let id, let name, let wid):
            showWorkspaces()
            guard let w = wid ?? store.selectedWorkspace?.id, store.space(id, in: w) != nil else {
                reply(L("Ese espacio ya no existe.", "That space doesn't exist anymore."), lang); return
            }
            store.selectSpace(id, in: w)
            let where_ = wid.flatMap { store.workspace($0)?.name }.map { L(" en \($0)", " in \($0)") } ?? ""
            reply(L("Espacio \(name)\(where_).", "Space \(name)\(where_)."), lang)
        case .list(let kind):
            reply(listText(kind, lang), lang)
        case .didYouMean(let heard, let options):
            guard !options.isEmpty else {
                reply(L("No encontré «\(heard)». Di «lista los espacios» o «lista los proyectos» para oír los nombres.",
                        "I couldn't find “\(heard)”. Say “list the spaces” or “list the projects” to hear the names."), lang)
                return
            }
            pendingChoice = (heard, options, lang)
            let names = options.map { placeLabel($0, lang) }
            if names.count == 1 {
                reply(L("¿Quisiste decir \(names[0])?", "Did you mean \(names[0])?"), lang)
            } else {
                let list = names.dropLast().joined(separator: ", ") + L(" o ", " or ") + names[names.count - 1]
                reply(L("¿Cuál? \(list).", "Which one? \(list)."), lang)
            }
        case .agentsView:
            if let nav, nav.settingsOpen, let panel { nav.closeSettings(panel: panel) }
            nav?.switchMode(.agents)
            reply(L("Vista de agentes.", "Agents view."), lang)
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
        case .controlPanes(let target, let settings):
            controlPanes(target: target, settings: settings, lang: lang)
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
            reply(useAI ? L("No entendí. Di ayuda para ver lo que puedo hacer.", "I didn't get that. Say help to hear what I can do.")
                        : L("Eso no es un comando que conozca, y la IA del Assistant está apagada. Actívala en Ajustes, Assistant, para que pueda responder cualquier cosa.",
                            "That's not a command I know, and the Assistant's AI is off. Turn it on in Settings, Assistant, so I can answer anything."), lang)
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

    /// Validate the entire request before touching any session. The existing Store controls own restarts.
    private func controlPanes(target: String, settings: String?, lang: AssistantLang) {
        guard let store else { return }
        func L(_ es: String, _ en: String) -> String { lang == .es ? es : en }
        let panes = paneList().compactMap { item -> AssistantCommands.ControlPane? in
            guard let (space, pane) = store.pane(item.ref.paneID, in: item.ref.workspaceID),
                  pane.tool == .claude || pane.tool == .codex, !pane.isAgentPane else { return nil }
            return .init(ref: item.ref, title: item.title, tool: pane.tool,
                         inCurrentSpace: space.id == store.selectedSpace?.id)
        }
        let focused = store.selectedWorkspace.flatMap { w in
            store.selectedSpace?.focusedPaneID.map { Store.PaneRef(workspaceID: w.id, paneID: $0) }
        }
        let refs = AssistantCommands.controlTargets(target, panes: panes, focused: focused, last: lastOpened)
        guard !refs.isEmpty, refs.allSatisfy({ r in panes.contains { $0.ref == r } }) else {
            reply(L("No encontré un panel único. Di su nombre exacto, el panel actual o todos los Claude o Codex de este espacio.",
                    "I couldn't identify the panes. Say an exact pane name, the focused pane, or all Claude or Codex panes in this space."), lang)
            return
        }
        var updates: [(Store.PaneRef, LaunchOptions)] = []
        if let settings {
            for ref in refs {
                guard let (_, pane) = store.pane(ref.paneID, in: ref.workspaceID) else { return }
                let current = LaunchCatalog.explicit(pane.launchOptions, tool: pane.tool, settings: store.settings)
                // First parse against every possible effort, then check the selected model's supported levels.
                guard var options = AssistantCommands.controlOptions(settings,
                    choices: LaunchCatalog.modelChoices(for: pane.tool, settings: store.settings),
                    efforts: ["minimal", "low", "medium", "high", "xhigh", "max"], current: current) else {
                    reply(L("Modelo o esfuerzo no reconocido para \(store.paneTitle(pane)). No cambié ningún panel.",
                            "Unrecognized model or effort for \(store.paneTitle(pane)). No panes were changed."), lang); return
                }
                let allowed = LaunchCatalog.efforts(for: pane.tool, model: options.model, settings: store.settings)
                if let e = options.effort, !allowed.contains(e) {
                    // A model-only change follows the composer's fallback for an incompatible inherited effort.
                    let explicitEffort = AssistantCommands.effort(in: AssistantCommands.normalize(settings), allowed: [])
                    guard explicitEffort == nil else {
                        reply(L("Ese modelo no admite ese esfuerzo. No cambié ningún panel.",
                                "That model doesn't support that effort. No panes were changed."), lang); return
                    }
                    options.effort = allowed.contains("medium") ? "medium" : allowed.first
                }
                updates.append((ref, options))
            }
        }
        if settings == nil {
            refs.forEach { store.closePane($0.paneID, in: $0.workspaceID) }
            lastOpened.removeAll { refs.contains($0) }
            reply(L("Cerré \(refs.count) paneles.", "Closed \(refs.count) panes."), lang)
        } else {
            var applied = 0
            for (ref, options) in updates {
                store.setLaunchOptions(options, pane: ref.paneID, in: ref.workspaceID)
                if store.pane(ref.paneID, in: ref.workspaceID)?.1.launchOptions == options { applied += 1 }
            }
            reply(L("Configuración aplicada en \(applied) de \(refs.count) paneles.",
                    "Settings applied to \(applied) of \(refs.count) panes."), lang)
        }
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
            + "\n\nRecent conversation:\n" + log.filter { !$0.notice && !$0.provisional }.suffix(7).dropLast()
                .map { ($0.fromUser ? "User: " : "Assistant: ") + $0.text }.joined(separator: "\n")
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
                // A short spoken apology (silence would leave you wondering); the details are shown.
                self.notice((lang == .es ? "La IA no respondió: " : "The AI didn't answer: ") + error.localizedDescription)
                self.reply(lang == .es ? "No pude responder ahora. Inténtalo otra vez." : "I couldn't answer that right now. Try again.", lang)
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
        Diagnostics.log("assistant: AI answered \"\(plan.say.prefix(140))\"\(plan.actions.isEmpty ? "" : " + \(plan.actions.map(\.kind).joined(separator: ", "))")")
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
        case "goto_space":
            if let n = a.n { intent = .gotoSpace(n) }
            else if let name = a.space {
                // The named workspace's spaces, else the open one's, else any workspace's.
                let ws = store.state.workspaces.filter { !$0.agentHost }
                let named = a.workspace.flatMap { n in
                    AssistantCommands.bestNames(in: AssistantCommands.normalize(n), ws.map { (key: $0.id, names: [$0.name]) }).first
                }
                let order = ws.filter { $0.id == named } + ws.filter { $0.id == store.selectedWorkspace?.id && $0.id != named }
                    + ws.filter { $0.id != named && $0.id != store.selectedWorkspace?.id }
                intent = order.lazy.compactMap { w -> AssistantIntent? in
                    guard let id = AssistantCommands.bestNames(in: AssistantCommands.normalize(name), w.spaces.map { (key: $0.id, names: [$0.name]) }).first,
                          let sp = w.spaces.first(where: { $0.id == id }) else { return nil }
                    return .selectSpace(id: sp.id, name: sp.name, workspaceID: w.id)
                }.first
            }
            else { intent = nil }
        case "open_workspace":
            let ws = store.state.workspaces.filter { !$0.agentHost }
            intent = (a.workspace ?? a.project).flatMap { n in
                AssistantCommands.bestNames(in: AssistantCommands.normalize(n), ws.map { (key: $0.id, names: [$0.name]) }).first
            }.flatMap { id in ws.first { $0.id == id } }.map { .openWorkspace(id: $0.id, name: $0.name) }
                ?? project.map { .openProject($0) }
        case "agents_view": intent = .agentsView
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
        case "close_pane", "configure_pane":
            guard let target = a.pane?.nonEmpty else { return }
            if a.kind == "configure_pane" {
                let settings = [a.model, a.effort].compactMap { $0?.nonEmpty }.joined(separator: " ")
                guard !settings.isEmpty else { return }
                // Always report the actual result, including invalid settings or cancelled restarts.
                perform(.controlPanes(target: target, settings: settings), lang: lang)
            } else {
                perform(.controlPanes(target: target, settings: nil), lang: lang)
            }
            return
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
        Diagnostics.log("assistant: replied \"\(text.prefix(140))\"")
        log.append(Entry(fromUser: false, text: text))
        trimLog()
        lastReply = (text, lang)
        if speak && speakReplies && !suppressSpeech { say(text, lang) } else { settle() }
    }

    /// Something went wrong (no mic, the AI failed): shown, not spoken.
    private func notice(_ text: String) {
        Diagnostics.log("assistant: notice \"\(text.prefix(140))\"")
        log.append(Entry(fromUser: false, text: text, notice: true))
        trimLog()
    }

    private func trimLog() {
        if log.count > 80 { log.removeFirst(log.count - 80) }
    }

    func say(_ text: String, _ lang: AssistantLang) {
        let clean = AssistantCommands.spoken(text, limit: 600)
        guard !clean.isEmpty else { settle(); return }
        wakeListener.pause()
        if isListening {
            // Something to report (an agent finished…) while you have the floor. If you're talking it stays in the
            // conversation unspoken; otherwise answer first (the turn would only hear it) and listen again after.
            if vad.heardSpeech || !liveText.isEmpty { return }
            abortTurn()
        }
        if orb.phase != .speaking {
            // A new answer: learn its echo afresh, starting from what the last one taught.
            bargeDetector = AssistantBargeIn(coupling: bargeDetector.coupling)
            if conversation && bargeIn, interrupt == .none { interrupt = .watching }
            startSpeakingMeter()
        }
        orb.phase = .speaking
        spokenTurn += " " + clean
        let v = voice(lang)
        let rate = min(AVSpeechUtteranceMaximumSpeechRate, Float(Double(AVSpeechUtteranceDefaultSpeechRate) * speechSpeed))
        // Sentence by sentence: the first one starts playing while the rest are still being rendered.
        for s in Self.sentences(clean) { speaker.speak(s, voice: v, rate: rate) }
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            current.append(c)
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            if ".!?…".contains(c), next.isWhitespace, current.trimmingCharacters(in: .whitespaces).count >= 12 {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    func stopSpeaking() {
        speaker.stop()
        stopSpeakingMeter()
        if orb.phase == .speaking { orb.phase = streaming ? .thinking : .idle }
        if case .suspected = interrupt { dismissInterruption() }
        settle()
    }

    /// Everything queued has been played.
    private func speechFinished() {
        stopSpeakingMeter()
        if case .suspected = interrupt {
            // You started talking just as it finished: that's your turn (if anything shows it was you).
            if suspectLoud >= 0.15 || AssistantBargeIn.newWords(liveText, spoken: spokenTurn) >= 1 {
                confirmInterruption(why: "talking as it finished")
                return
            }
            dismissInterruption()
        }
        // Between streamed sentences the answer may still be coming: back to "Thinking" until the next one.
        if orb.phase == .speaking { orb.phase = streaming ? .thinking : .idle }
        settle()
    }

    /// The orb follows the voice while it speaks.
    private func startSpeakingMeter() {
        guard speakingMeter == nil else { return }
        speakingMeter = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.orb.phase == .speaking else { self.stopSpeakingMeter(); return }
                self.orb.push(self.speaker.currentLevel())
            }
        }
    }

    private func stopSpeakingMeter() {
        speakingMeter?.invalidate()
        speakingMeter = nil
    }

    func clear() { log.removeAll(); lastReply = nil; pendingAgent = nil; pendingChoice = nil; liveUserEntryID = nil; lastHeard = nil }

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

    /// A voice's name as people know it: Siri voices are listed as "Voz 2" / "Voice 4", their real name is in the id.
    static func displayName(_ v: AVSpeechSynthesisVoice) -> String {
        let id = v.identifier
        if id.lowercased().contains("siri"), let last = id.split(separator: ".").last, last.first?.isLetter == true {
            return String(last)
        }
        return v.name
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

    /// Once: a basic (compact) voice chosen while a natural one is installed goes back to "most natural".
    private func upgradeBasicVoices() {
        guard d.object(forKey: "assistant.voiceUpgrade1") == nil else { return }
        d.set(true, forKey: "assistant.voiceUpgrade1")
        for lang in [AssistantLang.es, .en] {
            let chosen = lang == .es ? voiceES : voiceEN
            guard !chosen.isEmpty, let best = availableVoices(lang).first, Self.naturalness(best) >= 20,
                  let current = availableVoices(lang).first(where: { $0.identifier == chosen }),
                  Self.naturalness(current) < 20 else { continue }
            Diagnostics.log("assistant: \(lang.rawValue) voice \(current.identifier) → most natural installed (\(best.identifier))")
            if lang == .es { voiceES = "" } else { voiceEN = "" }
        }
    }

    func preview(_ lang: AssistantLang) {
        speaker.stop()
        voiceLists[lang] = nil
        say(lang == .es ? "Hola, así sueno. ¿En qué te ayudo con ProjectN?" : "Hi, this is how I sound. How can I help with ProjectN?", lang)
    }

    func refreshVoices() { voiceLists.removeAll(); prewarmVoices() }
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
    static let calibration: TimeInterval = 0.2
    private var began: Date?
    private var calibrating: [(level: Float, at: Date)] = []
    private var calibrated = false
    private var floor: Float = 0
    private var loudRun = 0
    private(set) var heardSpeech = false
    private var lastLoud = Date.distantPast

    init() {}

    var noiseFloor: Float { floor }

    /// A changing live transcript confirms speech even when a quiet voice falls below the volume gate.
    mutating func recognizedSpeech(now: Date = Date()) {
        heardSpeech = true
        lastLoud = now
    }

    /// Listening picks up mid-sentence (you interrupted an answer): already speaking, in a room at `floor`.
    mutating func startSpeaking(floor f: Float, now: Date = Date()) {
        began = now
        calibrating = []
        calibrated = true
        floor = f
        heardSpeech = true
        lastLoud = now
    }

    /// Speech starts above this…
    private var startLevel: Float { max(0.18, floor + 0.1) }
    /// …and goes on while above this.
    private var keepLevel: Float { max(0.12, floor + 0.06) }

    mutating func push(_ level: Float, now: Date = Date()) -> Result {
        if began == nil { began = now }
        let t = now.timeIntervalSince(began!)
        if !calibrated {
            calibrating.append((level, now))
            guard t >= Self.calibration else { return .listening }
            // The quiet moments are the room: even someone who starts talking at once pauses between syllables.
            // A low percentile, not the minimum: the first buffers of a starting mic can be pure silence.
            let sorted = calibrating.map(\.level).sorted()
            // Even a short calibration must ignore the input unit's first zero buffer.
            floor = sorted[min(sorted.count - 1, max(1, sorted.count / 5))]
            calibrated = true
            for s in calibrating.dropLast() { loudness(s.level, at: s.at, learnFloor: false) }
            calibrating = []
        }
        loudness(level, at: now)
        if t > maxLength { return heardSpeech ? .endOfSpeech : .nothingSaid }
        if heardSpeech { return now.timeIntervalSince(lastLoud) > silenceToEnd ? .endOfSpeech : .listening }
        return t > giveUpAfter ? .nothingSaid : .listening
    }

    private mutating func loudness(_ level: Float, at now: Date, learnFloor: Bool = true) {
        if level > (heardSpeech ? keepLevel : startLevel) {
            loudRun += 1
            if loudRun >= 2 { heardSpeech = true }       // two buffers in a row (~40 ms): not a click
            if heardSpeech { lastLoud = now }
        } else {
            loudRun = 0
            // Before you speak, follow the room: down quickly, up slowly.
            if !heardSpeech, learnFloor { floor += (level - floor) * (level < floor ? 0.3 : 0.02) }
        }
    }
}

extension AssistantVAD {
    /// How long a pause ends your turn, given what has been recognized so far: a finished sentence ends it sooner,
    /// a trailing "y", "que", "and", "the"… (you're still going) gives you a moment more.
    static func endpoint(after text: String, base: Double) -> Double {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return base }
        let words = t.folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if "?!".contains(last) || (last == "." && words.count >= 2) { return max(0.55, base * 0.7) }
        if let w = words.last, hangingWords.contains(String(w)) { return base + 0.7 }
        return base
    }

    private static let hangingWords: Set<String> = [
        "y", "e", "o", "u", "ni", "que", "de", "del", "la", "el", "los", "las", "un", "una", "en", "con", "para", "por",
        "a", "al", "pero", "como", "si", "mi", "tu", "su", "le", "les", "lo", "sin", "sobre", "entre", "hasta", "cuando",
        "and", "or", "the", "an", "to", "of", "in", "on", "at", "with", "for", "but", "that", "so", "if", "my", "your",
        "their", "its", "from", "into", "about", "then", "because", "when",
    ]
}

/// Notices you talking over the Assistant's answer (or, while it thinks, going on with what you were saying).
/// The mic also hears the answer through the speakers. `AssistantSpeaker` reports how loud the answer was over the
/// stretch each mic level covers (`ref`); this learns how much of that reaches the mic (it depends on the volume, the
/// room and the mic) and fires on clearly more than that — a voice on top of the echo — in two levels in a row.
/// With headphones nothing reaches the mic, so it learns that and any speech counts.
/// Tuned on recordings of a MacBook's own speakers and mic: no false alarms over a whole answer, and a second voice
/// at the same loudness as the answer noticed within ~0.4 s (someone talking near the mic is louder, so sooner).
struct AssistantBargeIn {
    /// The first moments of an answer only teach the echo.
    static let settle: TimeInterval = 0.2
    /// How long the echo is learned at the start of an answer (unless an earlier answer already taught it).
    static let learning: TimeInterval = 1.5
    /// The echo estimate is this high a percentile of (mic − ref): above most of the answer's own sound.
    static let percentile: Float = 0.85
    var minLevel: Float = 0.2
    var margin: Float = 0.1
    var holdFor: TimeInterval = 0.08
    private var began: Date?
    private var learnStart: Date?
    private var residuals: [Float] = []
    /// mic − reference while only the answer is heard (nil until learned).
    private(set) var coupling: Float?
    private let knownCoupling: Bool
    /// The room's background level.
    private(set) var room: Float = 1
    private var loudSince: Date?
    private var lastLoud: Date?
    /// The last level pushed was above what the answer alone would explain.
    private(set) var loudNow = false

    /// `coupling`: what an earlier answer in this conversation taught (same room, same volume).
    init(coupling: Float? = nil) {
        self.coupling = coupling
        knownCoupling = coupling != nil
    }

    /// What the mic would hear if you were silent (nil: the echo isn't known yet).
    func expected(ref: Float) -> Float? {
        guard ref > 0.05 else { return room + 0.08 }
        guard let coupling else { return nil }
        return max(room + 0.08, ref + coupling)
    }

    /// True once you're talking over it.
    mutating func push(mic m: Float, ref r: Float, now: Date = Date()) -> Bool {
        if began == nil { began = now; room = m }
        let t = now.timeIntervalSince(began!)
        // The room: follows quiet moments at once, louder ones only slowly.
        room += (m - room) * (m < room ? 0.5 : 0.01)
        if r > 0.1, learnStart == nil { learnStart = now }
        let learningNow = !knownCoupling && learnStart.map { now.timeIntervalSince($0) < Self.learning } == true
        let expect = expected(ref: r)
        loudNow = t >= Self.settle && expect.map { m > max(minLevel, $0 + margin) } == true
        if r > 0.1 {
            let d = m - r
            if learningNow {
                // At the start of the answer: everything heard is the answer.
                residuals.append(d)
                if residuals.count >= 4 {
                    let sorted = residuals.sorted()
                    coupling = sorted[min(sorted.count - 1, Int(Float(sorted.count) * Self.percentile))]
                }
            } else if !loudNow, let c = coupling {
                // Later, keep following it slowly, never from moments that may be you.
                coupling = c + 0.02 * (d > c ? Self.percentile : -(1 - Self.percentile))
            }
        }
        // A new sound after a gap must earn its own hold time; stale candidates cannot interrupt.
        if let ll = lastLoud, now.timeIntervalSince(ll) > 0.3 { loudSince = nil; lastLoud = nil }
        guard loudNow else { return false }
        if loudSince == nil { loudSince = now }
        lastLoud = now
        return now.timeIntervalSince(loudSince!) >= holdFor
    }

    /// The start of a turn that interrupted an answer may be the answer itself, heard through the speakers:
    /// Drop only a contiguous phrase from the answer. Sharing unrelated words with the answer isn't echo.
    static func stripEcho(_ heard: String, spoken: String) -> String {
        func norm(_ w: Substring) -> String { String(w).folded.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
        let said = spoken.split(whereSeparator: \.isWhitespace).map(norm).filter { !$0.isEmpty }
        let words = heard.split(whereSeparator: \.isWhitespace)
        let normalized = words.map(norm)
        var matched = 0
        for start in said.indices {
            var count = 0
            while count < words.count, start + count < said.count, normalized[count] == said[start + count] { count += 1 }
            matched = max(matched, count)
        }
        guard matched >= 2 else { return heard }
        return words.dropFirst(matched).joined(separator: " ")
    }

    /// A quiet explicit interruption is also recognized from live text. Words in our own answer cannot fire it.
    static func isStopRequest(_ heard: String, spoken: String) -> Bool {
        let stops: Set<String> = ["stop", "wait", "quiet", "silence", "espera", "detente", "para", "callate", "silencio"]
        let remaining = words(stripEcho(heard, spoken: spoken))
        let said = Set(words(spoken))
        return remaining.suffix(3).contains { stops.contains($0) && !said.contains($0) }
    }

    /// Words heard that the answer doesn't contain (so they can't be its echo). One-letter words don't count.
    static func newWords(_ heard: String, spoken: String) -> Int {
        let said = Set(words(spoken))
        return words(stripEcho(heard, spoken: spoken)).filter { $0.count > 1 && !said.contains($0) }.count
    }

    private static func words(_ text: String) -> [String] {
        text.folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}


/// Collects audio delivered on the audio queue.
private final class SampleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float] = []
    func append(_ s: [Float]) { lock.withLock { storage += s } }
    var samples: [Float] { lock.withLock { storage } }
}
