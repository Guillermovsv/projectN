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
    /// In conversation mode the mic stays open while it answers: start talking and it stops to listen to you.
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
    private var wakeSamples: [[Float]] = []
    static let wakeSamplesNeeded = 3
    private static let wakeSamplesKept = 6

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
    /// The mic is open during an answer, only to notice you talking over it.
    private var watchingBargeIn = false
    private var bargeDetector = AssistantBargeIn()
    /// Everything spoken for the current request: the start of a turn that interrupted it may still carry it (echo).
    private var spokenTurn = ""
    /// This turn began by interrupting an answer: what was being said, to remove from the transcript.
    private var echoText: String?
    private let wakeListener = AssistantWakeListener()
    private var wakeCapture = false
    private var lastPartial = ""

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
        bargeIn = d.object(forKey: "assistant.bargeIn") as? Bool ?? true
        wakeWordEnabled = d.object(forKey: "assistant.wakeWord") as? Bool ?? true
        wakeSensitivity = WakeWordDetector.Sensitivity(rawValue: d.string(forKey: "assistant.wakeSensitivity") ?? "") ?? .normal
        super.init()
        synth.delegate = self
    }

    func attach(store: Store, harness: AgentHarness, panel: RightPanelModel, nav: NavigationModel) {
        self.store = store; self.harness = harness; self.panel = panel; self.nav = nav
        harness.observe("assistant") { [weak self] task, event in self?.taskEvent(task, event) }
        configureWakeListening()
    }

    private func configureWakeListening() {
        // Unit tests must never request permission or activate a microphone.
        guard !AppHome.isTestProcess else { return }
        wakeListener.canListen = { [weak self] in
            guard let self else { return false }
            return self.orb.phase == .idle && !self.micOpen && !self.streaming && !self.transcribing
                && !self.isSpeaking && (!self.conversation || !self.handsFree) && !self.recordingWakeSample
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
        NVoiceController.shared.onDictationWillStart = { [weak self] in self?.wakeListener.pause() }
        updateWakeListening()
    }

    private func updateWakeListening() {
        guard store != nil, !AppHome.isTestProcess else { return }
        wakeListener.setEnabled(wakeWordEnabled)
    }

    // MARK: Your “Hey N” recordings

    /// Records one sample of you saying “Hey N” (2.5 s window, trimmed to the speech in it).
    func recordWakeSample() {
        guard !recordingWakeSample, !AppHome.isTestProcess else { return }
        guard orb.phase == .idle, !micOpen else {
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

    /// Adopt the wake recording, including any prompt spoken immediately after “Hey N”.
    private func wokeUp(prompt: String, floor: Float) {
        Diagnostics.log("assistant: woke on Hey N")
        relisten?.cancel()
        listenGen += 1
        let gen = listenGen
        micOpen = true
        wakeCapture = true
        conversation = true
        emptyTurns = 0
        echoText = nil
        lastPartial = ""
        vad = AssistantVAD()
        vad.silenceToEnd = silenceSeconds
        vad.giveUpAfter = 12
        if !prompt.isEmpty { vad.startSpeaking(floor: min(floor, 0.2)) }
        lastLevelAt = Date()
        orb.phase = .listening
        NVoiceController.shared.assistantSetLevelHandler { [weak self] in self?.heard(level: $0, gen: gen) }
        NVoiceController.shared.assistantSetTranscriptHandler { [weak self] in self?.heardPartial($0, gen: gen) }
        if floating {
            FloatingAssistant.shared.show()
        } else {
            panel?.show(.assistant)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Listening

    var isListening: Bool { orb.phase == .listening }

    /// Click on the orb / ⌥⌘A: start talking when it's idle; otherwise stop everything (listening, thinking, speaking).
    /// While it's answering, a click cuts the answer short and listens to you instead.
    func toggleListening() {
        switch orb.phase {
        case .idle: startListening()
        case .speaking:
            Diagnostics.log("assistant: answer cut short (click)")
            startListening()
        case .listening, .thinking: stopAll(reason: "click")
        }
    }

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
            self.stopAll(reason: "hidden")
        }
    }

    func stopAll(reason: String? = nil) {
        if let reason, orb.phase != .idle { Diagnostics.log("assistant: stopped (\(reason))") }
        conversation = false
        wakeListener.pause()
        watchingBargeIn = false
        echoText = nil
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
        wakeListener.pause()
        wakeCapture = false
        lastPartial = ""
        relisten?.cancel()
        echoText = nil
        if watchingBargeIn { watchingBargeIn = false; endTurn() }
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
                try await NVoiceController.shared.assistantStart(vocabulary: self.vocabulary(),
                    onTranscript: { [weak self] in self?.heardPartial($0, gen: gen) },
                    shouldStart: { [weak self] in self?.listenGen == gen && self?.isListening == true }
                ) { [weak self] l in self?.heard(level: l, gen: gen) }
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

    /// What you're likely to name, so speech recognition gets it right: "Claude" instead of "cloud",
    /// "Solar Devs" instead of "solar debs".
    func vocabulary() -> [String] {
        var out = ["Claude", "Claude Code", "Codex", "Cursor", "Opus", "Sonnet", "Haiku", "Fable", "terminal", "ProjectN", "NVoice"]
        guard let store else { return out }
        out += store.state.projects.map(\.name)
        out += store.state.workspaces.filter { !$0.agentHost }.map(\.name)
        out += (store.selectedWorkspace?.spaces ?? []).map(\.name).filter { !$0.hasPrefix("Space ") }
        out += (harness?.profiles ?? []).filter(\.enabled).map(\.name)
        out += paneList().map(\.title)
        var seen = Set<String>()
        return out.filter { !$0.isEmpty && seen.insert($0.folded).inserted }
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
        wakeCapture = false
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

    private func heardPartial(_ text: String, gen: Int) {
        guard gen == listenGen else { return }
        if watchingBargeIn {
            if bargeIn, AssistantBargeIn.isStopRequest(text, spoken: spokenTurn) { bargedIn() }
            return
        }
        guard isListening else { return }
        // The wake phrase isn't the prompt. Wait for the user even if they pause after saying the name.
        let speech = wakeCapture ? (AssistantWakeCommand.prompt(in: text) ?? "") : text
        let key = speech.folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        guard !key.isEmpty, key != lastPartial else { return }
        lastPartial = key
        vad.recognizedSpeech()
    }

    /// You finished talking (pause, or a click): transcribe and answer.
    func stopListening() {
        guard isListening else { return }
        orb.phase = .thinking
        transcribing = true
        let gen = listenGen
        let fromWake = wakeCapture
        let echo = echoText
        wakeCapture = false
        echoText = nil
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
                let r = try await Self.within(12) {
                    try await NVoiceController.shared.assistantStop { raw in
                        var text = fromWake ? (AssistantWakeCommand.prompt(in: raw) ?? "") : raw
                        if let echo {
                            let clean = AssistantBargeIn.stripEcho(text, spoken: echo)
                            if clean != text { Diagnostics.log("assistant: removed its own voice from the start of what it heard") }
                            text = clean
                        }
                        return text
                    }
                }
                guard gen == self.listenGen else { return }
                self.transcribing = false
                let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                Diagnostics.log(String(format: "assistant: heard \"%@\" (transcribed in %.1f s)", String(text.prefix(140)), Date().timeIntervalSince(t0)))
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
        // The answer is over: the mic that was waiting for an interruption closes (a fresh turn opens below).
        if watchingBargeIn { watchingBargeIn = false; endTurn() }
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
            agents: harness.profiles,
            panes: paneList(),
            lastOpened: lastOpened,
            models: models,
            efforts: [.claude: LaunchCatalog.claudeEfforts,
                      .codex: LaunchCatalog.efforts(for: .codex, model: nil, settings: store.settings)])
        let intent = AssistantCommands.parse(text, ctx)
        let kind = Mirror(reflecting: intent).children.first?.label ?? "\(intent)"
        Diagnostics.log("assistant: request → \(kind == "unknown" ? (useAI ? "AI (\(aiProvider.rawValue) \(aiModel))" : "not a command, AI is OFF") : kind)")
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
            reply(L("Puedo abrir proyectos y espacios, abrir varios paneles de Claude, Codex, Cursor o terminal con el modelo y el esfuerzo que digas y con un prompt para empezar, cerrar paneles abiertos o cambiar su modelo y esfuerzo, mandarles prompts, pedirle trabajo a tus agentes y decirte qué está corriendo. Por ejemplo: abre tres Claude en Opus 5.5 low que revisen el login; dile a Ada que corra los tests.",
                    "I can open projects and spaces, open several Claude, Codex, Cursor or terminal panes with the model and effort you say and a prompt to start on, close open panes or change their model and effort, send them prompts, hand work to your agents and tell you what's running. Try: open three Claude in Opus 5.5 low to review the login; tell Ada to run the tests."), lang)
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
        case .selectSpace(let id, let name):
            showWorkspaces()
            guard let w = store.selectedWorkspace else { return }
            store.selectSpace(id, in: w.id)
            reply(L("Espacio \(name).", "Space \(name)."), lang)
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
            else if let name = a.space, let w = store.selectedWorkspace,
                    let id = AssistantCommands.bestNames(in: AssistantCommands.normalize(name), w.spaces.map { (key: $0.id, names: [$0.name]) }).first,
                    let sp = w.spaces.first(where: { $0.id == id }) { intent = .selectSpace(id: sp.id, name: sp.name) }
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
        if log.count > 80 { log.removeFirst(log.count - 80) }
        lastReply = (text, lang)
        if speak && speakReplies && !suppressSpeech { say(text, lang) } else { settle() }
    }

    func say(_ text: String, _ lang: AssistantLang) {
        let clean = AssistantCommands.spoken(text, limit: 600)
        guard !clean.isEmpty else { settle(); return }
        wakeListener.pause()
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
        spokenTurn += " " + clean
        synth.speak(u)
        watchSpeech()
        watchForBargeIn()
    }

    // MARK: Interrupting

    /// While it answers in a conversation, keep the mic open: talking over the answer stops it and becomes your turn.
    private func watchForBargeIn() {
        guard bargeIn, !watchingBargeIn, !isListening, !transcribing else { return }
        watchingBargeIn = true
        bargeDetector = AssistantBargeIn()
        listenGen += 1
        let gen = listenGen
        micOp { [weak self] in
            guard let self, gen == self.listenGen, self.watchingBargeIn else { return }
            do {
                try await NVoiceController.shared.assistantStart(vocabulary: self.vocabulary(),
                    onTranscript: { [weak self] in self?.heardPartial($0, gen: gen) },
                    shouldStart: { [weak self] in self?.listenGen == gen && self?.watchingBargeIn == true }
                ) { [weak self] l in self?.micLevel(l, gen: gen) }
                self.micOpen = true
            } catch {
                Diagnostics.log("assistant: can't listen for interruptions — \(error.localizedDescription)")
                if gen == self.listenGen { self.watchingBargeIn = false }
                return
            }
            // The answer ended (or was stopped) while the mic was starting.
            guard gen == self.listenGen, self.watchingBargeIn || self.isListening else { self.closeMic(); return }
        }
    }

    private func micLevel(_ l: Float, gen: Int) {
        guard gen == listenGen else { return }
        guard watchingBargeIn else { heard(level: l, gen: gen); return }
        if bargeIn, bargeDetector.push(l) { bargedIn() }
    }

    /// You started talking over the answer: it stops, and the recording already running becomes your turn
    /// (so your first words aren't lost).
    private func bargedIn() {
        Diagnostics.log("assistant: interrupted — you talked over the answer")
        watchingBargeIn = false
        wakeCapture = false
        lastPartial = ""
        echoText = spokenTurn
        relisten?.cancel()
        stopSpeaking()
        cancelAI()
        conversation = true
        emptyTurns = 0
        let room = min(vad.noiseFloor, bargeDetector.quiet)
        vad = AssistantVAD()
        vad.silenceToEnd = silenceSeconds
        vad.startSpeaking(floor: room)
        lastLevelAt = Date()
        orb.phase = .listening
    }

    private var isSpeaking: Bool { !queued.isEmpty }

    func stopSpeaking() {
        queued.removeAll()
        speechCheck?.cancel()
        // isSpeaking can lag while an utterance is queued: always cancel pending playback as well.
        synth.stopSpeaking(at: .immediate)
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

/// Notices you talking over the Assistant's answer. The mic also hears the answer itself from the speakers, so it
/// follows that echo and only fires on something clearly louder that lasts (a word, not a cough or a click).
/// With headphones there is no echo and any speech counts.
struct AssistantBargeIn {
    /// The very start of the answer is ignored: the mic may still carry the end of your last sentence.
    static let settle: TimeInterval = 0.15
    var minLevel: Float = 0.18
    var margin: Float = 0.1
    var holdFor: TimeInterval = 0.12
    private var began: Date?
    /// What the speakers put into the mic: follows peaks quickly, decays slowly.
    private(set) var echo: Float = 0
    private var loudSince: Date?
    private var lastLoud: Date?
    /// The quietest level seen (the room).
    private(set) var quiet: Float = 1

    init() {}

    /// True once you're talking over the answer.
    mutating func push(_ l: Float, now: Date = Date()) -> Bool {
        if began == nil {
            began = now
            echo = l
        }
        quiet = min(quiet, l)
        let t = now.timeIntervalSince(began!)
        // A new sound after a gap must earn its own hold time; stale candidates cannot interrupt.
        if let ll = lastLoud, now.timeIntervalSince(ll) > 0.3 { loudSince = nil; lastLoud = nil }
        if t >= Self.settle, l > max(minLevel, echo + margin) {
            if loudSince == nil { loudSince = now }
            lastLoud = now
            return now.timeIntervalSince(loudSince!) >= holdFor
        }
        // Short dips between syllables don't restart the count.
        if loudSince == nil { echo += (l - echo) * (l > echo ? 0.5 : 0.04) }
        return false
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
        func words(_ text: String) -> [String] {
            text.folded.split(whereSeparator: { !$0.isLetter }).map(String.init)
        }
        let remaining = words(stripEcho(heard, spoken: spoken))
        let said = Set(words(spoken))
        return remaining.suffix(3).contains { stops.contains($0) && !said.contains($0) }
    }
}


/// Collects audio delivered on the audio queue.
private final class SampleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float] = []
    func append(_ s: [Float]) { lock.withLock { storage += s } }
    var samples: [Float] { lock.withLock { storage } }
}
