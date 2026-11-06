import Foundation

/// The choices offered in a pane's Model / Effort / Permissions menus, and how each maps to CLI flags.
enum LaunchCatalog {
    struct Choice: Identifiable, Hashable {
        var id: String { value }
        let value: String
        let label: String
        var detail: String? = nil
        var dangerous = false
        var older = false
    }

    // MARK: Claude

    /// Explicit model versions (IDs as Claude Code knows them), newest first.
    static let claudeModels: [Choice] = [
        Choice(value: "claude-fable-5-1", label: "Fable 5.1", detail: "Most capable"),
        Choice(value: "claude-opus-5-5", label: "Opus 5.5"),
        Choice(value: "claude-sonnet-5-5", label: "Sonnet 5.5"),
        Choice(value: "claude-haiku-5-5", label: "Haiku 5.5", detail: "Fastest"),
        Choice(value: "claude-fable-5", label: "Fable 5", older: true),
        Choice(value: "claude-opus-5", label: "Opus 5", older: true),
        Choice(value: "claude-sonnet-5", label: "Sonnet 5", older: true),
        Choice(value: "claude-opus-4-8", label: "Opus 4.8", older: true),
        Choice(value: "claude-opus-4-7", label: "Opus 4.7", older: true),
        Choice(value: "claude-opus-4-6", label: "Opus 4.6", older: true),
        Choice(value: "claude-sonnet-4-6", label: "Sonnet 4.6", older: true),
        Choice(value: "claude-sonnet-4-5", label: "Sonnet 4.5", older: true),
        Choice(value: "claude-haiku-4-5", label: "Haiku 4.5", older: true),
    ]

    /// Claude Code's aliases point at the latest version of each family.
    static let claudeAliases: [String: String] = [
        "fable": "claude-fable-5-1", "opus": "claude-opus-5-5", "sonnet": "claude-sonnet-5-5", "haiku": "claude-haiku-5-5",
    ]

    static func normalizeClaudeModel(_ m: String) -> String {
        let base = m.replacingOccurrences(of: "[1m]", with: "")
        return claudeAliases[base.lowercased()] ?? base
    }

