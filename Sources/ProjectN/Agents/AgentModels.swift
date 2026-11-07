import Foundation

// MARK: - Agent profiles

/// Who serves the model. Determines which runtimes are valid.
enum AgentProvider: String, Codable, CaseIterable, Identifiable {
    case anthropic, openai, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .other: return "Other (compatible)"
        }
    }
}

/// The CLI that actually runs the session. Each maps to an existing ProjectN pane tool.
enum AgentRuntime: String, Codable, CaseIterable, Identifiable {
    case claudeCode, codexCLI
    var id: String { rawValue }
    var label: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codexCLI: return "Codex CLI"
        }
    }
    var tool: Tool { self == .claudeCode ? .claude : .codex }
    /// Providers each runtime can talk to. "Other" means a compatible endpoint configured in the CLI itself
    /// (e.g. ANTHROPIC_BASE_URL / a Codex model_provider), so the model list comes from that CLI.
    var providers: [AgentProvider] {
        switch self {
        case .claudeCode: return [.anthropic, .other]
        case .codexCLI: return [.openai, .other]
        }
    }
    static func defaultRuntime(for provider: AgentProvider) -> AgentRuntime {
        provider == .openai ? .codexCLI : .claudeCode
    }
}

/// Access level. Deliberately has no "skip approvals" level: every level keeps the CLI's own
/// permission prompts for anything beyond it, so destructive or publishing actions are always confirmed.
enum AgentPermission: String, Codable, CaseIterable, Identifiable {
    /// Claude: plan mode. Codex: read-only sandbox, asks before anything else.
    case readOnly
    /// Claude: asks before every edit and command. Codex: read-only sandbox, asks to escalate.
    case askBeforeChanges
    /// Claude: edits files in the project without asking, commands still ask. Codex: workspace-write, asks for the rest.
    case editProject

    var id: String { rawValue }
    var label: String {
        switch self {
        case .readOnly: return "Read only"
        case .askBeforeChanges: return "Read & write — ask first"
        case .editProject: return "Read & write"
        }
    }
    var detail: String {
        switch self {
        case .readOnly: return "Reads files and runs read-only commands. Can't change anything."
        case .askBeforeChanges: return "Can edit and run commands, but every change waits for your approval."
        case .editProject: return "Edits files and runs builds/tests in the project on its own. Deleting, publishing and anything outside the project still ask you."
        }
    }
    /// True if the agent may write to the project (serialised per project to avoid conflicting edits).
    var canWrite: Bool { self != .readOnly }

    /// The pane permission value (see LaunchCatalog.claudePermissions / codexPermissions).
    /// `hookEnforced`: ProjectN's PreToolUse hook decides every tool call. Read-only Claude agents then run in the
    /// normal mode instead of plan mode — plan mode makes Claude refuse to delegate or call tools that "act" — and
    /// the hook denies every change. If the hook can't reach ProjectN, Claude asks in the pane (never auto-allows).
    func paneValue(for runtime: AgentRuntime, hookEnforced: Bool = false) -> String {
        switch (runtime, self) {
        case (.claudeCode, .readOnly): return hookEnforced ? "manual" : "plan"
        case (.claudeCode, .askBeforeChanges): return "manual"
        case (.claudeCode, .editProject): return "acceptEdits"
        case (.codexCLI, .readOnly), (.codexCLI, .askBeforeChanges): return "read-only"
        case (.codexCLI, .editProject): return "workspace"
        }
    }
}

/// How much an agent does without asking, on top of its access level. Deleting and admin/system changes always
/// ask you, at every level.
enum AgentAutonomy: String, Codable, CaseIterable, Identifiable {
    /// Asks about anything unusual: gray-area commands, reads outside the project, network downloads.
    case cautious
    /// Default. Routine and gray-area work runs on its own (reads anywhere except secrets, downloads, other
    /// commands). Asks before deleting, publishing / sending, remote systems and writing outside the project.
    case balanced
    /// Also publishes, sends data, works on remote systems and writes in your home folder on its own. Only deleting,
    /// administrator / system changes and secret files ask you.
    case high

    var id: String { rawValue }
    var label: String {
        switch self {
        case .cautious: return "Cautious"
        case .balanced: return "Balanced"
        case .high: return "High"
        }
    }
    var detail: String {
        switch self {
        case .cautious: return "Asks about anything outside routine project work."
        case .balanced: return "Works on its own. Asks before deleting, publishing or sending, remote systems and writing outside the project."
        case .high: return "Also publishes, sends and works outside the project on its own. Only deleting, admin/system changes and secret files ask."
        }
    }
    static let autoModeDetail = "Auto mode: does everything on its own and never stops to ask questions. Only deleting, admin/system changes and secret files ask."
}

