import Foundation
import Security

/// Approvals, questions and delegation: what agents reach through `pn-agent` (hook + ProjectN MCP server).
extension AgentHarness {
    // MARK: Launch plumbing

    func depthAllowsDelegation(_ t: AgentTask, _ p: AgentProfile) -> Bool {
        p.canDelegate && t.depth < policy.maxDelegationDepth
    }

    func issueToken(for taskID: UUID) {
        if let old = tokenOfTask[taskID] { tokens.removeValue(forKey: old) }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        tokens[token] = taskID
        tokenOfTask[taskID] = token
    }

    func revokeToken(for taskID: UUID) {
        if let t = tokenOfTask.removeValue(forKey: taskID) { tokens.removeValue(forKey: t) }
    }

    /// Environment + API keys for an agent pane. A pane restarted after its task ended gets no token,
    /// so its hook falls back to the CLI's own prompts.
    func launchContext(for pane: Pane) -> Store.AgentLaunchContext {
        var ctx = Store.AgentLaunchContext()
        guard let tid = pane.agentTaskID, let t = task(tid) else { return ctx }
        let keys = Set(store?.settings.apiKeyNames ?? [])
        ctx.apiKeyNames = (profile(t.agentID)?.apiKeys ?? []).filter(keys.contains)
        if let port = bridge.port { ctx.env["PROJECTN_AGENT_PORT"] = String(port) }
        if !t.status.isFinished, let token = tokenOfTask[tid] { ctx.env["PROJECTN_AGENT_TOKEN"] = token }
        ctx.env["PROJECTN_AGENT_TASK"] = tid.uuidString
        // Questions and waits can take long: don't let Claude Code give up on ProjectN's tools early.
        ctx.env["MCP_TOOL_TIMEOUT"] = String(max(60, (profile(t.agentID)?.timeoutMinutes ?? 30) * 60) * 1000)
        return ctx
    }

    /// ~/.projectn/agents/run/<task>.json — ProjectN's server + the profile's servers, 0600.
    func writeMCPConfig(task: AgentTask, profile: AgentProfile, helper: String?) -> URL? {
        var servers: [String: Any] = [:]
        // Claude Code's own servers (yours, then the project's), so agents can use what you use.
        if profile.useClaudeMCP, profile.runtime == .claudeCode, let project = store?.project(task.projectID) {
            for (k, v) in Self.claudeCodeMCPServers(projectPath: project.path) { servers[k] = v }
        }
        for (k, v) in (MCPConfig.loadRaw()["mcpServers"] as? [String: Any] ?? [:]) where profile.mcpServers.contains(k) { servers[k] = v }
        if let helper { servers["projectn"] = ["command": helper, "args": ["mcp"]] }
        AgentStore.bootstrap()
        let url = AgentStore.runDir.appendingPathComponent("\(task.id.uuidString).mcp.json")
        guard let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": servers], options: [.prettyPrinted, .sortedKeys]) else { return nil }
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        return url
    }