    static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]

    static let claudePermissions: [Choice] = [
        Choice(value: "manual", label: "Ask", detail: "Ask before edits and commands"),
        Choice(value: "acceptEdits", label: "Accept edits", detail: "Edit files without asking"),
        Choice(value: "plan", label: "Plan", detail: "Read-only planning"),
        Choice(value: "auto", label: "Auto mode", detail: "Claude decides what needs approval"),
        Choice(value: "dontAsk", label: "Don't ask", detail: "Deny anything not pre-approved"),
        Choice(value: "bypassPermissions", label: "Bypass all", detail: "Skip every permission check", dangerous: true),
    ]

    static func claudeArgs(_ o: LaunchOptions) -> [String] {
        var a: [String] = []
        if let m = o.model { a += ["--model", m] }
        if let e = o.effort { a += ["--effort", e] }
        if let p = o.permission {
            if p == "bypassPermissions" { a.append("--dangerously-skip-permissions") }
            else { a += ["--permission-mode", p] }
        }
        return a
    }

    // MARK: Codex

    struct CodexModel: Hashable {
        let slug: String
        let efforts: [String]
    }

    /// From Codex's own models cache; falls back to the configured model.
    nonisolated(unsafe) private static var codexCache: (path: String, mtime: Date?, models: [CodexModel])?

    /// Cached: views call this on every redraw, so only re-read the file when its modification date changes.
    static func codexModels(settings: AppSettings) -> [CodexModel] {
        let url = SessionDiscovery.codexHome(settings).appendingPathComponent("models_cache.json")
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let c = codexCache, c.path == url.path, c.mtime == mtime { return c.models }
        let models = loadCodexModels(url: url, settings: settings)
        codexCache = (url.path, mtime, models)
        return models
    }

    private static func loadCodexModels(url: URL, settings: AppSettings) -> [CodexModel] {
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            let list = (obj as? [String: Any])?["models"] as? [[String: Any]] ?? (obj as? [[String: Any]]) ?? []
            let models = list.compactMap { m -> CodexModel? in
                guard let slug = (m["slug"] as? String) ?? (m["id"] as? String) else { return nil }
                if (m["visibility"] as? String) == "hide" || slug.contains("auto-review") { return nil }
                let efforts = (m["supported_reasoning_levels"] as? [[String: Any]])?.compactMap { $0["effort"] as? String } ?? []
                return CodexModel(slug: slug, efforts: efforts)
            }
            if !models.isEmpty { return models }
        }
        if let cfg = codexConfigValue("model", settings: settings) { return [CodexModel(slug: cfg, efforts: ["low", "medium", "high", "xhigh"])] }
        return []
    }

    static func codexConfigValue(_ key: String, settings: AppSettings) -> String? {
        let url = SessionDiscovery.codexHome(settings).appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { break }   // only top-level keys
            let parts = t.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == key { return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        }
        return nil
    }

    static let codexPermissions: [Choice] = [
        Choice(value: "read-only", label: "Read only", detail: "Sandboxed, can't write files"),
        Choice(value: "workspace", label: "Workspace", detail: "Write in the project, ask for the rest"),
        Choice(value: "workspace-auto", label: "Workspace, no prompts", detail: "Write in the project, never ask"),
        Choice(value: "full", label: "Full access", detail: "No sandbox, no approvals", dangerous: true),
    ]

    static func codexArgs(_ o: LaunchOptions) -> [String] {
        var a: [String] = []
        if let m = o.model { a += ["-m", m] }
        if let e = o.effort { a += ["-c", "model_reasoning_effort=\"\(e)\""] }
        switch o.permission {
        case "read-only": a += ["-s", "read-only", "-a", "on-request"]
        case "workspace": a += ["-s", "workspace-write", "-a", "on-request"]
        case "workspace-auto": a += ["-s", "workspace-write", "-a", "never"]
        case "full": a.append("--dangerously-bypass-approvals-and-sandbox")
        default: break
        }
        return a
    }

    // MARK: Explicit values (no "Default")

    /// What each CLI would use on its own, resolved to concrete values from its config files.
    static func resolvedDefaults(_ tool: Tool, settings: AppSettings) -> LaunchOptions {
        switch tool {
        case .claude:
            let file = SessionDiscovery.claudeConfigDir(settings).appendingPathComponent("settings.json")
            let cfg = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let model = normalizeClaudeModel((cfg["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "opus")
            // Per-model effort (modelSettings) wins over the global effortLevel, like in Claude Code.
            let perModel = ((cfg["modelSettings"] as? [String: Any])?[model] as? [String: Any])?["effortLevel"] as? String
            let effort = [perModel, cfg["effortLevel"] as? String].compactMap { $0 }.first { claudeEfforts.contains($0) } ?? "medium"
            let mode = (cfg["permissions"] as? [String: Any])?["defaultMode"] as? String
            // With an auto-mode configuration Claude Code starts sessions in auto mode.
            let permission: String
            if let mode, claudePermissions.contains(where: { $0.value == mode }) { permission = mode }
            else if mode == "default" { permission = "manual" }
            else { permission = cfg["autoMode"] != nil ? "auto" : "manual" }
            return LaunchOptions(model: model, effort: effort, permission: permission)
        case .codex:
            let models = codexModels(settings: settings)
            let model = codexConfigValue("model", settings: settings) ?? models.first?.slug ?? "gpt-5"
            let supported = models.first { $0.slug == model }?.efforts ?? []
            let effort = codexConfigValue("model_reasoning_effort", settings: settings)
                ?? (supported.contains("medium") ? "medium" : supported.first) ?? "medium"
            let sandbox = codexConfigValue("sandbox_mode", settings: settings)
            let approval = codexConfigValue("approval_policy", settings: settings)
            let permission: String
            switch (sandbox, approval) {
            case ("danger-full-access", _): permission = "full"
            case ("read-only", _): permission = "read-only"
            case (_, "never"): permission = "workspace-auto"
            default: permission = "workspace"
            }
            return LaunchOptions(model: model, effort: effort, permission: permission)
        case .terminal:
            return LaunchOptions()
        }
    }

    /// Fills any unset field with the resolved concrete value.
    static func explicit(_ o: LaunchOptions, tool: Tool, settings: AppSettings) -> LaunchOptions {
        var o = o
        if tool == .claude, let m = o.model { o.model = normalizeClaudeModel(m) }
        guard tool != .terminal, o.model == nil || o.effort == nil || o.permission == nil else { return o }
        let d = resolvedDefaults(tool, settings: settings)
        return LaunchOptions(model: o.model ?? d.model, effort: o.effort ?? d.effort, permission: o.permission ?? d.permission)
    }

    static func modelLabel(_ value: String, tool: Tool) -> String {
        tool == .claude ? (claudeModels.first { $0.value == value }?.label ?? value) : value
    }

    // MARK: Labels

    static func summary(_ o: LaunchOptions, tool: Tool, settings: AppSettings) -> (model: String, effort: String, permission: String) {
        guard tool != .terminal else { return ("", "", "") }
        let x = explicit(o, tool: tool, settings: settings)
        let perms = tool == .claude ? claudePermissions : codexPermissions
        let p = x.permission.map { v in perms.first { $0.value == v }?.label ?? v } ?? ""
        return (modelLabel(x.model ?? "", tool: tool), x.effort ?? "", p)
    }
}