enum SessionPolicy: String, Codable, CaseIterable, Identifiable {
    /// One session per project: later messages about the same project continue it (no new terminal, no
    /// re-read context). "sesión nueva" / "desde cero" or a long idle time starts a new one.
    case perProject
    /// Every task gets a brand-new session.
    case alwaysNew
    /// New session by default; a previous session of the same thread is resumed only when the user asks explicitly.
    case resumeOnExplicitRequest
    var id: String { rawValue }
    /// Offered in the editor. `resumeOnExplicitRequest` is only read from old files (migrated to per-project).
    static let selectable: [SessionPolicy] = [.perProject, .alwaysNew]
    var label: String {
        switch self {
        case .perProject: return "One session per project (continues)"
        case .alwaysNew: return "Always a new session"
        case .resumeOnExplicitRequest: return "New session; resume only when explicitly asked"
        }
    }
}

/// Built-in Claude Code tools offered in the Tools picker.
enum AgentToolCatalog {
    static let claude = ["Read", "Glob", "Grep", "LS", "WebFetch", "WebSearch", "Edit", "Write", "MultiEdit", "NotebookEdit", "Bash", "TodoWrite", "Task"]
    /// Tools that change files: never useful to a read-only agent (ProjectN's hook would refuse them anyway).
    static let writing: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// The tools ticked for an access level. Bash stays for read-only agents: `git log`, `ls`, … are reading;
    /// the approval hook refuses commands that change things.
    static func preset(for p: AgentPermission) -> [String] {
        p == .readOnly ? claude.filter { !writing.contains($0) } : claude
    }

    /// What a profile actually gets: its own selection, or its access level's preset when it has none.
    static func effective(_ profile: AgentProfile) -> [String] {
        profile.tools.isEmpty ? preset(for: profile.permission) : profile.tools
    }

    /// `--tools` value for Claude Code, or nil when nothing needs restricting (the full set).
    /// ToolSearch is always kept: Claude Code needs it to load MCP tools, including ProjectN's own.
    static func claudeFlag(_ profile: AgentProfile) -> String? {
        let tools = effective(profile)
        guard Set(tools) != Set(claude) else { return nil }
        return (tools + ["ToolSearch"]).joined(separator: ",")
    }
}

