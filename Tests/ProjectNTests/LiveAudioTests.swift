import AVFoundation
import Foundation
import Testing
@testable import ProjectN

/// The Assistant's audio through the real speakers and microphone: its answer's own echo must not count as you
/// talking, and another voice over the answer must. Plays ~10 s of speech out loud.
/// Off by default. Run with:  PROJECTN_LIVE_AUDIO=1 ./scripts/test.sh --filter LiveAudio
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PROJECTN_LIVE_AUDIO"] == "1"))
struct LiveAudioTests {
    private struct Sample { let t: Double; let mic: Float; let ref: Float; let now: Float; let loud: Bool; let fired: Bool; var lags: [Float] = [] }
    private static let lags: [Double] = [0, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4]

    @Test func echoIsIgnoredAndAVoiceOverTheAnswerIsHeard() async throws {
        let mic = Transcriber()
        mic.inputDeviceProvider = { AudioDevices.resolve(AudioDevices.automatic) }
        let speaker = AssistantSpeaker()
        let voice = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("es") }
            .max { AssistantController.naturalness($0) < AssistantController.naturalness($1) }
        speaker.prewarm([voice].compactMap { $0 })
        speaker.prepare()
        try await Task.sleep(for: .seconds(2))

        var samples: [Sample] = []
        var detector = AssistantBargeIn()
        let t0 = Date()
        var phase = 0
        var fastest: TimeInterval = 1
        mic.onLevelAge = { l, age in
            fastest = min(fastest, age)
            let ref = speaker.referenceLevel(late: max(0, age - fastest))
            let fired = phase > 0 && speaker.isSpeaking && detector.push(mic: l, ref: ref)
            samples.append(Sample(t: Date().timeIntervalSince(t0), mic: l, ref: ref, now: speaker.currentLevel(),
                                  loud: detector.loudNow, fired: fired,
                                  lags: Self.lags.map { speaker.playedLevel(lag: $0, window: 0.1) }))
        }
        var partials: [String: String] = [:]
        try mic.start(localeIDs: ["es-MX", "en-US"], transcribe: false, keepPreroll: true)
        defer { mic.cancel() }
        try await Task.sleep(for: .seconds(1))

        // 1. The answer alone.
        phase = 1
        let rate = Float(Double(AVSpeechUtteranceDefaultSpeechRate) * 1.05)
        let answer = "Listo. Abrí tres paneles de Claude en Opus, y Developer está revisando el login en Blog. Te aviso cuando termine."
        var finished = false
        speaker.onFinished = { finished = true }
        for s in AssistantController.sentences(answer) { speaker.speak(s, voice: voice, rate: rate) }
        let answerStart = Date().timeIntervalSince(t0)
        while !finished, Date().timeIntervalSince(t0) < 20 { try await Task.sleep(for: .milliseconds(20)) }
        let answerEnd = Date().timeIntervalSince(t0)
        let echoOnly = samples.filter { $0.t >= answerStart && $0.t <= answerEnd }
        let coupling = detector.coupling
        try await Task.sleep(for: .milliseconds(600))

