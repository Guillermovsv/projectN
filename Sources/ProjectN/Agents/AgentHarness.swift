import Foundation

/// Runs agent tasks: resolves the profile, validates provider/model/effort and the project folder, loads the
/// authorised context, starts a *new* session (or an explicitly requested resume) through the normal pane
/// launcher, watches the session's transcript for the result, and enforces approvals, timeouts and concurrency.
@MainActor
final class AgentHarness: ObservableObject, AgentCoordinating {
    enum Event {
        case started
        case approvalNeeded(String)
        case planProposed(String)
        case finished
        /// An approval / question was created (routed to the orchestrator or to you).
        case requestCreated(AgentRequest)
        case requestResolved(AgentRequest)
        /// A request has waited on you for a while: nudge again (minutes waiting).
        case requestReminder(AgentRequest, Int)
    }

    @Published private(set) var profiles: [AgentProfile]
    @Published private(set) var tasks: [AgentTask]
    @Published private(set) var policy: AgentPolicy
    /// Approvals and questions agents are waiting on (in memory: they can't outlive the processes waiting).
    @Published var requests: [AgentRequest] = []

    let bridge = AgentBridge()
    /// Secret per running task → task id. Only in memory and in that task's environment.
    var tokens: [String: UUID] = [:]
    var tokenOfTask: [UUID: String] = [:]
    /// Replies waiting for a request's outcome (the hook / the `ask` tool call).
    var requestWaiters: [UUID: [(AgentRequest) -> Void]] = [:]
    var lastScheduleCheck = Date.distantPast
    /// Called after an agent is saved or deleted (Slack keeps each agent's channel in sync).
    var onProfilesChanged: (() -> Void)?
    /// `wait_for_tasks` calls to wake when something changes for that orchestrator.
    var orchestratorWaiters: [UUID: [() -> Void]] = [:]
    /// Tool calls ProjectN allowed recently, per task (to confirm the CLI's own redundant prompt for them).
    var recentlyApproved: [UUID: [(text: String, at: Date)]] = [:]
    /// A terminal prompt seen on screen, per task, and since when (reported only if it stays up).
    var promptSeen: [UUID: (text: String, at: Date)] = [:]
    /// When each task's current terminal prompt was last reported.
    var lastNoticeAt: [UUID: Date] = [:]
    /// When ProjectN's hook last allowed a tool call for each task (its latest decision was "allow").
    var lastHookAllowed: [UUID: Date] = [:]
    /// The Codex prompt ProjectN last answered by itself, per task (a prompt that stays up after that goes to you).
    var codexAutoAnswered: [UUID: (text: String, at: Date)] = [:]
    /// When each pending request was last reminded about.
    var remindedAt: [UUID: Date] = [:]
    /// When a message was last typed into each task's session.
    var lastTyped: [UUID: Date] = [:]
    /// Prompts seen in each task's transcript at the last read, and how many must appear before a finished turn
    /// counts (a message was typed in but the CLI hasn't written it yet).
    var promptsSeen: [UUID: Int] = [:]
    var promptsExpected: [UUID: (count: Int, at: Date)] = [:]

    private(set) weak var store: Store?
    let catalog: ModelCatalog
    /// Status changes (the Slack connector subscribes). Keyed so observers can be replaced.
    private var observers: [String: (AgentTask, Event) -> Void] = [:]
    private var monitor: DispatchSourceTimer?
    private let readQueue = DispatchQueue(label: "dev.projectn.agents.read", qos: .utility)
    private var readsInFlight = Set<UUID>()
    /// How long a pane may take to appear after a launch request.
    var launchGrace: TimeInterval = 45

    init(catalog: ModelCatalog? = nil) {
        AgentStore.bootstrap()
        self.catalog = catalog ?? .shared
        var policy = AgentStore.loadPolicy()
        if var saved = AgentStore.loadProfiles() {
            var changed = false
            // Older installs started a new session per message; move them to per-project sessions once.
            if !policy.perProjectSessionsMigrated {
                for i in saved.indices where saved[i].sessionPolicy == .alwaysNew { saved[i].sessionPolicy = .perProject }
                policy.perProjectSessionsMigrated = true
                changed = true
            }
            // Autonomous agents: "resume only when asked" opened a new session (and terminal) for every message;
            // coordinators need a model that delegates well; the old Project Manager text told it to ask first.
            if !policy.autonomyMigrated {
                for i in saved.indices {
                    if saved[i].sessionPolicy == .resumeOnExplicitRequest { saved[i].sessionPolicy = .perProject }
                    if saved[i].canDelegate, saved[i].runtime == .claudeCode, saved[i].model.contains("haiku") {
                        saved[i].model = "claude-sonnet-5-5"
                    }
                    let trim = { (x: String) in x.trimmingCharacters(in: .whitespacesAndNewlines) }
                    if trim(saved[i].instructions) == trim(AgentProfile.legacyProjectManagerInstructions) {
                        saved[i].instructions = AgentProfile.projectManagerInstructions
                    }
                }
                policy.autonomyMigrated = true
                changed = true
                AuditLog.record("agents.migrated", ["to": "per-project sessions, autonomy"])
            }
            if changed { AgentStore.saveProfiles(saved, policy: policy) }
            profiles = saved
        } else {
            policy.perProjectSessionsMigrated = true
            policy.autonomyMigrated = true
            let seeded = [AgentProfile.projectManager()]
            profiles = seeded
            AgentStore.saveProfiles(seeded, policy: policy)
        }
        self.policy = policy
        // Anything that was running when the app quit can't be followed any more: report it as interrupted.
        var loaded = AgentStore.loadTasks()
        var changed = false
        for i in loaded.indices where !loaded[i].status.isFinished {
            loaded[i].status = .interrupted
            loaded[i].finishedAt = Date()
            loaded[i].error = "ProjectN was closed while this task was \(loaded[i].startedAt == nil ? "queued" : "running")."
            changed = true
            AuditLog.record("task.interrupted", ["task": loaded[i].id.uuidString, "agent": loaded[i].agentName])
        }
        tasks = loaded
        if changed { AgentStore.saveTasks(tasks) }
    }

    /// Tests: stop tasks after this many seconds instead of the profile's minutes.
    var timeoutOverride: TimeInterval?