/// A reusable, project-independent agent profile.
struct AgentProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var role: String
    var provider: AgentProvider = .anthropic
    var runtime: AgentRuntime = .claudeCode
    /// Model id as the runtime knows it (e.g. "claude-opus-5-5", "gpt-5-codex").
    var model: String
    /// Reasoning effort; nil = the model's default. Dropped at launch if the model doesn't support it.
    var effort: String?
    var instructions: String
    /// Allowed tools (Claude Code `--tools`). Empty = the runtime's defaults.
    var tools: [String] = []
    var permission: AgentPermission = .readOnly
    /// Projects this agent may work in (ignored when `allProjects`).
    var allProjects: Bool = false
    var projectIDs: [UUID] = []
    /// Files read into every new session, relative to the project root (must stay inside it).
    var contextSources: [String] = ["README.md"]
    var sessionPolicy: SessionPolicy = .alwaysNew
    /// How much it does without asking (see AgentAutonomy).
    var autonomy: AgentAutonomy = .balanced
    /// Auto mode: approves everything except deleting, admin/system changes and secrets, and the agent never
    /// stops to ask questions (it decides with the most reasonable assumption). Overrides `autonomy`.
    var autoMode: Bool = false
    /// Also load the MCP servers configured in Claude Code (~/.claude.json: yours + the project's).
    var useClaudeMCP = true
    /// Simultaneous tasks of this profile (across all projects).
    var concurrencyLimit: Int = 2
    /// A task is stopped after this many minutes.
    var timeoutMinutes: Int = 30
    var enabled: Bool = true
    var createdAt = Date()

    /// May hand work to other agents (ProjectN's delegate_task / wait_for_tasks tools) and decide their
    /// gray-area approvals and questions.
    var canDelegate: Bool = false
    /// MCP servers (names from Settings → MCP Servers) this agent gets. Only these: the user's global
    /// Claude MCP configuration isn't loaded for agents.
    var mcpServers: [String] = []
    /// Commands this agent may run without asking (e.g. gh, wp, vercel). Deleting / publishing still asks you.
    var cliTools: [String] = []
    /// API keys (names from Settings → Accounts → API keys) exported to this agent's environment. Others aren't.
    var apiKeys: [String] = []
    /// Tasks this agent runs on its own on a schedule (while ProjectN is open).
    var schedules: [AgentSchedule] = []
    /// Emoji the agent signs its Slack messages with (":robot_face:" style). Empty = chosen from its role.
    var slackIcon: String = ""
    /// The agent's own private Slack channel (created by ProjectN's app), and the name it was created with.
    var slackChannelID: String?
    var slackChannelName: String?

    /// The emoji actually used in Slack.
    var slackEmoji: String {
        let e = slackIcon.trimmingCharacters(in: .whitespaces)
        if !e.isEmpty { return e.hasPrefix(":") ? e : ":\(e):" }
        let r = (role + " " + name).folded
        let byRole: [(String, String)] = [("project manager", ":card_index_dividers:"), ("manager", ":card_index_dividers:"),
                                          ("develop", ":computer:"), ("seo", ":mag:"), ("design", ":art:"), ("copy", ":pencil2:"),
                                          ("writ", ":pencil2:"), ("qa", ":white_check_mark:"), ("review", ":white_check_mark:"),
                                          ("analy", ":bar_chart:"), ("market", ":mega:"), ("support", ":speech_balloon:")]
        return byRole.first { r.contains($0.0) }?.1 ?? ":robot_face:"
    }

    init(name: String, role: String, provider: AgentProvider = .anthropic, runtime: AgentRuntime = .claudeCode,
         model: String, effort: String? = nil, instructions: String) {
        self.name = name
        self.role = role
        self.provider = provider
        self.runtime = runtime
        self.model = model
        self.effort = effort
        self.instructions = instructions
    }

    func mayAccess(_ projectID: UUID) -> Bool { allProjects || projectIDs.contains(projectID) }

    /// The Project Manager's instructions on installs before autonomous agents (replaced once if unchanged).
    static let legacyProjectManagerInstructions = """
    Eres el Project Manager de una agencia de marketing digital.

    Tu responsabilidad es recibir solicitudes, identificar proyectos, consultar su documentación, organizar tareas y comunicar resultados.

    Antes de actuar, verifica que tienes suficiente contexto.

    Utiliza el README y los archivos autorizados del proyecto.

    No inventes información sobre archivos o tareas.

    No modifiques archivos, publiques cambios ni ejecutes otros agentes sin autorización.

    Presenta resultados claros y solicita aprobación cuando corresponda.
    """

    static let projectManagerInstructions = """
    Eres el Project Manager de una agencia de marketing digital.

    Tu responsabilidad es recibir solicitudes, identificar el proyecto, organizar el trabajo, repartirlo entre los agentes y comunicar resultados.

    Cómo trabajar:
    - Actúa. Ya tienes acceso a los proyectos y a tus herramientas; no pidas permiso para lo que tu configuración permite. ProjectN pide aprobación al usuario automáticamente cuando hace falta.
    - Usa el contexto: la conversación anterior, el README, la memoria del proyecto y los archivos. Si algo es ambiguo, elige la interpretación más razonable, dila en una línea y avanza. Pregunta solo si equivocarte sería costoso.
    - Delega: cuando el trabajo corresponde a otro agente (desarrollo, SEO, contenido…) o el usuario dice “pídele / dile / que lo haga el developer…”, usa delegate_task con una instrucción completa. No le devuelvas al usuario lo que otro agente puede resolver.
    - No inventes información sobre archivos o tareas.
    - Responde breve y claro: qué se hizo, qué está en curso (y con quién) y qué necesita al usuario, si algo.
    """

    // Tolerant decoding so new fields don't break saved profiles.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AgentProfile(name: "", role: "", model: "", instructions: "")
        id = try c.decode(UUID.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Agent"
        role = (try? c.decode(String.self, forKey: .role)) ?? ""
        provider = (try? c.decode(AgentProvider.self, forKey: .provider)) ?? d.provider
        runtime = (try? c.decode(AgentRuntime.self, forKey: .runtime)) ?? d.runtime
        model = (try? c.decode(String.self, forKey: .model)) ?? ""
        effort = try? c.decode(String.self, forKey: .effort)
        instructions = (try? c.decode(String.self, forKey: .instructions)) ?? ""
        tools = (try? c.decode([String].self, forKey: .tools)) ?? []
        permission = (try? c.decode(AgentPermission.self, forKey: .permission)) ?? d.permission
        allProjects = (try? c.decode(Bool.self, forKey: .allProjects)) ?? false
        projectIDs = (try? c.decode([UUID].self, forKey: .projectIDs)) ?? []
        contextSources = (try? c.decode([String].self, forKey: .contextSources)) ?? d.contextSources
        sessionPolicy = (try? c.decode(SessionPolicy.self, forKey: .sessionPolicy)) ?? d.sessionPolicy
        autonomy = (try? c.decode(AgentAutonomy.self, forKey: .autonomy)) ?? d.autonomy
        autoMode = (try? c.decode(Bool.self, forKey: .autoMode)) ?? false
        useClaudeMCP = (try? c.decode(Bool.self, forKey: .useClaudeMCP)) ?? d.useClaudeMCP
        concurrencyLimit = max(1, (try? c.decode(Int.self, forKey: .concurrencyLimit)) ?? d.concurrencyLimit)
        timeoutMinutes = max(1, (try? c.decode(Int.self, forKey: .timeoutMinutes)) ?? d.timeoutMinutes)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        canDelegate = (try? c.decode(Bool.self, forKey: .canDelegate)) ?? false
        mcpServers = (try? c.decode([String].self, forKey: .mcpServers)) ?? []
        cliTools = (try? c.decode([String].self, forKey: .cliTools)) ?? []
        apiKeys = (try? c.decode([String].self, forKey: .apiKeys)) ?? []
        schedules = (try? c.decode([AgentSchedule].self, forKey: .schedules)) ?? []
        slackIcon = (try? c.decode(String.self, forKey: .slackIcon)) ?? ""
        slackChannelID = try? c.decode(String.self, forKey: .slackChannelID)
        slackChannelName = try? c.decode(String.self, forKey: .slackChannelName)
    }

    /// The first profile created on a fresh install (section 6 of the spec).
    static func projectManager() -> AgentProfile {
        var p = AgentProfile(
            name: "Project Manager", role: "Project Manager",
            provider: .anthropic, runtime: .claudeCode,
            model: "claude-opus-5-5", effort: "high",
            instructions: AgentProfile.projectManagerInstructions)
        p.permission = .readOnly
        p.canDelegate = true
        p.sessionPolicy = .perProject
        p.allProjects = true
        p.contextSources = ["README.md"]
        p.concurrencyLimit = 2
        return p
    }
}

