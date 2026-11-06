import AVFoundation
import Speech
import NaturalLanguage
import ObjCSupport

enum TranscriberError: LocalizedError {
    case unsupportedLocale(String)
    case noAudioFormat
    case micDenied
    case micUnavailable(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let l): return "On-device dictation does not support “\(l)”."
        case .noAudioFormat: return "Could not find a compatible audio format."
        case .micDenied: return "Microphone access is denied. Enable it in System Settings › Privacy & Security › Microphone."
        case .micUnavailable(let why): return "Microphone not ready — try again. (\(why))"
        }
    }
}

/// Records from the default mic and transcribes on-device with Apple's DictationTranscriber (macOS 26+).
final class Transcriber {
    /// 0…1 audio level, called on the main thread ~20×/s while recording.
    var onLevel: ((Float) -> Void)?
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
    private let audioQueue = DispatchQueue(label: "com.4vmarketing.nvoice.audio", qos: .userInitiated)
    private var warm: Warm?           // only touched on audioQueue
    private var engine: AVAudioEngine?   // the engine of the current dictation (main thread)
    private var rebuildAfterRecording = false
    private var configObserver: NSObjectProtocol?
    private var rebuildWork: DispatchWorkItem?
    private var rawContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var pipelineTask: Task<(String, String), Error>?
    private var startDate: Date?
    private(set) var isRecording = false

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

    static func makeModule(locale: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: locale,
                             contentHints: [],
                             transcriptionOptions: [.punctuation],
                             reportingOptions: [],
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
    func start(localeIDs: [String], contextualStrings: [String] = [], inputDevice: AudioInputDevice? = nil) throws {
        guard !isRecording else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw TranscriberError.micDenied }
        let ids = localeIDs.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }

