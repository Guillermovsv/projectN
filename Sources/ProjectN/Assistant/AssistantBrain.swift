import Foundation

/// A Claude CLI session kept running between questions, so the Assistant doesn't pay the CLI's ~3 s start-up on
/// every one: questions go in as stream-json lines on stdin and the answer streams back. No tools, no MCP, no
/// settings, no web. It is started when the Assistant opens and closed after a few idle minutes (or after enough
/// questions that its context would get heavy), so it costs nothing while you don't use the Assistant.
final class AssistantBrain: @unchecked Sendable {
    static let shared = AssistantBrain()

    static let idleSeconds: TimeInterval = 300
    static let maxTurns = 14

    private let q = DispatchQueue(label: "dev.projectn.assistant.brain")
    private var proc: Process?
    private var input: FileHandle?
    private var key = ""                 // model + system prompt it was started with
    private var turns = 0
    private var buffer = Data()
    private var errTail = ""
    private var idle: DispatchWorkItem?
    private struct Ask {
        let id: UUID
        var text = ""
        let onText: (String) -> Void
        let done: (Result<String, Error>) -> Void
    }
    private var current: Ask?

    /// Starts the session ahead of the first question.
    func prewarm(model: String, system: String) {
        q.async { _ = try? self.ensure(model: model, system: system) }
    }

    /// Asks one question; `onText` gets the answer as it's written (main thread). Cancelling stops it.
    func ask(_ text: String, model: String, system: String, timeout: TimeInterval = 60,
             onText: @escaping (String) -> Void) async throws -> String {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                q.async {
                    // One question at a time: an unfinished one is dropped together with its session.
                    if self.current != nil { self.fail(CancellationError(), restart: true) }
                    do { try self.ensure(model: model, system: system) } catch { cont.resume(throwing: error); return }
                    self.current = Ask(id: id, onText: onText, done: { cont.resume(with: $0) })
                    self.idle?.cancel()
                    let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
                    guard var line = try? JSONSerialization.data(withJSONObject: msg) else { return }
                    line.append(0x0A)
                    self.input?.write(line)
                    self.q.asyncAfter(deadline: .now() + timeout) {
                        if self.current?.id == id { self.fail(EnhancerError.timeout, restart: true) }
                    }
                }
            }
        } onCancel: {
            q.async { if self.current?.id == id { self.fail(CancellationError(), restart: true) } }
        }
    }

    func shutdown() { q.async { self.stop() } }

    // MARK: Process (on q)

    @discardableResult
    private func ensure(model: String, system: String) throws -> Bool {
        let k = model + "\u{1}" + system
        if let p = proc, p.isRunning, key == k, turns < Self.maxTurns { return false }
        stop()
        guard let bin = Enhancer.locate(.claude, override: NVoiceSettings.shared.claudePath) else {
            throw EnhancerError.cliNotFound("claude")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-p", "--model", model, "--system-prompt", system,
                       "--tools", "", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "",
                       "--input-format", "stream-json", "--output-format", "stream-json",
                       "--include-partial-messages", "--verbose"]
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (Enhancer.searchDirs + [env["PATH"] ?? ""]).joined(separator: ":")
        env["NO_COLOR"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = inp
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            self?.q.async { self?.consume(d, from: p) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            self?.q.async { self?.errTail = String((self?.errTail ?? "") + String(decoding: d, as: UTF8.self)).suffix(600).description }
        }
        p.terminationHandler = { [weak self] ended in
            self?.q.async {
                guard let self, self.proc === ended else { return }
                self.proc = nil
                if self.current != nil {
                    let why = self.errTail.split(separator: "\n").last.map(String.init) ?? "exit code \(ended.terminationStatus)"
                    self.fail(EnhancerError.failed("claude: \(why)"), restart: false)
                }
            }
        }
        try p.run()
        proc = p; input = inp.fileHandleForWriting; key = k; turns = 0; buffer = Data(); errTail = ""
        scheduleIdle()
        return true
    }

    private func consume(_ data: Data, from p: Process) {
        guard p === proc else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard current != nil else { continue }
            let s = Substring(String(decoding: line, as: UTF8.self))
            if let t = Enhancer.streamDelta(s) {
                current?.text += t
                let cb = current?.onText
                DispatchQueue.main.async { cb?(t) }
            } else if s.contains(#""type":"result""#),
                      let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                      obj["type"] as? String == "result" {
                let ask = current!
                current = nil
                turns += 1
                scheduleIdle()
                if obj["is_error"] as? Bool == true {
                    ask.done(.failure(EnhancerError.failed("claude: \(obj["result"] as? String ?? "error")")))
                } else {
                    let text = ask.text.isEmpty ? (obj["result"] as? String ?? "") : ask.text
                    ask.done(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }
    }

    /// Ends the current question with an error. With `restart`, the session (which may still be answering) is
    /// replaced by a fresh one so the next question is quick again.
    private func fail(_ error: Error, restart: Bool) {
        let ask = current
        current = nil
        let k = key
        if restart, proc != nil {
            stop()
            let parts = k.components(separatedBy: "\u{1}")
            if parts.count == 2 { _ = try? ensure(model: parts[0], system: parts[1]) }
        }
        ask?.done(.failure(error))
    }

    private func stop() {
        idle?.cancel()
        guard let p = proc else { return }
        proc = nil
        try? input?.close()
        input = nil
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (p.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if p.isRunning { p.terminate() }
    }

    private func scheduleIdle() {
        idle?.cancel()
        let w = DispatchWorkItem { [weak self] in if self?.current == nil { self?.stop() } }
        idle = w
        q.asyncAfter(deadline: .now() + Self.idleSeconds, execute: w)
    }
}
