import Foundation
import Testing
@testable import ProjectN

@MainActor
struct AssistantSpeechTests {
    @Test func personalCorrectionsAreAppliedEvenWhenHintsAreIgnored() {
        let rule = CorrectionRule(heard: "for v marketing", replacement: "4vmarketing")
        let profile = Profile(name: "Speaker", localeID: "en-US", dictionary: ["NVoice", "SEO"], rules: [rule])
        let result = ProfileStore.personalized("Open N voice and S E O for for v marketing", profile: profile)
        #expect(result.text == "Open NVoice and SEO for 4vmarketing")
        #expect(result.usedRules == [rule.id])
    }

    @Test func ambiguousEverydayWordsRequireAnExplicitCorrection() {
        var profile = Profile(name: "Speaker", localeID: "en-US", dictionary: ["NVoice"])
        #expect(ProfileStore.personalized("Send the invoice", profile: profile).text == "Send the invoice")
        profile.rules = [CorrectionRule(heard: "invoice", replacement: "NVoice")]
        #expect(ProfileStore.personalized("Open invoice", profile: profile).text == "Open NVoice")
    }

    @Test func additionalAppVocabularyAlsoGetsMatchedAfterRecognition() {
        let profile = Profile(name: "Speaker", localeID: "en-US")
        #expect(ProfileStore.personalized("open code x and search console", profile: profile,
                                         vocabulary: ["Codex", "Search Console"]).text == "open Codex and Search Console")
    }

    @Test func hintsReserveSpaceForPersonalWordsAndAppNames() {
        let personal = (0..<120).map { "Personal\($0)" }
        let context = (0..<120).map { "Project\($0)" }
        let hints = ProfileStore.recognitionHints(personal: personal, vocabulary: context)
        #expect(hints.count == 100)
        #expect(hints.filter { $0.hasPrefix("Personal") }.count == 75)
        #expect(hints.filter { $0.hasPrefix("Project") }.count == 25)
        #expect(ProfileStore.recognitionHints(personal: [" Codex ", "codex", "NVoice"],
                                              vocabulary: ["nvoice", " Claude  Code ", ""]).count == 3)
        #expect(ProfileStore.recognitionHints(personal: [], vocabulary: context).count == 100)
        #expect(ProfileStore.recognitionHints(personal: personal).count == 100)
    }

    @Test func wordsOutsideTheHintBudgetStillGetCorrected() {
        let terms = (0..<110).map { "Product\($0)" } + ["NVoice"]
        let profile = Profile(name: "Speaker", localeID: "en-US", dictionary: terms)
        #expect(!ProfileStore.recognitionHints(personal: terms).contains("NVoice"))
        #expect(ProfileStore.personalized("open N voice", profile: profile).text == "open NVoice")
    }

    @Test func contextTermsAlsoInALargeDictionaryKeepTheirReservedHint() {
        let personal = (0..<120).map { "Personal\($0)" } + ["Hey N", "Codex"]
        let hints = ProfileStore.recognitionHints(personal: personal, vocabulary: ["Hey N", "Codex"])
        #expect(hints.count == 100)
        #expect(hints.contains("Hey N"))
        #expect(hints.contains("Codex"))
        #expect(Set(hints).count == 100)
    }

    @Test func capturedProfileControlsCorrections() {
        let recorded = Profile(name: "First", localeID: "en-US",
                               rules: [CorrectionRule(heard: "cloud", replacement: "Claude")])
        let other = Profile(name: "Second", localeID: "en-US")
        #expect(ProfileStore.personalized("open cloud", profile: recorded).text == "open Claude")
        #expect(ProfileStore.personalized("open cloud", profile: other).text == "open cloud")
    }

    @Test func quietSpeechIsDetectedAndKeepsTheTurnOpen() {
        var vad = AssistantVAD()
        let start = Date()
        for i in 0..<8 { _ = vad.push(0.02, now: start.addingTimeInterval(Double(i) * 0.04)) }
        _ = vad.push(0.23, now: start.addingTimeInterval(0.35))
        _ = vad.push(0.24, now: start.addingTimeInterval(0.39))
        #expect(vad.heardSpeech)
        #expect(vad.push(0.15, now: start.addingTimeInterval(1.1)) == .listening)
        #expect(vad.push(0.02, now: start.addingTimeInterval(1.8)) == .listening)
        #expect(vad.push(0.02, now: start.addingTimeInterval(2.1)) == .endOfSpeech)
    }

    @Test func liveRecognitionConfirmsVeryQuietSpeech() {
        var vad = AssistantVAD()
        let start = Date()
        for i in 0..<8 { _ = vad.push(0.02, now: start.addingTimeInterval(Double(i) * 0.04)) }
        vad.recognizedSpeech(now: start.addingTimeInterval(1))
        #expect(vad.heardSpeech)
        #expect(vad.push(0.02, now: start.addingTimeInterval(1.5)) == .listening)
        vad.recognizedSpeech(now: start.addingTimeInterval(1.8))
        #expect(vad.push(0.02, now: start.addingTimeInterval(2.4)) == .listening)
        #expect(vad.push(0.02, now: start.addingTimeInterval(2.8)) == .endOfSpeech)
    }

    @Test func quietInterruptionStopsWithinTwoTenthsOfASecond() {
        var detector = AssistantBargeIn()
        let start = Date()
        for i in 0..<12 {
            let interrupted = detector.push(0.03, now: start.addingTimeInterval(Double(i) * 0.025))
            #expect(!interrupted)
        }
        var stoppedAt: Double?
        for i in 0..<9 {
            let elapsed = Double(i) * 0.025
            if detector.push(0.32, now: start.addingTimeInterval(0.4 + elapsed)) {
                stoppedAt = elapsed
                break
            }
        }
        #expect(stoppedAt != nil)
        #expect((stoppedAt ?? 1) <= 0.2)
    }

    @Test func isolatedClicksDoNotAccumulateIntoAnInterruption() {
        var detector = AssistantBargeIn()
        let start = Date()
        for i in 0..<10 { _ = detector.push(0.02, now: start.addingTimeInterval(Double(i) * 0.05)) }
        let first = detector.push(0.8, now: start.addingTimeInterval(0.6))
        let second = detector.push(0.8, now: start.addingTimeInterval(1.2))
        #expect(!first)
        #expect(!second)
    }

    @Test func explicitInterruptionsDoNotMatchTheAssistantsOwnWords() {
        #expect(AssistantBargeIn.isStopRequest("I opened Claude. Wait", spoken: "I opened Claude."))
        #expect(AssistantBargeIn.isStopRequest("detente", spoken: "Abrí Claude."))
        #expect(!AssistantBargeIn.isStopRequest("Please wait while it opens", spoken: "Please wait while it opens"))
        #expect(!AssistantBargeIn.isStopRequest("open Codex", spoken: "I opened Claude"))
        #expect(AssistantBargeIn.stripEcho("Claude Opus open Codex", spoken: "Open Claude in Opus") == "Claude Opus open Codex")
        #expect(AssistantBargeIn.stripEcho("no", spoken: "No problem") == "no")
    }

    @Test func wakeCommandKeepsThePromptAndAcceptsSpokenLetters() {
        #expect(AssistantWakeCommand.prompt(in: "Hey N") == "")
        #expect(AssistantWakeCommand.prompt(in: "Hey N.") == "")
        #expect(AssistantWakeCommand.prompt(in: "Hey, N, open Codex.") == "open Codex.")
        #expect(AssistantWakeCommand.prompt(in: "hey en abre Claude") == "abre Claude")
        #expect(AssistantWakeCommand.prompt(in: "Hey ene, abre el proyecto") == "abre el proyecto")
        #expect(AssistantWakeCommand.prompt(in: "background speech. Hey N, /tmp/project") == "/tmp/project")
        #expect(AssistantWakeCommand.prompt(in: "Hey N, ./scripts/test.sh") == "./scripts/test.sh")
        #expect(AssistantWakeCommand.prompt(in: "Hey N, #123 --help") == "#123 --help")
        #expect(AssistantWakeCommand.prompt(in: "hey anyone there") == nil)
        #expect(AssistantWakeCommand.prompt(in: "they need help") == nil)
        #expect(AssistantWakeCommand.prompt(in: "Hey N. Hey N, open Claude") == "open Claude")
    }

    @Test func wakeRecordingTransfersWithoutClosingTheMicrophone() async throws {
        let recorder = FakeWakeRecorder()
        let listener = makeListener(recorder)
        var available = true
        var prompts: [String] = []
        listener.canListen = { available }
        listener.onWake = { prompt, _ in prompts.append(prompt); available = false }
        listener.setEnabled(true)
        defer { listener.setEnabled(false) }
        try await waitFor { listener.isRecording }
        let callback = try #require(recorder.transcript)
        callback("Hey N, open Codex")
        #expect(prompts == ["open Codex"])
        #expect(!listener.isRecording)
        listener.pause()
        #expect(recorder.cancellations == 0)
        callback("Hey N, another command")
        #expect(prompts.count == 1)
        #expect(recorder.starts == 1)
    }

    @Test func dictationCanPreemptWakeAndLateResultsCannotWakeIt() async throws {
        let recorder = FakeWakeRecorder()
        let listener = makeListener(recorder)
        var wakes = 0
        listener.canListen = { true }
        listener.onWake = { _, _ in wakes += 1 }
        listener.setEnabled(true)
        defer { listener.setEnabled(false) }
        try await waitFor { listener.isRecording }
        let callback = try #require(recorder.transcript)
        listener.pause()
        callback("Hey N, open Codex")
        #expect(recorder.cancellations == 1)
        #expect(!listener.isRecording)
        #expect(wakes == 0)
    }

    @Test func cancelledWakeStartupCannotStealTheMicrophone() async throws {
        let recorder = FakeWakeRecorder()
        recorder.suspendStart = true
        let listener = makeListener(recorder)
        listener.canListen = { true }
        listener.setEnabled(true)
        defer { listener.setEnabled(false); recorder.resumeStart() }
        try await waitFor { recorder.pending != nil }
        listener.setEnabled(false)
        recorder.resumeStart()
        try await waitFor { recorder.attemptFinished }
        #expect(recorder.starts == 0)
        #expect(recorder.cancellations == 0)
        #expect(!listener.isRecording)
    }

    @Test func wakeDuringStartupReturnCannotCancelTheAdoptedPrompt() async throws {
        let recorder = FakeWakeRecorder()
        let listener = makeListener(recorder)
        var available = true
        var woke = false
        listener.canListen = { available }
        listener.onWake = { _, _ in woke = true; available = false }
        recorder.onOpened = { recorder.transcript?("Hey N, open Codex") }
        listener.setEnabled(true)
        defer { listener.setEnabled(false); recorder.onOpened = nil }
        try await waitFor { recorder.attemptFinished }
        #expect(woke)
        #expect(!listener.isRecording)
        #expect(recorder.inUse)
        #expect(recorder.cancellations == 0)
    }

    @Test func preemptionDuringStartupReturnCannotCancelNewDictation() async throws {
        let recorder = FakeWakeRecorder()
        let listener = makeListener(recorder)
        var available = true
        listener.canListen = { available }
        recorder.onOpened = {
            listener.pause()
            available = false
            recorder.inUse = true   // the shortcut now owns a different recording
        }
        listener.setEnabled(true)
        defer { listener.setEnabled(false); recorder.onOpened = nil }
        try await waitFor { recorder.attemptFinished }
        #expect(!listener.isRecording)
        #expect(recorder.inUse)
        #expect(recorder.cancellations == 1)
    }

    private func makeListener(_ recorder: FakeWakeRecorder) -> AssistantWakeListener {
        AssistantWakeListener(recordingAvailable: { !recorder.inUse }, startRecording: { hints, transcript, allowed, level in
            try await recorder.start(hints: hints, transcript: transcript, allowed: allowed, level: level)
        }, cancelRecording: { recorder.cancel() })
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition())
    }
}

@MainActor
private final class FakeWakeRecorder {
    var inUse = false
    var starts = 0
    var cancellations = 0
    var suspendStart = false
    var attemptFinished = false
    var onOpened: (() -> Void)?
    var transcript: ((String) -> Void)?
    var pending: CheckedContinuation<Void, Never>?

    func start(hints: [String], transcript: @escaping (String) -> Void, allowed: @escaping () -> Bool,
               level: @escaping (Float) -> Void) async throws {
        defer { attemptFinished = true }
        if suspendStart { await withCheckedContinuation { pending = $0 } }
        guard allowed() else { throw CancellationError() }
        #expect(hints.contains("Hey N"))
        self.transcript = transcript
        starts += 1
        inUse = true
        level(0.02)
        onOpened?()
    }

    func resumeStart() { pending?.resume(); pending = nil }
    func cancel() { cancellations += 1; inUse = false }
}
