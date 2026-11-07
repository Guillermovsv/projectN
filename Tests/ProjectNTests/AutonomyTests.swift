import AppKit
import Foundation
import Testing
@testable import ProjectN

/// Approvals, questions and delegation through the real `pn-agent` helper, called exactly as Claude Code calls
/// it (hook JSON on stdin / MCP JSON-RPC on stdin, environment carries the bridge port + task token).
/// Agent sessions are the fake `claude` (SLOW keeps them running).
@Suite(.serialized)
@MainActor
struct AutonomyTests {
    typealias Env = AgentHarnessTests.Env

    private func makeEnv() async throws -> Env {
        try await AgentHarnessTests.makeSharedEnv()
    }

    private func waitUntil(_ seconds: Double = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(condition())
    }

    /// Runs the helper like the CLI would; returns its stdout.
    private func helper(_ mode: String, stdin: String, task: UUID, env: Env, token: String? = nil) async -> String {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("pn-out-\(UUID()).txt")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: TestHome.helper)
        p.arguments = [mode]
        var e = ProcessInfo.processInfo.environment
        e["PROJECTN_AGENT_PORT"] = String(env.harness.bridge.port ?? 0)
        e["PROJECTN_AGENT_TOKEN"] = token ?? env.harness.tokenOfTask[task] ?? ""
        p.environment = e
        let inPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = try? FileHandle(forWritingTo: out)
        return await withCheckedContinuation { cont in
            p.terminationHandler = { _ in
                cont.resume(returning: (try? String(contentsOf: out, encoding: .utf8)) ?? "")
            }
            try? p.run()
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
    }