    func attach(_ store: Store, refreshModels: Bool = true) {
        guard self.store == nil else { return }
        self.store = store
        bridge.handler = { [weak self] req, reply in self?.handleBridge(req, reply: reply) }
        bridge.start()
        store.agentLaunchContext = { [weak self] pane in self?.launchContext(for: pane) ?? Store.AgentLaunchContext() }
        // A dispatch timer (not a run-loop Timer) so it also fires while menus/modal sheets are tracking.
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1.5)
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        t.resume()
        monitor = t
        if refreshModels { catalog.refresh() }
    }

    func observe(_ key: String, _ handler: @escaping (AgentTask, Event) -> Void) { observers[key] = handler }

    private func emit(_ task: AgentTask, _ event: Event) {
        for o in observers.values { o(task, event) }
    }

    func emitEvent(_ task: AgentTask, _ event: Event) { emit(task, event) }

    func setStatus(_ id: UUID, _ status: AgentTaskStatus) {
        guard task(id)?.status.isFinished == false else { return }
        update(id) { $0.status = status }
    }

    // MARK: Profiles

    func profile(_ id: UUID) -> AgentProfile? { profiles.first { $0.id == id } }

    func saveProfile(_ incoming: AgentProfile) {
        var p = incoming
        // An editor opened before a scheduled run must not roll back that run's time (it would run again).
        if let stored = profile(p.id) {
            for k in p.schedules.indices {
                if let s = stored.schedules.first(where: { $0.id == p.schedules[k].id }), let ran = s.lastRun,
                   ran > (p.schedules[k].lastRun ?? .distantPast) {
                    p.schedules[k].lastRun = ran
                }
            }
        }
        if let stored = profile(p.id) {
            // Channel bookkeeping belongs to Slack sync, not to an editor that may be stale.
            p.slackChannelID = stored.slackChannelID
            p.slackChannelName = stored.slackChannelName
        }
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p } else { profiles.append(p) }
        AgentStore.saveProfiles(profiles, policy: policy)
        onProfilesChanged?()
        AuditLog.record("agent.saved", ["agent": p.name, "model": p.model, "permission": p.permission.rawValue])
    }

    @discardableResult
    func duplicateProfile(_ id: UUID) -> AgentProfile? {
        guard var copy = profile(id) else { return nil }
        copy.id = UUID()
        copy.createdAt = Date()
        var name = "\(copy.name) Copy"
        var n = 2
        while profiles.contains(where: { $0.name == name }) { name = "\(copy.name) Copy \(n)"; n += 1 }
        copy.name = name
        saveProfile(copy)
        return copy
    }

    func deleteProfile(_ id: UUID) {
        guard let p = profile(id) else { return }
        for t in tasks where t.agentID == id && !t.status.isFinished { cancel(t.id) }
        profiles.removeAll { $0.id == id }
        AgentStore.saveProfiles(profiles, policy: policy)
        onProfilesChanged?()
        AuditLog.record("agent.deleted", ["agent": p.name])
    }

    func replaceProfileQuietly(_ p: AgentProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == p.id }) else { return }
        profiles[i] = p
        AgentStore.saveProfiles(profiles, policy: policy)
    }

    func savePolicy(_ p: AgentPolicy) {
        policy = p
        AgentStore.saveProfiles(profiles, policy: p)
        AuditLog.record("policy.saved", ["gray": p.grayApprover.rawValue, "depth": String(p.maxDelegationDepth),
                                         "max_tasks": String(p.maxTasksPerRequest)])
    }

    // MARK: AgentCoordinating

    func availableAgents() -> [AgentProfile] { profiles.filter(\.enabled) }

    func agents(matchingRole role: String) -> [AgentProfile] {
        let r = role.folded
        return availableAgents().filter { $0.role.folded.contains(r) || $0.name.folded.contains(r) }
    }

    func task(_ id: UUID) -> AgentTask? { tasks.first { $0.id == id } }

    /// Validates and queues a task. Validation failures that concern a known agent + project are also recorded
    /// as failed tasks so they show up in the log.
    @discardableResult
    func submit(_ incoming: AgentTaskRequest) -> Result<AgentTask, AgentHarnessError> {
        guard let store else { return .failure(.invalidRuntime("ProjectN isn't ready yet.")) }
        guard let profile = profile(incoming.agentID) else { return fail(.agentNotFound, incoming) }
        guard profile.enabled else { return fail(.agentDisabled(profile.name), incoming) }
        var request = incoming
        // Coordinators work outside the projects: the request goes to their coordination session, and a project
        // it was aimed at becomes a hint they use to pick where (and to whom) to send the work.
        if profile.worksOutsideProjects, request.projectID != Store.coordinationProjectID {
            if let p = store.project(request.projectID), request.resumeTaskID == nil {
                request.instruction += "\n\n(Proyecto indicado: \(p.name) — \(p.path))"
            }
            request.projectID = Store.coordinationProjectID
            if let rid = request.resumeTaskID, task(rid)?.projectID != Store.coordinationProjectID { request.resumeTaskID = nil }
        }
        guard let project = store.project(request.projectID) else { return fail(.projectNotFound, request) }
        guard profile.mayAccess(project.id) else {
            return fail(.projectNotAllowed(agent: profile.name, project: project.name), request)
        }
        if let e = PathGuard.checkWorkingDirectory(project.path) {
            return record(e, request, profile: profile, project: project)
        }
        guard request.dependsOn.allSatisfy({ task($0) != nil }) else { return fail(.dependencyMissing, request) }

        var resumeFrom: AgentTask?
        if let rid = request.resumeTaskID {
            guard let prev = task(rid), prev.sessionID != nil, prev.agentID == profile.id, prev.projectID == project.id else {
                return record(.nothingToResume, request, profile: profile, project: project)
            }
            resumeFrom = prev
        }

        let resolution: ModelResolution
        switch catalog.resolve(profile, settings: store.settings) {
        case .success(let r): resolution = r
        case .failure(let e): return record(e, request, profile: profile, project: project)
        }

        // The session is already working on this conversation: the message goes straight into it
        // (typed into its terminal as soon as it can take input), instead of a new task or a new session.
        if request.resumeTaskID == nil, !request.freshSession, profile.sessionPolicy == .perProject,
           let live = liveTask(agent: profile.id, project: project.id, origin: request.origin) {
            deliverMessage(request.instruction, to: live.id)
            return .success(task(live.id) ?? live)
        }

        // Per-project sessions: continue this agent's session for the project instead of opening a new one.
        var continued = false
        if resumeFrom == nil, profile.sessionPolicy == .perProject, !request.freshSession,
           let prev = projectSession(agent: profile, project: project.id, model: resolution.model) {
            resumeFrom = prev
            continued = true
        }

        var t = AgentTask(agentID: profile.id, agentName: profile.name, projectID: project.id, projectName: project.name,
                          instruction: request.instruction, origin: request.origin, runtime: profile.runtime,
                          model: resolution.model, effort: resolution.effort, permission: profile.permission)
        t.notes = resolution.notes
        t.dependsOn = request.dependsOn
        if request.freshSession { t.skipRecap = true }
        if let parentID = request.origin.parentTaskID, let parent = task(parentID) {
            t.depth = parent.depth + 1
            t.rootTaskID = parent.rootTaskID ?? parent.id
        } else {
            t.rootTaskID = t.id
        }
        if let resumeFrom {
            t.resumedFromTaskID = resumeFrom.id
            t.sessionID = resumeFrom.sessionID
            if continued { t.continuedSession = true }
        }
        tasks.append(t)
        persist()
        AuditLog.record("task.queued", ["task": t.id.uuidString, "agent": profile.name, "project": project.name,
                                        "origin": t.origin.label, "model": t.model, "effort": t.effort ?? "default",
                                        "resume": resumeFrom == nil ? "no" : (continued ? "project session" : "explicit")])
        pump()
        return .success(task(t.id) ?? t)
    }

    func requestReview(of taskID: UUID, by reviewerID: UUID, instruction: String) -> Result<AgentTask, AgentHarnessError> {
        guard let original = task(taskID) else { return .failure(.dependencyMissing) }
        let body = "\(instruction)\n\nReview the result of task “\(original.instruction)” by \(original.agentName)."
        return submit(AgentTaskRequest(agentID: reviewerID, projectID: original.projectID, instruction: body,
                                       origin: TaskOrigin(kind: .agent, parentTaskID: taskID), dependsOn: [taskID]))
    }

    func cancel(_ id: UUID) {
        guard let t = task(id), !t.status.isFinished else { return }
        if let pid = t.paneID { store?.killRuntime(pid) }
        finish(id, status: .cancelled, error: "Cancelled.")
    }

    private func fail(_ e: AgentHarnessError, _ r: AgentTaskRequest) -> Result<AgentTask, AgentHarnessError> {
        AuditLog.record("task.rejected", ["reason": e.description, "origin": r.origin.label])
        return .failure(e)
    }

    private func record(_ e: AgentHarnessError, _ r: AgentTaskRequest, profile: AgentProfile, project: Project) -> Result<AgentTask, AgentHarnessError> {
        var t = AgentTask(agentID: profile.id, agentName: profile.name, projectID: project.id, projectName: project.name,
                          instruction: r.instruction, origin: r.origin, runtime: profile.runtime,
                          model: profile.model, effort: profile.effort, permission: profile.permission)
        t.status = .failed
        t.finishedAt = Date()
        t.error = e.description
        t.delivered = true   // the caller reports the error directly
        tasks.append(t)
        persist()
        AuditLog.record("task.rejected", ["task": t.id.uuidString, "agent": profile.name, "project": project.name, "reason": e.description])
        return .failure(e)
    }

    func markDelivered(_ id: UUID) {
        update(id) { $0.delivered = true }
    }

    // MARK: Scheduling

    func activeCount(agent: UUID) -> Int { tasks.filter { $0.agentID == agent && $0.status.isActive }.count }

    /// Another agent that edits on its own is active in the project. Only "Read & write" agents lock each other
    /// out (those that ask first have every edit approved), and never inside one delegation chain: a coordinator
    /// waiting on its delegate must not block it (that deadlocked until the coordinator gave up).
    private func projectHasWriter(_ project: UUID, for t: AgentTask) -> Bool {
        let mine = lineage(t)
        return tasks.contains { o in
            o.id != t.id && o.projectID == project && o.status.isActive && o.permission == .editProject
                && !mine.contains(o.id) && !lineage(o).contains(t.id)
        }
    }

    /// Why a queued task hasn't started (for coordinators following it).
    func queueReason(_ t: AgentTask) -> String {
        if let dep = t.dependsOn.compactMap(task).first(where: { !$0.status.isFinished }) {
            return "waits for task \(dep.id.uuidString) (\(dep.agentName)) it depends on"
        }
        if let prev = t.resumedFromTaskID.flatMap(task), !prev.status.isFinished {
            return "\(t.agentName) is still busy with an earlier message in the same session; it continues right after"
        }
        if let p = profile(t.agentID), activeCount(agent: t.agentID) >= max(1, p.concurrencyLimit) {
            return "\(t.agentName) is at its limit of \(p.concurrencyLimit) tasks at a time"
        }
        if t.permission == .editProject, projectHasWriter(t.projectID, for: t) {
            return "another agent is editing \(t.projectName); it starts when that one finishes"
        }
        return "starting"
    }

    /// The task and the tasks that delegated it, up the chain.
    func lineage(_ t: AgentTask) -> Set<UUID> {
        var out: Set<UUID> = [t.id]
        var cur = t.origin.parentTaskID
        while let c = cur, !out.contains(c) {
            out.insert(c)
            cur = task(c)?.origin.parentTaskID
        }
        return out
    }

    /// Starts queued tasks whose agent has a free slot, whose dependencies completed, and — for agents that may
    /// write — when no other writing agent is active in the same project (avoids conflicting edits).
    func pump() {
        for t in tasks where t.status == .queued {
            if !t.dependsOn.isEmpty {
                let deps = t.dependsOn.compactMap(task)
                if deps.contains(where: { $0.status.isFinished && $0.status != .completed }) {
                    finish(t.id, status: .failed, error: "A task it depended on didn't complete.")
                    continue
                }
                if !deps.allSatisfy({ $0.status == .completed }) { continue }
            }
            guard let profile = profile(t.agentID) else {
                finish(t.id, status: .failed, error: "The agent profile was deleted.")
                continue
            }
            // A message for a busy session waits for it, then continues in it.
            if let prev = t.resumedFromTaskID.flatMap(task), !prev.status.isFinished { continue }
            guard activeCount(agent: t.agentID) < max(1, profile.concurrencyLimit) else { continue }
            if t.permission == .editProject, projectHasWriter(t.projectID, for: t) { continue }
            launch(t.id, profile: profile)
        }
    }

    private func launch(_ id: UUID, profile: AgentProfile) {
        guard let store, var t = task(id), let project = store.project(t.projectID) else {
            finish(id, status: .failed, error: AgentHarnessError.projectNotFound.description)
            return
        }
        if let e = PathGuard.checkWorkingDirectory(project.path) {
            finish(id, status: .failed, error: e.description)
            return
        }
        let resumeFrom = t.resumedFromTaskID.flatMap(task)
        if let prev = resumeFrom, continueInPlace(&t, after: prev) { return }
        let helper = AgentBridge.helperPath
        // ProjectN's tools (ask, delegate_task, …) reach both runtimes through `pn-agent mcp`.
        let tools: PromptComposer.Capabilities = helper == nil ? .none : depthAllowsDelegation(t, profile) ? .delegate : .ask
        let prompt: String
        let notes = AgentStore.projectNotes(project.id)
        let digest = AgentStore.notesDigest(notes)
        if let prev = resumeFrom {
            prompt = PromptComposer.resumeMessage(task: t, updatedNotes: prev.notesDigest == digest ? nil : notes)
            t.notesDigest = digest
        } else {
            t.notesDigest = digest
            let coordinating = project.id == Store.coordinationProjectID
            let ctx = coordinating ? ContextLoader.Bundle() : ContextLoader.load(projectPath: project.path, sources: profile.contextSources)
            t.notes += ctx.notes
            prompt = PromptComposer.firstMessage(task: t, profile: profile, project: project, context: ctx,
                                                 includeInstructions: profile.runtime != .claudeCode, capabilities: tools,
                                                 recap: t.skipRecap == true || profile.sessionPolicy != .perProject ? [] : recentConversation(for: t),
                                                 projects: coordinating ? coordinatedProjects(profile) : [])
            // One terminal per agent + project: earlier sessions of this pair whose work is done are closed.
            closeFinishedPanes(agent: profile.id, project: project.id)
        }
        // The bridge must be listening before a session that relies on it starts.
        guard bridge.port != nil || AgentBridge.helperPath == nil else { return }
        var args: [String] = []
        if profile.runtime == .claudeCode {
            args += ["--append-system-prompt", PromptComposer.systemPrompt(profile: profile, project: project, capabilities: tools)]
            if project.id == Store.coordinationProjectID {
                // Reads the projects it coordinates without Claude Code asking for each folder.
                for p in coordinatedProjects(profile) { args += ["--add-dir", p.path] }
            }
            // Built-in tools for the access level (or the profile's own selection). MCP tools aren't affected.
            if let tools = AgentToolCatalog.claudeFlag(profile) { args += ["--tools", tools] }
            if !profile.usesClaudeMCP(ClaudeMCPEntry.chromeName) { args.append("--no-chrome") }
            // Only this agent's MCP servers (+ ProjectN's), never the user's global MCP setup.
            if let file = writeMCPConfig(task: t, profile: profile, helper: helper) {
                args += ["--strict-mcp-config", "--mcp-config", file.path]
            }
            // Every tool call goes through ProjectN's approval policy first.
            if let helper, let hooks = Self.hookSettings(helper: helper, timeoutSeconds: profile.timeoutMinutes * 60) {
                args += ["--settings", hooks]
            }
        } else {
            args += MCPConfig.codexOverrides(MCPConfig.load().filter { profile.mcpServers.contains($0.name) && $0.name != "projectn" })
            // Without this Codex never sees delegate_task / list_agents / ask, so a Codex coordinator can't delegate.
            if let helper { args += MCPConfig.codexProjectNOverrides(helper: helper, toolTimeoutSeconds: profile.timeoutMinutes * 60) }
            // Auto mode / High: network inside the sandbox (curl, APIs, localhost) without asking each time.
            if profile.autoMode || profile.autonomy == .high {
                args += ["-c", "sandbox_workspace_write.network_access=true"]
            }
        }
        issueToken(for: t.id)
        let hookEnforced = profile.runtime == .claudeCode && helper != nil
        let options = LaunchOptions(model: t.model, effort: t.effort,
                                    permission: profile.permission.paneValue(for: profile.runtime, hookEnforced: hookEnforced))
        let finishedTaskIDs = Set(tasks.filter { $0.status.isFinished }.map(\.id))
        let launch = Store.AgentLaunch(taskID: t.id, tool: profile.runtime.tool, projectID: project.id, options: options,
                                       agentArgs: args, prompt: prompt, title: "\(profile.name) · \(project.name)",
                                       resumeSessionID: resumeFrom?.sessionID, reusePaneID: resumeFrom?.paneID)
        if let prevSession = resumeFrom?.sessionID {
            let url = profile.runtime == .claudeCode
                ? TranscriptReader.claudeTranscript(sessionID: prevSession, settings: store.settings)
                : TranscriptReader.codexTranscript(sessionID: prevSession, settings: store.settings)
            t.transcriptOffset = TranscriptReader.fileSize(url)
        }
        guard let (wid, pane) = store.launchAgentPane(launch, recyclable: finishedTaskIDs) else {
            replace(t)
            finish(id, status: .failed, error: "Couldn't create a pane for the task.")
            return
        }
        t.workspaceID = wid
        t.paneID = pane.id
        t.sessionID = profile.runtime == .claudeCode ? pane.claudeSessionID : (resumeFrom?.sessionID ?? pane.codexSessionID)
        t.status = .starting
        t.startedAt = Date()
        replace(t)
        AuditLog.record("task.started", ["task": t.id.uuidString, "agent": t.agentName, "project": t.projectName,
                                         "session": t.sessionID ?? "pending", "pane": pane.id.uuidString,
                                         "permission": options.permission ?? "", "model": t.model])
        emit(t, .started)
    }

    /// The projects a coordinator sees and sends work to (existing folders it may access).
    func coordinatedProjects(_ profile: AgentProfile) -> [Project] {
        (store?.state.projects ?? []).filter { profile.mayAccess($0.id) && $0.exists }
    }

    // MARK: Per-project sessions

    /// The session to continue for (agent, project): its latest task that had a session, if it ran on the same
    /// runtime and model, didn't crash, and was used within the idle window.
    func projectSession(agent p: AgentProfile, project: UUID, model: String) -> AgentTask? {
        // A queued task that will continue the session counts too: the next one waits for it and then continues
        // in its terminal, instead of resuming the same conversation in a second terminal.
        guard let prev = tasks.last(where: { $0.agentID == p.id && $0.projectID == project && $0.sessionID != nil
                                             && ($0.paneID != nil || $0.status == .queued) })
        else { return nil }
        guard prev.runtime == p.runtime, prev.status != .failed else { return nil }
        let lastUsed = prev.finishedAt ?? Date()
        guard Date().timeIntervalSince(lastUsed) < Double(max(1, policy.sessionIdleHours) * 3600) else { return nil }
        // A long conversation is re-read on every step: past the limit, start fresh (the new session gets a recap).
        // Not while the session is warm (its terminal still open, used within the idle-close window): a follow-up
        // there is the same piece of work, and the CLI compacts its own context. Rotating it lost continuity —
        // a follow-up a minute later landed in a new terminal with no memory of what it had just done.
        let warm = prev.paneID.flatMap { store?.runtimes[$0] }?.isRunning == true
            && Date().timeIntervalSince(lastUsed) < Double(policy.idleCloseMinutes * 60)
        if !warm, let size = sessionContextTokens(prev), size >= policy.maxSessionContextK * 1000 {
            AuditLog.record("session.rotated", ["agent": prev.agentName, "project": prev.projectName,
                                                "session": prev.sessionID ?? "", "context_tokens": String(size)])
            return nil
        }
        return prev
    }

    /// Conversation size of the session `t` belongs to, at its last model call (walks back to the last task of
    /// the session that recorded usage: a queued continuation has none yet).
    func sessionContextTokens(_ t: AgentTask) -> Int? {
        var cur: AgentTask? = t
        var seen = Set<UUID>()
        while let c = cur, !seen.contains(c.id) {
            seen.insert(c.id)
            if let n = c.usage?.contextTokens { return n }
            cur = c.resumedFromTaskID.flatMap(task)
        }
        return nil
    }

    /// The session's terminal is still running: type the next message into it (no new process, no context reload).
    /// Returns false when it isn't, so the caller resumes the conversation in a new process instead.
    private func continueInPlace(_ t: inout AgentTask, after prev: AgentTask) -> Bool {
        guard let store, let paneID = prev.paneID, let wid = prev.workspaceID, let rt = store.runtimes[paneID], rt.isRunning,
              let (_, pane) = store.pane(paneID, in: wid), pane.agentTaskID == prev.id, let sid = prev.sessionID,
              prev.model == t.model, !rt.needsInput,
              // Only a process ProjectN started this run holds a live token: one restored after an app restart has
              // none (tokens live in memory), so its ProjectN tools and approval hook can't reach the app. Resume
              // the conversation in a fresh, connected process instead.
              tokenOfTask[prev.id] != nil else { return false }
        let url = t.runtime == .claudeCode
            ? TranscriptReader.claudeTranscript(sessionID: sid, settings: store.settings)
            : TranscriptReader.codexTranscript(sessionID: sid, settings: store.settings)
        t.transcriptOffset = TranscriptReader.fileSize(url)
        t.paneID = paneID
        t.workspaceID = wid
        t.sessionID = sid
        t.status = .running
        t.startedAt = Date()
        // Hooks of this process carry the session's token: point it at the new task.
        if let token = tokenOfTask.removeValue(forKey: prev.id) {
            tokens[token] = t.id
            tokenOfTask[t.id] = token
        }
        store.updatePane(paneID, in: wid) {
            $0.agentTaskID = t.id
            $0.lastPrompt = t.instruction
        }
        let notes = AgentStore.projectNotes(t.projectID)
        let digest = AgentStore.notesDigest(notes)
        let message = PromptComposer.resumeMessage(task: t, updatedNotes: prev.notesDigest == digest ? nil : notes)
        t.notesDigest = digest
        replace(t)
        lastTyped[t.id] = Date()
        promptsSeen[t.id] = 0   // the transcript is read from here on (new offset)
        expectPrompt(t.id)
        rt.submit(message)
        AuditLog.record("task.started", ["task": t.id.uuidString, "agent": t.agentName, "project": t.projectName,
                                         "session": sid, "pane": paneID.uuidString, "mode": "continued in place"])
        emit(t, .started)
        return true
    }

    // MARK: Monitoring

    private func tick() {
        guard let store else { return }
        expireRequests()
        remindPendingRequests()
        if Date().timeIntervalSince(lastScheduleCheck) >= 30 {
            lastScheduleCheck = Date()
            runDueSchedules()
            closeIdleSessions()
        }
        for t in tasks where t.status.isActive {
            guard let paneID = t.paneID, let wid = t.workspaceID else { continue }
            let profile = profile(t.agentID)
            // Timeout (not while it's waiting for your answer: that's your time, not its).
            let limit = timeoutOverride ?? Double((profile?.timeoutMinutes ?? 30) * 60)
            if t.status != .waitingForUser, let started = t.startedAt, Date().timeIntervalSince(started) > limit {
                store.killRuntime(paneID)
                finish(t.id, status: .timedOut, error: "Stopped after \(profile?.timeoutMinutes ?? 30) minutes without finishing.")
                continue
            }
            // Pane closed by the user.
            guard let (_, pane) = store.pane(paneID, in: wid) else {
                finish(t.id, status: .cancelled, error: "The task's pane was closed in ProjectN.")
                continue
            }
            let rt = store.runtimes[paneID]
            if rt == nil {
                if !store.hasPendingLaunch(paneID), let s = t.startedAt, Date().timeIntervalSince(s) > launchGrace {
                    finish(t.id, status: .failed, error: "The session didn't start.")
                }
                continue
            }
            // Codex picks its own session id; the Store discovers it shortly after launch.
            if t.sessionID == nil, let sid = pane.codexSessionID { update(t.id) { $0.sessionID = sid } }
            if let rt {
                switch rt.activity {
                case .needsInput(let q):
                    let approved = (recentlyApproved[t.id] ?? []).filter { Date().timeIntervalSince($0.at) < 180 }.map(\.text)
                    if !approved.isEmpty, let answer = rt.confirmApprovedPrompt(approved) {
                        promptSeen.removeValue(forKey: t.id)
                        AuditLog.record("prompt.confirmed", ["task": t.id.uuidString, "agent": t.agentName, "answer": answer,
                                                             "prompt": ApprovalPolicy.clip(q)])
                    } else if let allowedAt = lastHookAllowed[t.id], Date().timeIntervalSince(allowedAt) < 20,
                              promptSeen[t.id]?.text == q,
                              !requests.contains(where: { $0.taskID == t.id && $0.isPending }),
                              rt.answerPendingPrompt(approve: true) {
                        // Every tool call passes ProjectN's hook first: a CLI prompt right after the hook allowed the
                        // call is Claude Code asking again (its own checks), not a new decision for you.
                        lastHookAllowed.removeValue(forKey: t.id)
                        promptSeen.removeValue(forKey: t.id)
                        AuditLog.record("prompt.confirmed", ["task": t.id.uuidString, "agent": t.agentName, "answer": "Yes",
                                                             "why": "already allowed by ProjectN", "prompt": ApprovalPolicy.clip(q)])
                    } else if let last = rt.lastAutoAnswer, Date().timeIntervalSince(last.at) < 8 {
                        // Just answered: the screen still shows the prompt until the CLI redraws. Not a new one.
                    } else if let seen = promptSeen[t.id], seen.text == q {
                        // Only a prompt that stays up is reported (half-drawn frames and instant redraws aren't).
                        let up = Date().timeIntervalSince(seen.at)
                        if up >= 1.5, let profile, decideCodexPrompt(t, profile: profile, runtime: rt, question: q) {
                            promptSeen.removeValue(forKey: t.id)
                        } else if up >= 3 { noteApproval(t.id, question: q) }
                    } else {
                        promptSeen[t.id] = (q, Date())
                    }
                case .working where t.status != .running && t.status != .waitingForUser && !requests.contains(where: { $0.taskID == t.id && $0.isPending }):
                    promptGone(t.id)
                    update(t.id) { $0.status = .running }
                default:
                    promptGone(t.id)
                    if t.status == .starting, rt.isRunning { update(t.id) { $0.status = .running } }
                }
                flushInbox(t.id)
            }
            readTranscript(task(t.id) ?? t)
        }
    }

    /// Codex has no hook: its terminal prompt is judged here with the same policy as Claude's tool calls
    /// (autonomy / Auto mode). Allowed → answered "Allow" / "Yes" (once, never "always"); not allowed for this agent →
    /// refused. Returns false when the user decides (deleting, admin/system changes, secrets, or Auto mode off).
    private func decideCodexPrompt(_ t: AgentTask, profile: AgentProfile, runtime rt: TerminalSession, question q: String) -> Bool {
        guard t.runtime == .codexCLI, let project = store?.project(t.projectID) else { return false }
        // Answered by ProjectN a moment ago and still up: the answer didn't take, so you decide.
        if let last = codexAutoAnswered[t.id], last.text == q, Date().timeIntervalSince(last.at) < 30 { return false }
        let screen = rt.scrollbackText(maxLines: 40).components(separatedBy: "\n")
        let ask = CodexPromptPolicy.parse(screen: screen, question: q)
        let ctx = ApprovalPolicy.Context(permission: profile.permission, projectPath: project.path, cliTools: profile.cliTools,
                                         cwd: project.path, autonomy: profile.autonomy, autoMode: profile.autoMode)
        let tier = CodexPromptPolicy.decide(ask, ctx)
        let call = CodexPromptPolicy.describe(ask)
        switch tier {
        case .allow:
            guard rt.answerPendingPrompt(approve: true) else { return false }
            codexAutoAnswered[t.id] = (q, Date())
            AuditLog.record("prompt.auto_approved", ["task": t.id.uuidString, "agent": t.agentName, "call": call,
                                                     "why": profile.autoMode ? "Auto mode" : "autonomy \(profile.autonomy.label)",
                                                     "prompt": ApprovalPolicy.clip(q)])
            if t.status == .needsApproval { update(t.id) { $0.status = .running } }
            return true
        case .deny(let why):
            guard rt.answerPendingPrompt(approve: false) else { return false }
            codexAutoAnswered[t.id] = (q, Date())
            AuditLog.record("prompt.auto_denied", ["task": t.id.uuidString, "agent": t.agentName, "call": call, "reason": why])
            queueForSession(t.id, "ProjectN refused that: \(why)")
            return true
        case .orchestrator, .user:
            return false
        }
    }

    /// The CLI shows its own prompt and nothing answered it: ask the user (Slack buttons / ProjectN), then
    /// answer it in the terminal for them.
    private func noteApproval(_ id: UUID, question: String) {
        guard let t = task(id), let paneID = t.paneID else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.status = .needsApproval }
        guard !requests.contains(where: { $0.taskID == id && $0.isPending && $0.terminalPrompt == true }) else { return }
        let screen = store?.runtimes[paneID]?.scrollbackText(maxLines: 14) ?? ""
        let detail = screen.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " │┃║╭╮╰╯─━")) }
            .filter { !$0.isEmpty }.suffix(10).joined(separator: "\n")
        // Keyed by what the prompt shows (the command), not its question: Claude Code asks "Do you want to
        // proceed?" for every command, and a second one right after an approval used to be swallowed. A prompt
        // still up with nothing pending for it (answer failed, expired, identical repeat) is re-reported.
        let key = String((detail.isEmpty ? q : detail).hashValue)
        if t.lastApprovalNotice == key, let at = lastNoticeAt[id], Date().timeIntervalSince(at) < 60 { return }
        update(id) { $0.lastApprovalNotice = key }
        lastNoticeAt[id] = Date()
        AuditLog.record("task.approval_needed", ["task": id.uuidString, "agent": t.agentName, "prompt": q])
        createRequest(kind: .approval, task: t, summary: Redactor.redact(detail.isEmpty ? q : detail),
                      reason: "\(t.runtime.label) asks in its terminal: \(q)", route: .user, terminalPrompt: true) { [weak self] r in
            guard let self else { return }
            // Decided: whatever the CLI asks next is a new prompt, even with the same text.
            if r.status != .pending {
                self.promptSeen.removeValue(forKey: id)
                self.lastNoticeAt.removeValue(forKey: id)
                if self.task(id)?.lastApprovalNotice?.hasPrefix("plan:") == false { self.update(id) { $0.lastApprovalNotice = nil } }
            }
            guard let rt = self.store?.runtimes[paneID] else { return }
            switch r.status {
            case .approved: if !rt.answerPendingPrompt(approve: true) { AuditLog.record("prompt.answer_failed", ["task": id.uuidString]) }
            case .denied: rt.answerPendingPrompt(approve: false)
            default: break
            }
        }
        if let t = task(id) { emit(t, .approvalNeeded(q)) }
    }

    /// Requests waiting on you don't sit silently: a reminder after 10 min, then every 20 min.
    func remindPendingRequests(now: Date = Date()) {
        remindedAt = remindedAt.filter { id, _ in requests.contains { $0.id == id && $0.isPending } }
        for r in requests where r.isPending && r.route == .user {
            let waited = now.timeIntervalSince(r.createdAt)
            let due = remindedAt[r.id].map { now.timeIntervalSince($0) >= 20 * 60 } ?? (waited >= 10 * 60)
            guard due, let t = task(r.taskID) else { continue }
            remindedAt[r.id] = now
            AuditLog.record("request.reminded", ["request": r.id.uuidString, "agent": r.agentName, "minutes": String(Int(waited / 60))])
            emit(t, .requestReminder(r, Int(waited / 60)))
        }
    }

    /// The terminal prompt went away (answered there, or by ProjectN): forget it, so the next one is reported.
    private func promptGone(_ id: UUID) {
        promptSeen.removeValue(forKey: id)
        if task(id)?.lastApprovalNotice != nil, task(id)?.lastApprovalNotice?.hasPrefix("plan:") == false {
            update(id) { $0.lastApprovalNotice = nil }
        }
        for r in requests where r.taskID == id && r.isPending && r.terminalPrompt == true
            && Date().timeIntervalSince(r.createdAt) > 3 {
            closeRequest(r.id, status: .expired, by: "ProjectN (answered in the terminal)")
        }
    }

    private func readTranscript(_ t: AgentTask) {
        guard let store, !readsInFlight.contains(t.id) else { return }
        let settings = store.settings
        let exitURL = t.paneID.map(AgentStore.exitMarker)
        readsInFlight.insert(t.id)
        let id = t.id
        readQueue.async { [weak self] in
            // Exit code first: if the CLI wrote its last entry and exited between the two reads,
            // the transcript read below still sees the finished turn.
            let exitCode = exitURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var snap: TranscriptReader.Snapshot?
            if let sid = t.sessionID {
                let url = t.runtime == .claudeCode
                    ? TranscriptReader.claudeTranscript(sessionID: sid, settings: settings)
                    : TranscriptReader.codexTranscript(sessionID: sid, settings: settings)
                if let url { snap = TranscriptReader.read(runtime: t.runtime, url: url, offset: t.transcriptOffset) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.readsInFlight.remove(id)
                self.apply(snapshot: snap, exitCode: exitCode, to: id)
            }
        }
    }

    /// A message was just typed in: a finished turn doesn't count until the transcript shows it.
    func expectPrompt(_ id: UUID) {
        let base = max(promptsSeen[id] ?? 0, promptsExpected[id]?.count ?? 0)
        promptsExpected[id] = (base + 1, Date())
    }

    private func apply(snapshot: TranscriptReader.Snapshot?, exitCode: String?, to id: UUID) {
        guard let t = task(id), t.status.isActive else { return }
        if let u = snapshot?.usage { update(id) { $0.usage = u } }
        if let s = snapshot { promptsSeen[id] = s.prompts }
        if let s = snapshot, s.finished, let e = promptsExpected[id] {
            // The typed message hasn't reached the transcript yet: the "finished" turn is the previous one.
            if s.prompts < e.count && Date().timeIntervalSince(e.at) < 90 { return }
            promptsExpected.removeValue(forKey: id)
        }
        if let s = snapshot, s.finished {
            // More messages for it: the session continues instead of finishing.
            if !(t.inbox ?? []).isEmpty { flushInbox(id); return }
            // It asked a question and ended its turn: it waits for the answer (no timeout meanwhile).
            if let q = t.awaitingAnswer, requests.contains(where: { $0.id == q && $0.isPending }) {
                if t.status != .waitingForUser { update(id) { $0.status = .waitingForUser; $0.result = s.result } }
                return
            }
            update(id) { $0.result = s.result ?? "" }
            finish(id, status: .completed, error: s.error)
            return
        }
        if let plan = snapshot?.pendingPlan, t.lastApprovalNotice != "plan:\(plan.hashValue)" {
            update(id) { $0.status = .needsApproval; $0.lastApprovalNotice = "plan:\(plan.hashValue)"; $0.result = plan }
            AuditLog.record("task.plan_proposed", ["task": id.uuidString, "agent": t.agentName])
            if let t = task(id) { emit(t, .planProposed(plan)) }
        }
        if let code = exitCode {
            // The CLI ended without a finished turn: a crash, a bad flag, an unavailable model, a kill…
            let tail = t.paneID.flatMap { store?.runtimes[$0]?.scrollbackText(maxLines: 15) } ?? ""
            let detail = tail.isEmpty ? "" : "\nLast output:\n" + String(tail.suffix(1200))
            finish(id, status: .failed, error: "\(t.runtime.label) exited (code \(code)) before finishing.\(detail)")
        }
    }

    private func finish(_ id: UUID, status: AgentTaskStatus, error: String? = nil) {
        guard let t = task(id), !t.status.isFinished else { return }
        update(id) {
            $0.status = status
            $0.finishedAt = Date()
            if let error, !error.isEmpty { $0.error = error }
        }
        // A completed task's session stays open for the project's next message; its token moves on with it.
        if status != .completed { revokeToken(for: id) }
        recentlyApproved.removeValue(forKey: id)
        expireRequests()
        promptSeen.removeValue(forKey: id)
        lastNoticeAt.removeValue(forKey: id)
        lastHookAllowed.removeValue(forKey: id)
        promptsExpected.removeValue(forKey: id)
        promptsSeen.removeValue(forKey: id)
        lastTyped.removeValue(forKey: id)
        // Requests addressed to this task as a coordinator go to the user now that it stopped listening.
        for r in requests where r.isPending && r.route == .orchestrator(id) { escalateRequest(r.id, note: "the coordinator finished its turn") }
        guard let done = task(id) else { return }
        AuditLog.record("task.\(status.rawValue)", ["task": id.uuidString, "agent": done.agentName, "project": done.projectName,
                                                     "duration_s": String(Int(done.duration ?? 0)),
                                                     "tokens": done.usage.map { String($0.total) } ?? "n/a",
                                                     "error": done.error ?? ""])
        emit(done, .finished)
        // Messages that arrived too late for this turn continue the session as a follow-up.
        if let left = done.inbox, !left.isEmpty, status != .cancelled {
            update(id) { $0.inbox = [] }
            var origin = done.origin
            origin.automatic = true
            submit(AgentTaskRequest(agentID: done.agentID, projectID: done.projectID,
                                    instruction: left.joined(separator: "\n\n"), origin: origin))
        }
        handBackToCoordinator(done)
        pump()
    }

    // MARK: Live sessions

    /// The active task of this agent + project for the same conversation (Slack channel, or ProjectN itself).
    func liveTask(agent: UUID, project: UUID, origin: TaskOrigin) -> AgentTask? {
        guard origin.kind == .slack || origin.kind == .local else { return nil }
        return tasks.last { t in
            t.agentID == agent && t.projectID == project && t.status.isActive && t.origin.kind == origin.kind
                && (origin.kind != .slack || t.origin.slackChannel == origin.slackChannel)
        }
    }

    /// Hands a new message to a running session: it waits in the inbox until the terminal can take it (typed in
    /// right away when possible). An open question stays open (replies to it are routed as answers by Slack).
    func deliverMessage(_ text: String, to id: UUID) {
        guard let t = task(id) else { return }
        queueForSession(id, PromptComposer.newMessage(text))
        AuditLog.record("task.message_queued", ["task": id.uuidString, "agent": t.agentName, "text": ApprovalPolicy.clip(text)])
    }

    func queueForSession(_ id: UUID, _ message: String) {
        update(id) { $0.inbox = ($0.inbox ?? []) + [message] }
        flushInbox(id)
    }

    /// Types the next waiting message into the session when it can take input: running (Claude Code queues
    /// what's typed while it works), not showing a prompt, not waiting on an approval hook.
    func flushInbox(_ id: UUID) {
        guard let store, let t = task(id), t.status.isActive, t.status != .starting, var inbox = t.inbox, !inbox.isEmpty,
              let paneID = t.paneID, let rt = store.runtimes[paneID], rt.isRunning, !rt.needsInput,
              !requests.contains(where: { $0.taskID == id && $0.isPending && $0.kind == .approval }) else { return }
        if let last = lastTyped[id], Date().timeIntervalSince(last) < 2 { return }   // one message at a time
        let next = inbox.removeFirst()
        lastTyped[id] = Date()
        expectPrompt(id)
        update(id) {
            $0.inbox = inbox
            $0.followUps = ($0.followUps ?? []) + [next]
            if $0.status == .waitingForUser || $0.status == .needsApproval {
                $0.status = .running
                $0.startedAt = Date()   // the timeout counts from here
            }
        }
        store.updatePane(paneID, in: t.workspaceID ?? UUID()) { $0.lastPrompt = next }
        rt.submit(next)
        AuditLog.record("task.message_delivered", ["task": id.uuidString, "agent": t.agentName])
    }

    /// A delegated task ended: its coordinator gets the result in its session — now if it's still working (and
    /// not inside wait_for_tasks, which reports it anyway), else as a follow-up that answers the user.
    private func handBackToCoordinator(_ done: AgentTask) {
        guard let pid = done.origin.parentTaskID, let parent = task(pid) else { return }
        let message = PromptComposer.delegatedResult(done)
        if parent.status.isActive {
            if orchestratorWaiters[pid]?.isEmpty == false { return }
            queueForSession(pid, message)
        } else if parent.status == .completed, profile(parent.agentID)?.enabled == true {
            var origin = parent.origin
            origin.automatic = true
            submit(AgentTaskRequest(agentID: parent.agentID, projectID: parent.projectID, instruction: message, origin: origin))
        }
    }

    /// Earlier exchanges of this conversation, for a session that starts fresh.
    func recentConversation(for t: AgentTask, limit: Int = 6) -> [AgentTask] {
        guard t.origin.kind == .slack || t.origin.kind == .local else { return [] }
        let recent = tasks.filter { o in
            o.id != t.id && o.agentID == t.agentID && o.projectID == t.projectID && o.status.isFinished
                && o.origin.kind == t.origin.kind && o.origin.automatic != true
                && (t.origin.kind != .slack || o.origin.slackChannel == t.origin.slackChannel)
                && Date().timeIntervalSince(o.createdAt) < 48 * 3600
        }
        return Array(recent.suffix(limit))
    }

    /// Closes this agent + project's panes whose tasks have finished (a new session is starting for the pair).
    private func closeFinishedPanes(agent: UUID, project: UUID) {
        guard let store else { return }
        for o in tasks where o.agentID == agent && o.projectID == project && o.status.isFinished {
            guard let pid = o.paneID, let wid = o.workspaceID, let (_, pane) = store.pane(pid, in: wid), pane.agentTaskID == o.id else { continue }
            store.closePane(pid, in: wid)
            AuditLog.record("session.closed", ["agent": o.agentName, "project": o.projectName, "session": o.sessionID ?? "", "why": "replaced"])
        }
    }

    /// Closes a task's session terminal (pane); a running task is cancelled first. The conversation stays in the
    /// CLI's history: the next message about that project resumes it in a new terminal.
    func closeSession(_ id: UUID) {
        guard let t = task(id) else { return }
        if !t.status.isFinished { cancel(id) }
        guard let store, let pid = t.paneID, let wid = t.workspaceID, store.pane(pid, in: wid) != nil else { return }
        store.closePane(pid, in: wid)
        AuditLog.record("session.closed", ["agent": t.agentName, "project": t.projectName, "session": t.sessionID ?? "", "why": "closed by you"])
    }

    /// Idle sessions don't keep a process running forever: stopped after the idle time, and only the most recent
    /// few per agent stay up. The pane and conversation remain; the next message resumes it.
    func closeIdleSessions(now: Date = Date()) {
        guard let store, let w = store.agentWorkspace else { return }
        // Idle since the task finished, or since the process last printed / was (re)started: a session you
        // reopen by looking at it counts as fresh, not as idle since its task ended long ago.
        var idle: [(pane: UUID, task: AgentTask, since: Date)] = []
        let visible = store.visiblePaneIDs
        for p in w.spaces.flatMap(\.panes) {
            guard let tid = p.agentTaskID, let t = task(tid), t.status.isFinished,
                  let rt = store.runtimes[p.id], rt.isRunning else { continue }
            if visible.contains(p.id) { continue }   // on screen: never stopped under your eyes
            idle.append((p.id, t, max(t.finishedAt ?? now, rt.startedAt, rt.lastOutputAt)))
        }
        let limit = Double(policy.idleCloseMinutes * 60)
        var keep: [UUID: Int] = [:]
        for item in idle.sorted(by: { $0.since > $1.since }) {
            let age = now.timeIntervalSince(item.since)
            let n = keep[item.task.agentID, default: 0]
            if age > limit || n >= policy.maxIdleSessionsPerAgent {
                store.killRuntime(item.pane)
                AuditLog.record("session.stopped", ["agent": item.task.agentName, "project": item.task.projectName,
                                                    "session": item.task.sessionID ?? "", "why": age > limit ? "idle" : "too many idle sessions"])
            } else {
                keep[item.task.agentID] = n + 1
            }
        }
    }

    // MARK: Helpers

    func update(_ id: UUID, _ mutate: (inout AgentTask) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        var t = tasks[i]
        mutate(&t)
        guard t != tasks[i] else { return }
        tasks[i] = t
        persist()
        taskChanged(t)
    }

    func replaceTask(_ t: AgentTask) { replace(t) }

    private func replace(_ t: AgentTask) {
        guard let i = tasks.firstIndex(where: { $0.id == t.id }) else { return }
        tasks[i] = t
        persist()
        taskChanged(t)
    }

    private var saveWork: DispatchWorkItem?
    private func persist() {
        saveWork?.cancel()
        let snapshot = tasks
        let work = DispatchWorkItem { AgentStore.saveTasks(snapshot) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        AgentStore.saveTasks(tasks)
    }

    func clearFinishedTasks() {
        tasks.removeAll { $0.status.isFinished }
        saveNow()
    }

    /// Opens the task's pane in ProjectN.
    func reveal(_ id: UUID) {
        guard let t = task(id), let p = t.paneID, let w = t.workspaceID else { return }
        store?.reveal(pane: p, in: w)
    }
}

extension String {
    /// Lowercased, accents removed: "Revisión" ≈ "revision".
    var folded: String { folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased() }
}