        // 2. Another answer, and a second voice talking over it (standing in for you). Like the Assistant: on
        //    suspicion it lowers its voice and transcribes from just before; your level or your words confirm it.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("projectn-live-other.aiff")
        let render = Process()
        render.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        render.arguments = ["-v", "Paulina", "-o", file.path, "Espera, espera. Mejor abre Codex en el proyecto Blog."]
        try render.run()
        render.waitUntilExit()
        detector = AssistantBargeIn(coupling: coupling)
        phase = 2
        finished = false
        let second = "Claro. Ahora mismo tienes cinco paneles corriendo en el espacio Videos y dos agentes trabajando en tus proyectos."
        var suspectedAt: Double?
        var confirmedAt: Double?
        var confirmedBy = ""
        var loudAfter = 0.0
        var lastT: Double?
        let watchStart = samples.count
        for s in AssistantController.sentences(second) { speaker.speak(s, voice: voice, rate: rate) }
        try await Task.sleep(for: .milliseconds(1500))
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        other.arguments = [file.path]
        let otherStart = Date().timeIntervalSince(t0)
        try other.run()
        var checked = watchStart
        while other.isRunning || (suspectedAt != nil && confirmedAt == nil && Date().timeIntervalSince(t0) - suspectedAt! < 1.3) {
            try await Task.sleep(for: .milliseconds(20))
            while checked < samples.count {
                let smp = samples[checked]; checked += 1
                if suspectedAt == nil, smp.fired {
                    suspectedAt = smp.t
                    speaker.duck(0.3)
                    mic.beginTranscription(localeIDs: ["es-MX", "en-US"], prerollSeconds: 0.7) { locale, text in partials[locale] = text }
                } else if let since = suspectedAt, confirmedAt == nil {
                    if smp.loud, smp.t - since > 0.25 { loudAfter += smp.t - (lastT ?? smp.t) }
                    if loudAfter >= 0.45 { confirmedAt = smp.t; confirmedBy = "level" }
                    if partials.values.contains(where: { AssistantBargeIn.newWords($0, spoken: second) >= 2
                                                         || AssistantBargeIn.isStopRequest($0, spoken: second) }) {
                        confirmedAt = smp.t; confirmedBy = "words"
                    }
                }
                lastT = smp.t
            }
            if confirmedAt != nil { speaker.stop() }
        }
        let otherEnd = Date().timeIntervalSince(t0)
        let firstFire = suspectedAt
        speaker.stop()
        let heard = try await mic.finishTranscription()

        // Report
        func stats(_ s: [Sample]) -> String {
            guard !s.isEmpty else { return "none" }
            let m = s.map(\.mic).sorted(), r = s.map(\.ref).sorted()
            return String(format: "n=%d mic p50 %.2f p90 %.2f max %.2f | ref p50 %.2f max %.2f | loud %d",
                          s.count, m[m.count / 2], m[m.count * 9 / 10], m.last!, r[r.count / 2], r.last!, s.filter(\.loud).count)
        }
        let room = samples.filter { $0.t < answerStart }
        print("live-audio: voice \(voice?.identifier ?? "default")")
        print("live-audio: room        \(stats(room))")
        print("live-audio: echo only   \(stats(echoOnly))  coupling \(coupling.map { String(format: "%.2f", $0) } ?? "-")")
        print("live-audio: voice over  \(stats(samples.filter { $0.t >= otherStart && $0.t <= otherEnd }))")
        print("live-audio: suspected \(firstFire.map { String(format: "%.2f s after the other voice started", $0 - otherStart) } ?? "NEVER")")
        print("live-audio: confirmed \(confirmedAt.map { String(format: "%.2f s after it started, by %@", $0 - otherStart, confirmedBy) } ?? "NEVER")")
        print("live-audio: false interruptions during the answer alone: \(echoOnly.filter(\.fired).count)")
        print("live-audio: transcript after the interruption (\(heard.localeID)): \(heard.text)")
        print("live-audio: new words (not the answer's): \(AssistantBargeIn.newWords(heard.text, spoken: second))")
        print("live-audio: live text per language: \(partials)")
        // Trace for tuning: time, mic, ref, instantaneous output, detector state.
        let trace = samples.filter { $0.t >= answerStart - 0.3 }.map {
            String(format: "%.3f %.3f %.3f %.3f %d %d ", $0.t, $0.mic, $0.ref, $0.now, $0.loud ? 1 : 0, $0.fired ? 1 : 0)
                + $0.lags.map { String(format: "%.3f", $0) }.joined(separator: " ")
        }.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("projectn-live-audio-trace.txt")
        try? (String(format: "answer %.3f %.3f other %.3f %.3f\n", answerStart, answerEnd, otherStart, otherEnd) + trace)
            .write(to: url, atomically: true, encoding: .utf8)
        print("live-audio: trace \(url.path)")

        #expect(echoOnly.filter(\.fired).isEmpty)
        #expect(firstFire != nil)
        #expect(confirmedAt != nil)
    }
}

