import AVFoundation

/// Speaks the Assistant's answers through its own small audio engine (AVSpeechSynthesizer renders the audio, a player
/// node plays it) instead of `AVSpeechSynthesizer.speak`:
/// - It knows exactly what is being played at each moment: that is what the interruption detector compares the mic
///   with, so the Assistant can tell your voice from its own coming back through the speakers.
/// - It knows when the last sentence has really finished playing. `speak`'s callbacks were unreliable with some voices
///   and left the Assistant stuck on "Speaking".
/// - It can lower its voice or stop within a few milliseconds when you talk over it.
/// It uses its own engine, never the microphone's, so dictation and listening are unaffected.
/// (Apple's voice processing — hardware echo cancellation — was tried first and isn't used: on a MacBook Pro it
/// reported 7–9 input channels, failed to start with -10875 unless the mixer was touched first, and after one
/// interrupted session kept "running" without delivering any audio until coreaudiod recovered.)
@MainActor
final class AssistantSpeaker {
    /// Everything queued has been played.
    var onFinished: (() -> Void)?
    private(set) var isSpeaking = false

    private let synth = AVSpeechSynthesizer()
    /// Loads voices ahead of time. Siri voices take ~4 s to load the first time, which delayed the first answer.
    private let warmer = AVSpeechSynthesizer()
    private var warmedAt: [String: Date] = [:]
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private let worker = AudioWorker(label: "dev.projectn.assistant.speaker")
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var configObserver: NSObjectProtocol?
    private var engineFailed = false
    private var fallback: FallbackSpeaker?

    private var queue: [AVSpeechUtterance] = []
    private var writing = false
    /// Bumped by `stop`: audio and callbacks from what was playing before are ignored.
    private var gen = 0
    /// Chunks handed to the player and not played back yet.
    private var unplayed = 0
    private var converter: AVAudioConverter?
    private var chunk: AVAudioPCMBuffer?
    private static let chunkFrames: AVAudioFrameCount = 4_800       // 100 ms
    private var writeWatchdog: DispatchWorkItem?
    private var idleStop: DispatchWorkItem?
    private var fade: DispatchWorkItem?

    /// Loudness of what was scheduled, 20 ms at a time, by position on the player's timeline.
    private var envelope: [(at: AVAudioFramePosition, rms: Float)] = []
    private var scheduledEnd: AVAudioFramePosition = 0
    private static let envelopeStep = 960                         // 20 ms
    private(set) var volume: Float = 1
    /// When the last answer finished playing: its echo is still in the room for a moment.
    private var finishedAt: Date?

    // MARK: Speaking

    /// Queues one sentence (or a few). Sentences are rendered one after another while earlier ones play, so there is
    /// no gap between them.
    func speak(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Float) {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = rate
        u.prefersAssistiveTechnologySettings = false
        u.preUtteranceDelay = 0
        u.postUtteranceDelay = 0
        idleStop?.cancel()
        if let f = fade { f.cancel(); fade = nil; player?.stop() }
        if !isSpeaking {
            isSpeaking = true
            finishedAt = nil
            setVolume(1)
        }
        if engineFailed || !ensureEngine() {
            fallbackSpeaker().speak(u)
            return
        }
        queue.append(u)
        renderNext()
    }

    /// Gets the output ready ahead of the first answer of a conversation.
    func prepare() {
        idleStop?.cancel()
        if !engineFailed { _ = ensureEngine() }
        if !isSpeaking { scheduleIdleStop() }
    }