        let t0 = Date()
        let (rawStream, rawCont) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .unbounded)
        rawContinuation = rawCont

        let tapBlock: AVAudioNodeTapBlock = { [weak self] buffer, _ in
            guard let self else { return }
            if let copy = buffer.copy() as? AVAudioPCMBuffer { rawCont.yield(copy) }
            let level = Self.level(of: buffer)
            DispatchQueue.main.async { self.onLevel?(level) }
        }
        // Fast path: the warm engine (~50 ms). If it turns out stale, rebuild once and retry.
        var micFormat: AVAudioFormat!
        var lastError: Error = TranscriberError.micUnavailable("no input format")
        for attempt in 0..<2 {
            let w = takeWarm(forceRebuild: attempt > 0)
            guard let w else { continue }
            do {
                micFormat = try Self.begin(w, tap: tapBlock)
                engine = w.engine
                // Only the engine being recorded with: building an engine fires this too, so a global
                // observer would rebuild forever.
                configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                        object: w.engine, queue: .main) { [weak self] _ in
                    self?.rebuildAfterRecording = true
                }
                break
            } catch {
                lastError = error
                Diagnostics.log("audio start failed (\(attempt == 0 ? "warm engine" : "fresh engine")): \(error.localizedDescription)")
            }
        }
        guard engine != nil, micFormat != nil else {
            rawCont.finish(); rawContinuation = nil
            prewarm()
            throw lastError
        }
        isRecording = true
        startDate = Date()
        Diagnostics.log(String(format: "recording started in %.0f ms", Date().timeIntervalSince(t0) * 1000))

        // Analyzer setup runs concurrently; mic buffers queue up in rawStream so nothing is lost.
        pipelineTask = Task.detached(priority: .userInitiated) {
            var lanes: [Lane] = []
            var firstError: Error?
            for (i, id) in ids.enumerated() {
                do { lanes.append(try await Lane.make(localeID: id, primary: i == 0, micFormat: micFormat, contextualStrings: contextualStrings)) }
                catch { firstError = firstError ?? error }
            }
            guard !lanes.isEmpty else { throw firstError ?? TranscriberError.noAudioFormat }

            for await raw in rawStream {
                for lane in lanes { lane.feed(raw) }
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
        let converter: AVAudioConverter?
        let input: AsyncStream<AnalyzerInput>.Continuation
        let collector: Task<(String, Double, Int), Error>

        private init(localeID: String, primary: Bool, module: DictationTranscriber, analyzer: SpeechAnalyzer, format: AVAudioFormat,
                     converter: AVAudioConverter?, input: AsyncStream<AnalyzerInput>.Continuation, collector: Task<(String, Double, Int), Error>) {
            self.localeID = localeID; self.primary = primary; self.module = module; self.analyzer = analyzer
            self.format = format; self.converter = converter; self.input = input; self.collector = collector
        }

        static func make(localeID: String, primary: Bool, micFormat: AVAudioFormat, contextualStrings: [String]) async throws -> Lane {
            let locale = try await Transcriber.resolveLocale(localeID)
            let module = Transcriber.makeModule(locale: locale)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: micFormat) else {
                throw TranscriberError.noAudioFormat
            }
            let analyzer = SpeechAnalyzer(modules: [module])
            if !contextualStrings.isEmpty {
                // Personal dictionary: bias recognition toward this speaker's names and jargon.
                let context = AnalysisContext()
                context.contextualStrings[.general] = contextualStrings
                try? await analyzer.setContext(context)
            }
            try await analyzer.prepareToAnalyze(in: format)
            let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
            let collector = Task { () -> (String, Double, Int) in
                var text = "", confSum = 0.0, confChars = 0
                for try await r in module.results where r.isFinal {
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
            if let converted = Transcriber.convert(raw, with: converter, to: format) {
                input.yield(AnalyzerInput(buffer: converted))
            }
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
        teardownAudio()
        let (text, locale) = try await pipelineTask?.value ?? ("", "")
        pipelineTask = nil
        return (text, duration, locale)
    }

    func cancel() {
        guard isRecording else { return }
        teardownAudio()
        pipelineTask?.cancel()
        pipelineTask = nil
    }

    private func teardownAudio() {
        if let e = engine {
            _ = NVTryObjC({ e.inputNode.removeTap(onBus: 0) }, nil)
            e.stop()
        }
        engine = nil
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        rawContinuation?.finish()
        rawContinuation = nil
        isRecording = false
        if rebuildAfterRecording { rebuildAfterRecording = false; invalidateEngine(reason: "audio setup changed while recording") }
    }

    // MARK: Warm engine

    /// Builds the engine in the background (if it isn't ready already) so the next fn press starts instantly.
    func prewarm() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let device = self.inputDeviceProvider()
            if let w = self.warm, w.requestedUID == device?.uid { return }
            self.warm = Self.build(device)
        }
    }

    /// The audio setup changed (wake, unlock, device change, mic setting): drop the engine and build a fresh one.
    func invalidateEngine(reason: String) {
        if isRecording { rebuildAfterRecording = true; return }
        // Coalesce bursts (unlock fires several notifications; AirPods connecting changes several properties).
        rebuildWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.isRecording else { self?.rebuildAfterRecording = true; return }
            Diagnostics.log("rebuilding audio engine — \(reason)")
            self.audioQueue.async { [weak self] in self?.warm = nil }
            self.prewarm()
        }
        rebuildWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    /// Main thread. Returns the warm engine if it matches the current mic, otherwise builds one now
    /// (waits for a build already running in the background rather than starting a second one).
    private func takeWarm(forceRebuild: Bool) -> Warm? {
        audioQueue.sync {
            let device = inputDeviceProvider()
            if !forceRebuild, let w = warm, w.requestedUID == device?.uid { return w }
            let t0 = Date()
            warm = Self.build(device)
            Diagnostics.log(String(format: "audio engine built on demand in %.0f ms", Date().timeIntervalSince(t0) * 1000))
            return warm
        }
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
