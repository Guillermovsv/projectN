import Foundation

enum Tool: String, Codable, CaseIterable, Identifiable {
    case claude, codex, cursor, terminal
    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .terminal: return "Terminal"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .terminal: return "terminal"
        }
    }

    /// Agents whose plan usage ProjectN shows in the top bar.
    var hasUsageMeter: Bool { self != .terminal }
}

struct Project: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var path: String

    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// One terminal inside a Space: Claude, Codex or a shell, running in one project folder.
struct Pane: Codable, Identifiable, Hashable {
    var id = UUID()
    var tool: Tool
    var projectID: UUID
    var title: String?
    var autoComplete: Bool?
    /// Claude conversation bound to this pane (`--session-id` on first launch, `--resume` afterwards).
    /// Launch options (nil = the CLI's own default / config).
    var model: String?
    var effort: String?
    var permission: String?
    var claudeSessionID: String?
    /// Codex session discovered from ~/.codex/sessions after launch (`codex resume <id>` afterwards).
    var codexSessionID: String?
    /// Cursor Agent chat created with `cursor-agent create-chat` (`--resume <id>` on every launch).
    var cursorSessionID: String?
    /// Latest prompt sent from ProjectN (sticky header). Survives relaunch.
    var lastPrompt: String?
    var createdAt = Date()

    var isAutoComplete: Bool { autoComplete ?? false }

    var launchOptions: LaunchOptions {
        get { LaunchOptions(model: model, effort: effort, permission: permission) }
        set { model = newValue.model; effort = newValue.effort; permission = newValue.permission }
    }
}

struct LaunchOptions: Codable, Equatable, Hashable {
    var model: String?
    var effort: String?
    var permission: String?
}

/// A screen of 1–8 panes tiled together.
struct Space: Codable, Identifiable, Hashable {
    static let maxPanes = 8

    var id = UUID()
    var name: String
    var panes: [Pane] = []
    var focusedPaneID: UUID?

    var isFull: Bool { panes.count >= Space.maxPanes }
}

struct Workspace: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var projectIDs: [UUID]
    var spaces: [Space] = []
    var expanded: Bool = true
    var lastOpened: Date?

    init(name: String, projectIDs: [UUID]) {
        self.name = name
        self.projectIDs = projectIDs
        self.spaces = [Space(name: "Space 1")]
    }

    func nextSpaceName() -> String {
        var n = spaces.count + 1
        while spaces.contains(where: { $0.name == "Space \(n)" }) { n += 1 }
        return "Space \(n)"
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, projectIDs, spaces, expanded, lastOpened, sessions
    }

    /// Legacy (v1) session format, migrated into spaces of up to 8 panes.
    private struct LegacySession: Codable {
        var id: UUID
        var title: String?
        var tool: Tool
        var projectID: UUID
        var autoComplete: Bool?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        projectIDs = (try? c.decode([UUID].self, forKey: .projectIDs)) ?? []
        expanded = (try? c.decode(Bool.self, forKey: .expanded)) ?? true
        lastOpened = try? c.decode(Date.self, forKey: .lastOpened)
        if let spaces = try? c.decode([Space].self, forKey: .spaces) {
            self.spaces = spaces
        } else {
            let legacy = (try? c.decode([LegacySession].self, forKey: .sessions)) ?? []
            let panes = legacy.map { Pane(id: $0.id, tool: $0.tool, projectID: $0.projectID, autoComplete: $0.autoComplete) }
            var spaces: [Space] = []
            for start in stride(from: 0, to: max(panes.count, 1), by: Space.maxPanes) {
                let chunk = Array(panes[min(start, panes.count)..<min(start + Space.maxPanes, panes.count)])
                spaces.append(Space(name: "Space \(spaces.count + 1)", panes: chunk, focusedPaneID: chunk.first?.id))
            }
            self.spaces = spaces
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(projectIDs, forKey: .projectIDs)
        try c.encode(spaces, forKey: .spaces)
        try c.encode(expanded, forKey: .expanded)
        try c.encodeIfPresent(lastOpened, forKey: .lastOpened)
    }
}

struct UIState: Codable, Equatable {
    var selectedWorkspaceID: UUID?
    var selectedSpaceID: UUID?
    var projectsExpanded: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedWorkspaceID = try? c.decode(UUID.self, forKey: .selectedWorkspaceID)
        selectedSpaceID = try? c.decode(UUID.self, forKey: .selectedSpaceID)
        projectsExpanded = (try? c.decode(Bool.self, forKey: .projectsExpanded)) ?? true
    }
}