// MARK: - Tasks

/// Where a task came from, so results can be sent back.
struct TaskOrigin: Codable, Hashable {
    enum Kind: String, Codable { case slack, local, agent, schedule }
    var kind: Kind
    var slackChannel: String?
    var slackThreadTS: String?
    var slackMessageTS: String?
    var slackUser: String?
    /// For delegated tasks: the task (agent) that created this one.
    var parentTaskID: UUID?
    var delegatedBy: String?
    /// Which Slack app received the request (and posts the replies): "main" or an agent's own app.
    var slackBot: String?
    /// For scheduled tasks: which schedule.
    var scheduleID: UUID?
    var scheduleName: String?
    /// Created by ProjectN itself (e.g. results of delegated tasks handed back to the coordinator): no "started" notice.
    var automatic: Bool?

    static let local = TaskOrigin(kind: .local)
    /// How the request's author is named to the agent (no raw Slack member ids).
    var promptLabel: String {
        switch kind {
        case .slack: return "the user, via Slack"
        case .local: return "the user, in ProjectN"
        default: return label
        }
    }
    var label: String {
        switch kind {
        case .slack: return "Slack" + (slackUser.map { " · \($0)" } ?? "")
        case .local: return "ProjectN"
        case .agent: return "Delegated by " + (delegatedBy ?? "an agent")
        case .schedule: return "Scheduled" + (scheduleName.map { " · \($0)" } ?? "")
        }
    }
}

enum AgentTaskStatus: String, Codable {
    case queued, starting, running, needsApproval, waitingForUser, completed, failed, cancelled, timedOut, interrupted
    var isFinished: Bool { [.completed, .failed, .cancelled, .timedOut, .interrupted].contains(self) }
    var isActive: Bool { [.starting, .running, .needsApproval, .waitingForUser].contains(self) }
    var label: String {
        switch self {
        case .queued: return "Queued"
        case .starting: return "Starting"
        case .running: return "Running"
        case .needsApproval: return "Needs approval"
        case .waitingForUser: return "Waiting for your answer"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .timedOut: return "Timed out"
        case .interrupted: return "Interrupted"
        }
    }
}

