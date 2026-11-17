import Foundation

/// Match the spoken letter in English or Spanish, with word boundaries so “hey anyone” cannot wake us.
enum AssistantWakeCommand {
    private static let phrase = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}])hey[\\s,]+(?:n|en|ene)(?![\\p{L}\\p{N}])", options: [.caseInsensitive])

    /// nil means no wake command; an empty string means the user has only said “Hey N” so far.
    static func prompt(in transcript: String) -> String? {
        let text = transcript as NSString
        guard let match = phrase.matches(in: transcript, range: NSRange(location: 0, length: text.length)).last else { return nil }
        return text.substring(from: NSMaxRange(match.range))
            .replacingOccurrences(of: "^(?:\\s|[,!?;:]|\\.(?=\\s|$))+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Passive, on-device wake listening using NVoice's existing recognizer and microphone. On wake, ownership
/// transfers to the Assistant without restarting capture: “Hey N, open…” stays in one recording.
@MainActor
final class AssistantWakeListener {
    typealias StartRecording = ([String], @escaping (String) -> Void, @escaping () -> Bool,
                               @escaping (Float) -> Void) async throws -> Void
    var canListen: () -> Bool = { false }
    var vocabulary: () -> [String] = { [] }
    var onWake: ((String, Float) -> Void)?
    var onStatus: ((String) -> Void)?
    private(set) var isRecording = false
    private var enabled = false
    private var starting = false
    private var generation = 0
    private var monitor: Task<Void, Never>?
    private var began = Date.distantPast
    private var retryAt = Date.distantPast
    private var levels: [Float] = []
    private let recordingAvailable: () -> Bool
    private let startRecording: StartRecording
    private let cancelRecording: () -> Void
    private var status = "Off" {
        didSet { if status != oldValue { onStatus?(status) } }
    }

    init(recordingAvailable: @escaping () -> Bool = { NVoiceController.shared.assistantRecordingAvailable },
         startRecording: @escaping StartRecording = { vocabulary, transcript, shouldStart, level in
             try await NVoiceController.shared.assistantStart(vocabulary: vocabulary, onTranscript: transcript,
                                                             shouldStart: shouldStart, onLevel: level)
         }, cancelRecording: @escaping () -> Void = { NVoiceController.shared.assistantCancel() }) {
        self.recordingAvailable = recordingAvailable
        self.startRecording = startRecording
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

    /// Called before speaking, manual listening or dictation. Never closes a recording already handed off.
    func pause() {
        generation += 1
        retryAt = Date().addingTimeInterval(0.8)
        if isRecording { cancelRecording() }
        isRecording = false
        if enabled { status = "Paused while the microphone is in use" }
    }

    private func poll() async {
        guard enabled, canListen() else {
            if isRecording { pause() }
            return
        }
        // Bound passive audio/transcript memory. Ambient audio is discarded, never saved to history.
        if isRecording, Date().timeIntervalSince(began) > 30 { pause() }
        guard !isRecording, !starting, Date() >= retryAt,
              recordingAvailable() else { return }
        starting = true
        defer { starting = false }
        let token = generation
        levels = []
        do {
            try await startRecording(
                ["Hey N", "Hey en", "Hey ene"] + vocabulary(),
                { [weak self] text in
                    guard let self, self.isRecording, self.generation == token,
                          let prompt = AssistantWakeCommand.prompt(in: text), self.canListen() else { return }
                    let sorted = self.levels.sorted()
                    let floor = sorted.isEmpty ? 0 : sorted[sorted.count / 5]
                    self.isRecording = false       // the Assistant now owns the running recording
                    self.generation += 1
                    self.status = "Assistant awake"
                    self.onWake?(prompt, floor)
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
                // A wake callback may already have transferred it, or a shortcut cancelled ours and opened
                // a new recording. Never cancel that newer owner when this async call returns late.
                if generation == token, isRecording { pause() }
                return
            }
            isRecording = true
            began = Date()
            status = "Listening for “Hey N”"
        } catch {
            guard generation == token else { return }
            isRecording = false
            status = "Wake listening unavailable: \(error.localizedDescription)"
            retryAt = Date().addingTimeInterval(5)
            Diagnostics.log("assistant: wake listening unavailable — \(error.localizedDescription)")
        }
    }
}