    private func hook(_ tool: String, _ input: [String: Any], task: UUID, env: Env, token: String? = nil) async -> (decision: String, reason: String) {
        let payload: [String: Any] = ["tool_name": tool, "tool_input": input, "hook_event_name": "PreToolUse",
                                      "cwd": env.project.path, "session_id": "x"]
        let json = String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        let out = await helper("hook", stdin: json, task: task, env: env, token: token)
        let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])?["hookSpecificOutput"] as? [String: Any]
        return (obj?["permissionDecision"] as? String ?? "?", obj?["permissionDecisionReason"] as? String ?? out)
    }

    /// MCP session: initialize, then the given calls; returns each call's text result.
    private func mcp(_ calls: [(String, [String: Any])], task: UUID, env: Env) async -> (tools: [String], results: [String]) {
        var lines = [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
                     #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                     #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#]
        for (i, c) in calls.enumerated() {
            let msg: [String: Any] = ["jsonrpc": "2.0", "id": i + 2, "method": "tools/call", "params": ["name": c.0, "arguments": c.1]]
            lines.append(String(data: try! JSONSerialization.data(withJSONObject: msg), encoding: .utf8)!)
        }
        let out = await helper("mcp", stdin: lines.joined(separator: "\n") + "\n", task: task, env: env)
        var tools: [String] = []
        var results: [String] = []
        for line in out.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let r = o["result"] as? [String: Any] else { continue }
            if let t = r["tools"] as? [[String: Any]] { tools = t.compactMap { $0["name"] as? String } }
            if let c = (r["content"] as? [[String: Any]])?.first?["text"] as? String { results.append(c) }
        }
        return (tools, results)
    }

    private func startPM(_ env: Env, ts: String) async throws -> AgentTask {
        env.slack.handle(event: ["type": "app_mention", "user": "U1", "channel": "C1", "ts": ts,
                                 "text": "<@UBOT> Project Manager, coordina el trabajo en Demo SLOW"], eventID: "Ev\(ts)")
        let t = try #require(env.harness.tasks.last)
        try await waitUntil { env.harness.task(t.id)?.status == .running || env.harness.task(t.id)?.status == .starting }
        return t
    }

    private func addDeveloper(_ env: Env) -> AgentProfile {
        var dev = AgentProfile(name: "Developer", role: "Developer", model: "claude-opus-5-5", instructions: "Code.")
        dev.permission = .editProject
        dev.allProjects = true
        dev.concurrencyLimit = 3
        env.harness.saveProfile(dev)
        return dev
    }

    // MARK: Hook

    @Test func hookAllowsRoutineDeniesReadOnlyEditsAndSendsDeletionsToTheUser() async throws {
        let env = try await makeEnv()
        defer { env.store.terminateAll() }
        let pm = try await startPM(env, ts: "1.1")

        // The session was started with ProjectN's hook and only ProjectN's MCP config.
        let argsFile = TestHome.url.appendingPathComponent("fake/args-\(env.harness.task(pm.id)?.sessionID ?? "")-new")
        // The fake writes its arguments one by one: wait for the first message (the last argument).
        try await waitUntil { ((try? String(contentsOf: argsFile, encoding: .utf8)) ?? "").contains("## Request") }
        let args = (try? String(contentsOf: argsFile, encoding: .utf8)) ?? ""
        #expect(args.contains("--strict-mcp-config") && args.contains("pn-agent hook") && args.contains("--settings"))

        #expect(await hook("Bash", ["command": "ls -la"], task: pm.id, env: env).decision == "allow")
        let edit = await hook("Edit", ["file_path": env.project.path + "/README.md"], task: pm.id, env: env)
        #expect(edit.decision == "deny" && edit.reason.contains("read-only"))
        // Unknown token: fall back to the CLI's own prompt.
        #expect(await hook("Bash", ["command": "ls"], task: pm.id, env: env, token: "bogus").decision == "ask")

        // Deleting: waits for the user. An unauthorised click does nothing; an authorised Deny answers it.
        async let pending = hook("Bash", ["command": "rm README.md"], task: pm.id, env: env)
        try await waitUntil { env.harness.pendingUserRequests().count == 1 }
        let r = try #require(env.harness.pendingUserRequests().first)
        #expect(r.summary == "rm README.md" && r.route == .user)
        #expect(env.harness.task(pm.id)?.status == .needsApproval)
        try await waitUntil { env.posts.texts(thread: "1.1").contains { $0.hasPrefix("🔐 *Project Manager* necesita tu aprobación") } }
        env.slack.handleInteraction(["type": "block_actions", "user": ["id": "U999"],
                                     "actions": [["action_id": "pn_approve", "value": r.id.uuidString]]])
        #expect(env.harness.pendingUserRequests().count == 1)
        env.slack.handleInteraction(["type": "block_actions", "user": ["id": "U1"], "channel": ["id": "C1"], "message": ["ts": "m1"],
                                     "actions": [["action_id": "pn_deny", "value": r.id.uuidString]]])
        let decided = await pending
        #expect(decided.decision == "deny" && decided.reason.contains("Denied by <@U1>"))
        #expect(FileManager.default.fileExists(atPath: env.project.path + "/README.md"))

        // Approving by replying in the thread.
        async let second = hook("Bash", ["command": "git push"], task: pm.id, env: env)
        try await waitUntil { env.harness.pendingUserRequests().count == 1 }
        env.slack.handle(event: ["type": "message", "user": "U1", "channel": "C1", "ts": "1.9", "thread_ts": "1.1", "text": "aprobar"], eventID: "Ev1.9")
        #expect(await second.decision == "allow")
        #expect(env.harness.task(pm.id)?.status != .needsApproval)
    }

    // MARK: Delegation

    @Test func projectManagerDelegatesAndDecidesGrayAreaButNeverDeletions() async throws {
        let env = try await makeEnv()
        defer { env.store.terminateAll() }
        _ = addDeveloper(env)
        let pm = try await startPM(env, ts: "2.1")

        // Delegator tools for the PM.
        let (tools, listed) = await mcp([("list_agents", [:])], task: pm.id, env: env)
        #expect(Set(["ask", "list_agents", "delegate_task", "wait_for_tasks", "answer_request"]).isSubset(of: Set(tools)))
        #expect(listed.first?.contains("\"Developer\"") == true)

        // Delegate a task that finishes, and wait for it.
        let (_, r1) = await mcp([("delegate_task", ["agent": "Developer", "instruction": "Revisa el login"]),
                                 ("wait_for_tasks", ["timeout_seconds": 30])], task: pm.id, env: env)
        let child = try #require(env.harness.tasks.first { $0.origin.parentTaskID == pm.id })
        #expect(child.depth == 1 && child.rootTaskID == pm.id && child.origin.delegatedBy == "Project Manager")
        #expect(child.origin.slackThreadTS == "2.1")
        #expect(r1.count == 2 && r1[1].contains("\"all_finished\" : true") && r1[1].contains("RESULT-new"))
        try await waitUntil { env.posts.texts(thread: "2.1").contains { $0.contains("↳ *Project Manager* delegó a *Developer*") } }

        // The developer's session has only `ask` (it can't delegate).
        let (devTools, _) = await mcp([], task: child.id, env: env)
        #expect(devTools == ["ask"] || devTools.isEmpty)   // empty once the child finished (token revoked)

        // A running child: gray area goes to the PM, deletion goes to the user.
        let (_, r2) = await mcp([("delegate_task", ["agent": "Developer", "instruction": "SLOW implementa el login"])], task: pm.id, env: env)
        #expect(r2.first?.contains("task_id") == true)
        let worker = try #require(env.harness.tasks.last { $0.origin.parentTaskID == pm.id })
        try await waitUntil { env.harness.tokenOfTask[worker.id] != nil && env.harness.task(worker.id)?.status.isActive == true }
        #expect(await hook("Bash", ["command": "npm test"], task: worker.id, env: env).decision == "allow")

        async let gray = hook("Bash", ["command": "curl https://example.com/data.json"], task: worker.id, env: env)
        async let del = hook("Bash", ["command": "rm -rf node_modules"], task: worker.id, env: env)
        try await waitUntil { env.harness.requests.filter(\.isPending).count == 2 }
        let toPM = try #require(env.harness.requests.first { $0.isPending && $0.route == .orchestrator(pm.id) })
        #expect(toPM.summary.contains("curl"))
        #expect(env.harness.requests.contains { $0.isPending && $0.route == .user && $0.summary == "rm -rf node_modules" })

        // The PM sees it in wait_for_tasks and approves it.
        let (_, r3) = await mcp([("wait_for_tasks", ["timeout_seconds": 10]),
                                 ("answer_request", ["request_id": toPM.id.uuidString, "decision": "approve", "text": "solo lectura"])],
                                task: pm.id, env: env)
        #expect(r3.first?.contains("requests_for_you") == true && r3.first?.contains(toPM.id.uuidString) == true)
        let g = await gray
        #expect(g.decision == "allow" && g.reason.contains("Approved by Project Manager"))
        // The PM can't answer the deletion: it isn't routed to it.
        let userReq = try #require(env.harness.pendingUserRequests().first)
        let (_, r4) = await mcp([("answer_request", ["request_id": userReq.id.uuidString, "decision": "approve"])], task: pm.id, env: env)
        #expect(r4.first?.contains("Unknown or already handled") == true)
        env.harness.resolveRequest(userReq.id, approve: false, by: "you (ProjectN)")
        #expect(await del.decision == "deny")

        // Questions go up to the PM too.
        async let question = mcp([("ask", ["question": "¿Uso OAuth o email?"])], task: worker.id, env: env)
        try await waitUntil { env.harness.requests.contains { $0.isPending && $0.kind == .question } }
        let q = try #require(env.harness.requests.first { $0.isPending && $0.kind == .question })
        #expect(q.route == .orchestrator(pm.id))
        _ = await mcp([("answer_request", ["request_id": q.id.uuidString, "decision": "answer", "text": "Email"])], task: pm.id, env: env)
        #expect(await question.results.first?.contains("Answer from Project Manager:\nEmail") == true)

        // Escalation hands a gray request to you.
        async let escalated = hook("WebFetch", ["url": "https://example.com"], task: worker.id, env: env)
        try await waitUntil { env.harness.requests.contains { $0.isPending && $0.route == .orchestrator(pm.id) } }
        let e = try #require(env.harness.requests.first { $0.isPending && $0.route == .orchestrator(pm.id) })
        _ = await mcp([("answer_request", ["request_id": e.id.uuidString, "decision": "escalate", "text": "no estoy seguro"])], task: pm.id, env: env)
        #expect(env.harness.pendingUserRequests().contains { $0.id == e.id })
        env.slack.handleInteraction(["type": "block_actions", "user": ["id": "U1"],
                                     "actions": [["action_id": "pn_approve", "value": e.id.uuidString]]])
        #expect(await escalated.decision == "allow")

        // Ending the PM cancels nothing by itself, but its pending requests can't hang: they expire.
        async let orphan = hook("Bash", ["command": "curl https://example.com"], task: worker.id, env: env)
        try await waitUntil { env.harness.requests.contains { $0.isPending && $0.route == .orchestrator(pm.id) } }
        env.harness.cancel(pm.id)
        #expect(await orphan.decision == "deny")
        env.harness.cancel(worker.id)
    }

    @Test func policyLimitsAndGrayAreaToUser() async throws {
        let env = try await makeEnv()
        defer { env.store.terminateAll() }
        _ = addDeveloper(env)
        var policy = env.harness.policy
        policy.grayApprover = .user
        policy.maxTasksPerRequest = 1
        env.harness.savePolicy(policy)
        let pm = try await startPM(env, ts: "3.1")
        let (_, r) = await mcp([("delegate_task", ["agent": "Developer", "instruction": "SLOW uno"]),
                                ("delegate_task", ["agent": "Developer", "instruction": "dos"]),
                                ("delegate_task", ["agent": "Project Manager", "instruction": "yo"])], task: pm.id, env: env)
        #expect(r.count == 3 && r[1].contains("Limit reached") && r[2].contains("not to yourself"))
        let worker = try #require(env.harness.tasks.last { $0.origin.parentTaskID == pm.id })
        try await waitUntil { env.harness.tokenOfTask[worker.id] != nil && env.harness.task(worker.id)?.status.isActive == true }
        async let gray = hook("WebFetch", ["url": "https://example.com"], task: worker.id, env: env)
        try await waitUntil { !env.harness.pendingUserRequests().isEmpty }   // to you, not the PM
        env.harness.resolveRequest(env.harness.pendingUserRequests()[0].id, approve: true, by: "you")
        #expect(await gray.decision == "allow")
        // Non-delegators can't use delegation tools.
        let (_, denied) = await mcp([("delegate_task", ["agent": "Project Manager", "instruction": "x"])], task: worker.id, env: env)
        #expect(denied.first?.contains("can't delegate") == true)
        env.harness.cancel(worker.id)
        env.harness.cancel(pm.id)
    }

    @Test func agentsGetOnlyTheirOwnMCPServersAndKeys() async throws {
        let env = try await makeEnv()
        defer { env.store.terminateAll() }
        MCPConfig.upsert(MCPServer(name: "seo", command: "seo-mcp"))
        MCPConfig.upsert(MCPServer(name: "ads", command: "ads-mcp"))
        Secrets.set("PN_TEST_KEY_A", value: "a")
        defer { Secrets.delete("PN_TEST_KEY_A"); MCPConfig.remove("seo"); MCPConfig.remove("ads") }
        env.store.settings.apiKeyNames = ["PN_TEST_KEY_A", "PN_TEST_KEY_B"]
        var seo = AgentProfile(name: "SEO", role: "SEO", model: "claude-opus-5-5", instructions: "SEO.")
        seo.allProjects = true
        seo.mcpServers = ["seo"]
        seo.apiKeys = ["PN_TEST_KEY_A"]
        env.harness.saveProfile(seo)
        let t = try env.harness.submit(.init(agentID: seo.id, projectID: env.project.id, instruction: "SLOW audita", origin: .local)).get()
        try await waitUntil { env.harness.task(t.id)?.paneID != nil }
        let config = try String(contentsOf: AgentStore.runDir.appendingPathComponent("\(t.id.uuidString).mcp.json"), encoding: .utf8)
        #expect(config.contains("\"seo\"") && config.contains("\"projectn\"") && !config.contains("\"ads\""))
        let attrs = try FileManager.default.attributesOfItem(atPath: AgentStore.runDir.appendingPathComponent("\(t.id.uuidString).mcp.json").path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let pane = try #require(env.store.agentWorkspace?.spaces.flatMap(\.panes).first { $0.agentTaskID == t.id })
        let ctx = env.harness.launchContext(for: pane)
        #expect(ctx.apiKeyNames == ["PN_TEST_KEY_A"])
        #expect(ctx.env["PROJECTN_AGENT_TOKEN"]?.count == 64 && ctx.env["PROJECTN_AGENT_PORT"] != nil)
        env.harness.cancel(t.id)
        // After the task ends, a restarted pane gets no token.
        #expect(env.harness.launchContext(for: pane).env["PROJECTN_AGENT_TOKEN"] == nil)
    }

    /// Claude Code sometimes asks again after the hook allowed a command; ProjectN answers that prompt only
    /// for the exact command it approved.
    @Test func redundantCLIPromptIsConfirmedOnlyForApprovedCommands() async throws {
        let env = try await makeEnv()
        defer { env.store.terminateAll() }
        let ws = env.store.ensureAgentWorkspace()
        let pane = try #require(env.store.addPane(tool: .terminal, projectID: env.project.id, in: ws.id, space: ws.spaces[0].id))
        try await waitUntil { env.store.runtimes[pane.id] != nil }
        let rt = try #require(env.store.runtimes[pane.id])
        let cmd = "find Sources -name '*.swift' | wc -l; echo \"$(date)\""
        let screen = ["╭────────────────────────────────────────────────────────────╮",
                      "│ Bash command                                               │",
                      "│   \(cmd)  │",
                      "│ Do you want to proceed?                                    │",
                      "│ ❯ 1. Yes                                                   │",
                      "│   2. Yes, and don't ask again for find commands            │",
                      "│   3. No, and tell Claude what to do differently (esc)      │",
                      "╰────────────────────────────────────────────────────────────╯"]
        rt.view.feed(text: "\u{1b}[2J\u{1b}[20;1H" + screen.joined(separator: "\r\n"))
        // Not approved → never answered.
        let until = Date().addingTimeInterval(1)
        while Date() < until {
            #expect(rt.confirmApprovedPrompt(["rm -rf build"]) == nil)
            try await Task.sleep(for: .milliseconds(50))
        }
        // Approved → "Yes", once.
        var answer: String?
        let deadline = Date().addingTimeInterval(5)
        while answer == nil, Date() < deadline {
            answer = rt.confirmApprovedPrompt([cmd])
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(answer == "Yes")
        try await Task.sleep(for: .milliseconds(200))
        #expect(rt.confirmApprovedPrompt([cmd]) == nil)
    }

    @Test func projectsAreCreatedOnYourRequestOrWithYourApproval() async throws {
        let env = try await makeEnv()
        defer { env.store.terminateAll() }
        let base = TestHome.projects.appendingPathComponent("new-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var policy = env.harness.policy
        policy.newProjectsFolder = base.path
        env.harness.savePolicy(policy)

        // 1. Your Slack request creates it right away and runs the task inside it.
        env.slack.handle(event: ["type": "app_mention", "user": "U1", "channel": "C1", "ts": "8.1",
                                 "text": "<@UBOT> Project Manager, crea el proyecto Landing García y prepara un plan"], eventID: "Ev8.1")
        let created = base.appendingPathComponent("Landing García")
        #expect(FileManager.default.fileExists(atPath: created.appendingPathComponent("README.md").path))
        let p = try #require(env.store.state.projects.first { $0.name == "Landing García" })
        try await waitUntil { env.harness.tasks.first { $0.projectID == p.id }?.status == .completed }
        try await waitUntil { env.posts.texts(thread: "8.1").contains { $0.hasPrefix("📁 Proyecto *Landing García* creado") } }
        // Asking again doesn't recreate or overwrite it: it's an existing project now.
        let readme = try String(contentsOf: created.appendingPathComponent("README.md"), encoding: .utf8)
        env.slack.handle(event: ["type": "app_mention", "user": "U1", "channel": "C1", "ts": "8.2",
                                 "text": "<@UBOT> Project Manager, crea el proyecto Landing García y revisa"], eventID: "Ev8.2")
        #expect(try String(contentsOf: created.appendingPathComponent("README.md"), encoding: .utf8) == readme)
        #expect(env.store.state.projects.filter { $0.name == "Landing García" }.count == 1)
        // Bad names are refused, nothing is created.
        env.slack.handle(event: ["type": "app_mention", "user": "U1", "channel": "C1", "ts": "8.3",
                                 "text": "<@UBOT> Project Manager, crea el proyecto \"../../etc\" ya"], eventID: "Ev8.3")
        try await waitUntil { env.posts.texts(thread: "8.3").contains { $0.contains("No pude crear el proyecto") } }

        // 2. An agent's create_project asks you; denied → nothing; approved → created.
        let pm = try await startPM(env, ts: "8.4")
        async let denied = mcp([("create_project", ["name": "Idea del PM"])], task: pm.id, env: env)
        try await waitUntil { env.harness.pendingUserRequests().contains { $0.summary.contains("Idea del PM") } }
        try await waitUntil { env.posts.texts(thread: "8.4").contains { $0.contains("Create project “Idea del PM”") } }
        env.slack.handleInteraction(["type": "block_actions", "user": ["id": "U1"],
                                     "actions": [["action_id": "pn_deny", "value": env.harness.pendingUserRequests()[0].id.uuidString]]])
        #expect(await denied.results.first?.contains("Not created") == true)
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("Idea del PM").path))

        async let approved = mcp([("create_project", ["name": "Sitio Florina", "description": "Web nueva."])], task: pm.id, env: env)
        try await waitUntil { env.harness.pendingUserRequests().contains { $0.summary.contains("Sitio Florina") } }
        env.harness.resolveRequest(env.harness.pendingUserRequests()[0].id, approve: true, by: "you")
        #expect(await approved.results.first?.contains("\"project\" : \"Sitio Florina\"") == true)
        #expect(env.store.state.projects.contains { $0.name == "Sitio Florina" })
        #expect(try String(contentsOf: base.appendingPathComponent("Sitio Florina/README.md"), encoding: .utf8).contains("Web nueva."))
        env.harness.cancel(pm.id)
    }

    @Test func scheduledTasksRunOnceWhenDueAndReportToSlack() async throws {
        let env = try await makeEnv()
        defer { env.store.terminateAll() }
        var pm = try #require(env.harness.profiles.first)
        var s = AgentSchedule()
        s.name = "Reporte diario"
        s.projectID = env.project.id
        s.instruction = "Resume el estado del proyecto"
        s.frequency = .hourly
        s.everyHours = 1
        s.minute = 0
        s.createdAt = Date().addingTimeInterval(-2 * 3600)   // due at least once already
        s.slackTarget = "C1"
        var skipped = AgentSchedule()
        skipped.name = "Sin recuperar"
        skipped.projectID = env.project.id
        skipped.instruction = "x"
        skipped.frequency = .daily
        skipped.hour = Calendar.current.component(.hour, from: Date().addingTimeInterval(-3 * 3600))
        skipped.createdAt = Date().addingTimeInterval(-26 * 3600)
        skipped.runIfMissed = false
        pm.schedules = [s, skipped]
        env.harness.saveProfile(pm)

        env.harness.runDueSchedules()
        let runs = env.harness.tasks.filter { $0.origin.kind == .schedule }
        #expect(runs.count == 1)
        let t = try #require(runs.first)
        #expect(t.origin.scheduleName == "Reporte diario" && t.instruction == "Resume el estado del proyecto")
        #expect(env.harness.profile(pm.id)?.schedules[0].lastRun != nil)
        #expect(env.harness.profile(pm.id)?.schedules[1].lastRun != nil)   // missed run skipped, not queued
        // Not due again right away.
        env.harness.runDueSchedules()
        #expect(env.harness.tasks.filter { $0.origin.kind == .schedule }.count == 1)
        // An editor opened earlier can't roll back lastRun (that would re-run it).
        env.harness.saveProfile(pm)
        env.harness.runDueSchedules()
        #expect(env.harness.tasks.filter { $0.origin.kind == .schedule }.count == 1)

        // Slack: opens its own message, then the result in that thread.
        try await waitUntil { env.harness.task(t.id)?.status == .completed }
        try await waitUntil { env.posts.items.contains { $0.channel == "C1" && $0.thread == nil && $0.text.hasPrefix("🗓 *Project Manager* — tarea programada *Reporte diario*") } }
        let thread = try #require(env.harness.task(t.id)?.origin.slackThreadTS)
        try await waitUntil { env.posts.texts(thread: thread).contains { $0.contains("RESULT-new") } }

        // Run Now from the editor.
        #expect(env.harness.runSchedule(env.harness.profile(pm.id)!.schedules[0], of: env.harness.profile(pm.id)!) == nil)
        #expect(env.harness.tasks.filter { $0.origin.kind == .schedule }.count == 2)
    }
}
