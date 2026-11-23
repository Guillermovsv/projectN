import AVFoundation
import CoreAudio
import Speech
import NaturalLanguage
import ObjCSupport

enum TranscriberError: LocalizedError {
    case unsupportedLocale(String)
    case noAudioFormat
    case micDenied
    case micUnavailable(String)
    case audioSystemStuck
    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let l): return "On-device dictation does not support “\(l)”."
        case .noAudioFormat: return "Could not find a compatible audio format."
        case .micDenied: return "Microphone access is denied. Enable it in System Settings › Privacy & Security › Microphone."
        case .micUnavailable(let why): return "Microphone not ready — try again. (\(why))"
        case .audioSystemStuck: return "macOS audio isn't responding. NVoice menu › Restart Audio System…"
        }
    }
}

/// Records from the default mic and transcribes on-device with Apple's DictationTranscriber (macOS 26+).
final class Transcriber {
    /// 0…1 audio level, called on the main thread ~10–20×/s while recording.
    var onLevel: ((Float) -> Void)?
    /// The same level with how long ago (seconds) the end of the audio it measures was captured: the main thread
    /// can deliver it late, and the Assistant lines it up with what its speaker was playing at that moment.
    var onLevelAge: ((Float, TimeInterval) -> Void)?
    /// Status messages while downloading speech models.
    var onStatus: ((String) -> Void)?

    /// Which mic to record from (nil = system default). Called on a background queue.
    var inputDeviceProvider: () -> AudioInputDevice? = { nil }

    /// A ready-to-record engine. Building one costs ~1.5 s (CoreAudio opens the input unit and, when we switch
    /// away from a Bluetooth mic, reconfigures it), which used to freeze the app on every fn press. So it is
    /// built in the background ahead of time and reused; it is thrown away and rebuilt only when the audio
    /// setup changes (wake/unlock, device plugged in or out, mic setting) — a stale engine is what crashed
    /// after unlocking. A prepared but stopped engine does not open the mic.
    private struct Warm {
        let engine: AVAudioEngine
        let requestedUID: String?     // what was asked for (nil = system default)
        let switched: Bool            // the device switch actually happened
    }
    /// CoreAudio can block forever, so nothing on the main thread waits on it without a limit.
    private static let startTimeout: TimeInterval = 4      // an on-demand build alone can take ~2.5 s
    private static let stopTimeout: TimeInterval = 1.5
    private static let prewarmTimeout: TimeInterval = 15
    private let worker = AudioWorker(label: "dev.projectn.nvoice.audio")
    private let warmLock = NSLock()
    private var warmStorage: Warm?
    private var warm: Warm? {
        get { warmLock.withLock { warmStorage } }
        set { warmLock.withLock { warmStorage = newValue } }
    }
    private var engine: AVAudioEngine?   // the engine of the current dictation (main thread)
    private var rebuildAfterRecording = false
    private var recheckAfterRecording = false
    private var pendingRebuild: (reason: String, force: Bool)?
    private var configObserver: NSObjectProtocol?
    private var rebuildWork: DispatchWorkItem?
    /// Capture health. Bluetooth connecting/disconnecting can leave an engine that starts fine but delivers no audio
    /// (or pure digital silence) — every dictation then ends in “No speech detected”. A watchdog notices within
    /// half a second and moves the recording to a fresh engine. Counters are guarded by `sinkLock`.
    private var buffersSeen = 0
    private var peakSeen: Float = 0
    private var everHeardSound = false
    private var lastCheckedBuffers = 0
    private var captureStart = Date()
    private var watchdog: Timer?
    private var currentTap: AVAudioNodeTapBlock?
    private var recordingID = 0
    private var restarting = false
    private var restarts: [Date] = []
    private var silenceRestarted = false
    static let watchdogInterval: TimeInterval = 0.5
    /// Where the mic tap sends audio for transcription. Nil while only listening for “Hey N” (no transcript);
    /// set when a transcription starts on the open mic. Guarded by `sinkLock`, like the pre-roll.
    private let sinkLock = NSLock()
    private var sinkStorage: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var rawContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation? {
        get { sinkLock.withLock { sinkStorage } }
        set { sinkLock.withLock { sinkStorage = newValue } }
    }
    /// The last ~2 s of mic audio while the mic is open without a transcript (“Hey N” listening, the Assistant between
    /// turns), so a transcription started a moment later still hears the start of what was said.
    private var preroll: [AVAudioPCMBuffer] = []
    private var prerollFrames: AVAudioFramePosition = 0
    private var keepPreroll = false
    static let prerollSeconds = 2.0
    /// Gets 16 kHz mono audio while recording (the “Hey N” matcher). Guarded by `sinkLock`.
    private var monitorStorage: ((AVAudioPCMBuffer) -> Void)?
    private var micFormat: AVAudioFormat?
    private let monitorQueue = DispatchQueue(label: "dev.projectn.nvoice.wake", qos: .userInitiated)
    private var pipelineTask: Task<(String, String), Error>?
    private var startDate: Date?
    private(set) var isRecording = false
    /// Set when CoreAudio refuses to start the mic ('stop') or hangs. Until then `start` fails at once instead of
    /// freezing the app for seconds on every press, and no rebuilds pile up on a dead audio system.
    private(set) var audioStuckUntil: Date?
    static let stuckCooldown: TimeInterval = 15
    var audioSystemStuck: Bool { audioStuckUntil.map { $0 > Date() } ?? false }
    /// Called on the main thread when `audioSystemStuck` changes.
    var onAudioHealthChange: ((Bool) -> Void)?
    private func markAudio(stuck: Bool) {
        let was = audioSystemStuck
        audioStuckUntil = stuck ? Date().addingTimeInterval(Self.stuckCooldown) : nil
        if was != stuck { onAudioHealthChange?(stuck) }
    }
    /// kAudioHardwareNotRunningError ('stop'): the HAL won't run the device — a wedged coreaudiod, not a stale engine.
    static func isHardwareNotRunning(_ error: Error) -> Bool { (error as NSError).code == Int(kAudioHardwareNotRunningError) }

