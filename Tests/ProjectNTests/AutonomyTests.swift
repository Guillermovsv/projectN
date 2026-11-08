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

    private func waitUntil(_ seconds: Double = 15, line: Int = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(condition(), "waited at line \(line)")
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

    private func addDeveloper(_ env: Env, autonomy: AgentAutonomy = .cautious) -> AgentProfile {
        var dev = AgentProfile(name: "Developer", role: "Developer", model: "claude-opus-5-5", instructions: "Code.")
        dev.autonomy = autonomy
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
        let (_, r1) = await mcp([("delegate_task", ["agent": "Developer", "instruction": "Revisa el login", "context": "Las tareas están en Notion › Project Hub › Tasks (T1–T12), proyecto Demo."]),
                                 ("wait_for_tasks", ["timeout_seconds": 30])], task: pm.id, env: env)
        let child = try #require(env.harness.tasks.first { $0.origin.parentTaskID == pm.id })
        #expect(child.depth == 1 && child.rootTaskID == pm.id && child.origin.delegatedBy == "Project Manager")
        #expect(child.origin.slackThreadTS == "2.1")
        #expect(r1.count == 2 && r1[1].contains("\"all_finished\":true") && r1[1].contains("RESULT-new"))
        try await waitUntil { env.posts.texts(thread: "2.1").contains { $0.contains("↳ *Project Manager* delegó a *Developer*") } }

        // The developer's session has only `ask` (it can't delegate).
        let (devTools, _) = await mcp([], task: child.id, env: env)
        #expect(devTools == ["ask"] || devTools.isEmpty)   // empty once the child finished (token revoked)

        // A running child: gray area goes to the PM, deletion goes to the user.
        let (_, r2) = await mcp([("delegate_task", ["agent": "Developer", "instruction": "SLOW implementa el login", "context": "Las tareas están en Notion › Project Hub › Tasks (T1–T12), proyecto Demo."])], task: pm.id, env: env)
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

        // Questions go up to the PM too. `ask` doesn't block (Claude Code would move a long call to the background):
        // it returns at once, and the answer is typed into the asking session.
        let (_, asked) = await mcp([("ask", ["question": "¿Uso OAuth o email?"])], task: worker.id, env: env)
        #expect(asked.first?.contains("Question sent to Project Manager") == true)
        let q = try #require(env.harness.requests.first { $0.isPending && $0.kind == .question })
        #expect(q.route == .orchestrator(pm.id))
        #expect(env.harness.task(worker.id)?.awaitingAnswer == q.id)
        // The PM, not inside wait_for_tasks, is told in its own session.
        #expect(env.harness.task(pm.id).map { (($0.inbox ?? []) + ($0.followUps ?? [])).contains { $0.contains("Developer needs you") } } == true)
        _ = await mcp([("answer_request", ["request_id": q.id.uuidString, "decision": "answer", "text": "Email"])], task: pm.id, env: env)
        try await waitUntil {
            let w = env.harness.task(worker.id)
            return ((w?.inbox ?? []) + (w?.followUps ?? [])).contains { $0.contains("Answer to your question (from Project Manager)") && $0.contains("Email") }
        }
        #expect(env.harness.task(worker.id)?.awaitingAnswer == nil)

        // Escalation hands a gray request to you.
        async let escalated = hook("WebFetch", ["url": "https://example.com"], task: worker.id, env: env)
        try await waitUntil { env.harness.requests.contains { $0.isPending && $0.route == .orchestrator(pm.id) } }
        let e = try #require(env.harness.requests.first { $0.isPending && $0.route == .orchestrator(pm.id) })
        _ = await mcp([("answer_request", ["request_id": e.id.uuidString, "decision": "escalate", "text": "no estoy seguro"])], task: pm.id, env: env)
        #expect(env.harness.pendingUserRequests().contains { $0.id == e.id })
        env.slack.handleInteraction(["type": "block_actions", "user": ["id": "U1"],
                                     "actions": [["action_id": "pn_approve", "value": e.id.uuidString]]])
        #expect(await escalated.decision == "allow")

        // Ending the PM cancels nothing by itself, but its pending requests can't hang: they go to you.
        async let orphan = hook("Bash", ["command": "curl https://example.com"], task: worker.id, env: env)
        try await waitUntil { env.harness.requests.contains { $0.isPending && $0.route == .orchestrator(pm.id) } }
        env.harness.cancel(pm.id)
        let handed = try #require(env.harness.pendingUserRequests().first { $0.summary.contains("curl") })
        env.harness.resolveRequest(handed.id, approve: false, by: "you")
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
        let (_, r) = await mcp([("delegate_task", ["agent": "Developer", "instruction": "SLOW uno", "context": "Las tareas están en Notion › Project Hub › Tasks (T1–T12), proyecto Demo."]),
                                ("delegate_task", ["agent": "Developer", "instruction": "dos", "context": "Las tareas están en Notion › Project Hub › Tasks (T1–T12), proyecto Demo."]),
                                ("delegate_task", ["agent": "Project Manager", "instruction": "yo", "context": "Las tareas están en Notion › Project Hub › Tasks (T1–T12), proyecto Demo."])], task: pm.id, env: env)
        #expect(r.count == 3 && r[1].contains("Limit reached") && r[2].contains("not to yourself"))
        let worker = try #require(env.harness.tasks.last { $0.origin.parentTaskID == pm.id })
        try await waitUntil { env.harness.tokenOfTask[worker.id] != nil && env.harness.task(worker.id)?.status.isActive == true }
        async let gray = hook("WebFetch", ["url": "https://example.com"], task: worker.id, env: env)
        try await waitUntil { !env.harness.pendingUserRequests().isEmpty }   // to you, not the PM
        env.harness.resolveRequest(env.harness.pendingUserRequests()[0].id, approve: true, by: "you")
        #expect(await gray.decision == "allow")
        // Non-delegators can't use delegation tools.
        let (_, denied) = await mcp([("delegate_task", ["agent": "Project Manager", "instruction": "x", "context": "Las tareas están en Notion › Project Hub › Tasks (T1–T12), proyecto Demo."])], task: worker.id, env: env)
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
        if env.harness.tasks.first(where: { $0.projectID == p.id })?.status != .completed {
            Issue.record("\(env.harness.tasks.map { "\($0.instruction) | \($0.projectName) | \($0.status) | \($0.error ?? "") | inbox \($0.inbox ?? [])" }) runtimes=\(env.store.runtimes.count)")
        }
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

        // 2. An agent's create_project: created directly (balanced autonomy)…
        let pm = try await startPM(env, ts: "8.4")
        let (_, direct) = await mcp([("create_project", ["name": "Directo PM"])], task: pm.id, env: env)
        #expect(direct.first?.contains("\"project\":\"Directo PM\"") == true)
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("Directo PM/README.md").path))
        // …or, for a cautious agent, it asks you; denied → nothing; approved → created.
        if var cautious = env.harness.profile(pm.agentID) { cautious.autonomy = .cautious; env.harness.saveProfile(cautious) }
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
        #expect(await approved.results.first?.contains("\"project\":\"Sitio Florina\"") == true)
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

    // MARK: No threads (default) and agents as their own DMs

    @Test func withoutThreadsRepliesGoStraightIntoTheConversation() async throws {
        let env = try await makeEnv()
        defer { env.store.terminateAll() }
        env.slack.settings.replyInThreads = false
        var signers: [String?] = []
        env.slack.signedSender = { _, who, _ in signers.append(who) }

        // Clarification answered by just writing in the channel (no thread, no mention needed).
        env.slack.handle(event: ["type": "app_mention", "user": "U1", "channel": "C1", "ts": "9.1",
                                 "text": "<@UBOT> Project Manager, revisa el proyecto Fantasma"], eventID: "Ev9.1")
        try await waitUntil { env.posts.items.contains { $0.text.contains("No encuentro el proyecto") } }
        #expect(env.posts.items.allSatisfy { $0.thread == nil })
        #expect(env.posts.items.last?.text.contains("Responde aquí") == true)
        env.slack.handle(event: ["type": "message", "user": "U1", "channel": "C1", "ts": "9.2", "text": "Tienda"], eventID: "Ev9.2")
        try await waitUntil { env.harness.tasks.first?.projectID == env.other.id && env.harness.tasks.first?.status == .completed }
        try await waitUntil { env.posts.items.contains { $0.text.contains("RESULT-new") } }
        #expect(env.posts.items.allSatisfy { $0.thread == nil })
        // Task messages are signed by the agent; routing messages ("which project?") by the app itself.
        #expect(signers.contains("Project Manager"))

        // A question from a running agent is answered by a plain message in the same channel; the answer is
        // typed into the agent's session.
        if var p = env.harness.profiles.first { p.sessionPolicy = .perProject; env.harness.saveProfile(p) }
        let pm = try await startPM(env, ts: "9.3")
        let sent = { (id: UUID) in (env.harness.task(id)?.inbox ?? []) + (env.harness.task(id)?.followUps ?? []) }
        let (_, q) = await mcp([("ask", ["question": "¿Qué color?"])], task: pm.id, env: env)
        #expect(q.first?.contains("Question sent to the user") == true)
        try await waitUntil { env.posts.items.contains { $0.text.contains("pregunta") && $0.text.contains("Responde aquí") } }
        env.slack.handle(event: ["type": "message", "user": "U1", "channel": "C1", "ts": "9.4", "text": "Azul"], eventID: "Ev9.4")
        try await waitUntil { sent(pm.id).contains { $0.contains("Answer to your question") && $0.contains("Azul") } }
        // …while a message that starts with an agent's name is a new instruction, not an answer: it goes into the
        // same running session (no new task, no new terminal) and the question stays open.
        _ = await mcp([("ask", ["question": "¿Y el tamaño?"])], task: pm.id, env: env)
        try await waitUntil { env.harness.requests.contains { $0.isPending && $0.kind == .question } }
        let before = env.harness.tasks.count
        env.slack.handle(event: ["type": "message", "user": "U1", "channel": "C1", "ts": "9.5", "channel_type": "channel",
                                 "text": "Project Manager, revisa Demo"], eventID: "Ev9.5")
        #expect(env.harness.tasks.count == before)
        #expect(sent(pm.id).contains { $0.contains("New message from the user") && $0.contains("revisa Demo") })
        try await waitUntil { env.posts.items.contains { $0.text.hasPrefix("📨 *Project Manager* ya está trabajando") } }
        #expect(env.harness.requests.contains { $0.isPending && $0.kind == .question })
        // Approval by plain "aprobar".
        async let gate = hook("Bash", ["command": "git push"], task: pm.id, env: env)
        try await waitUntil { env.harness.pendingUserRequests().contains { $0.kind == .approval } }
        env.slack.handle(event: ["type": "message", "user": "U1", "channel": "C1", "ts": "9.6", "text": "aprobar"], eventID: "Ev9.6")
        #expect(await gate.decision == "allow")
        env.slack.handle(event: ["type": "message", "user": "U1", "channel": "C1", "ts": "9.7", "text": "Grande"], eventID: "Ev9.7")
        try await waitUntil { sent(pm.id).contains { $0.contains("Grande") } }
        env.harness.cancel(pm.id)
    }

    @Test func eachAgentGetsItsOwnChannelSignedWithItsName() async throws {
        let env = try await makeEnv()
        defer { env.store.terminateAll() }
        env.slack.settings.replyInThreads = false
        var calls: [(String, [String: Any])] = []
        var taken: Set<String> = ["developer"]   // a channel with that name already exists in the workspace
        env.slack.apiCaller = { method, params in
            calls.append((method, params))
            switch method {
            case "conversations.create":
                let name = params["name"] as! String
                if taken.contains(name) { throw SlackAPI.APIError(message: "conversations.create: name_taken") }
                taken.insert(name)
                return ["ok": true, "channel": ["id": "G-" + name, "name": name]]
            case "conversations.rename":
                return ["ok": true, "channel": ["id": params["channel"]!, "name": params["name"]!]]
            default:
                return ["ok": true]
            }
        }
        var said: [(channel: String, who: String?, text: String)] = []
        env.slack.signedSender = { ch, who, text in said.append((ch, who, text)) }
        var dev = AgentProfile(name: "Developer", role: "Developer", model: "claude-opus-5-5", instructions: "Code.")
        dev.permission = .editProject; dev.allProjects = true
        env.harness.saveProfile(dev)

        env.slack.syncAgentChannels()
        try await waitUntil { env.harness.profiles.allSatisfy { $0.slackChannelID != nil } }
        let pm = try #require(env.harness.profiles.first { $0.name == "Project Manager" })
        dev = try #require(env.harness.profile(dev.id))
        #expect(pm.slackChannelName == "project-manager" && pm.slackChannelID == "G-project-manager")
        #expect(dev.slackChannelName == "developer-agente")   // "developer" was taken
        #expect(calls.contains { $0.0 == "conversations.create" && ($0.1["is_private"] as? Bool) == true })
        #expect(calls.contains { $0.0 == "conversations.invite" && ($0.1["users"] as? String) == "U1" })
        try await waitUntil { said.contains { $0.channel == "G-project-manager" && $0.who == "Project Manager" && $0.text.contains("Soy *Project Manager*") } }
        #expect(pm.slackEmoji == ":card_index_dividers:" && dev.slackEmoji == ":computer:")

        // Writing in the Developer's channel: no name, no mention — it's for the Developer, signed by it.
        said.removeAll()
        env.slack.handle(event: ["type": "message", "channel_type": "group", "user": "U1", "channel": "G-developer-agente", "ts": "12.1",
                                 "text": "arregla el login en Demo"], eventID: "Ev12.1")
        let t = try #require(env.harness.tasks.last)
        #expect(t.agentID == dev.id && t.projectID == env.project.id && t.instruction == "arregla el login en Demo")
        try await waitUntil { env.harness.task(t.id)?.status == .completed }
        try await waitUntil { said.contains { $0.text.contains("RESULT-new") } }
        #expect(said.allSatisfy { $0.channel == "G-developer-agente" && $0.who == "Developer" })
        // Not in the authorized-channels list, yet accepted: it's the agent's own channel. Strangers still aren't.
        let before = env.harness.tasks.count
        env.slack.handle(event: ["type": "message", "channel_type": "group", "user": "U999", "channel": "G-developer-agente", "ts": "12.2",
                                 "text": "borra todo"], eventID: "Ev12.2")
        #expect(env.harness.tasks.count == before)

        // Renaming the agent renames its channel and its signature.
        dev.name = "Dev Web"
        env.harness.saveProfile(dev)
        env.slack.syncAgentChannels()
        try await waitUntil { env.harness.profile(dev.id)?.slackChannelName == "dev-web" }
        #expect(calls.contains { $0.0 == "conversations.rename" && ($0.1["name"] as? String) == "dev-web" })
        #expect(env.harness.profile(dev.id)?.slackChannelID == "G-developer-agente")   // same channel, new name

        // A schedule can report to the agent's channel.
        var sch = AgentSchedule(); sch.name = "Diario"; sch.projectID = env.project.id; sch.instruction = "estado"; sch.slackTarget = "agent"
        dev = env.harness.profile(dev.id)!; dev.schedules = [sch]; env.harness.saveProfile(dev)
        env.harness.runSchedule(sch, of: dev)
        let run = try #require(env.harness.tasks.last { $0.origin.kind == .schedule })
        #expect(run.origin.slackChannel == "G-developer-agente")
        try await waitUntil { said.contains { $0.text.hasPrefix("🗓 *Dev Web*") && $0.who == "Dev Web" } }
    }

    // MARK: Per-project sessions (default)

    @Test func claudeMCPServersCanBeTurnedOffOneByOne() async throws {
        let env = try await makeEnv()
        defer { env.store.terminateAll() }
        // A project with its own Claude Code servers (.mcp.json), and a home with yours (~/.claude.json).
        let mcp = ["mcpServers": ["elementor": ["command": "npx", "args": ["elementor-mcp"]], "notion": ["url": "https://mcp.notion.com", "type": "http"]]]
        try JSONSerialization.data(withJSONObject: mcp).write(to: URL(fileURLWithPath: env.project.path).appendingPathComponent(".mcp.json"))
        let home = TestHome.url.appendingPathComponent("claude-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["mcpServers": ["zernio": ["command": "zernio"], "projectn": ["command": "x"]]])
            .write(to: home.appendingPathComponent(".claude.json"))

        let catalog = AgentHarness.claudeMCPCatalog(projects: [(env.project.name, env.project.path)], home: home.path)
        #expect(catalog.map(\.name) == [ClaudeMCPEntry.chromeName, "elementor", "notion", "zernio"])
        #expect(catalog.first { $0.name == "zernio" }?.scopeLabel == "All projects")
        #expect(catalog.first { $0.name == "notion" }?.scopeLabel == env.project.name)
        #expect(catalog.first { $0.name == "elementor" }?.summary == "npx elementor-mcp")

        // Turned off: not in the session's MCP config; Claude in Chrome off → --no-chrome.
        var pm = try #require(env.harness.profiles.first)
        pm.claudeMCPDisabled = ["elementor", ClaudeMCPEntry.chromeName]
        env.harness.saveProfile(pm)
        let t = AgentTask(agentID: pm.id, agentName: pm.name, projectID: env.project.id, projectName: env.project.name,
                          instruction: "x", origin: .local, runtime: .claudeCode, model: pm.model, effort: nil, permission: pm.permission)
        let file = try #require(env.harness.writeMCPConfig(task: t, profile: pm, helper: nil))
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let names = Set((written["mcpServers"] as? [String: Any] ?? [:]).keys)
        #expect(names.contains("notion") && !names.contains("elementor"))
        #expect(pm.usesClaudeMCP("notion") && !pm.usesClaudeMCP(ClaudeMCPEntry.chromeName))
        pm.useClaudeMCP = false
        #expect(!pm.usesClaudeMCP("notion"))

        let started = try await startPM(env, ts: "31.1")
        let argsFile = TestHome.url.appendingPathComponent("fake/args-\(env.harness.task(started.id)?.sessionID ?? "")-new")
        try await waitUntil { ((try? String(contentsOf: argsFile, encoding: .utf8)) ?? "").contains("## Request") }
        #expect(((try? String(contentsOf: argsFile, encoding: .utf8)) ?? "").contains("--no-chrome"))
    }

    @Test func aSessionPastTheContextLimitStartsFreshWithARecap() async throws {
        let env = try await makeEnv()
        defer { env.store.terminateAll() }
        env.slack.settings.replyInThreads = false
        var pm = try #require(env.harness.profiles.first)
        pm.sessionPolicy = .perProject
        env.harness.saveProfile(pm)
        func say(_ text: String, _ ts: String) {
            env.slack.handle(event: ["type": "message", "channel_type": "im", "user": "U1", "channel": "D1", "ts": ts,
                                     "text": text], eventID: "Ev\(ts)")
        }
        say("Project Manager, revisa Demo y dime qué falta", "21.1")
        var first = try #require(env.harness.tasks.last)
        try await waitUntil { env.harness.task(first.id)?.status == .completed }
        first = try #require(env.harness.task(first.id))
        #expect(first.usage?.contextTokens == 10)   // read from the transcript

        // The conversation grew past the limit: the next message starts a new session, with a recap.
        var big = first
        big.usage?.contextTokens = env.harness.policy.maxSessionContextK * 1000 + 1
        env.harness.replaceTask(big)
        say("Project Manager, ahora prioriza esas tareas", "21.2")
        let second = try #require(env.harness.tasks.last)
        #expect(second.continuedSession != true && second.resumedFromTaskID == nil)
        try await waitUntil { env.harness.task(second.id)?.status == .completed }
        let sid = try #require(env.harness.task(second.id)?.sessionID)
        #expect(sid != first.sessionID)
        let args = (try? String(contentsOf: TestHome.url.appendingPathComponent("fake/args-\(sid)-new"), encoding: .utf8)) ?? ""
        #expect(args.contains("## Earlier in this conversation") && args.contains("revisa Demo y dime qué falta"))
    }

    @Test func messagesAboutTheSameProjectContinueOneSession() async throws {
        let env = try await makeEnv()
        defer { env.store.terminateAll() }
        env.slack.settings.replyInThreads = false
        var pm = try #require(env.harness.profiles.first)
        pm.sessionPolicy = .perProject
        env.harness.saveProfile(pm)
        func say(_ text: String, _ ts: String) {
            env.slack.handle(event: ["type": "message", "channel_type": "im", "user": "U1", "channel": "D1", "ts": ts,
                                     "text": text], eventID: "Ev\(ts)")
        }

        say("Project Manager, revisa Demo y dime qué falta", "11.1")
        let first = try #require(env.harness.tasks.last)
        try await waitUntil { env.harness.task(first.id)?.status == .completed }
        let argsText = (try? String(contentsOf: TestHome.url.appendingPathComponent("fake/args-\(first.sessionID ?? "")-new"), encoding: .utf8)) ?? ""
        let firstPrompt = argsText.components(separatedBy: "\n<<ARG>>\n").filter { !$0.isEmpty }.last ?? ""
        #expect(firstPrompt.contains("<untrusted_file path=\"README.md\""))   // context read once

        // Next message, no project named: same project, same terminal, same session; no new process.
        say("Project Manager, ahora prioriza esas tareas", "11.2")
        let second = try #require(env.harness.tasks.last)
        #expect(second.projectID == env.project.id && second.continuedSession == true)
        #expect(second.paneID == first.paneID && second.sessionID == first.sessionID)
        try await waitUntil { env.harness.task(second.id)?.status == .completed }
        #expect(env.harness.task(second.id)?.result == "RESULT-followup")
        let followups = (try? String(contentsOf: TestHome.url.appendingPathComponent("fake/followups-\(first.sessionID ?? "")"), encoding: .utf8)) ?? ""
        #expect(followups.contains("ahora prioriza esas tareas") && !followups.contains("untrusted_file"))   // no context re-sent
        let launches = (try? FileManager.default.contentsOfDirectory(atPath: TestHome.url.appendingPathComponent("fake").path))?
            .filter { $0.hasPrefix("args-\(first.sessionID ?? "")") } ?? []
        #expect(launches == ["args-\(first.sessionID ?? "")-new"])   // launched exactly once
        try await waitUntil { env.posts.items.contains { $0.text.contains("sigue en *Demo* (misma sesión)") } }

        // The approval hook follows the session to the new task.
        let token = try #require(env.harness.tokenOfTask[second.id])
        #expect(env.harness.tokens[token] == second.id)

        // A busy session: the next message goes straight into it (no new task, no new terminal).
        say("Project Manager, revisa Demo otra vez", "11.3")
        let third = try #require(env.harness.tasks.last)
        say("Project Manager, y resume en una línea", "11.4")
        #expect(env.harness.tasks.last?.id == third.id)
        try await waitUntil { env.posts.items.contains { $0.text.hasPrefix("📨 *Project Manager* ya está trabajando") } }
        try await waitUntil { env.harness.task(third.id)?.status == .completed }
        #expect(env.harness.task(third.id)?.followUps?.contains { $0.contains("y resume en una línea") } == true)
        #expect(env.harness.task(third.id)?.paneID == first.paneID)
        let typed = (try? String(contentsOf: TestHome.url.appendingPathComponent("fake/followups-\(first.sessionID ?? "")"), encoding: .utf8)) ?? ""
        #expect(typed.contains("y resume en una línea"))   // it finished only after answering the typed message

        // "sesión nueva" and another project start a new session.
        say("Project Manager, sesión nueva: revisa Demo desde cero", "11.5")
        let fresh = try #require(env.harness.tasks.last)
        #expect(fresh.continuedSession != true && fresh.paneID != first.paneID)
        try await waitUntil { env.harness.task(fresh.id)?.status == .completed }
        say("Project Manager, revisa Tienda", "11.6")
        let other = try #require(env.harness.tasks.last)
        #expect(other.projectID == env.other.id && other.continuedSession != true)
        try await waitUntil { env.harness.task(other.id)?.status == .completed }

        // The terminal was closed (e.g. ProjectN restarted): the same conversation is resumed (--resume).
        env.store.killRuntime(other.paneID!)
        try await waitUntil { env.store.runtimes[other.paneID!] == nil }
        say("Project Manager, sigue con Tienda", "11.7")
        let resumed = try #require(env.harness.tasks.last)
        #expect(resumed.projectID == env.other.id && resumed.sessionID == other.sessionID)
        try await waitUntil { env.harness.task(resumed.id)?.status == .completed }
        #expect(env.harness.task(resumed.id)?.result == "RESULT-resume: 1. Arreglar login")

        // ProjectN restarted and restored the terminal: the process runs but holds no live token (no ProjectN
        // tools, no approval hook). The next message must not be typed into it: it resumes in a connected process.
        let restoredProcess = try #require(env.store.runtimes[resumed.paneID!])
        #expect(restoredProcess.isRunning)
        if let stale = env.harness.tokenOfTask.removeValue(forKey: resumed.id) { env.harness.tokens.removeValue(forKey: stale) }
        say("Project Manager, delega la revisión de Tienda", "11.8")
        let reconnected = try #require(env.harness.tasks.last)
        #expect(reconnected.id != resumed.id && reconnected.sessionID == other.sessionID)   // same conversation…
        try await waitUntil { env.harness.task(reconnected.id)?.paneID.flatMap { env.store.runtimes[$0] }.map { $0 !== restoredProcess } == true }   // …in a new process
        let fresh2 = try #require(env.harness.tokenOfTask[reconnected.id])
        #expect(env.harness.tokens[fresh2] == reconnected.id)
        try await waitUntil { env.harness.task(reconnected.id)?.status == .completed }
    }

    @Test func delegatedResultsComeBackToTheCoordinatorsSession() async throws {
        let env = try await makeEnv()
        defer { env.store.terminateAll() }
        _ = addDeveloper(env, autonomy: .balanced)
        let pm = try await startPM(env, ts: "14.1")
        // The PM delegates and doesn't wait: the result is typed into its session when the child finishes.
        let (_, r) = await mcp([("delegate_task", ["agent": "Developer", "instruction": "Revisa el login", "context": "Las tareas están en Notion › Project Hub › Tasks (T1–T12), proyecto Demo."])], task: pm.id, env: env)
        #expect(r.first?.contains("task_id") == true)
        let child = try #require(env.harness.tasks.first { $0.origin.parentTaskID == pm.id })
        try await waitUntil { env.harness.task(child.id)?.status == .completed }
        try await waitUntil {
            let p = env.harness.task(pm.id)
            return ((p?.inbox ?? []) + (p?.followUps ?? [])).contains { $0.contains("Result of a task you delegated") && $0.contains("RESULT-new") }
        }
        // Balanced autonomy: gray-area work doesn't wait for anyone.
        let worker = try env.harness.submit(.init(agentID: child.agentID, projectID: env.project.id, instruction: "SLOW x",
                                                  origin: TaskOrigin(kind: .agent, parentTaskID: pm.id, delegatedBy: "Project Manager"))).get()
        try await waitUntil { env.harness.tokenOfTask[worker.id] != nil && env.harness.task(worker.id)?.status.isActive == true }
        #expect(await hook("Bash", ["command": "curl https://example.com/data.json"], task: worker.id, env: env).decision == "allow")
        env.harness.cancel(worker.id)
        env.harness.cancel(pm.id)
    }

    @Test func coordinatorSeesAgentsBlockedOnYouAndYouGetReminded() async throws {
        let env = try await makeEnv()
        defer { env.store.terminateAll() }
        _ = addDeveloper(env)
        let pm = try await startPM(env, ts: "977.1")
        _ = await mcp([("delegate_task", ["agent": "Developer", "instruction": "SLOW redacta las specs", "context": "Las tareas están en Notion › Project Hub › Tasks (T13–T16), proyecto Demo."])], task: pm.id, env: env)
        let worker = try #require(env.harness.tasks.last { $0.origin.parentTaskID == pm.id })
        try await waitUntil { env.harness.tokenOfTask[worker.id] != nil && env.harness.task(worker.id)?.status.isActive == true }
        async let del = hook("Bash", ["command": "rm -rf build"], task: worker.id, env: env)
        try await waitUntil { env.harness.pendingUserRequests().contains { $0.taskID == worker.id } }

        // A later turn of the PM (a new task) still sees what its agent is stopped on, and can reach it.
        env.harness.cancel(pm.id)
        let pm2 = try await startPM(env, ts: "977.2")
        #expect(pm2.id != pm.id)
        let (_, r) = await mcp([("list_agents", [:]), ("get_task", ["task_id": worker.id.uuidString]),
                                ("message_task", ["task_id": worker.id.uuidString, "message": "¿cómo vas?"])], task: pm2.id, env: env)
        #expect(r.count == 3)
        #expect(r[0].contains("blocked_on_user") && r[0].contains("rm -rf build") && r[0].contains(worker.id.uuidString))
        #expect(r[1].contains("blocked_on_user") && !r[1].contains("Unknown task_id"))
        #expect(r[2].contains("\"queued\":true") && r[2].contains("blocked_on_user"))
        #expect(env.harness.task(worker.id)?.inbox?.contains { $0.contains("¿cómo vas?") } == true)

        // Nobody answered: you're reminded once after 10 min, again after 20 more, not every tick.
        let req = try #require(env.harness.pendingUserRequests().first { $0.taskID == worker.id })
        env.harness.remindPendingRequests(now: req.createdAt.addingTimeInterval(5 * 60))
        env.harness.remindPendingRequests(now: req.createdAt.addingTimeInterval(11 * 60))
        env.harness.remindPendingRequests(now: req.createdAt.addingTimeInterval(12 * 60))
        try await waitUntil { env.posts.texts(thread: "977.1").contains { $0.contains("sigue esperando tu aprobación") } }
        #expect(env.posts.texts(thread: "977.1").filter { $0.contains("sigue esperando") }.count == 1)
        env.harness.resolveRequest(req.id, approve: false, by: "you")
        #expect(await del.decision == "deny")
        env.harness.cancel(worker.id)
        env.harness.cancel(pm2.id)
    }

    @Test func idleSessionsStopAndResumeOnTheNextMessage() async throws {
        let env = try await makeEnv()
        defer { env.store.terminateAll() }
        env.slack.settings.replyInThreads = false
        if var p = env.harness.profiles.first { p.sessionPolicy = .perProject; env.harness.saveProfile(p) }
        func say(_ text: String, _ ts: String) {
            env.slack.handle(event: ["type": "message", "channel_type": "im", "user": "U1", "channel": "D2", "ts": ts, "text": text], eventID: "Ev\(ts)")
        }
        say("Project Manager, revisa Demo", "15.1")
        let first = try #require(env.harness.tasks.last)
        try await waitUntil { env.harness.task(first.id)?.status == .completed }
        #expect(env.store.runtimes[first.paneID!]?.isRunning == true)   // kept open for the next message
        env.harness.closeIdleSessions(now: Date().addingTimeInterval(3 * 3600))
        #expect(env.store.runtimes[first.paneID!] == nil)                // stopped after the idle time
        say("Project Manager, sigue", "15.2")
        let next = try #require(env.harness.tasks.last)
        #expect(next.id != first.id && next.sessionID == first.sessionID && next.paneID == first.paneID)   // same conversation, same pane
        try await waitUntil { env.harness.task(next.id)?.status == .completed }
        #expect(env.harness.task(next.id)?.result == "RESULT-resume: 1. Arreglar login")
    }

    /// The coordinator (may edit, asks first) waiting on its delegate must not block it: that deadlocked until the
    /// coordinator gave up ("Calling ProjectN" for minutes). Delegations carry context; notes are shared.
    @Test func delegatesStartRightAwayWithContextAndProjectNotes() async throws {
        let env = try await makeEnv()
        defer { env.store.terminateAll() }
        var dev = addDeveloper(env, autonomy: .balanced)
        dev.sessionPolicy = .perProject
        env.harness.saveProfile(dev)
        if var p = env.harness.profiles.first(where: { $0.name == "Project Manager" }) {
            p.permission = .askBeforeChanges; p.sessionPolicy = .perProject; env.harness.saveProfile(p)
        }
        let pm = try await startPM(env, ts: "16.1")

        // Notes saved by one agent reach every later session in the project.
        let (_, saved) = await mcp([("save_project_note", ["note": "Las tareas de Demo están en Notion › Project Hub › Tasks: https://app.notion.com/p/abc123"])], task: pm.id, env: env)
        #expect(saved.first?.contains("Saved") == true)
        #expect(AgentStore.projectNotes(env.project.id).contains("https://app.notion.com/p/abc123"))

        // No context → refused with a reason.
        let (_, bare) = await mcp([("delegate_task", ["agent": "Developer", "instruction": "Revisa las tareas"])], task: pm.id, env: env)
        #expect(bare.first?.contains("Add `context`") == true)

        // With context: starts right away (not queued behind its own coordinator) and gets the user's words.
        let (_, r) = await mcp([("delegate_task", ["agent": "Developer", "instruction": "SLOW revisa las tareas T1–T12",
                                                  "context": "Las tareas están en Notion › Project Hub › Tasks (T1–T12), enlazadas al proyecto."])],
                               task: pm.id, env: env)
        #expect(r.first?.contains("task_id") == true)
        let child = try #require(env.harness.tasks.first { $0.origin.parentTaskID == pm.id })
        #expect(env.harness.task(child.id)?.status != .queued)
        #expect(child.instruction.contains("## Context from Project Manager") && child.instruction.contains("Notion › Project Hub › Tasks"))
        #expect(child.instruction.contains("What the user asked Project Manager") && child.instruction.contains("coordina el trabajo en Demo"))
        let argsFile = TestHome.url.appendingPathComponent("fake/args-\(env.harness.task(child.id)?.sessionID ?? "")-new")
        try await waitUntil { ((try? String(contentsOf: argsFile, encoding: .utf8)) ?? "").contains("## Project notes") }

        // A second delegation to the same agent waits for the first and continues its session (one terminal).
        let (_, r2) = await mcp([("delegate_task", ["agent": "Developer", "instruction": "y luego resume",
                                                   "context": "Sigue con las mismas tareas de Notion de la tarea anterior."])], task: pm.id, env: env)
        #expect(r2.first?.contains("task_id") == true)
        let second = try #require(env.harness.tasks.last { $0.origin.parentTaskID == pm.id })
        #expect(second.resumedFromTaskID == child.id && second.status == .queued)
        let (_, w) = await mcp([("wait_for_tasks", ["task_ids": [second.id.uuidString], "timeout_seconds": 5])], task: pm.id, env: env)
        #expect(w.first?.contains("still busy with an earlier message") == true)
        env.harness.cancel(second.id)
        env.harness.cancel(child.id)
        env.harness.cancel(pm.id)
    }
}
