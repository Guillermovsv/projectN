import Foundation

enum EnhancerError: LocalizedError {
    case cliNotFound(String)
    case failed(String)
    case timeout
    var errorDescription: String? {
        switch self {
        case .cliNotFound(let n): return "Could not find the `\(n)` CLI. Install it or set its path in Settings › AI."
        case .failed(let m): return m
        case .timeout: return "The AI took too long to respond."
        }
    }
}

/// Rewrites dictated text into a polished prompt using the locally logged-in
/// Claude Code (`claude -p`) or Codex (`codex exec`) CLI — i.e. your subscription, no API key.
enum Enhancer {
    static let searchDirs: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
                "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin", "/usr/bin", "/bin"]
    }()

    static func locate(_ provider: AIProvider, override: String) -> String? {
        let fm = FileManager.default
        let o = (override as NSString).expandingTildeInPath
        if !o.isEmpty, fm.isExecutableFile(atPath: o) { return o }
        for dir in searchDirs {
            let p = "\(dir)/\(provider.binaryName)"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        // Last resort: ask a login shell (picks up nvm / custom PATHs).
        let out = try? run("/bin/zsh", ["-lc", "command -v \(provider.binaryName)"], stdin: nil, timeout: 5)
        let path = out?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fm.isExecutableFile(atPath: path) ? path : nil
    }

    static func enhance(_ text: String, settings s: NVoiceSettings) async throws -> String {
        let provider = s.provider
        let model = s.effectiveModel
        let system = s.enhancePrompt
        let override = provider == .claude ? s.claudePath : s.codexPath
        return try await Task.detached(priority: .userInitiated) {
            guard let bin = locate(provider, override: override) else { throw EnhancerError.cliNotFound(provider.binaryName) }
            let result: (stdout: String, stderr: String, status: Int32)
            switch provider {
            case .claude:
                result = try run(bin, [
                    "-p", "--model", model,
                    "--system-prompt", system,
                    "--tools", "",
                    "--no-session-persistence",
                    "--strict-mcp-config",
                    "--setting-sources", "",
                ], stdin: text, timeout: 90)
            case .codex:
                let outFile = FileManager.default.temporaryDirectory.appendingPathComponent("nvoice-\(UUID().uuidString).txt")
                defer { try? FileManager.default.removeItem(at: outFile) }
                var args = ["exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only",
                            "-m", model, "-c", "model_reasoning_effort=\"low\"",
                            "--color", "never", "-o", outFile.path]
                for name in codexMCPServers() { args += ["-c", "mcp_servers.\(name).enabled=false"] }
                args.append("-")
                let prompt = "\(system)\n\n<dictation>\n\(text)\n</dictation>"
                let r = try run(bin, args, stdin: prompt, timeout: 120)
                let last = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
                result = (last, r.stderr + r.stdout, r.status)
            }
            let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.status == 0, !out.isEmpty else {
                let err = result.stderr.split(separator: "\n").last(where: { $0.contains("ERROR") || $0.contains("rror") }).map(String.init)
                    ?? result.stderr.split(separator: "\n").last.map(String.init) ?? "exit code \(result.status)"
                throw EnhancerError.failed("\(provider.rawValue): \(err)")
            }
            return out
        }.value
    }

    /// Names of MCP servers in ~/.codex/config.toml, so we can turn them off for this one-shot call (much faster startup).
    static func codexMCPServers() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        guard let toml = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var names = Set<String>()
        for line in toml.split(separator: "\n") where line.hasPrefix("[mcp_servers.") {
            let rest = line.dropFirst("[mcp_servers.".count)
            if let name = rest.split(whereSeparator: { $0 == "." || $0 == "]" }).first { names.insert(String(name)) }
        }
        return names.sorted()
    }

    // MARK: Process

    @discardableResult
    static func run(_ path: String, _ args: [String], stdin: String?, timeout: TimeInterval) throws -> (stdout: String, stderr: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchDirs + [env["PATH"] ?? ""]).joined(separator: ":")
        env["NO_COLOR"] = "1"
        p.environment = env

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = inPipe

        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter(); group.enter()
        DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        try p.run()
        if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? inPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() > deadline { p.terminate(); throw EnhancerError.timeout }
            Thread.sleep(forTimeInterval: 0.05)
        }
        group.wait()
        return (String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self), p.terminationStatus)
    }
}