    // MARK: Permissions & models

    static func requestPermissions() async -> Bool {
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        _ = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        return mic
    }

    static func supportedLocales() async -> [Locale] {
        await DictationTranscriber.supportedLocales.sorted { $0.identifier < $1.identifier }
    }

    static func resolveLocale(_ id: String) async throws -> Locale {
        guard let l = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else {
            throw TranscriberError.unsupportedLocale(id)
        }
        return l
    }

    static func makeModule(locale: Locale, liveResults: Bool = false) -> DictationTranscriber {
        DictationTranscriber(locale: locale,
                             contentHints: [],
                             transcriptionOptions: [.punctuation],
                             reportingOptions: liveResults ? [.volatileResults] : [],
                             attributeOptions: [.transcriptionConfidence])
    }

    /// Downloads the on-device speech model for the locale if needed.
    func ensureModel(localeID: String) async throws {
        let locale = try await Self.resolveLocale(localeID)
        let module = Self.makeModule(locale: locale)
        if await AssetInventory.status(forModules: [module]) == .installed { return }
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            await MainActor.run { onStatus?("Downloading speech model for \(locale.identifier)…") }
            try await req.downloadAndInstall()
            await MainActor.run { onStatus?("Speech model ready") }
        }
    }

    // MARK: Recording

    /// Starts recording. With more than one locale (e.g. English + Spanish), every language transcribes the
    /// same audio in parallel and the most confident result wins — automatic language detection per dictation.
    /// `transcribe: false` opens the mic without transcribing (“Hey N” listening, the Assistant's conversation): audio
    /// goes only to `onAudio16k` (16 kHz mono, on a background queue) and the preroll until `beginTranscription`.
    /// `onTranscript` gets live text with the language it was recognized in.
    func start(localeIDs: [String], contextualStrings: [String] = [], inputDevice: AudioInputDevice? = nil,
               transcribe: Bool = true, keepPreroll: Bool = false, onAudio16k: (([Float]) -> Void)? = nil,
               onTranscript: ((String, String) -> Void)? = nil) throws {
        guard !isRecording else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw TranscriberError.micDenied }
        if audioSystemStuck { throw TranscriberError.audioSystemStuck }
        let ids = Self.unique(localeIDs)

        let t0 = Date()
        var rawStream: AsyncStream<AVAudioPCMBuffer>?
        var rawCont: AsyncStream<AVAudioPCMBuffer>.Continuation?
        if transcribe { (rawStream, rawCont) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .unbounded) }
        let monitor = onAudio16k.map { Self.monitor(on: monitorQueue, $0) }
        sinkLock.withLock {
            sinkStorage = rawCont
            self.keepPreroll = keepPreroll || onAudio16k != nil
            preroll = []; prerollFrames = 0
            monitorStorage = monitor
        }

        let tapBlock: AVAudioNodeTapBlock = { [weak self] buffer, when in
            guard let self else { return }
            let peak = Self.peak(of: buffer)
            let copy = buffer.copy() as? AVAudioPCMBuffer
            let monitor = self.sinkLock.withLock { () -> ((AVAudioPCMBuffer) -> Void)? in
                self.buffersSeen += 1
                self.peakSeen = max(self.peakSeen, peak)
                guard let copy else { return nil }
                self.sinkStorage?.yield(copy)
                if self.keepPreroll { self.remember(copy) }
                return self.monitorStorage
            }
            if let copy { monitor?(copy) }
            let level = Self.level(of: buffer)
            let captured: Double? = when.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: when.hostTime) + Double(buffer.frameLength) / buffer.format.sampleRate : nil
            DispatchQueue.main.async {
                self.onLevel?(level)
                if let age = self.onLevelAge {
                    age(level, captured.map { max(0, AVAudioTime.seconds(forHostTime: mach_absolute_time()) - $0) } ?? 0)
                }
            }
        }
        // Fast path: the warm engine (~50 ms). If it turns out stale, rebuild once and retry.
        let outcome = worker.run(timeout: Self.startTimeout, work: { [self] () -> Result<(Warm, AVAudioFormat), Error> in
            var lastError: Error = TranscriberError.micUnavailable("no input format")
            for attempt in 0..<2 {
                guard let w = takeWarm(forceRebuild: attempt > 0) else { continue }
                do { return .success((w, try Self.begin(w, tap: tapBlock))) }
                catch {
                    lastError = error
                    Diagnostics.log("audio start failed (\(attempt == 0 ? "warm engine" : "fresh engine")): \(error.localizedDescription)")
                    // A fresh engine can't fix a HAL that isn't running; retrying only doubles the wait.
                    if Self.isHardwareNotRunning(error) { break }
                }
            }
            return .failure(lastError)
        }, discard: { result in
            // It started after we gave up: never leave the mic open.
            if case .success(let started) = result { Self.end(started.0.engine) }
        })
        let w: Warm, micFormat: AVAudioFormat
        do {
            guard let outcome else {
                Diagnostics.log("audio start timed out — CoreAudio is not responding, moving to a fresh audio queue")
                warm = nil
                markAudio(stuck: true)
                throw TranscriberError.audioSystemStuck
            }
            do { (w, micFormat) = try outcome.get() } catch where Self.isHardwareNotRunning(error) {
                Diagnostics.log("CoreAudio reports the audio hardware is not running — failing fast for \(Int(Self.stuckCooldown)) s")
                warm = nil
                markAudio(stuck: true)
                throw TranscriberError.audioSystemStuck
            }
        } catch {
            rawCont?.finish()
            sinkLock.withLock { sinkStorage = nil; self.keepPreroll = false; preroll = []; prerollFrames = 0; monitorStorage = nil }
            if !audioSystemStuck { prewarm() }   // a build on a dead audio system just hangs another queue
            throw error
        }
        markAudio(stuck: false)
        engine = w.engine
        observeConfiguration(of: w.engine)
        isRecording = true
        startDate = Date()
        recordingID += 1
        currentTap = tapBlock
        restarts = []
        silenceRestarted = false
        everHeardSound = false
        resetCaptureHealth()
        startWatchdog()
        Diagnostics.log(String(format: "recording started in %.0f ms", Date().timeIntervalSince(t0) * 1000))

        self.micFormat = micFormat
        if let rawStream {
            pipelineTask = Self.pipeline(ids: ids, contextualStrings: contextualStrings, micFormat: micFormat,
                                         onTranscript: onTranscript, rawStream)
        }
    }

    /// Starts transcribing on a mic opened with `transcribe: false`, beginning with the last `prerollSeconds` of audio
    /// (at most ~2 s are kept).
    func beginTranscription(localeIDs: [String], contextualStrings: [String] = [], prerollSeconds: Double = prerollSeconds,
                            onTranscript: ((String, String) -> Void)? = nil) {
        guard isRecording, pipelineTask == nil, let micFormat else { return }
        let (rawStream, rawCont) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .unbounded)
        sinkLock.withLock {
            // Only the most recent part: older audio may be something else entirely (the Assistant's own answer).
            var keep: [AVAudioPCMBuffer] = []
            var frames: AVAudioFramePosition = 0
            for b in preroll.reversed() {
                guard Double(frames) < prerollSeconds * b.format.sampleRate else { break }
                keep.append(b)
                frames += AVAudioFramePosition(b.frameLength)
            }
            for b in keep.reversed() { rawCont.yield(b) }
            sinkStorage = rawCont
        }
        startDate = Date()
        pipelineTask = Self.pipeline(ids: Self.unique(localeIDs), contextualStrings: contextualStrings,
                                     micFormat: micFormat, onTranscript: onTranscript, rawStream)
    }

    /// A transcription is running on the open mic.
    var isTranscribing: Bool { pipelineTask != nil }

    /// Drops the transcription started by `beginTranscription`; the mic stays open.
    func endTranscription() {
        guard isRecording, pipelineTask != nil else { return }
        let old = sinkLock.withLock { () -> AsyncStream<AVAudioPCMBuffer>.Continuation? in
            defer { sinkStorage = nil }
            return sinkStorage
        }
        old?.finish()
        pipelineTask?.cancel()
        pipelineTask = nil
    }

    /// Ends the transcription started by `beginTranscription` and returns its text; the mic stays open (and keeps
    /// filling the preroll), so the next transcription can start at once.
    func finishTranscription() async throws -> (text: String, localeID: String) {
        guard let pipeline = pipelineTask else { return ("", "") }
        pipelineTask = nil
        let old = sinkLock.withLock { () -> AsyncStream<AVAudioPCMBuffer>.Continuation? in
            defer { sinkStorage = nil }
            return sinkStorage
        }
        old?.finish()
        return try await pipeline.value
    }

    /// Stops sending audio to the “Hey N” matcher (the Assistant took over the recording).
    func stopAudioMonitor() {
        sinkLock.withLock { monitorStorage = nil }
    }

    /// Under `sinkLock`.
    private func remember(_ buffer: AVAudioPCMBuffer) {
        preroll.append(buffer)
        prerollFrames += AVAudioFramePosition(buffer.frameLength)
        let limit = AVAudioFramePosition(Self.prerollSeconds * buffer.format.sampleRate)
        while prerollFrames > limit, let first = preroll.first {
            prerollFrames -= AVAudioFramePosition(first.frameLength)
            preroll.removeFirst()
        }
    }

    private static func unique(_ ids: [String]) -> [String] {
        ids.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    /// Converts mic buffers to 16 kHz mono on `queue` (in order) and hands the samples to `onAudio` there.
    private static func monitor(on queue: DispatchQueue, _ onAudio: @escaping ([Float]) -> Void) -> (AVAudioPCMBuffer) -> Void {
        let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        var converter: AVAudioConverter?     // only touched on `queue`
        return { buffer in
            queue.async {
                if converter?.inputFormat != buffer.format {
                    converter = AVAudioConverter(from: buffer.format, to: out)
                    converter?.downmix = true
                }
                guard let c = convert(buffer, with: converter, to: out), let data = c.floatChannelData?[0] else { return }
                onAudio(Array(UnsafeBufferPointer(start: data, count: Int(c.frameLength))))
            }
        }
    }

    private static func pipeline(ids: [String], contextualStrings: [String], micFormat: AVAudioFormat,
                                 onTranscript: ((String, String) -> Void)?, _ rawStream: AsyncStream<AVAudioPCMBuffer>)
        -> Task<(String, String), Error> {
        // Analyzer setup runs concurrently; mic buffers queue up in rawStream so nothing is lost.
        return Task.detached(priority: .userInitiated) {
            var lanes: [Lane] = []
            var firstError: Error?
            for (i, id) in ids.enumerated() {
                let live = onTranscript.map { report in { (text: String) in report(id, text) } }
                do { lanes.append(try await Lane.make(localeID: id, primary: i == 0, micFormat: micFormat,
                                                     contextualStrings: contextualStrings, onTranscript: live)) }
                catch { firstError = firstError ?? error }
            }
            guard !lanes.isEmpty else { throw firstError ?? TranscriberError.noAudioFormat }

            for await raw in rawStream {
                for lane in lanes { lane.feed(raw) }
            }
            // Cancelled (or replaced by a restart): nobody wants this transcript.
            if Task.isCancelled {
                for lane in lanes { await lane.cancel() }
                throw CancellationError()
            }
            var results: [LaneResult] = []
            for lane in lanes { results.append(try await lane.finish()) }

            let best = results.max { $0.score < $1.score }!
            if results.count > 1 {
                let detail = results.map { String(format: "%@ %.2f", $0.localeID, $0.score) }.joined(separator: " · ")
                Diagnostics.log("language pick: \(best.localeID)  (\(detail))")
            }
            return (best.text, best.localeID)
        }
    }

    struct LaneResult { let localeID: String; let text: String; let score: Double }

    /// One language's transcriber fed with the shared mic audio.
    final class Lane {
        let localeID: String
        let primary: Bool
        let module: DictationTranscriber
        let analyzer: SpeechAnalyzer
        let format: AVAudioFormat
        var converter: AVAudioConverter?   // replaced if the mic format changes (recording moved to a fresh engine)
        let input: AsyncStream<AnalyzerInput>.Continuation
        let collector: Task<(String, Double, Int), Error>

        private init(localeID: String, primary: Bool, module: DictationTranscriber, analyzer: SpeechAnalyzer, format: AVAudioFormat,
                     converter: AVAudioConverter?, input: AsyncStream<AnalyzerInput>.Continuation, collector: Task<(String, Double, Int), Error>) {
            self.localeID = localeID; self.primary = primary; self.module = module; self.analyzer = analyzer
            self.format = format; self.converter = converter; self.input = input; self.collector = collector
        }

        static func make(localeID: String, primary: Bool, micFormat: AVAudioFormat, contextualStrings: [String],
                         onTranscript: ((String) -> Void)? = nil) async throws -> Lane {
            let locale = try await Transcriber.resolveLocale(localeID)
            let module = Transcriber.makeModule(locale: locale, liveResults: onTranscript != nil)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: micFormat) else {
                throw TranscriberError.noAudioFormat
            }
            let analyzer = SpeechAnalyzer(modules: [module])
            if !contextualStrings.isEmpty {
                // Personal dictionary: bias recognition toward this speaker's names and jargon.
                let context = AnalysisContext()
                context.contextualStrings[.general] = contextualStrings
                do { try await analyzer.setContext(context) }
                catch { Diagnostics.log("dictionary hints rejected by speech engine (\(localeID)): \(error.localizedDescription)") }
            }
            try await analyzer.prepareToAnalyze(in: format)
            let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
            let collector = Task { () -> (String, Double, Int) in
                var text = "", confSum = 0.0, confChars = 0
                for try await r in module.results {
                    if let onTranscript {
                        let current = text + String(r.text.characters)
                        await MainActor.run { onTranscript(current) }
                    }
                    guard r.isFinal else { continue }
                    text += String(r.text.characters)
                    for run in r.text.runs {
                        if let c = run.transcriptionConfidence {
                            let n = r.text[run.range].characters.count
                            confSum += c * Double(n); confChars += n
                        }
                    }
                }
                return (text, confSum, confChars)
            }
            try await analyzer.start(inputSequence: stream)
            return Lane(localeID: localeID, primary: primary, module: module, analyzer: analyzer, format: format,
                        converter: AVAudioConverter(from: micFormat, to: format), input: cont, collector: collector)
        }

        func feed(_ raw: AVAudioPCMBuffer) {
            if raw.format != format, converter?.inputFormat != raw.format { converter = AVAudioConverter(from: raw.format, to: format) }
            if let converted = Transcriber.convert(raw, with: converter, to: format) {
                input.yield(AnalyzerInput(buffer: converted))
            }
        }

        func cancel() async {
            input.finish()
            await analyzer.cancelAndFinishNow()
            collector.cancel()
        }

        func finish() async throws -> LaneResult {
            input.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let (raw, confSum, confChars) = try await collector.value
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return LaneResult(localeID: localeID, text: "", score: -1) }
            let confidence = confChars > 0 ? confSum / Double(confChars) : 0.5
            // Does the text actually read like this lane's language? (Spanish speech forced through the
            // English model tends to come out as low-confidence, odd English.)
            let lang = Locale(identifier: localeID).language.languageCode?.identifier ?? ""
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            let fit = recognizer.languageHypotheses(withMaximum: 5)[NLLanguage(rawValue: lang)] ?? 0
            let score = confidence * (0.6 + 0.4 * fit) + (primary ? 0.02 : 0)
            return LaneResult(localeID: localeID, text: text, score: score)
        }
    }

    /// Stops recording and returns the final transcript plus the recording duration.
    func stop() async throws -> (text: String, duration: TimeInterval, localeID: String) {
        guard isRecording else { return ("", 0, "") }
        let duration = Date().timeIntervalSince(startDate ?? Date())
        // Taken now: a new recording may start while this one is still being transcribed.
        let pipeline = pipelineTask
        pipelineTask = nil
        teardownAudio()
        let (text, locale) = try await pipeline?.value ?? ("", "")
        return (text, duration, locale)
    }

    func cancel() {
        guard isRecording else { return }
        teardownAudio()
        pipelineTask?.cancel()
        pipelineTask = nil
    }

    private func teardownAudio() {
        watchdog?.invalidate(); watchdog = nil
        currentTap = nil
        let peak = sinkLock.withLock { peakSeen }
        if !everHeardSound && peak == 0 {
            Diagnostics.log("the mic delivered only silence — rebuilding the audio engine")
            rebuildAfterRecording = true
        }
        if restarting, let e = engine {
            // A restart is busy on the audio queue; don't queue behind it (and don't call that a stuck audio system).
            DispatchQueue.global(qos: .utility).async { Self.end(e) }
        } else if let e = engine, worker.run(timeout: Self.stopTimeout, work: { Self.end(e) }) == nil {
            Diagnostics.log("audio stop timed out — CoreAudio is not responding, moving to a fresh audio queue")
            // The job may never have got its turn; the mic must still be released.
            DispatchQueue.global(qos: .utility).async { Self.end(e) }
            warm = nil
            markAudio(stuck: true)
        }
        engine = nil
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        sinkLock.withLock {
            sinkStorage?.finish()
            sinkStorage = nil
            keepPreroll = false
            preroll = []; prerollFrames = 0
            monitorStorage = nil
        }
        micFormat = nil
        isRecording = false
        if rebuildAfterRecording {
            rebuildAfterRecording = false; recheckAfterRecording = false
            invalidateEngine(reason: "audio setup changed while recording")
        } else if recheckAfterRecording {
            recheckAfterRecording = false
            invalidateEngine(reason: "audio devices changed while recording", force: false)
        }
    }

    // MARK: Capture watchdog

    private func observeConfiguration(of e: AVAudioEngine) {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        // Only the engine being recorded with: building an engine fires this too, so a global
        // observer would rebuild forever.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: e, queue: .main) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.rebuildAfterRecording = true
            // The engine usually stops itself here (a device came or went); look now rather than at the next tick.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.checkCapture() }
        }
    }

    private func resetCaptureHealth() {
        sinkLock.withLock { buffersSeen = 0; peakSeen = 0 }
        lastCheckedBuffers = 0
        captureStart = Date()
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        let t = Timer(timeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in self?.checkCapture() }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    /// Main thread, while recording: is the mic still delivering real audio?
    private func checkCapture() {
        guard isRecording, !restarting else { return }
        let (count, peak) = sinkLock.withLock { (buffersSeen, peakSeen) }
        let elapsed = Date().timeIntervalSince(captureStart)
        defer { lastCheckedBuffers = count }
        if peak > 0 { everHeardSound = true }
        let problem: String?
        if engine?.isRunning == false {
            problem = "the mic engine stopped (audio device change)"
        } else if elapsed >= Self.watchdogInterval * 0.9, count == lastCheckedBuffers {
            problem = count == 0 ? "the mic delivered no audio" : "the mic stopped delivering audio"
        } else if elapsed >= 0.6, count > 0, peak == 0, !silenceRestarted {
            // A working mic always picks up some noise; exact zeros mean a dead input route.
            silenceRestarted = true
            problem = "the mic is delivering pure silence"
        } else {
            problem = nil
        }
        if let problem { restartCapture(problem) }
    }

    /// Moves the running recording to a freshly built engine (same tap, same transcript), off the main thread.
    private func restartCapture(_ why: String) {
        guard isRecording, !restarting, let tap = currentTap else { return }
        let now = Date()
        restarts = restarts.filter { now.timeIntervalSince($0) < 10 }
        guard restarts.count < 2 else { return }   // don't thrash a broken audio system
        restarts.append(now)
        restarting = true
        let id = recordingID, old = engine
        Diagnostics.log("\(why) — restarting the recording on a fresh audio engine")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome = self.worker.run(timeout: Self.startTimeout, work: { [self] () -> Result<(Warm, AVAudioFormat), Error> in
                if let old { Self.end(old) }
                self.warm = nil
                guard let w = self.takeWarm(forceRebuild: true) else { return .failure(TranscriberError.micUnavailable("no input format")) }
                do { return .success((w, try Self.begin(w, tap: tap))) } catch { return .failure(error) }
            }, discard: { result in
                if case .success(let started) = result { Self.end(started.0.engine) }
            })
            DispatchQueue.main.async {
                self.restarting = false
                guard self.isRecording, self.recordingID == id else {
                    // The recording ended meanwhile: never leave the mic open.
                    if case .success(let started)? = outcome { DispatchQueue.global(qos: .utility).async { Self.end(started.0.engine) } }
                    return
                }
                switch outcome {
                case .success(let (w, format))?:
                    self.engine = w.engine
                    self.micFormat = format
                    self.observeConfiguration(of: w.engine)
                    self.resetCaptureHealth()
                    Diagnostics.log("mic recovered on a fresh audio engine")
                case .failure(let error)?:
                    Diagnostics.log("mic restart failed: \(error.localizedDescription)")
                case nil:
                    Diagnostics.log("mic restart timed out — CoreAudio is not responding")
                }
            }
        }
    }

    // MARK: Warm engine

    /// Builds the engine in the background (if it isn't ready already) so the next fn press starts instantly.
    /// `reason` is logged only when an engine actually gets built.
    func prewarm(discardExisting: Bool = false, reason: String? = nil) {
        // Waits on a background thread, so a build that hangs gets abandoned before the next fn press needs the queue.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let finished: Void? = self.worker.run(timeout: Self.prewarmTimeout, work: { [weak self] in
                guard let self else { return }
                if discardExisting { self.warm = nil }
                let device = self.inputDeviceProvider()
                if let w = self.warm, w.requestedUID == device?.uid { return }
                if let reason { Diagnostics.log("rebuilding audio engine — \(reason)") }
                _ = self.buildWarm(device)
            })
            if finished == nil { Diagnostics.log("audio engine build timed out — moving to a fresh audio queue") }
        }
    }

    /// The audio setup changed. `force` (wake, unlock, mic setting, coreaudiod restart): drop the engine and build a
    /// fresh one. Otherwise (devices came or went): rebuild only if the mic we record from is now a different one.
    func invalidateEngine(reason: String, force: Bool = true, audioRestarted: Bool = false) {
        if audioRestarted { markAudio(stuck: false) }
        if isRecording {
            if force { rebuildAfterRecording = true } else { recheckAfterRecording = true }
            return
        }
        // Coalesce bursts (unlock fires several notifications; AirPods connecting fires many over several seconds).
        if pendingRebuild?.force != true || force { pendingRebuild = (reason, force || pendingRebuild?.force == true) }
        rebuildWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.pendingRebuild else { return }
            guard !self.isRecording else {
                if pending.force { self.rebuildAfterRecording = true } else { self.recheckAfterRecording = true }
                self.pendingRebuild = nil
                return
            }
            self.pendingRebuild = nil
            self.prewarm(discardExisting: pending.force, reason: pending.reason)
        }
        rebuildWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (pendingRebuild?.force == true ? 0.6 : 1.5), execute: w)
    }

    /// On the worker. Returns the warm engine if it matches the current mic, otherwise builds one now
    /// (the worker is serial, so a build already running finishes first rather than starting a second one).
    private func takeWarm(forceRebuild: Bool) -> Warm? {
        let device = inputDeviceProvider()
        if !forceRebuild, let w = warm, w.requestedUID == device?.uid { return w }
        let t0 = Date()
        let w = buildWarm(device)
        Diagnostics.log(String(format: "audio engine built on demand in %.0f ms", Date().timeIntervalSince(t0) * 1000))
        return w
    }

    /// On the worker. A build left behind by an abandoned queue must not replace the current engine.
    private func buildWarm(_ device: AudioInputDevice?) -> Warm? {
        let generation = worker.generation
        let w = Self.build(device)
        if worker.generation == generation { warm = w }
        return w
    }

    private static func end(_ engine: AVAudioEngine) {
        _ = NVTryObjC({ engine.inputNode.removeTap(onBus: 0) }, nil)
        engine.stop()
    }

    private static func build(_ device: AudioInputDevice?) -> Warm? {
        let e = AVAudioEngine()
        let input = e.inputNode
        var switched = false
        if let dev = device {
            // Record from this mic instead of the system default (must happen before reading the format).
            do { try input.auAudioUnit.setDeviceID(dev.id); switched = true; Diagnostics.log("audio engine ready — mic: \(dev.name)") }
            catch { Diagnostics.log("could not switch mic to \(dev.name): \(error.localizedDescription)") }
        }
        _ = format(of: input, switched: switched)     // pay CoreAudio's setup cost now, not on fn press
        return Warm(engine: e, requestedUID: device?.uid, switched: switched)
    }

    /// After switching devices the node's output format still describes the old mic; the input side has the
    /// real hardware format, and tapping with anything else throws "format mismatch".
    private static func format(of input: AVAudioInputNode, switched: Bool) -> AVAudioFormat {
        switched ? input.inputFormat(forBus: 0) : input.outputFormat(forBus: 0)
    }

    /// Installs the tap and starts the engine. Throws (never crashes) if the engine is stale.
    private static func begin(_ w: Warm, tap: @escaping AVAudioNodeTapBlock) throws -> AVAudioFormat {
        let input = w.engine.inputNode
        let f = format(of: input, switched: w.switched)
        guard f.sampleRate > 0, f.channelCount > 0 else { throw TranscriberError.micUnavailable("no input format") }
        _ = NVTryObjC({ input.removeTap(onBus: 0) }, nil)
        var objcError: NSError?
        guard NVTryObjC({ input.installTap(onBus: 0, bufferSize: 1024, format: f, block: tap) }, &objcError) else {
            throw TranscriberError.micUnavailable(objcError?.localizedDescription ?? "tap failed")
        }
        w.engine.prepare()
        do { try w.engine.start() } catch {
            _ = NVTryObjC({ input.removeTap(onBus: 0) }, nil)
            throw error
        }
        return f
    }

    // MARK: Helpers

    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter?, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 1 }   // not float: can't tell, assume alive
        var p: Float = 0
        for i in 0..<Int(buffer.frameLength) { p = max(p, abs(data[i])) }
        return p
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(n))
        let db = 20 * log10(max(rms, 1e-7))          // ~ -70…0 dB
        return max(0, min(1, (db + 55) / 45))          // map -55dB…-10dB → 0…1
    }
}