struct PersistedState: Codable {
    var version = 2
    var projects: [Project] = []
    var workspaces: [Workspace] = []
    var ui = UIState()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = (try? c.decode([Project].self, forKey: .projects)) ?? []
        workspaces = (try? c.decode([Workspace].self, forKey: .workspaces)) ?? []
        ui = (try? c.decode(UIState.self, forKey: .ui)) ?? UIState()
    }
}

struct AppSettings: Codable, Equatable {
    var shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    var claudeCommand: String = "claude"
    var claudeExtraArgs: String = ""
    var codexCommand: String = "codex"
    var codexExtraArgs: String = ""
    var cursorCommand: String = "cursor-agent"
    var cursorExtraArgs: String = ""
    /// Pass ~/.projectn/mcp.json to Claude via --mcp-config
    var claudeUseAppMCP: Bool = true
    /// Translate ~/.projectn/mcp.json into `-c mcp_servers.*` overrides for Codex
    var codexUseAppMCP: Bool = true
    /// Use CLAUDE_CONFIG_DIR=~/.projectn/claude (separate login/config from your global one)
    var isolateClaudeConfig: Bool = false
    /// Use CODEX_HOME=~/.projectn/codex (separate login/config from your global one)
    var isolateCodexHome: Bool = false
    var fontSize: Double = 13
    var theme: String = "midnight"
    /// Play a sound when a chat stops for your input or finishes.
    var notificationSound: Bool = true
    /// Name of a macOS system sound (/System/Library/Sounds).
    var notificationSoundName: String = "Glass"
    /// Names of API keys (values live in the Keychain) passed to every session as environment variables.
    var apiKeyNames: [String] = []
    /// Defaults applied to new panes.
    var claudeDefaults = LaunchOptions()
    var codexDefaults = LaunchOptions()
    var cursorDefaults = LaunchOptions()
    /// Built-in NVoice dictation (hold fn anywhere to talk, text is pasted at the cursor).
    var voiceEnabled: Bool = true
    /// Show NVoice's waveform icon in the macOS menu bar (person, language, mic, correct last dictation).
    var voiceMenuBarIcon: Bool = true

    init() {}

    // Tolerant decoding so new fields don't break old settings files.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        shell = (try? c.decode(String.self, forKey: .shell)) ?? d.shell
        claudeCommand = (try? c.decode(String.self, forKey: .claudeCommand)) ?? d.claudeCommand
        claudeExtraArgs = (try? c.decode(String.self, forKey: .claudeExtraArgs)) ?? d.claudeExtraArgs
        codexCommand = (try? c.decode(String.self, forKey: .codexCommand)) ?? d.codexCommand
        codexExtraArgs = (try? c.decode(String.self, forKey: .codexExtraArgs)) ?? d.codexExtraArgs
        cursorCommand = (try? c.decode(String.self, forKey: .cursorCommand)) ?? d.cursorCommand
        cursorExtraArgs = (try? c.decode(String.self, forKey: .cursorExtraArgs)) ?? d.cursorExtraArgs
        claudeUseAppMCP = (try? c.decode(Bool.self, forKey: .claudeUseAppMCP)) ?? d.claudeUseAppMCP
        codexUseAppMCP = (try? c.decode(Bool.self, forKey: .codexUseAppMCP)) ?? d.codexUseAppMCP
        isolateClaudeConfig = (try? c.decode(Bool.self, forKey: .isolateClaudeConfig)) ?? d.isolateClaudeConfig
        isolateCodexHome = (try? c.decode(Bool.self, forKey: .isolateCodexHome)) ?? d.isolateCodexHome
        fontSize = (try? c.decode(Double.self, forKey: .fontSize)) ?? d.fontSize
        theme = (try? c.decode(String.self, forKey: .theme)) ?? d.theme
        notificationSound = (try? c.decode(Bool.self, forKey: .notificationSound)) ?? d.notificationSound
        notificationSoundName = (try? c.decode(String.self, forKey: .notificationSoundName)) ?? d.notificationSoundName
        apiKeyNames = (try? c.decode([String].self, forKey: .apiKeyNames)) ?? d.apiKeyNames
        claudeDefaults = (try? c.decode(LaunchOptions.self, forKey: .claudeDefaults)) ?? d.claudeDefaults
        codexDefaults = (try? c.decode(LaunchOptions.self, forKey: .codexDefaults)) ?? d.codexDefaults
        cursorDefaults = (try? c.decode(LaunchOptions.self, forKey: .cursorDefaults)) ?? d.cursorDefaults
        voiceEnabled = (try? c.decode(Bool.self, forKey: .voiceEnabled)) ?? d.voiceEnabled
        voiceMenuBarIcon = (try? c.decode(Bool.self, forKey: .voiceMenuBarIcon)) ?? d.voiceMenuBarIcon
    }
}
