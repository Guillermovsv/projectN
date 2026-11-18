import Foundation

/// The environment your login shell builds (PATH from Homebrew / nvm, exports in ~/.zshrc…), captured once and
/// reused for every Claude / Codex / Cursor pane.
///
/// Panes used to start as `zsh -l -i -c "<cli>"`, which runs all your startup files (~/.zprofile, ~/.zshrc, nvm.sh…)
/// again before the CLI even starts: about a second per pane on a typical setup (nvm alone takes most of it). With a
/// capture, a pane gets exactly the environment those files produce and starts as `zsh -f -i -c "<cli>"`: no startup
/// files, but still an interactive shell, so the CLI keeps its own process group as before. The shell you land in
/// after the CLI exits is still a full login shell.
///
/// The full login shell is used instead when the shell isn't zsh, there's no capture (yet, or it failed), a startup
/// file changed since it was taken, or the command is an alias or function (only your shell can run those).
enum LoginShell {
    struct Capture {
        let shell: String
        /// The environment the shell started with, and the one its startup files left behind.
        let input: [String: String]
        let output: [String: String]
        /// `whence -w` per command name: "command", "alias", "function", "builtin", "none"…
        let kinds: [String: String]
        /// The startup files' modification dates when captured (any change makes the capture stale).
        let stamp: String
        let at: Date

        /// Set per process by the shell itself (not something a startup file chose).
        static let volatile: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_"]

        /// Variables the startup files set or changed, and the ones they removed.
        var changes: (set: [String: String], removed: [String]) {
            var set: [String: String] = [:]
            for (k, v) in output where !Self.volatile.contains(k) && input[k] != v { set[k] = v }
            let removed = input.keys.filter { output[$0] == nil && !Self.volatile.contains($0) }
            return (set, removed)
        }

        /// The command's first word is a program on the captured PATH (not an alias / function / missing).
        func runsProgram(_ name: String) -> Bool { kinds[name] == "command" }

        /// `env` (KEY=VALUE entries) as the startup files would have left it.
        func applied(to env: [String]) -> [String] {
            var d = LoginShell.dictionary(env)
            let c = changes
            for k in c.removed { d.removeValue(forKey: k) }
            for (k, v) in c.set { d[k] = v }
            return d.map { "\($0.key)=\($0.value)" }
        }
    }

    /// Only zsh: `-f` (skip startup files) and `whence -w` are what this relies on.
    static func supports(_ shell: String) -> Bool { (shell as NSString).lastPathComponent == "zsh" }

