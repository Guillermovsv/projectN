import AppKit
import Foundation
import Testing
@testable import ProjectN

/// Incremental transcript reads, the fast pane start (captured login environment) and the off-main file tree.
@Suite(.serialized)
struct PerformanceTests {
    private func tempDir(_ name: String) throws -> URL {
        let url = TestHome.url.appendingPathComponent("perf-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func json(_ o: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), encoding: .utf8)!
    }

    private func append(_ data: Data, to url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: data)
    }

    /// What a read from scratch would return: every line from `offset` parsed.
    private func fullParse(_ runtime: AgentRuntime, _ url: URL, offset: UInt64) throws -> TranscriptReader.Snapshot {
        let data = try Data(contentsOf: url)
        let part = data.count > Int(offset) ? Data(data[Int(offset)...]) : Data()
        var s = runtime == .claudeCode ? TranscriptReader.parseClaude(part) : TranscriptReader.parseCodex(part)
        s.size = UInt64(data.count)
        return s
    }

    /// Writes each entry in two halves and checks, after every write, that the incremental reader (which only parses
    /// what was appended) says exactly what parsing everything again says.
    private func checkIncremental(_ runtime: AgentRuntime, prefix: [String], entries: [String]) throws {
        let url = try tempDir("transcript").appendingPathComponent("t.jsonl")
        let head = Data(prefix.map { $0 + "\n" }.joined().utf8)
        try head.write(to: url)
        let offset = UInt64(head.count)
        var cursor: TranscriptReader.Cursor?
        for entry in entries {
            let bytes = Data((entry + "\n").utf8)
            let half = bytes.count / 2
            for piece in [bytes.prefix(half), bytes.suffix(from: half)] {
                try append(Data(piece), to: url)
                let incremental = TranscriptReader.read(runtime: runtime, url: url, offset: offset, cursor: &cursor)
                #expect(incremental == (try fullParse(runtime, url, offset: offset)))
            }
        }
        // A replaced file (another inode) starts over instead of continuing from the old position.
        try Data((prefix + [entries[0]]).map { $0 + "\n" }.joined().utf8).write(to: url, options: .atomic)
        let replaced = TranscriptReader.read(runtime: runtime, url: url, offset: offset, cursor: &cursor)
        #expect(replaced == (try fullParse(runtime, url, offset: offset)))
    }

