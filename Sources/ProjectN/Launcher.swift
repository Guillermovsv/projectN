import Foundation

/// Builds the shell command + environment used to start a pane.
enum Launcher {
    struct Plan {
        var executable: String
        var args: [String]
        var environment: [String]
        var directory: String
        var commandLine: String   // what we display
    }

    /// How the tool should treat its conversation.
    enum SessionMode {
        case fresh
        case claudeNew(id: String)        // claude --session-id <id>
        case claudeResume(id: String)     // claude --resume <id>
        case codexResume(id: String)      // codex resume <id>
        case cursorResume(id: String)     // cursor-agent --resume <id>
    }

    /// `extraArgs` (agent profiles: system prompt, tool limits) go after the regular flags.
    /// `prompt` starts the session with that first message; it is always placed after `--`
    /// so variadic flags (`--tools`, `--add-dir`) can't swallow it, and never interpreted by a shell.
    static func plan(tool: Tool, mode: SessionMode, options: LaunchOptions = LaunchOptions(), project: Project, workspaceName: String,
                     settings: AppSettings, extraArgs: [String] = [], prompt: String? = nil,
                     exitMarker: URL? = nil, extraEnv: [String: String] = [:]) -> Plan {
        let shell = settings.shell.isEmpty ? "/bin/zsh" : settings.shell
        let servers = MCPConfig.load()
        var parts: [String] = []

        switch tool {
        case .claude:
            parts = Shell.split(settings.claudeCommand)
            switch mode {
            case .claudeNew(let id): parts += ["--session-id", id]
            case .claudeResume(let id): parts += ["--resume", id]
            default: break
            }
            if settings.claudeUseAppMCP && !servers.isEmpty {
                parts += ["--mcp-config", AppHome.mcpFile.path]
            }
            parts += LaunchCatalog.claudeArgs(options)
            parts += Shell.split(settings.claudeExtraArgs)
            parts += extraArgs
            if let prompt, !prompt.isEmpty { parts += ["--", prompt] }
        case .codex:
            parts = Shell.split(settings.codexCommand)
            var resumeID: String?
            if case .codexResume(let id) = mode { parts.append("resume"); resumeID = id }
            if settings.codexUseAppMCP { parts += MCPConfig.codexOverrides(servers) }
            parts += LaunchCatalog.codexArgs(options)
            parts += Shell.split(settings.codexExtraArgs)
            parts += extraArgs
            if let resumeID { parts.append(resumeID) }
            if let prompt, !prompt.isEmpty { parts += ["--", prompt] }
        case .cursor:
            parts = Shell.split(settings.cursorCommand)
            if case .cursorResume(let id) = mode { parts += ["--resume", id] }
            parts += LaunchCatalog.cursorArgs(options)
            parts += Shell.split(settings.cursorExtraArgs)
        case .terminal:
            break
        }

        let commandLine = parts.map(Shell.quote).joined(separator: " ")
        let args: [String]
        if tool == .terminal {
            args = ["-l", "-i"]
        } else {
            // Run through an interactive login shell so the user's PATH (nvm, ~/.local/bin, …) is set up,
            // then drop into a shell in the same folder when the tool exits.
            // Agent panes: record the tool's exit code so the harness can tell a crash from a finished turn.
            let marker = exitMarker.map { "; __pn_rc=$?; echo $__pn_rc > \(Shell.quote($0.path))" } ?? ""
            let script = "\(commandLine)\(marker); echo; echo \"[\(tool.label) exited — you're in a shell now]\"; exec \(Shell.quote(shell)) -l -i"
            args = ["-l", "-i", "-c", script]
        }

        var env = environment(project: project, workspaceName: workspaceName, settings: settings)
        if !extraEnv.isEmpty {
            env.removeAll { kv in extraEnv.keys.contains { kv.hasPrefix($0 + "=") } }
            env += extraEnv.map { "\($0.key)=\($0.value)" }
        }
        return Plan(executable: shell,
                    args: args,
                    environment: env,
                    directory: project.path,
                    commandLine: tool == .terminal ? shell : commandLine)
    }

    /// Runs an arbitrary command (e.g. "claude auth login") in the user's login shell from the home folder.
    static func commandPlan(_ command: String, settings: AppSettings) -> Plan {
        let shell = settings.shell.isEmpty ? "/bin/zsh" : settings.shell
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let script = "\(command); echo; echo '[Finished — you can close this window]'"
        return Plan(executable: shell, args: ["-l", "-i", "-c", script],
                    environment: environment(project: Project(name: "home", path: home), workspaceName: "", settings: settings),
                    directory: home, commandLine: command)
    }

    static func environment(project: Project, workspaceName: String, settings: AppSettings) -> [String] {
        var env = ProcessInfo.processInfo.environment
        // Don't leak "we're inside Claude Code / Codex" markers if the app was started from one of them.
        // (Your shell rc files still run, so anything you export there is re-applied.)
        for k in env.keys where k == "CLAUDECODE" || k.hasPrefix("CLAUDE_CODE_") || k.hasPrefix("CODEX_SANDBOX") || k == "CODEX_THREAD_ID" {
            env.removeValue(forKey: k)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "ProjectN"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        let extraPath = [AppHome.binDir.path, AppHome.mcpDir.appendingPathComponent("node_modules/.bin").path]
        env["PATH"] = (extraPath + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        env["PROJECTN_HOME"] = AppHome.root.path
        env["PROJECTN_MCP_CONFIG"] = AppHome.mcpFile.path
        env["PROJECTN_WORKSPACE"] = workspaceName
        env["PROJECTN_PROJECT"] = project.name
        env["PWD"] = project.path
        // API keys / tokens from Settings → Accounts & Connections (stored in the Keychain).
        for (k, v) in Secrets.environment(names: settings.apiKeyNames) { env[k] = v }
        if settings.isolateClaudeConfig {
            try? FileManager.default.createDirectory(at: AppHome.claudeConfigDir, withIntermediateDirectories: true)
            env["CLAUDE_CONFIG_DIR"] = AppHome.claudeConfigDir.path
        }
        if settings.isolateCodexHome {
            try? FileManager.default.createDirectory(at: AppHome.codexHomeDir, withIntermediateDirectories: true)
            env["CODEX_HOME"] = AppHome.codexHomeDir.path
        }
        return env.map { "\($0.key)=\($0.value)" }
    }
}