    static func dictionary(_ env: [String]) -> [String: String] {
        var d: [String: String] = [:]
        for kv in env {
            guard let eq = kv.firstIndex(of: "=") else { continue }
            d[String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
        }
        return d
    }

    /// The startup files zsh reads for a login + interactive shell, with their modification dates.
    static func startupFilesStamp(environment: [String: String]) -> String {
        let dot = environment["ZDOTDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? environment["HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let files = ["/etc/zshenv", "/etc/zprofile", "/etc/zshrc", "/etc/zlogin"]
            + [".zshenv", ".zprofile", ".zshrc", ".zlogin"].map { (dot as NSString).appendingPathComponent($0) }
        return files.map { f -> String in
            let a = try? FileManager.default.attributesOfItem(atPath: f)
            let m = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let s = (a?[.size] as? NSNumber)?.intValue ?? -1
            return "\(f):\(m):\(s)"
        }.joined(separator: "|")
    }

    private static let envMark = "__PROJECTN_ENV__", kindsMark = "__PROJECTN_KINDS__", endMark = "__PROJECTN_END__"

    /// Runs your login shell once (`-l -i`) and records the environment it ends up with, plus what each command
    /// name resolves to. Blocking (about as long as your shell takes to start); never call it on the main thread.
    static func capture(shell: String, environment: [String: String], commands: [String],
                        directory: URL = FileManager.default.homeDirectoryForCurrentUser,
                        timeout: TimeInterval = 15) -> Capture? {
        guard supports(shell) else { return nil }
        let names = commands.filter { !$0.isEmpty }.map(Shell.quote).joined(separator: " ")
        let script = "builtin print -rn -- \(envMark); command env -0; builtin print -rn -- \(kindsMark); "
            + (names.isEmpty ? "" : "whence -w -- \(names) 2>/dev/null; ")
            + "builtin print -rn -- \(endMark)"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-i", "-c", script]
        p.environment = environment
        p.currentDirectoryURL = directory
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let buffer = Buffer()
        let done = DispatchSemaphore(value: 0)
        let end = Data(endMark.utf8)
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            // Stop at the end marker: something your startup files start in the background may keep the pipe open.
            if chunk.isEmpty || buffer.append(chunk, until: end) { h.readabilityHandler = nil; done.signal() }
        }
        let started = Date()
        do { try p.run() } catch { pipe.fileHandleForReading.readabilityHandler = nil; return nil }
        let finished = done.wait(timeout: .now() + timeout) == .success
        pipe.fileHandleForReading.readabilityHandler = nil
        // An interactive zsh ignores SIGTERM: a shell stuck in a startup file has to be killed.
        if !finished, p.isRunning { kill(p.processIdentifier, SIGKILL) }
        guard finished, let parsed = parse(buffer.data) else { return nil }
        return Capture(shell: shell, input: environment, output: parsed.env, kinds: parsed.kinds,
                       stamp: startupFilesStamp(environment: environment), at: started)
    }

    /// Splits the capture output: NUL-separated `KEY=VALUE` entries, then `name: kind` lines.
    static func parse(_ data: Data) -> (env: [String: String], kinds: [String: String])? {
        guard let text = String(data: data, encoding: .utf8),
              let a = text.range(of: envMark), let b = text.range(of: kindsMark, range: a.upperBound..<text.endIndex),
              let c = text.range(of: endMark, range: b.upperBound..<text.endIndex) else { return nil }
        var env: [String: String] = [:]
        for entry in text[a.upperBound..<b.lowerBound].split(separator: "\0") {
            guard let eq = entry.firstIndex(of: "="), eq != entry.startIndex else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        guard env["PATH"] != nil else { return nil }
        var kinds: [String: String] = [:]
        for line in text[b.upperBound..<c.lowerBound].split(separator: "\n") {
            guard let r = line.range(of: ": ", options: .backwards) else { continue }
            kinds[String(line[..<r.lowerBound])] = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return (env, kinds)
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
        /// Appends; true once `marker` has arrived.
        func append(_ chunk: Data, until marker: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            bytes.append(chunk)
            return bytes.range(of: marker) != nil
        }
    }

    // MARK: Cache

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Capture?
    nonisolated(unsafe) private static var failedAt: Date?
    nonisolated(unsafe) private static var refreshing = false
    /// Older captures are still used, but taken again in the background (things your startup files read can change
    /// without the files themselves changing, e.g. `nvm alias default`).
    static let maxAge: TimeInterval = 30 * 60
    private static let refreshQueue = DispatchQueue(label: "dev.projectn.login-shell", qos: .utility)

    /// First words of the configured Claude / Codex / Cursor commands.
    static func commandNames(_ settings: AppSettings) -> [String] {
        [settings.claudeCommand, settings.codexCommand, settings.cursorCommand].compactMap { Shell.split($0).first }
    }

    /// The capture a pane launch should use, taking it now if needed (blocking: call it off the main thread, e.g. on
    /// the Store's launch queue). nil → start through the full login shell, as before.
    static func forLaunch(settings: AppSettings) -> Capture? {
        guard settings.fastPaneStart else { return nil }
        let shell = settings.shell.isEmpty ? "/bin/zsh" : settings.shell
        guard supports(shell) else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let input = dictionary(Launcher.environment(project: Project(name: "home", path: home.path), workspaceName: "", settings: settings))
        let commands = commandNames(settings)
        let stamp = startupFilesStamp(environment: input)
        lock.lock()
        let current = cached
        let failed = failedAt
        lock.unlock()
        if let c = current, c.shell == shell, c.stamp == stamp, commands.allSatisfy({ c.kinds[$0] != nil }) {
            if Date().timeIntervalSince(c.at) > maxAge { refreshInBackground(shell: shell, input: input, commands: commands) }
            return c
        }
        // A capture that failed (timeout, odd output) isn't retried on every launch.
        if let failed, Date().timeIntervalSince(failed) < 5 * 60 { return nil }
        let fresh = capture(shell: shell, environment: input, commands: commands)
        remember(fresh)
        return fresh
    }

    private static func remember(_ c: Capture?) {
        lock.lock()
        if let c { cached = c; failedAt = nil } else { failedAt = Date() }
        lock.unlock()
    }

    private static func refreshInBackground(shell: String, input: [String: String], commands: [String]) {
        lock.lock()
        let already = refreshing
        refreshing = true
        lock.unlock()
        guard !already else { return }
        refreshQueue.async {
            let fresh = capture(shell: shell, environment: input, commands: commands)
            lock.lock(); refreshing = false; lock.unlock()
            if let fresh { remember(fresh) }
        }
    }

    /// Tests: forget the cached capture.
    static func reset() {
        lock.lock(); cached = nil; failedAt = nil; lock.unlock()
    }
}