    @Test func incrementalClaudeTranscriptReadsMatchAFullParse() throws {
        let usage: [String: Any] = ["input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 3]
        func assistant(_ id: String, _ stop: String, _ content: [[String: Any]], extra: [String: Any] = [:]) -> String {
            json(["type": "assistant", "message": ["id": id, "role": "assistant", "stop_reason": stop, "content": content, "usage": usage]]
                .merging(extra) { $1 })
        }
        let user = { (t: String) in self.json(["type": "user", "message": ["role": "user", "content": t]]) }
        try checkIncremental(.claudeCode, prefix: [user("earlier task"), assistant("m0", "end_turn", [["type": "text", "text": "old"]])], entries: [
            user("revisa el README"),
            assistant("m1", "tool_use", [["type": "text", "text": "Voy a mirar"], ["type": "tool_use", "name": "Read", "input": ["file": "README.md"]]]),
            json(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": String(repeating: "x", count: 5000)]]]]),
            assistant("m2", "end_turn", [["type": "text", "text": "Listo: el README está bien."]]),
            json(["type": "system", "subtype": "turn_duration", "durationMs": 1200]),
            user("ahora un plan"),
            assistant("m3", "tool_use", [["type": "tool_use", "name": "ExitPlanMode", "input": ["plan": "1. hacer X"]]]),
            assistant("m4", "end_turn", [["type": "text", "text": "You've hit your usage limit"]], extra: ["isApiErrorMessage": true]),
        ])
    }

    @Test func incrementalCodexTranscriptReadsMatchAFullParse() throws {
        func event(_ type: String, _ payload: [String: Any]) -> String { json(["type": type, "payload": payload]) }
        try checkIncremental(.codexCLI, prefix: [event("session_meta", ["id": "abc", "cwd": "/tmp"])], entries: [
            event("event_msg", ["type": "task_started"]),
            event("response_item", ["type": "message", "role": "assistant", "phase": "commentary", "content": [["type": "output_text", "text": "Voy a revisar"]]]),
            event("event_msg", ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 50, "cached_input_tokens": 10, "output_tokens": 7],
                                                                  "last_token_usage": ["input_tokens": 40]]]),
            event("response_item", ["type": "function_call_output", "output": String(repeating: "y", count: 8000)]),
            event("event_msg", ["type": "task_complete", "last_agent_message": "Hecho"]),
            event("event_msg", ["type": "task_started"]),
            event("event_msg", ["type": "task_complete", "error": ["message": "You've hit your usage limit", "codex_error_info": "usage_limit_exceeded"]]),
        ])
    }

    @Test func lastPromptOnlyReadsWhatWasAppended() throws {
        var settings = AppSettings()
        settings.isolateClaudeConfig = true
        let id = UUID().uuidString
        let url = AppHome.claudeConfigDir.appendingPathComponent("projects/perf/\(id).jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let user = { (t: String) in self.json(["type": "user", "message": ["role": "user", "content": t]]) }
        try Data((user("uno") + "\n").utf8).write(to: url)
        #expect(PromptTracker.lastPrompt(tool: .claude, sessionID: id, settings: settings) == "uno")
        // Assistant output and tool results after it: still the same prompt.
        let busy = json(["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": String(repeating: "z", count: 20_000)]]]])
        try append(Data((busy + "\n").utf8), to: url)
        try append(Data((json(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": "ok"]]]]) + "\n").utf8), to: url)
        #expect(PromptTracker.lastPrompt(tool: .claude, sessionID: id, settings: settings) == "uno")
        // A prompt being written (half a line) doesn't count yet; once complete it does.
        let next = Data((user("dos") + "\n").utf8)
        try append(Data(next.prefix(10)), to: url)
        #expect(PromptTracker.lastPrompt(tool: .claude, sessionID: id, settings: settings) == "uno")
        try append(Data(next.suffix(from: 10)), to: url)
        #expect(PromptTracker.lastPrompt(tool: .claude, sessionID: id, settings: settings) == "dos")
        // A whole line still missing its newline is already the newest prompt.
        try append(Data(user("tres").utf8), to: url)
        #expect(PromptTracker.lastPrompt(tool: .claude, sessionID: id, settings: settings) == "tres")
        try append(Data("\n".utf8), to: url)
        #expect(PromptTracker.lastPrompt(tool: .claude, sessionID: id, settings: settings) == "tres")
    }

    // MARK: Fast pane start

    /// A ZDOTDIR with its own .zshrc, so the capture never runs your real startup files.
    private func fakeShellHome() throws -> (dir: URL, input: [String: String]) {
        let dir = try tempDir("zdot")
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("pn-fake-cli")
        try "#!/bin/sh\necho \"$PN_FROM_RC\" > \(Shell.quote(dir.appendingPathComponent("out.txt").path))\nexec sleep 30\n"
            .write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        try """
        export PN_FROM_RC="set by rc"
        export PATH=\(Shell.quote(bin.path)):$PATH
        alias pnalias='echo hi'
        unset PN_REMOVE_ME
        """.write(to: dir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let input = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "ZDOTDIR": dir.path,
                     "PN_REMOVE_ME": "x", "LANG": "en_US.UTF-8"]
        return (dir, input)
    }

    @Test func capturesWhatTheStartupFilesSetAndHowCommandsResolve() throws {
        let (dir, input) = try fakeShellHome()
        let c = try #require(LoginShell.capture(shell: "/bin/zsh", environment: input,
                                                commands: ["pn-fake-cli", "pnalias", "pn-missing-cli"], directory: dir))
        let changes = c.changes
        #expect(changes.set["PN_FROM_RC"] == "set by rc")
        #expect(changes.set["PATH"]?.hasPrefix(dir.appendingPathComponent("bin").path + ":") == true)
        #expect(changes.removed.contains("PN_REMOVE_ME"))
        #expect(changes.set["PWD"] == nil && changes.set["SHLVL"] == nil && changes.set["_"] == nil)
        #expect(c.runsProgram("pn-fake-cli"))
        #expect(!c.runsProgram("pnalias"))
        #expect(!c.runsProgram("pn-missing-cli"))
        #expect(c.stamp == LoginShell.startupFilesStamp(environment: input))
        // Other shells aren't captured.
        #expect(LoginShell.capture(shell: "/bin/bash", environment: input, commands: []) == nil)
    }

    @Test func plansUseTheCaptureOnlyWhenItApplies() {
        let cap = LoginShell.Capture(shell: "/bin/zsh",
                                     input: ["PATH": "/usr/bin", "KEEP": "1"],
                                     output: ["PATH": "/opt/x/bin:/usr/bin", "KEEP": "1", "NEW": "y", "PWD": "/elsewhere", "SHLVL": "3"],
                                     kinds: ["claude": "command", "codex": "alias"], stamp: "", at: Date())
        var s = AppSettings()
        s.shell = "/bin/zsh"
        s.claudeCommand = "claude"
        s.codexCommand = "codex"
        s.claudeUseAppMCP = false
        s.codexUseAppMCP = false
        let project = Project(name: "p", path: "/tmp/p")
        let fast = Launcher.plan(tool: .claude, mode: .fresh, project: project, workspaceName: "w", settings: s, login: cap)
        #expect(fast.args.first == "-f")
        #expect(fast.args.dropFirst().first == "-i")
        #expect(fast.args.last?.hasSuffix("exec /bin/zsh -l -i") == true)   // still a full login shell after the CLI exits
        let env = LoginShell.dictionary(fast.environment)
        #expect(env["PATH"] == "/opt/x/bin:/usr/bin")
        #expect(env["NEW"] == "y")
        #expect(env["PWD"] == "/tmp/p")
        #expect(env["TERM_PROGRAM"] == "ProjectN")
        #expect(env["PROJECTN_PROJECT"] == "p")
        // An alias needs the real shell; so does another shell; and without a capture nothing changes.
        #expect(Launcher.plan(tool: .codex, mode: .fresh, project: project, workspaceName: "w", settings: s, login: cap).args.first == "-l")
        var bash = s
        bash.shell = "/bin/bash"
        #expect(Launcher.plan(tool: .claude, mode: .fresh, project: project, workspaceName: "w", settings: bash, login: cap).args.first == "-l")
        #expect(Launcher.plan(tool: .claude, mode: .fresh, project: project, workspaceName: "w", settings: s).args.first == "-l")
        // Terminal panes are your interactive login shell itself.
        #expect(Launcher.plan(tool: .terminal, mode: .fresh, project: project, workspaceName: "w", settings: s, login: cap).args == ["-l", "-i"])
    }

    @MainActor
    @Test func fastStartRunsTheCLIInATerminalWithTheCapturedEnvironment() async throws {
        _ = NSApplication.shared
        let (dir, input) = try fakeShellHome()
        let cap = try #require(LoginShell.capture(shell: "/bin/zsh", environment: input, commands: ["pn-fake-cli"], directory: dir))
        var s = AppSettings()
        s.shell = "/bin/zsh"
        s.claudeCommand = "pn-fake-cli"
        s.claudeUseAppMCP = false
        s.claudeUsesBuiltInBrowser = false
        let plan = Launcher.plan(tool: .claude, mode: .fresh, project: Project(name: "p", path: dir.path),
                                 workspaceName: "w", settings: s, login: cap)
        #expect(plan.args.first == "-f")
        let rt = TerminalSession(id: UUID(), plan: plan, fontSize: 13)
        defer { rt.terminate() }
        let out = dir.appendingPathComponent("out.txt")
        let deadline = Date().addingTimeInterval(10)
        var text = ""
        while Date() < deadline {
            text = (try? String(contentsOf: out, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(text == "set by rc")
    }

    // MARK: Files panel

    @MainActor
    @Test func fileTreeRefreshPicksUpChangesWithoutBlocking() async throws {
        let dir = try tempDir("tree")
        try "a".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let model = FileTreeModel()
        model.setRoot(dir)
        #expect(model.rows().map(\.0.name) == ["a.txt"])
        try "b".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        model.refresh()
        let deadline = Date().addingTimeInterval(5)
        while model.rows().map(\.0.name) != ["a.txt", "b.txt"], Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.rows().map(\.0.name) == ["a.txt", "b.txt"])
    }
}