    /// Stops at once (a 40 ms fade avoids a click). Nothing queued is spoken.
    func stop() {
        fallback?.stop()
        guard isSpeaking || writing || !queue.isEmpty || unplayed > 0 else { return }
        gen += 1
        queue.removeAll()
        writing = false
        chunk = nil
        unplayed = 0
        envelope = []
        scheduledEnd = 0
        writeWatchdog?.cancel()
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
        finishedAt = nil
        if let p = player, p.isPlaying {
            // Fade over ~40 ms, then stop.
            let start = volume
            for i in 1...4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.01) { [weak self] in
                    guard let self, self.fade != nil else { return }
                    self.player?.volume = start * Float(4 - i) / 4
                }
            }
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.fade = nil
                self.player?.stop()
                self.setVolume(1)
            }
            fade = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: w)
        } else {
            player?.stop()
            setVolume(1)
        }
        scheduleIdleStop()
    }

    /// Lowers (or restores, with 1) the voice: when you start talking over it, it gets quieter at once while it
    /// checks that it really is you.
    func duck(_ level: Float) {
        guard fade == nil else { return }
        let from = volume
        volume = level
        for i in 1...3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.012) { [weak self] in
                guard let self, self.fade == nil, self.volume == level else { return }
                self.player?.volume = from + (level - from) * Float(i) / 3
            }
        }
    }

    private func setVolume(_ v: Float) {
        volume = v
        player?.volume = v
    }

    // MARK: What is playing now

    /// How loud the answer was over the stretch the mic level that just arrived covers (0…1, the mic's scale).
    /// Measured on a MacBook: the mic hears the speakers ~0.1 s after the player renders, in ~0.1 s buffers; the
    /// louder of two neighbouring alignments absorbs jitter. Stays valid briefly after the answer ends (its echo).
    /// `late`: how much later than usual that mic level was delivered.
    func referenceLevel(late: TimeInterval = 0) -> Float {
        let late = min(late, 0.5)
        return max(playedLevel(lag: 0.1 + late, window: 0.1), playedLevel(lag: 0.15 + late, window: 0.1))
    }

    /// How loud the answer is right now (0…1), for the orb.
    func currentLevel() -> Float {
        level(from: -0.03, to: 0.03)
    }

    /// How loud what played between `lag + window` and `lag` seconds ago was (0…1, energy mean).
    func playedLevel(lag: Double, window: Double) -> Float {
        guard isSpeaking || finishedAt.map({ Date().timeIntervalSince($0) < 0.4 }) == true, !envelope.isEmpty else { return 0 }
        let now = playhead()
        let lo = now - AVAudioFramePosition((lag + window) * format.sampleRate)
        let hi = now - AVAudioFramePosition(lag * format.sampleRate)
        var energy: Float = 0
        var n = 0
        for e in envelope where e.at >= lo && e.at < hi { energy += e.rms * e.rms; n += 1 }
        let expected = max(1, Int(window * format.sampleRate) / Self.envelopeStep)
        return n == 0 ? 0 : Self.normalized(sqrt(energy / Float(max(n, expected))) * volume)
    }

    private func level(from: Double, to: Double) -> Float {
        guard isSpeaking, !envelope.isEmpty else { return 0 }
        let now = playhead()
        let lo = now + AVAudioFramePosition(from * format.sampleRate)
        let hi = now + AVAudioFramePosition(to * format.sampleRate)
        var peak: Float = 0
        for e in envelope where e.at + AVAudioFramePosition(Self.envelopeStep) >= lo && e.at <= hi { peak = max(peak, e.rms) }
        return Self.normalized(peak * volume)
    }

    /// The same 0…1 mapping as the mic level: −55 dB … −10 dB.
    static func normalized(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 55) / 45))
    }

    private func playhead() -> AVAudioFramePosition {
        guard let p = player, let node = p.lastRenderTime, node.isSampleTimeValid,
              let t = p.playerTime(forNodeTime: node) else { return 0 }
        return t.sampleTime
    }

    // MARK: Voices

    /// Loads voices ahead of time so the first answer doesn't wait for them. Cheap when they're already loaded.
    func prewarm(_ voices: [AVSpeechSynthesisVoice]) {
        for v in voices {
            if let at = warmedAt[v.identifier], Date().timeIntervalSince(at) < 120 { continue }
            warmedAt[v.identifier] = Date()
            let u = AVSpeechUtterance(string: v.language.hasPrefix("es") ? "Hola." : "Hello.")
            u.voice = v
            warmer.write(u) { _ in }
        }
    }

    // MARK: Rendering

    private func renderNext() {
        guard !writing, !queue.isEmpty else { return }
        let u = queue.removeFirst()
        writing = true
        let g = gen
        // A voice that never renders must not leave the Assistant speaking forever.
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.gen == g, self.writing else { return }
            Diagnostics.log("assistant: the voice didn't render a sentence in 8 s — skipped it")
            self.synth.stopSpeaking(at: .immediate)
            self.sentenceRendered(gen: g)
        }
        writeWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: watchdog)
        synth.write(u) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            let copy: AVAudioPCMBuffer? = pcm.frameLength > 0 ? (pcm.copy() as? AVAudioPCMBuffer) : nil
            let end = pcm.frameLength == 0
            DispatchQueue.main.async {
                guard let self, self.gen == g else { return }
                if let copy { self.append(copy) }
                if end { self.sentenceRendered(gen: g) }
            }
        }
    }

    private func sentenceRendered(gen g: Int) {
        guard g == gen, writing else { return }
        writeWatchdog?.cancel()
        writing = false
        flushChunk()
        converter?.reset()
        renderNext()
        finishIfDone()
    }

    /// Converts to the player's format and collects 100 ms chunks (fewer, larger buffers for the player).
    private func append(_ pcm: AVAudioPCMBuffer) {
        if pcm.format != format, converter?.inputFormat != pcm.format {
            converter = AVAudioConverter(from: pcm.format, to: format)
        }
        guard let audio = pcm.format == format ? pcm : Transcriber.convert(pcm, with: converter, to: format),
              let src = audio.floatChannelData?[0] else { return }
        var offset = 0
        let total = Int(audio.frameLength)
        while offset < total {
            if chunk == nil { chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.chunkFrames) }
            guard let c = chunk, let dst = c.floatChannelData?[0] else { return }
            let n = min(total - offset, Int(c.frameCapacity - c.frameLength))
            (dst + Int(c.frameLength)).update(from: src + offset, count: n)
            c.frameLength += AVAudioFrameCount(n)
            offset += n
            if c.frameLength == c.frameCapacity { flushChunk() }
        }
    }

    private func flushChunk() {
        guard let c = chunk, c.frameLength > 0, let player else { chunk = nil; return }
        chunk = nil
        let start = max(scheduledEnd, playhead())
        remember(c, at: start)
        scheduledEnd = start + AVAudioFramePosition(c.frameLength)
        unplayed += 1
        let g = gen
        player.scheduleBuffer(c, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.chunkPlayed(gen: g) }
        }
        if !player.isPlaying { player.play() }
    }

    private func remember(_ c: AVAudioPCMBuffer, at start: AVAudioFramePosition) {
        guard let data = c.floatChannelData?[0] else { return }
        let n = Int(c.frameLength)
        var i = 0
        while i < n {
            let len = min(Self.envelopeStep, n - i)
            var sum: Float = 0
            for k in i..<(i + len) { sum += data[k] * data[k] }
            envelope.append((start + AVAudioFramePosition(i), sqrt(sum / Float(len))))
            i += len
        }
        let old = playhead() - AVAudioFramePosition(format.sampleRate)
        if let first = envelope.firstIndex(where: { $0.at >= old }), first > 0 { envelope.removeFirst(first) }
    }

    private func chunkPlayed(gen g: Int) {
        guard g == gen, unplayed > 0 else { return }
        unplayed -= 1
        finishIfDone()
    }

    private func finishIfDone() {
        guard isSpeaking, unplayed == 0, !writing, queue.isEmpty, chunk == nil else { return }
        isSpeaking = false
        finishedAt = Date()       // the player keeps its timeline, so the echo reference stays valid for a moment
        scheduleIdleStop()
        onFinished?()
    }

    // MARK: Engine

    /// Starts the output engine if needed. CoreAudio can block, so it is never waited on for more than 1.5 s.
    private func ensureEngine() -> Bool {
        if let engine, engine.isRunning, player != nil { return true }
        tearDownEngine()
        let fmt = format
        let started: (AVAudioEngine, AVAudioPlayerNode)?? = worker.run(timeout: 1.5, work: {
            let e = AVAudioEngine()
            let p = AVAudioPlayerNode()
            e.attach(p)
            e.connect(p, to: e.mainMixerNode, format: fmt)
            e.prepare()
            do { try e.start() } catch {
                Diagnostics.log("assistant: couldn't start the voice output — \(error.localizedDescription)")
                return nil
            }
            return (e, p)
        }, discard: { late in late?.0.stop() })
        guard let made = started ?? nil else {
            Diagnostics.log("assistant: voice output unavailable — using the system speech instead")
            engineFailed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.engineFailed = false }
            return false
        }
        engine = made.0
        player = made.1
        player?.volume = volume
        // Output device changed (headphones plugged in, AirPods connected): the engine stops; build a new one.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: made.0, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
        return true
    }

    private func outputChanged() {
        Diagnostics.log("assistant: audio output changed")
        let wasSpeaking = isSpeaking
        gen += 1
        queue.removeAll(); writing = false; chunk = nil; unplayed = 0; envelope = []; scheduledEnd = 0
        synth.stopSpeaking(at: .immediate)
        tearDownEngine()
        if wasSpeaking {
            isSpeaking = false
            onFinished?()
        }
    }

    private func tearDownEngine() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        if let e = engine { _ = worker.run(timeout: 1, work: { e.stop() }) }
        engine = nil
        player = nil
    }

    /// The output device stays reserved only while it's in use.
    private func scheduleIdleStop() {
        idleStop?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.isSpeaking else { return }
            self.tearDownEngine()
        }
        idleStop = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: w)
    }

    // MARK: Fallback

    /// Only when the output engine can't start: the plain system speech (no interruption detection).
    private func fallbackSpeaker() -> FallbackSpeaker {
        if let fallback { return fallback }
        let f = FallbackSpeaker()
        f.onFinished = { [weak self] in
            guard let self, self.isSpeaking else { return }
            self.isSpeaking = false
            self.onFinished?()
        }
        fallback = f
        return f
    }
}

/// `AVSpeechSynthesizer.speak`, used only if the Assistant's own audio output can't start.
@MainActor
private final class FallbackSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    var onFinished: (() -> Void)?
    private let synth = AVSpeechSynthesizer()
    private var pending = 0

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ u: AVSpeechUtterance) {
        pending += 1
        synth.speak(u)
    }

    func stop() {
        guard pending > 0 else { return }
        pending = 0
        synth.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.ended() }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.ended() }
    }

    private func ended() {
        guard pending > 0 else { return }
        pending -= 1
        if pending == 0 { onFinished?() }
    }
}