struct TokenUsage: Codable, Hashable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var total: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
}

struct AgentTask: Codable, Identifiable, Hashable {
    var id = UUID()
    var agentID: UUID
    var agentName: String
    var projectID: UUID
    var projectName: String
    /// The user's instruction, verbatim.
    var instruction: String
    var origin: TaskOrigin
    var status: AgentTaskStatus = .queued
    var createdAt = Date()
    var startedAt: Date?
    var finishedAt: Date?
    var runtime: AgentRuntime
    var model: String
    var effort: String?
    var permission: AgentPermission
    /// Where it runs.
    var workspaceID: UUID?
    var paneID: UUID?
    /// Claude session id / Codex session id once known.
    var sessionID: String?
    /// Set when this task continues an earlier task's session.
    var resumedFromTaskID: UUID?
    /// Continues the project's session (per-project policy) rather than an explicit resume.
    var continuedSession: Bool?
    /// Transcript bytes that existed before this task (resumed sessions): only later entries count.
    var transcriptOffset: UInt64 = 0
    var result: String?
    var error: String?
    /// Notes shown with the result (missing README, effort not supported, …).
    var notes: [String] = []
    var usage: TokenUsage?
    /// Tasks that must complete first.
    var dependsOn: [UUID] = []
    /// Delegation: 0 for a request from you, 1 for a task an agent delegated, …
    var depth = 0
    /// The task you started this chain with (self for depth 0).
    var rootTaskID: UUID?
    /// Last approval prompt reported, so each one is reported once.
    var lastApprovalNotice: String?
    /// The final outcome was delivered to the origin (Slack). Undelivered outcomes are sent on reconnect.
    var delivered = false
    /// Messages for this session not typed into it yet (sent while it was busy or waiting on a prompt).
    var inbox: [String]?
    /// Messages added to this task after it started (follow-ups, answers, results of delegated tasks).
    var followUps: [String]?
    /// The question (request id) this task asked and is waiting on, with its turn ended.
    var awaitingAnswer: UUID?
    /// Don't recap earlier conversation in a new session ("sesión nueva").
    var skipRecap: Bool?
    /// Digest of the project notes this session has seen (sent again when they change).
    var notesDigest: String?
    var duration: TimeInterval? { startedAt.map { (finishedAt ?? Date()).timeIntervalSince($0) } }
}

// MARK: - Delegation

/// A request to run work through the harness: from Slack, the local "Run Task" sheet, or an agent that delegates.
struct AgentTaskRequest {
    var agentID: UUID
    var projectID: UUID
    var instruction: String
    var origin: TaskOrigin
    /// Explicitly continue this earlier task's session (only if the profile allows it).
    var resumeTaskID: UUID?
    /// Don't continue the project's session even if the profile would ("sesión nueva").
    var freshSession = false
    /// Tasks that must finish (completed) before this one starts.
    var dependsOn: [UUID] = []
}

/// What a coordinating agent (e.g. the Project Manager) can do. `AgentHarness` implements it; agents with
/// `canDelegate` reach it through ProjectN's MCP tools (see AgentTools).
@MainActor
protocol AgentCoordinating: AnyObject {
    func availableAgents() -> [AgentProfile]
    func agents(matchingRole role: String) -> [AgentProfile]
    @discardableResult
    func submit(_ request: AgentTaskRequest) -> Result<AgentTask, AgentHarnessError>
    func task(_ id: UUID) -> AgentTask?
    func cancel(_ id: UUID)
    /// Creates a review task for `reviewerID` that depends on `taskID` and receives its result as context.
    @discardableResult
    func requestReview(of taskID: UUID, by reviewerID: UUID, instruction: String) -> Result<AgentTask, AgentHarnessError>
}

enum AgentHarnessError: Error, Equatable, CustomStringConvertible {
    case agentNotFound
    case agentDisabled(String)
    case projectNotFound
    case projectNotAllowed(agent: String, project: String)
    case projectFolderMissing(String)
    case protectedDirectory(String)
    case invalidRuntime(String)
    case modelUnavailable(model: String, available: [String])
    case resumeNotAllowed
    case nothingToResume
    case dependencyMissing
    case delegationNotAllowed(String)