/// A transcript started partway through an open recording (as on an interruption) hears what follows and the
/// preroll before it. Plays one ~3 s phrase. Run with:  PROJECTN_LIVE_AUDIO=1 ./scripts/test.sh --filter LiveTurn
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PROJECTN_LIVE_AUDIO"] == "1"))
struct LiveTurnTests {
    @Test func transcriptStartedMidRecordingHearsTheSpeech() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("projectn-live-turn.aiff")
        let render = Process()
        render.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        render.arguments = ["-v", "Paulina", "-o", file.path, "Espera, espera. Mejor abre Codex en el proyecto Blog."]
        try render.run()
        render.waitUntilExit()
        let mic = Transcriber()
        mic.inputDeviceProvider = { AudioDevices.resolve(AudioDevices.automatic) }
        var levels = 0
        mic.onLevel = { _ in levels += 1 }
        try mic.start(localeIDs: ["es-MX", "en-US"], transcribe: false, keepPreroll: true)
        defer { mic.cancel() }
        try await Task.sleep(for: .milliseconds(800))
        let play = Process()
        play.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        play.arguments = [file.path]
        try play.run()
        try await Task.sleep(for: .milliseconds(700))
        var partials: [String] = []
        let t0 = Date()
        mic.beginTranscription(localeIDs: ["es-MX", "en-US"], prerollSeconds: 0.7) { locale, text in
            partials.append(String(format: "%.2f %@: %@", Date().timeIntervalSince(t0), locale, text))
        }
        print("live-turn: transcribing: \(mic.isTranscribing)")
        while play.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(400))
        let t1 = Date()
        let heard = try await mic.finishTranscription()
        print(String(format: "live-turn: final in %.2f s (%@): %@", Date().timeIntervalSince(t1), heard.localeID, heard.text))
        print("live-turn: levels \(levels), partials \(partials.count)")
        for p in partials.suffix(8) { print("live-turn:   \(p)") }
        #expect(!heard.text.isEmpty)
    }

    @Test func interruptionTranscriptHearsYouOverTheLoweredAnswer() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("projectn-live-turn.aiff")
        let render = Process()
        render.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        render.arguments = ["-v", "Paulina", "-o", file.path, "Espera, espera. Mejor abre Codex en el proyecto Blog."]
        try render.run()
        render.waitUntilExit()
        let speaker = AssistantSpeaker()
        let voice = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("es") }
            .max { AssistantController.naturalness($0) < AssistantController.naturalness($1) }
        speaker.prewarm([voice].compactMap { $0 })
        speaker.prepare()
        let mic = Transcriber()
        mic.inputDeviceProvider = { AudioDevices.resolve(AudioDevices.automatic) }
        try mic.start(localeIDs: ["es-MX", "en-US"], transcribe: false, keepPreroll: true)
        defer { mic.cancel() }
        try await Task.sleep(for: .milliseconds(1500))
        let answer = "Claro. Ahora mismo tienes cinco paneles corriendo en el espacio Videos y dos agentes trabajando en tus proyectos."
        for s in AssistantController.sentences(answer) {
            speaker.speak(s, voice: voice, rate: Float(Double(AVSpeechUtteranceDefaultSpeechRate) * 1.05))
        }
        try await Task.sleep(for: .milliseconds(1200))
        let play = Process()
        play.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        play.arguments = [file.path]
        try play.run()
        try await Task.sleep(for: .milliseconds(650))
        speaker.duck(0.3)
        var partials: [String] = []
        let t0 = Date()
        mic.beginTranscription(localeIDs: ["es-MX", "en-US"], prerollSeconds: 0.7) { locale, text in
            partials.append(String(format: "%.2f %@: %@", Date().timeIntervalSince(t0), locale, text))
        }
        try await Task.sleep(for: .milliseconds(800))
        speaker.stop()
        while play.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(400))
        let heard = try await mic.finishTranscription()
        print("live-turn2: final (\(heard.localeID)): \(heard.text)")
        print("live-turn2: partials \(partials.count)")
        for p in partials.prefix(3) + partials.suffix(5) { print("live-turn2:   \(p)") }
        #expect(!heard.text.isEmpty)
    }
}