    /// MCP servers configured in Claude Code: user-level `mcpServers` in ~/.claude.json plus that file's entry for
    /// the project folder, plus a `.mcp.json` in the project. Later ones win on a name clash.
    nonisolated static func claudeCodeMCPServers(projectPath: String, home: String = NSHomeDirectory()) -> [String: Any] {
        var out: [String: Any] = [:]
        let file = URL(fileURLWithPath: home).appendingPathComponent(".claude.json")
        if let data = try? Data(contentsOf: file), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in json["mcpServers"] as? [String: Any] ?? [:] { out[k] = v }
            let projects = json["projects"] as? [String: Any] ?? [:]
            let key = PathGuard.canonical(projectPath)
            let entry = (projects[projectPath] ?? projects[key]) as? [String: Any]
            for (k, v) in entry?["mcpServers"] as? [String: Any] ?? [:] { out[k] = v }
        }
        let local = URL(fileURLWithPath: projectPath).appendingPathComponent(".mcp.json")
        if let data = try? Data(contentsOf: local), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in json["mcpServers"] as? [String: Any] ?? [:] { out[k] = v }
        }
        out.removeValue(forKey: "projectn")
        return out
    }

    /// `--settings` JSON registering the PreToolUse hook for every tool.
    static func hookSettings(helper: String, timeoutSeconds: Int) -> String? {
        let obj: [String: Any] = ["hooks": ["PreToolUse": [["matcher": "*", "hooks": [[
            "type": "command", "command": "\(Shell.quote(helper)) hook", "timeout": max(60, timeoutSeconds),
        ]]]]]]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: Bridge requests

    func handleBridge(_ req: [String: Any], reply: @escaping AgentBridge.Reply) {
        guard let token = req["token"] as? String, let tid = tokens[token], let t = task(tid), !t.status.isFinished,
              let profile = profile(t.agentID) else {
            reply(["decision": "ask", "reason": "This session isn't an active ProjectN task.", "text": "Not an active ProjectN task.", "isError": true])
            return
        }
        switch req["op"] as? String {
        case "hook":
            handleHook(req["payload"] as? [String: Any] ?? [:], task: t, profile: profile, reply: reply)
        case "tools":
            reply(["tools": AgentTools.definitions(canDelegate: depthAllowsDelegation(t, profile))])
        case "call":
            let name = req["name"] as? String ?? ""
            let args = req["arguments"] as? [String: Any] ?? [:]
            callTool(name, args, task: t, profile: profile) { text, isError in reply(["text": text, "isError": isError]) }
        default:
            reply(["text": "Unknown operation", "isError": true, "decision": "ask"])
        }
    }

    private func handleHook(_ payload: [String: Any], task t: AgentTask, profile: AgentProfile, reply: @escaping AgentBridge.Reply) {
        guard let store, let project = store.project(t.projectID) else { reply(["decision": "ask"]); return }
        let tool = payload["tool_name"] as? String ?? ""
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let ctx = ApprovalPolicy.Context(permission: profile.permission, projectPath: project.path,
                                         cliTools: profile.cliTools, cwd: payload["cwd"] as? String, autonomy: profile.autonomy,
                                         autoMode: profile.autoMode)
        let tier = ApprovalPolicy.decide(tool: tool, input: input, ctx)
        let summary = Self.describe(tool: tool, input: input)
        switch tier {
        case .allow:
            if !["Read", "Glob", "Grep", "LS", "TodoWrite"].contains(tool) {
                AuditLog.record("tool.allowed", ["task": t.id.uuidString, "agent": t.agentName, "tool": tool, "call": summary])
            }
            rememberApproved(t.id, input: input, summary: summary)
            reply(["decision": "allow", "reason": "Allowed by ProjectN policy (routine work in the project)."])
        case .deny(let why):
            AuditLog.record("tool.denied", ["task": t.id.uuidString, "agent": t.agentName, "tool": tool, "call": summary, "reason": why])
            reply(["decision": "deny", "reason": "ProjectN: \(why)"])
        case .orchestrator(let why), .user(let why):
            var route = AgentRequest.Route.user
            if case .orchestrator = tier, policy.grayApprover == .orchestrator,
               let parent = t.origin.parentTaskID, task(parent)?.status.isFinished == false {
                route = .orchestrator(parent)
            }
            createRequest(kind: .approval, task: t, summary: summary, reason: why, route: route) { r in
                switch r.status {
                case .approved:
                    self.rememberApproved(t.id, input: input, summary: summary)
                    reply(["decision": "allow", "reason": "Approved by \(r.decidedBy ?? "the user")" + (r.answer.map { ": \($0)" } ?? ".")])
                case .expired:
                    reply(["decision": "deny", "reason": "No approval within the time limit, so ProjectN blocked it. Don't retry; report that it needs approval."])
                default:
                    reply(["decision": "deny", "reason": "Denied by \(r.decidedBy ?? "the user")" + (r.answer.map { ": \($0)" } ?? ".") + " Don't try another way to do it."])
                }
            }
        }
    }

    func rememberApproved(_ taskID: UUID, input: [String: Any], summary: String) {
        let text = (input["command"] as? String) ?? (input["file_path"] as? String) ?? summary
        var list = (recentlyApproved[taskID] ?? []).filter { Date().timeIntervalSince($0.at) < 180 }
        list.append((text, Date()))
        recentlyApproved[taskID] = Array(list.suffix(20))
    }

    static func describe(tool: String, input: [String: Any]) -> String {
        if let c = input["command"] as? String { return ApprovalPolicy.clip(c) }
        if let p = (input["file_path"] ?? input["path"]) as? String { return "\(tool) \(p)" }
        if let u = input["url"] as? String { return "\(tool) \(u)" }
        let args = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return ApprovalPolicy.clip("\(tool) \(args)")
    }

    // MARK: Requests

    func createRequest(kind: AgentRequest.Kind, task t: AgentTask, summary: String, reason: String,
                       route: AgentRequest.Route, terminalPrompt: Bool = false, completion: @escaping (AgentRequest) -> Void) {
        var r = AgentRequest(taskID: t.id, agentName: t.agentName, kind: kind, summary: Redactor.redact(summary),
                             reason: Redactor.redact(reason), route: route)
        if terminalPrompt { r.terminalPrompt = true }
        requests.append(r)
        requestWaiters[r.id, default: []].append(completion)
        // A question doesn't stop the agent's turn (it ends it itself); approvals hold the tool call.
        if kind == .approval { setStatus(t.id, .needsApproval) }
        AuditLog.record("request.created", ["request": r.id.uuidString, "task": t.id.uuidString, "agent": t.agentName,
                                            "kind": kind.rawValue, "route": Self.routeLabel(route), "summary": summary, "reason": reason])
        if case .orchestrator(let o) = route {
            if orchestratorWaiters[o]?.isEmpty == false {
                wakeOrchestrator(o)
            } else {
                // The coordinator isn't inside wait_for_tasks: tell it in its session.
                let how = kind == .approval ? "answer_request(request_id: \"\(r.id.uuidString)\", decision: approve | deny | escalate)"
                                            : "answer_request(request_id: \"\(r.id.uuidString)\", decision: answer, text: …)"
                queueForSession(o, "## \(t.agentName) needs you (\(kind == .approval ? "approval" : "question"))\n\n\(r.summary)\n\(r.reason)\n\nDecide with \(how), or escalate it to the user.")
            }
        }
        emitEvent(t, .requestCreated(r))
    }

    /// Ends a pending request without a decision (expired, answered in the terminal, …).
    func closeRequest(_ id: UUID, status: AgentRequest.Status, by: String) {
        guard let i = requests.firstIndex(where: { $0.id == id }), requests[i].isPending else { return }
        var r = requests[i]
        r.status = status
        r.decidedBy = by
        r.decidedAt = Date()
        finishRequest(i, r)
    }

    /// Decide a pending request (from Slack, the Tasks screen, or the orchestrator's `answer_request`).
    @discardableResult
    func resolveRequest(_ id: UUID, approve: Bool? = nil, answer: String? = nil, by: String) -> Bool {
        guard let i = requests.firstIndex(where: { $0.id == id }), requests[i].isPending else { return false }
        var r = requests[i]
        switch r.kind {
        case .approval: r.status = (approve ?? false) ? .approved : .denied
        case .question: r.status = .answered
        }
        r.answer = answer.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        r.decidedBy = by
        r.decidedAt = Date()
        finishRequest(i, r)
        return true
    }

    /// Hand a request routed to the orchestrator over to you.
    func escalateRequest(_ id: UUID, note: String?) {
        guard let i = requests.firstIndex(where: { $0.id == id }), requests[i].isPending else { return }
        requests[i].route = .user
        if let note, !note.isEmpty { requests[i].reason += " — orchestrator: \(note)" }
        AuditLog.record("request.escalated", ["request": id.uuidString])
        if let t = task(requests[i].taskID) { emitEvent(t, .requestCreated(requests[i])) }
    }

    private func finishRequest(_ i: Int, _ r: AgentRequest) {
        requests[i] = r
        AuditLog.record("request.\(r.status.rawValue)", ["request": r.id.uuidString, "agent": r.agentName, "by": r.decidedBy ?? "",
                                                         "summary": r.summary, "answer": r.answer ?? ""])
        for w in requestWaiters.removeValue(forKey: r.id) ?? [] { w(r) }
        if let t = task(r.taskID) {
            if !t.status.isFinished, !requests.contains(where: { $0.taskID == t.id && $0.isPending }) { setStatus(t.id, .running) }
            emitEvent(task(r.taskID) ?? t, .requestResolved(r))
        }
        // Keep the list short: resolved requests older than a day go away.
        requests.removeAll { !$0.isPending && ($0.decidedAt ?? Date()) < Date().addingTimeInterval(-86400) }
    }

    /// Called every tick and when a task ends: pending requests past the limit (or of ended tasks) expire.
    func expireRequests() {
        let limit = Double(policy.requestTimeoutMinutes * 60)
        for r in requests where r.isPending {
            let ended = task(r.taskID)?.status.isFinished ?? true
            guard ended || Date().timeIntervalSince(r.createdAt) > limit,
                  let i = requests.firstIndex(where: { $0.id == r.id }) else { continue }
            var x = r
            x.status = .expired
            x.decidedBy = ended ? "ProjectN (task ended)" : "ProjectN (no answer in \(policy.requestTimeoutMinutes) min)"
            x.decidedAt = Date()
            finishRequest(i, x)
        }
    }

    static func routeLabel(_ r: AgentRequest.Route) -> String {
        if case .orchestrator(let id) = r { return "orchestrator:\(id.uuidString)" }
        return "user"
    }

    func pendingUserRequests() -> [AgentRequest] {
        requests.filter { $0.isPending && $0.route == .user }
    }

    // MARK: Orchestrator wake-ups

    func wakeOrchestrator(_ id: UUID) {
        for w in orchestratorWaiters.removeValue(forKey: id) ?? [] { w() }
    }

    /// A child changed state: its parent's `wait_for_tasks` should look again.
    func taskChanged(_ t: AgentTask) {
        if let p = t.origin.parentTaskID { wakeOrchestrator(p) }
    }

    // MARK: Tools

    func callTool(_ name: String, _ a: [String: Any], task t: AgentTask, profile: AgentProfile,
                  reply: @escaping (String, Bool) -> Void) {
        let delegator = depthAllowsDelegation(t, profile)
        func needDelegate() -> Bool {
            if !delegator { reply("\(profile.name) can't delegate (not enabled in its profile, or the delegation depth limit is reached).", true) }
            return delegator
        }
        AuditLog.record("tool.projectn", ["task": t.id.uuidString, "agent": t.agentName, "tool": name])
        switch name {
        case "ask":
            // Non-blocking: Claude Code moves MCP calls that run over 2 minutes to the background and the agent then
            // ends its turn, so a blocking ask lost every answer that took longer. Now the question is sent, the
            // agent ends its turn, and the answer is typed into the same session when it comes.
            let q = (a["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { reply("Missing `question`.", true); return }
            if profile.autoMode {
                AuditLog.record("question.skipped", ["task": t.id.uuidString, "agent": t.agentName, "question": q])
                reply("Auto mode is on: nobody will answer questions. Decide yourself — use the project's files and notes, "
                      + "pick the most reasonable option, state your assumption in one line in your final answer, and continue now.", false)
                return
            }
            if let open = t.awaitingAnswer, requests.contains(where: { $0.id == open && $0.isPending }) {
                reply("You already have a question waiting for an answer. End your turn now; the answer will arrive as your next message.", false)
                return
            }
            var route = AgentRequest.Route.user
            if let parent = t.origin.parentTaskID, task(parent)?.status.isActive == true { route = .orchestrator(parent) }
            let taskID = t.id
            createRequest(kind: .question, task: t, summary: q, reason: "Question from \(t.agentName)", route: route) { [weak self] r in
                guard let self else { return }
                self.update(taskID) { if $0.awaitingAnswer == r.id { $0.awaitingAnswer = nil } }
                guard let cur = self.task(taskID), !cur.status.isFinished else { return }
                self.queueForSession(taskID, PromptComposer.answerMessage(r))
            }
            if let r = requests.last(where: { $0.taskID == t.id && $0.kind == .question }) {
                update(t.id) { $0.awaitingAnswer = r.id }
            }
            let who: String
            if case .orchestrator = route { who = t.origin.delegatedBy ?? "your coordinator" } else { who = "the user" }
            reply("Question sent to \(who). Now end your turn with one short line (don't repeat the question). "
                  + "The answer will arrive as the next message in this session and you'll continue from there.", false)

        case "save_project_note":
            let note = (a["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard note.count >= 10 else { reply("Missing `note` (one durable fact, with links / IDs).", true); return }
            let added = AgentStore.addProjectNote(t.projectID, note, by: t.agentName)
            AuditLog.record("project.note", ["agent": t.agentName, "project": t.projectName, "note": note])
            reply(added ? "Saved. Every agent working on \(t.projectName) gets it from now on." : "Already in the project notes.", false)

        case "list_agents":
            guard needDelegate() else { return }
            let projectPath = store?.project(t.projectID)?.path ?? ""
            let inherited = Array(Self.claudeCodeMCPServers(projectPath: projectPath).keys)
            let list = availableAgents().filter { $0.id != profile.id }.map { p -> [String: Any] in
                let servers = Set(p.mcpServers + (p.useClaudeMCP && p.runtime == .claudeCode ? inherited : []))
                return ["name": p.name, "role": p.role, "runtime": p.runtime.label, "model": p.model, "access": p.permission.label,
                        "autonomy": p.autoMode ? "Auto mode" : p.autonomy.label,
                        "projects": p.allProjects ? "all" : (store?.state.projects.filter { p.mayAccess($0.id) }.map(\.name).joined(separator: ", ") ?? ""),
                        "mcp_servers_in_this_project": servers.sorted(), "cli_tools": p.cliTools, "can_delegate": p.canDelegate,
                        "busy": tasks.contains { $0.agentID == p.id && $0.status.isActive }]
            }
            reply(Self.json(["agents": list]), false)

        case "delegate_task":
            guard needDelegate() else { return }
            let agentName = (a["agent"] as? String ?? "").folded
            guard let target = availableAgents().first(where: { $0.name.folded == agentName || $0.id.uuidString.lowercased() == agentName }) else {
                reply("No enabled agent named “\(a["agent"] as? String ?? "")”. Call list_agents.", true); return
            }
            guard target.id != profile.id else { reply("Delegate to another agent, not to yourself.", true); return }
            let bare = (a["instruction"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bare.isEmpty else { reply("Missing `instruction`.", true); return }
            let context = (a["context"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard context.count >= 30 else {
                reply("Add `context`: the agent doesn't see your conversation. Give the goal in the user's words, where the inputs live (Notion pages / databases with links, URLs, files), what's known or decided, and constraints.", true)
                return
            }
            let instruction = bare + "\n\n## Context from \(t.agentName)\n" + context + delegationBackground(for: t)
            let rootID = t.rootTaskID ?? t.id
            let created = tasks.filter { $0.rootTaskID == rootID && $0.id != rootID }.count
            guard created < policy.maxTasksPerRequest else {
                reply("Limit reached: at most \(policy.maxTasksPerRequest) delegated tasks per request.", true); return
            }
            var projectID = t.projectID
            if let pname = a["project"] as? String, !pname.isEmpty {
                guard let p = store?.state.projects.first(where: { $0.name.folded == pname.folded }) else {
                    reply("No project named “\(pname)”.", true); return
                }
                projectID = p.id
            }
            let deps = (a["depends_on"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
            var origin = t.origin
            origin.kind = .agent
            origin.parentTaskID = t.id
            origin.delegatedBy = t.agentName
            switch submit(AgentTaskRequest(agentID: target.id, projectID: projectID, instruction: instruction, origin: origin, dependsOn: deps)) {
            case .success(let child):
                reply(Self.json(["task_id": child.id.uuidString, "agent": child.agentName, "project": child.projectName,
                                 "status": child.status.rawValue, "next": "Call wait_for_tasks to follow it."]), false)
            case .failure(let e):
                reply("Couldn't delegate: \(e.description)", true)
            }

        case "request_review":
            guard needDelegate() else { return }
            guard let id = (a["task_id"] as? String).flatMap(UUID.init(uuidString:)), let original = task(id),
                  original.origin.parentTaskID == t.id || original.id == t.id else { reply("Unknown task_id (use one of your tasks).", true); return }
            let reviewerName = (a["reviewer_agent"] as? String ?? "").folded
            guard let reviewer = availableAgents().first(where: { $0.name.folded == reviewerName }), reviewer.id != profile.id else {
                reply("No enabled reviewer agent with that name.", true); return
            }
            let body = (a["instruction"] as? String ?? "Review this work and list concrete problems.")
                + "\n\nWork to review — task “\(original.instruction)” by \(original.agentName):\n\(original.result ?? "(not finished yet; wait for it)")"
            var origin = t.origin
            origin.kind = .agent; origin.parentTaskID = t.id; origin.delegatedBy = t.agentName
            switch submit(AgentTaskRequest(agentID: reviewer.id, projectID: original.projectID, instruction: body, origin: origin,
                                           dependsOn: original.status.isFinished ? [] : [original.id])) {
            case .success(let r): reply(Self.json(["task_id": r.id.uuidString, "status": r.status.rawValue]), false)
            case .failure(let e): reply("Couldn't create the review: \(e.description)", true)
            }

        case "get_task":
            guard let id = (a["task_id"] as? String).flatMap(UUID.init(uuidString:)), let c = task(id),
                  c.origin.parentTaskID == t.id else { reply("Unknown task_id (only your own delegated tasks).", true); return }
            reply(Self.json(snapshot(c)), false)

        case "wait_for_tasks":
            guard needDelegate() else { return }
            let mine = tasks.filter { $0.origin.parentTaskID == t.id }.map(\.id)
            let ids = (a["task_ids"] as? [String])?.compactMap(UUID.init(uuidString:)).filter(mine.contains) ?? mine
            // Under Claude Code's 2-minute limit for a tool call (it moves longer calls to the background).
            let timeout = min(90, max(5, (a["timeout_seconds"] as? Double) ?? 90))
            waitForChildren(orchestrator: t.id, ids: ids, deadline: Date().addingTimeInterval(timeout), reply: reply)

        case "answer_request":
            guard let id = (a["request_id"] as? String).flatMap(UUID.init(uuidString:)),
                  let r = requests.first(where: { $0.id == id }), r.isPending, r.route == .orchestrator(t.id) else {
                reply("Unknown or already handled request_id.", true); return
            }
            let decision = (a["decision"] as? String ?? "").lowercased()
            let text = a["text"] as? String
            switch decision {
            case "approve" where r.kind == .approval: resolveRequest(id, approve: true, answer: text, by: t.agentName)
            case "deny" where r.kind == .approval: resolveRequest(id, approve: false, answer: text, by: t.agentName)
            case "answer" where r.kind == .question:
                guard let text, !text.isEmpty else { reply("`answer` needs `text`.", true); return }
                resolveRequest(id, answer: text, by: t.agentName)
            case "escalate": escalateRequest(id, note: text)
            default: reply("decision must be approve / deny (approvals), answer (questions) or escalate.", true); return
            }
            reply("Done.", false)

        case "create_project":
            guard needDelegate() else { return }
            let rawName = a["name"] as? String ?? ""
            guard policy.allowProjectCreation else { reply(ProjectCreationError.disabled.description, true); return }
            guard let path = plannedProjectPath(rawName) else { reply(ProjectCreationError.invalidName(rawName).description, true); return }
            if let existing = store?.state.projects.first(where: { $0.name.folded == rawName.folded }) {
                reply("A project named \(existing.name) already exists; use it.", false); return
            }
            guard !FileManager.default.fileExists(atPath: path) else { reply(ProjectCreationError.exists(path).description, true); return }
            let about = a["description"] as? String
            // Cautious agents ask first; others create it (it's an empty folder + README, nothing is lost).
            if profile.autonomy != .cautious || profile.autoMode {
                switch createProject(name: rawName, description: about, by: t.agentName) {
                case .success(let p):
                    reply(Self.json(["project": p.name, "path": p.path, "next": "Delegate work with delegate_task(project: \"\(p.name)\")."]), false)
                case .failure(let e):
                    reply(e.description, true)
                }
                return
            }
            createRequest(kind: .approval, task: t, summary: "Create project “\(rawName)” at \(path)",
                          reason: "Creates a new project folder", route: .user) { [weak self] r in
                guard let self else { return }
                guard r.status == .approved else {
                    reply("Not created: \(r.status == .expired ? "no answer in time" : "denied by \(r.decidedBy ?? "the user")")\(r.answer.map { " (\($0))" } ?? "").", false)
                    return
                }
                switch self.createProject(name: rawName, description: about, by: t.agentName) {
                case .success(let p):
                    reply(Self.json(["project": p.name, "path": p.path, "next": "Delegate work with delegate_task(project: \"\(p.name)\")."]), false)
                case .failure(let e):
                    reply(e.description, true)
                }
            }

        case "cancel_task":
            guard let id = (a["task_id"] as? String).flatMap(UUID.init(uuidString:)), let c = task(id),
                  c.origin.parentTaskID == t.id else { reply("Unknown task_id (only your own delegated tasks).", true); return }
            cancel(id)
            reply("Cancelled.", false)

        default:
            reply("Unknown tool \(name).", true)
        }
    }

    private func waitForChildren(orchestrator: UUID, ids: [UUID], deadline: Date, reply: @escaping (String, Bool) -> Void) {
        let pending = requests.filter { $0.isPending && $0.route == .orchestrator(orchestrator) }
        let children = ids.compactMap(task)
        let allDone = children.allSatisfy { $0.status.isFinished }
        let orchestratorGone = task(orchestrator)?.status.isFinished ?? true
        if !pending.isEmpty || allDone || Date() >= deadline || orchestratorGone {
            var out: [String: Any] = ["tasks": children.map(snapshot)]
            if !pending.isEmpty {
                out["requests_for_you"] = pending.map {
                    ["request_id": $0.id.uuidString, "from_agent": $0.agentName, "kind": $0.kind.rawValue,
                     "summary": $0.summary, "reason": $0.reason,
                     "how_to_answer": $0.kind == .approval ? "answer_request(decision: approve|deny|escalate)" : "answer_request(decision: answer, text: …)"]
                }
            }
            out["all_finished"] = allDone
            if children.isEmpty { out["note"] = "You have no delegated tasks." }
            else if !allDone && pending.isEmpty {
                out["note"] = "Still running. Call wait_for_tasks again, or end your turn telling the user what is in progress: each result will be sent to you as a new message."
            }
            reply(Self.json(out), false)
            return
        }
        var fired = false
        let resume = { [weak self] in
            guard !fired else { return }
            fired = true
            self?.waitForChildren(orchestrator: orchestrator, ids: ids, deadline: deadline, reply: reply)
        }
        orchestratorWaiters[orchestrator, default: []].append(resume)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, deadline.timeIntervalSinceNow)) { resume() }
    }

    /// What a delegated task gets besides the coordinator's own context: the user's words that led to it.
    func delegationBackground(for t: AgentTask) -> String {
        var asks: [String] = recentConversation(for: t, limit: 3).map(\.instruction)
        if t.origin.automatic != true { asks.append(t.instruction) }
        asks += (t.followUps ?? []).filter { $0.hasPrefix("## New message") || $0.hasPrefix("## Answer to your question") }
        let lines = asks.suffix(5).map { "- " + PromptComposer.oneLine($0.replacingOccurrences(of: "## New message from the user (sent while you were working)", with: ""), 500) }
        guard !lines.isEmpty else { return "" }
        return "\n\n## What the user asked \(t.agentName) (verbatim, most recent last)\n" + lines.joined(separator: "\n")
    }

    func snapshot(_ c: AgentTask) -> [String: Any] {
        var d: [String: Any] = ["task_id": c.id.uuidString, "agent": c.agentName, "project": c.projectName,
                                "status": c.status.rawValue, "instruction": ApprovalPolicy.clip(c.instruction)]
        if c.status == .queued { d["waiting_for"] = queueReason(c) }
        if let r = c.result { d["result"] = r.count > 6000 ? String(r.prefix(6000)) + "\n[…truncated]" : r }
        if let e = c.error { d["error"] = e }
        if !c.notes.isEmpty { d["notes"] = c.notes }
        return d
    }

    static func json(_ obj: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// MCP tool definitions served to agents (depends on whether the caller may delegate).
enum AgentTools {
    static func definitions(canDelegate: Bool) -> [[String: Any]] {
        func tool(_ name: String, _ desc: String, _ props: [String: Any], _ required: [String]) -> [String: Any] {
            ["name": name, "description": desc,
             "inputSchema": ["type": "object", "properties": props, "required": required, "additionalProperties": false]]
        }
        let str: (String) -> [String: Any] = { ["type": "string", "description": $0] }
        var tools = [tool("save_project_note", "Save one durable fact about this project for every agent that works on it: where tasks / docs live (Notion page or database links and IDs), site URLs, MCP server names, conventions, decisions. No secrets.",
                          ["note": str("The fact, self-contained, with links / IDs.")], ["note"]),
                     tool("ask", "Ask whoever gave you this task (the coordinating agent or the user) a question you can't resolve yourself. Returns immediately: then end your turn with one short line. The answer arrives as your next message in this session.",
                          ["question": str("Self-contained. One line of context, then the question(s) as a numbered list (1., 2.…); put choices under each as `- a) …`, `- b) …`.")], ["question"])]
        guard canDelegate else { return tools }
        tools += [
            tool("list_agents", "List the agents you can delegate to: role, runtime, access, projects, MCP servers and CLI tools.", [:], []),
            tool("delegate_task", "Start a task for another agent (a new session). Returns its task_id; follow it with wait_for_tasks.",
                 ["agent": str("Agent name from list_agents."),
                  "instruction": str("What to do, including what done means."),
                  "context": str("Everything the agent needs that it can't see (it doesn't see your conversation): the goal in the user's words, where the inputs live — e.g. Notion task database / pages with links and IDs, site URLs, files —, what's known or decided, constraints, who to ask."),
                  "project": str("Project name; default: your project."),
                  "depends_on": ["type": "array", "items": ["type": "string"], "description": "task_ids that must complete first."]],
                 ["agent", "instruction", "context"]),
            tool("wait_for_tasks", "Wait (up to 90 s per call) until your delegated tasks finish, or until one of your agents needs an approval or an answer from you. Returns their status/results and requests_for_you. For long work you may instead end your turn: results are sent to you as new messages.",
                 ["task_ids": ["type": "array", "items": ["type": "string"], "description": "Default: all your delegated tasks."],
                  "timeout_seconds": ["type": "number", "description": "Max wait (5–90, default 90)."]], []),
            tool("get_task", "Status and result of one of your delegated tasks.", ["task_id": str("The task_id.")], ["task_id"]),
            tool("answer_request", "Decide an approval or answer a question from one of your agents. Use escalate to pass it to the user.",
                 ["request_id": str("From wait_for_tasks."),
                  "decision": ["type": "string", "enum": ["approve", "deny", "answer", "escalate"]],
                  "text": str("Answer text (for questions) or a short reason.")], ["request_id", "decision"]),
            tool("request_review", "Have another agent review a task's result (runs after it finishes).",
                 ["task_id": str("Task to review."), "reviewer_agent": str("Reviewer agent name."), "instruction": str("What to check.")],
                 ["task_id", "reviewer_agent"]),
            tool("cancel_task", "Cancel one of your delegated tasks.", ["task_id": str("The task_id.")], ["task_id"]),
            tool("create_project", "Create a new, empty project (folder + README) in the user's projects folder. Use it only when the work needs a project that doesn't exist yet.",
                 ["name": str("Project name; becomes the folder name (letters, numbers, spaces, - _ .)."),
                  "description": str("One or two sentences for the README.")], ["name"]),
        ]
        return tools
    }
}