    var description: String {
        switch self {
        case .agentNotFound: return "Agent not found."
        case .agentDisabled(let n): return "Agent \(n) is disabled."
        case .projectNotFound: return "Project not found."
        case .projectNotAllowed(let a, let p): return "\(a) is not allowed to work in \(p)."
        case .projectFolderMissing(let p): return "The project folder no longer exists: \(p)"
        case .protectedDirectory(let p): return "Refusing to run an agent in a personal/system folder: \(p)"
        case .invalidRuntime(let r): return r
        case .modelUnavailable(let m, let a):
            return "Model \(m) is not available for this runtime." + (a.isEmpty ? "" : " Available: \(a.prefix(8).joined(separator: ", "))")
        case .resumeNotAllowed: return "This agent's session policy doesn't allow resuming sessions."
        case .nothingToResume: return "There is no earlier session in this thread to resume."
        case .dependencyMissing: return "A task this one depends on doesn't exist."
        case .delegationNotAllowed(let r): return r
        }
    }
}

// MARK: - Autonomy policy & pending requests

/// How autonomous agents are. Stored with the profiles (agents.json).
struct AgentPolicy: Codable, Equatable {
    enum GrayApprover: String, Codable, CaseIterable, Identifiable {
        case orchestrator, user
        var id: String { rawValue }
        var label: String { self == .orchestrator ? "The orchestrating agent" : "Me" }
    }
    /// Who decides gray-area actions of delegated tasks. Deleting, publishing and anything outside the project
    /// always go to you, whatever this says.
    var grayApprover: GrayApprover = .orchestrator
    /// 1 = only agents you message can delegate; 2 = their delegates may delegate once more.
    var maxDelegationDepth = 2
    /// Upper bound on tasks created under one request of yours.
    var maxTasksPerRequest = 10
    /// How long an agent's question / approval waits for an answer before it's treated as "no".
    var requestTimeoutMinutes = 60
    /// Per-project sessions idle longer than this start fresh.
    var sessionIdleHours = 12
    /// Profiles were moved to per-project sessions once (older installs defaulted to a new session per message).
    var perProjectSessionsMigrated = false
    /// Second migration: "resume only when asked" → per project, orchestrators off Haiku, PM instructions.
    var autonomyMigrated = false
    /// An idle session's process is stopped after this many minutes (it resumes on the next message).
    var idleCloseMinutes = 30
    /// At most this many idle session processes per agent stay running.
    var maxIdleSessionsPerAgent = 2
    /// Agents (with your approval) and your own Slack requests may create new projects.
    var allowProjectCreation = true
    /// Where new project folders are created. Empty = the folder most of your projects live in (else ~/Documents).
    var newProjectsFolder = ""

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AgentPolicy()
        grayApprover = (try? c.decode(GrayApprover.self, forKey: .grayApprover)) ?? d.grayApprover
        maxDelegationDepth = (try? c.decode(Int.self, forKey: .maxDelegationDepth)) ?? d.maxDelegationDepth
        maxTasksPerRequest = (try? c.decode(Int.self, forKey: .maxTasksPerRequest)) ?? d.maxTasksPerRequest
        requestTimeoutMinutes = (try? c.decode(Int.self, forKey: .requestTimeoutMinutes)) ?? d.requestTimeoutMinutes
        sessionIdleHours = (try? c.decode(Int.self, forKey: .sessionIdleHours)) ?? d.sessionIdleHours
        perProjectSessionsMigrated = (try? c.decode(Bool.self, forKey: .perProjectSessionsMigrated)) ?? false
        autonomyMigrated = (try? c.decode(Bool.self, forKey: .autonomyMigrated)) ?? false
        idleCloseMinutes = max(5, (try? c.decode(Int.self, forKey: .idleCloseMinutes)) ?? d.idleCloseMinutes)
        maxIdleSessionsPerAgent = max(1, (try? c.decode(Int.self, forKey: .maxIdleSessionsPerAgent)) ?? d.maxIdleSessionsPerAgent)
        allowProjectCreation = (try? c.decode(Bool.self, forKey: .allowProjectCreation)) ?? d.allowProjectCreation
        newProjectsFolder = (try? c.decode(String.self, forKey: .newProjectsFolder)) ?? d.newProjectsFolder
    }
}

