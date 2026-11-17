import Foundation

/// Match the spoken letter in English or Spanish, with word boundaries so “hey anyone” cannot wake us.
enum AssistantWakeCommand {
    private static let phrase = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}])hey[\\s,]+(?:n|en|ene)(?![\\p{L}\\p{N}])", options: [.caseInsensitive])

    /// nil means no wake command; an empty string means the user has only said “Hey N” so far.
    static func prompt(in transcript: String) -> String? {
        let text = transcript as NSString
        guard let match = phrase.matches(in: transcript, range: NSRange(location: 0, length: text.length)).last else { return nil }
        let remainder = text.substring(from: NSMaxRange(match.range))
        return remainder
            .replacingOccurrences(of: "^(?:\\s|[,!?;:]|\\.(?=\\s|$))+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Passive “Hey N” listening in two stages, so ProjectN doesn't transcribe everything it hears:
/// 1. The mic is open but audio only goes to a light sound matcher (`WakeDetecting`) trained on your recordings.
///    Nothing becomes text.
/// 2. When something sounds like “Hey N”, the speech recognizer transcribes the last ~2 s plus what follows to
///    confirm it. Confirmed: ownership of the running recording passes to the Assistant without restarting capture,
///    so “Hey N, open…” stays in one recording. Not confirmed within a few seconds: the transcript is dropped and
///    matching resumes.
@MainActor
final class AssistantWakeListener {
    typealias StartRecording = (@escaping ([Float]) -> Void, @escaping () -> Bool, @escaping (Float) -> Void) async throws -> Void
    typealias BeginTranscript = ([String], @escaping (String) -> Void) -> Void
    var canListen: () -> Bool = { false }
    var vocabulary: () -> [String] = { [] }
    /// A fresh matcher for each recording; nil until you've recorded your “Hey N”.
    var makeDetector: () -> WakeDetecting? = { nil }
    var onWake: ((String, Float) -> Void)?
    var onStatus: ((String) -> Void)?
    private(set) var isRecording = false
    private(set) var isConfirming = false
    private var enabled = false
    private var starting = false
    private var generation = 0
    private var monitor: Task<Void, Never>?
    private var confirmUntil = Date.distantPast
    private var retryAt = Date.distantPast
    private var levels: [Float] = []
    private let recordingAvailable: () -> Bool
    private let startRecording: StartRecording
    private let beginTranscript: BeginTranscript
    private let endTranscript: () -> Void
    private let cancelRecording: () -> Void
    static let confirmSeconds: TimeInterval = 3
    static let listeningStatus = "Listening for “Hey N” — sound only, nothing is transcribed"
    static let needsSamplesStatus = "Record your “Hey N” below to turn this on"
    private var status = "Off" {
        didSet { if status != oldValue { onStatus?(status) } }
    }

    init(recordingAvailable: @escaping () -> Bool = { NVoiceController.shared.assistantRecordingAvailable },
         startRecording: @escaping StartRecording = { audio, shouldStart, level in
             try await NVoiceController.shared.assistantStartWakeListening(onAudio: audio, shouldStart: shouldStart,
                                                                           onLevel: level)
         },
         beginTranscript: @escaping BeginTranscript = { vocabulary, transcript in
             NVoiceController.shared.assistantBeginTranscript(vocabulary: vocabulary, onTranscript: transcript)
         },
         endTranscript: @escaping () -> Void = { NVoiceController.shared.assistantEndTranscript() },
         cancelRecording: @escaping () -> Void = { NVoiceController.shared.assistantCancel() }) {
        self.recordingAvailable = recordingAvailable
        self.startRecording = startRecording
        self.beginTranscript = beginTranscript
        self.endTranscript = endTranscript
        self.cancelRecording = cancelRecording
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        monitor?.cancel()
        monitor = nil
        pause()
        guard enabled else { status = "Off"; return }
        status = "Waiting for the microphone"
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    /// Called before speaking, manual listening, dictation or recording a sample. Never closes a recording
    /// already handed off.
    func pause() {
        generation += 1
        retryAt = Date().addingTimeInterval(0.8)
        if isRecording { cancelRecording() }
        isRecording = false
        isConfirming = false
        if enabled { status = "Paused while the microphone is in use" }
    }

    /// The recordings changed: start over with a matcher built from them.
    func reload() {
        guard enabled else { return }
        pause()
    }

    private func poll() async {
        guard enabled, canListen() else {
            if isRecording { pause() }
            return
        }
        if isRecording {
            if isConfirming, Date() >= confirmUntil {
                isConfirming = false
                endTranscript()
                status = Self.listeningStatus
                Diagnostics.log("assistant: it wasn't “Hey N” — transcript dropped, back to matching sound only")
            }
            return
        }
        guard !starting, Date() >= retryAt, recordingAvailable() else { return }
        guard let detector = makeDetector() else {
            status = Self.needsSamplesStatus
            return
        }
        starting = true
        defer { starting = false }
        let token = generation
        levels = []
        do {
            try await startRecording(
                Self.audioHandler(detector) { distance in
                    Task { @MainActor [weak self] in self?.matched(distance: distance, token: token) }
                }, { [weak self] in
                    guard let self else { return false }
                    guard self.enabled, self.generation == token, self.canListen() else { return false }
                    // Claim immediately before capture starts, before the async call returns to poll().
                    // A shortcut can then cancel our mic even in that return/scheduling window.
                    self.isRecording = true
                    return true
                }, { [weak self] level in
                    guard let self, self.isRecording, self.generation == token else { return }
                    self.levels.append(level)
                    if self.levels.count > 40 { self.levels.removeFirst() }
                })
            guard enabled, canListen(), generation == token else {
                // A wake may already have transferred it, or a shortcut cancelled ours and opened a new
                // recording. Never cancel that newer owner when this async call returns late.
                if generation == token, isRecording { pause() }
                return
            }
            isRecording = true
            status = Self.listeningStatus
        } catch {
            guard generation == token else { return }
            isRecording = false
            status = "Wake listening unavailable: \(error.localizedDescription)"
            retryAt = Date().addingTimeInterval(5)
            Diagnostics.log("assistant: wake listening unavailable — \(error.localizedDescription)")
        }
    }

    /// Runs on the audio queue, never on the main actor.
    nonisolated private static func audioHandler(_ detector: WakeDetecting,
                                                 onMatch: @escaping (Float) -> Void) -> ([Float]) -> Void {
        { samples in if let d = detector.feed(samples) { onMatch(d) } }
    }

    /// Stage 2: something sounded like “Hey N”. Transcribe a few seconds to be sure.
    func matched(distance: Float, token: Int) {
        guard enabled, isRecording, !isConfirming, generation == token, canListen() else { return }
        Diagnostics.log(String(format: "assistant: sounded like “Hey N” (distance %.2f) — confirming", distance))
        isConfirming = true
        confirmUntil = Date().addingTimeInterval(Self.confirmSeconds)
        beginTranscript(["Hey N", "Hey en", "Hey ene"] + vocabulary()) { [weak self] text in
            guard let self, self.isRecording, self.isConfirming, self.generation == token,
                  let prompt = AssistantWakeCommand.prompt(in: text), self.canListen() else { return }
            let sorted = self.levels.sorted()
            let floor = sorted.isEmpty ? 0 : sorted[sorted.count / 5]
            self.isRecording = false       // the Assistant now owns the running recording
            self.isConfirming = false
            self.generation += 1
            self.status = "Assistant awake"
            self.onWake?(prompt, floor)
        }
    }

    /// For tests: the generation a recording started now would get.
    var currentToken: Int { generation }
}
