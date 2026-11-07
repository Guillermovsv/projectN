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
        let policy = AgentStore.loadPolicy()
        self.policy = policy
        if var saved = AgentStore.loadProfiles() {
            // Older installs started a new session per message; move them to per-project sessions once.
            if !policy.perProjectSessionsMigrated {
                for i in saved.indices where saved[i].sessionPolicy == .alwaysNew { saved[i].sessionPolicy = .perProject }
                var migrated = policy
                migrated.perProjectSessionsMigrated = true
                self.policy = migrated
                AgentStore.saveProfiles(saved, policy: migrated)
            }
            profiles = saved
        } else {
            let seeded = [AgentProfile.projectManager()]
            profiles = seeded
            AgentStore.saveProfiles(seeded, policy: policy)
        }
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
    func submit(_ request: AgentTaskRequest) -> Result<AgentTask, AgentHarnessError> {
        guard let store else { return .failure(.invalidRuntime("ProjectN isn't ready yet.")) }
        guard let profile = profile(request.agentID) else { return fail(.agentNotFound, request) }
        guard profile.enabled else { return fail(.agentDisabled(profile.name), request) }
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
            guard profile.sessionPolicy == .resumeOnExplicitRequest else { return record(.resumeNotAllowed, request, profile: profile, project: project) }
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

    private func activeCount(agent: UUID) -> Int { tasks.filter { $0.agentID == agent && $0.status.isActive }.count }

    private func projectHasWriter(_ project: UUID) -> Bool {
        tasks.contains { $0.projectID == project && $0.status.isActive && $0.permission.canWrite }
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
            if t.permission.canWrite, projectHasWriter(t.projectID) { continue }
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
        let prompt: String
        if resumeFrom != nil {
            prompt = PromptComposer.resumeMessage(task: t)
        } else {
            let ctx = ContextLoader.load(projectPath: project.path, sources: profile.contextSources)
            t.notes += ctx.notes
            prompt = PromptComposer.firstMessage(task: t, profile: profile, project: project, context: ctx,
                                                 includeInstructions: profile.runtime != .claudeCode)
        }
        // The bridge must be listening before a session that relies on it starts.
        guard bridge.port != nil || AgentBridge.helperPath == nil else { return }
        let helper = AgentBridge.helperPath
        var args: [String] = []
        if profile.runtime == .claudeCode {
            let tools = helper != nil && depthAllowsDelegation(t, profile) ? PromptComposer.Capabilities.delegate
                      : helper != nil ? .ask : PromptComposer.Capabilities.none
            args += ["--append-system-prompt", PromptComposer.systemPrompt(profile: profile, project: project, capabilities: tools)]
            // Built-in tools for the access level (or the profile's own selection). MCP tools aren't affected.
            if let tools = AgentToolCatalog.claudeFlag(profile) { args += ["--tools", tools] }
            // Only this agent's MCP servers (+ ProjectN's), never the user's global MCP setup.
            if let file = writeMCPConfig(task: t, profile: profile, helper: helper) {
                args += ["--strict-mcp-config", "--mcp-config", file.path]
            }
            // Every tool call goes through ProjectN's approval policy first.
            if let helper, let hooks = Self.hookSettings(helper: helper, timeoutSeconds: profile.timeoutMinutes * 60) {
                args += ["--settings", hooks]
            }
        } else {
            args += MCPConfig.codexOverrides(MCPConfig.load().filter { profile.mcpServers.contains($0.name) })
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

    // MARK: Per-project sessions

    /// The session to continue for (agent, project): its latest task that had a session, if it ran on the same
    /// runtime and model, didn't crash, and was used within the idle window.
    func projectSession(agent p: AgentProfile, project: UUID, model: String) -> AgentTask? {
        guard let prev = tasks.last(where: { $0.agentID == p.id && $0.projectID == project && $0.sessionID != nil && $0.paneID != nil })
        else { return nil }
        guard prev.runtime == p.runtime, prev.model == model, prev.status != .failed else { return nil }
        let lastUsed = prev.finishedAt ?? Date()
        guard Date().timeIntervalSince(lastUsed) < Double(max(1, policy.sessionIdleHours) * 3600) else { return nil }
        return prev
    }

    /// The session's terminal is still running: type the next message into it (no new process, no context reload).
    /// Returns false when it isn't, so the caller resumes the conversation in a new process instead.
    private func continueInPlace(_ t: inout AgentTask, after prev: AgentTask) -> Bool {
        guard let store, let paneID = prev.paneID, let wid = prev.workspaceID, let rt = store.runtimes[paneID], rt.isRunning,
              let (_, pane) = store.pane(paneID, in: wid), pane.agentTaskID == prev.id, let sid = prev.sessionID else { return false }
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
        replace(t)
        rt.submit(PromptComposer.resumeMessage(task: t))
        AuditLog.record("task.started", ["task": t.id.uuidString, "agent": t.agentName, "project": t.projectName,
                                         "session": sid, "pane": paneID.uuidString, "mode": "continued in place"])
        emit(t, .started)
        return true
    }

    // MARK: Monitoring

    private func tick() {
        guard let store else { return }
        expireRequests()
        if Date().timeIntervalSince(lastScheduleCheck) >= 30 {
            lastScheduleCheck = Date()
            runDueSchedules()
        }
        for t in tasks where t.status.isActive {
            guard let paneID = t.paneID, let wid = t.workspaceID else { continue }
            let profile = profile(t.agentID)
            // Timeout.
            let limit = timeoutOverride ?? Double((profile?.timeoutMinutes ?? 30) * 60)
            if let started = t.startedAt, Date().timeIntervalSince(started) > limit {
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
                        AuditLog.record("prompt.confirmed", ["task": t.id.uuidString, "agent": t.agentName, "answer": answer,
                                                             "prompt": ApprovalPolicy.clip(q)])
                    } else {
                        noteApproval(t.id, question: q)
                    }
                case .working where t.status != .running && !requests.contains(where: { $0.taskID == t.id && $0.isPending }):
                    update(t.id) { $0.status = .running }
                default:
                    if t.status == .starting, rt.isRunning { update(t.id) { $0.status = .running } }
                }
            }
            readTranscript(task(t.id) ?? t)
        }
    }

    private func noteApproval(_ id: UUID, question: String) {
        guard let t = task(id) else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.status = .needsApproval }
        guard t.lastApprovalNotice != q else { return }
        update(id) { $0.lastApprovalNotice = q }
        AuditLog.record("task.approval_needed", ["task": id.uuidString, "agent": t.agentName, "prompt": q])
        if let t = task(id) { emit(t, .approvalNeeded(q)) }
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

    private func apply(snapshot: TranscriptReader.Snapshot?, exitCode: String?, to id: UUID) {
        guard let t = task(id), t.status.isActive else { return }
        if let u = snapshot?.usage { update(id) { $0.usage = u } }
        if let s = snapshot, s.finished {
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
        guard let done = task(id) else { return }
        AuditLog.record("task.\(status.rawValue)", ["task": id.uuidString, "agent": done.agentName, "project": done.projectName,
                                                     "duration_s": String(Int(done.duration ?? 0)),
                                                     "tokens": done.usage.map { String($0.total) } ?? "n/a",
                                                     "error": done.error ?? ""])
        emit(done, .finished)
        pump()
    }

    // MARK: Helpers

    private func update(_ id: UUID, _ mutate: (inout AgentTask) -> Void) {
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