/// Something an agent is waiting on: an approval for a tool call, or an answer to a question.
struct AgentRequest: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case approval, question }
    enum Route: Codable, Hashable {
        /// The agent that delegated the task (its task id).
        case orchestrator(UUID)
        case user
    }
    enum Status: String, Codable { case pending, approved, denied, answered, expired }

    var id = UUID()
    var taskID: UUID
    var agentName: String
    var kind: Kind
    /// What is asked: the command / tool call, or the question.
    var summary: String
    /// Why it was routed here (policy reason).
    var reason: String
    var route: Route
    var status: Status = .pending
    var answer: String?
    var decidedBy: String?
    var createdAt = Date()
    var decidedAt: Date?
    /// The CLI's own prompt in the terminal (answered by sending keys), not a hook or `ask` request.
    var terminalPrompt: Bool?

    var isPending: Bool { status == .pending }
}

// MARK: - Schedules

/// A task an agent runs by itself at set times. Runs only while ProjectN is open; a run missed while it was
/// closed happens once on the next launch (if `runIfMissed`).
struct AgentSchedule: Codable, Identifiable, Hashable {
    enum Frequency: String, Codable, CaseIterable, Identifiable {
        case hourly, daily, weekdays, weekly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .hourly: return "Every few hours"
            case .daily: return "Every day"
            case .weekdays: return "Weekdays (Mon–Fri)"
            case .weekly: return "On chosen days"
            }
        }
    }

    var id = UUID()
    var name: String = "New schedule"
    var enabled = true
    var projectID: UUID?
    var instruction: String = ""
    var frequency: Frequency = .weekdays
    var hour = 9
    var minute = 0
    /// Calendar weekdays for `.weekly` (1 = Sunday … 7 = Saturday).
    var weekdays: [Int] = [2]
    /// For `.hourly`: runs at hours divisible by this (e.g. 4 → 0:00, 4:00, 8:00 … at `minute`).
    var everyHours = 4
    /// Slack channel ID (C…) or member ID (U… → DM) to post the run and its result to; empty = ProjectN only.
    var slackTarget: String = ""
    var runIfMissed = true
    var createdAt = Date()
    var lastRun: Date?

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AgentSchedule()
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? d.name
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        projectID = try? c.decode(UUID.self, forKey: .projectID)
        instruction = (try? c.decode(String.self, forKey: .instruction)) ?? ""
        frequency = (try? c.decode(Frequency.self, forKey: .frequency)) ?? d.frequency
        hour = (try? c.decode(Int.self, forKey: .hour)) ?? d.hour
        minute = (try? c.decode(Int.self, forKey: .minute)) ?? d.minute
        weekdays = (try? c.decode([Int].self, forKey: .weekdays)) ?? d.weekdays
        everyHours = max(1, (try? c.decode(Int.self, forKey: .everyHours)) ?? d.everyHours)
        slackTarget = (try? c.decode(String.self, forKey: .slackTarget)) ?? ""
        runIfMissed = (try? c.decode(Bool.self, forKey: .runIfMissed)) ?? true
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        lastRun = try? c.decode(Date.self, forKey: .lastRun)
    }

    /// The first run time strictly after `date`.
    func nextRun(after date: Date, calendar: Calendar = .current) -> Date? {
        let startOfDay = calendar.startOfDay(for: date)
        for dayOffset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfDay) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            switch frequency {
            case .weekdays where weekday == 1 || weekday == 7: continue
            case .weekly where !weekdays.contains(weekday): continue
            default: break
            }
            let hours = frequency == .hourly ? Array(stride(from: 0, to: 24, by: max(1, everyHours))) : [hour]
            for h in hours {
                if let t = calendar.date(bySettingHour: h, minute: minute, second: 0, of: day), t > date { return t }
            }
        }
        return nil
    }

    /// When it runs next (from the last run, or from creation).
    func upcoming(now: Date = Date()) -> Date? {
        nextRun(after: max(lastRun ?? createdAt, now.addingTimeInterval(-1)))
    }

    var summary: String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch frequency {
        case .hourly: return "Every \(everyHours) h at :\(String(format: "%02d", minute))"
        case .daily: return "Every day at \(time)"
        case .weekdays: return "Weekdays at \(time)"
        case .weekly:
            let names = Calendar.current.shortWeekdaySymbols
            return weekdays.sorted().map { names[($0 - 1) % 7] }.joined(separator: ", ") + " at \(time)"
        }
    }
}
