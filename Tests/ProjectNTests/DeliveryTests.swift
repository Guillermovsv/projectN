import AppKit
import Foundation
import Testing
@testable import ProjectN

/// Deliveries: the rules for criteria and findings, the automatic cycle's next step, grouping tasks into
/// requests, and the facts read from allowed commands (worktrees, background processes).
struct DeliveryRuleTests {
    private func record(cycle: Bool = false, tester: String? = "QA") -> DeliveryRecord {
        var r = DeliveryRecord(id: UUID())
        if cycle {
            r.cycle = DeliveryCycle(fixer: "Developer", tester: tester, verifier: "Verificador", projectID: UUID(),
                                    coordinatorTaskID: UUID(), maxRounds: 2)
        }
        return r
    }

    @Test func criteriaAreNumberedAndLockOnceChecked() throws {
        var r = record()
        try r.setCriteria([(nil, "Exporta solo filas filtradas", "npm test"), ("c9", "Fechas dd/mm/aaaa", "leer el CSV")], by: "Developer")
        #expect(r.criteria.map(\.id) == ["C1", "C9"])
        // Still pending: the author may refine them.
        try r.setCriteria([(nil, "Exporta solo filas filtradas", "npm test")], by: "Developer")
        #expect(r.criteria.count == 1)
        #expect(throws: DeliveryError.self) { try r.updateCriterion("C1", status: .met, evidence: "  ", by: "Verificador") }
        try r.updateCriterion("c1", status: .met, evidence: "npm test: 48/48", by: "Verificador")
        #expect(r.criteriaMet == 1)
        #expect(throws: DeliveryError.criteriaLocked) { try r.setCriteria([(nil, "Otra cosa", "x")], by: "Developer") }
        #expect(throws: DeliveryError.self) { try r.setCriteria([(nil, "", "x")], by: "Developer") }
    }

    @Test func theFixerCannotMarkCriteria() throws {
        var r = record(cycle: true)
        try r.setCriteria([(nil, "A", "b")], by: "Developer")
        #expect(throws: DeliveryError.self) { try r.updateCriterion("C1", status: .met, evidence: "yo digo", by: "developer") }
        try r.updateCriterion("C1", status: .unmet, evidence: "falla", by: "Verificador")
        #expect(r.criteria[0].status == .unmet)
    }

    @Test func findingsMoveThroughFixedToClosedBySomeoneElse() throws {
        var r = record(cycle: true)
        let p1 = try r.openFinding(id: nil, text: "No descarga en móvil", anchor: "page: #exportar · 390×844", severity: "P1", by: "QA")
        let b20 = try r.openFinding(id: "b20", text: "Pide TPDA", anchor: "criterion C1", severity: nil, by: "Verificador")
        let p2 = try r.openFinding(id: nil, text: "Negativos sin color", anchor: "td.monto", severity: nil, by: "QA")
        #expect([p1, b20, p2] == ["P1", "B20", "P2"])
        #expect(throws: DeliveryError.self) { try r.openFinding(id: "B20", text: "x", anchor: "y", severity: nil, by: "QA") }
        #expect(throws: DeliveryError.self) { try r.openFinding(id: nil, text: "x", anchor: " ", severity: nil, by: "QA") }

        // Fixed needs a commit (or a note); closing needs someone other than the fixer, with evidence.
        #expect(throws: DeliveryError.self) { try r.updateFinding("P1", status: .fixed, commit: nil, note: nil, by: "Developer") }
        try r.updateFinding("P1", status: .fixed, commit: "a3f91c", note: nil, by: "Developer")
        #expect(throws: DeliveryError.self) { try r.updateFinding("P1", status: .closed, commit: nil, note: "ok", by: "Developer") }
        #expect(throws: DeliveryError.self) { try r.updateFinding("P1", status: .closed, commit: nil, note: nil, by: "QA") }
        try r.updateFinding("P1", status: .reopened, commit: nil, note: "sigue sin descargar", by: "QA")
        #expect(r.findings[0].status == .reopened)
        #expect(throws: DeliveryError.self) { try r.updateFinding("P1", status: .closed, commit: nil, note: "x", by: "QA") }
        try r.updateFinding("P1", status: .fixed, commit: "b2", note: nil, by: "Developer")
        try r.updateFinding("P1", status: .closed, commit: nil, note: "descarga en 390×844", by: "QA")
        #expect(r.findings[0].history.map(\.status) == [.open, .fixed, .reopened, .fixed, .closed])
        #expect(r.openFindings.map(\.id) == ["B20", "P2"])
        // Whoever opened a finding may withdraw it before anyone fixed it.
        try r.updateFinding("P2", status: .closed, commit: nil, note: "no era un error", by: "QA")
        #expect(r.openFindings.map(\.id) == ["B20"])
    }

    @Test func cycleGoesFixRetestVerifyThenDone() throws {
        var r = record(cycle: true)
        try r.setCriteria([(nil, "A", "check a")], by: "Developer")
        #expect(DeliveryRecord.nextStep(r) == .verify)

        r.cycle?.verifiedSinceChange = true
        try r.updateCriterion("C1", status: .unmet, evidence: "falla", by: "Verificador")
        try r.openFinding(id: nil, text: "A falla", anchor: "criterion C1", severity: nil, by: "Verificador")
        #expect(DeliveryRecord.nextStep(r) == .fix(["P1"]))

        r.cycle?.round = 1
        try r.updateFinding("P1", status: .fixed, commit: "c1", note: nil, by: "Developer")
        #expect(DeliveryRecord.nextStep(r) == .retest(["P1"]))
        try r.updateFinding("P1", status: .closed, commit: nil, note: "ok", by: "QA")
        #expect(DeliveryRecord.nextStep(r) == .verify)

        r.cycle?.verifiedSinceChange = true
        // Verified, but the verifier didn't update C1 nor open findings: stop instead of looping.
        if case .stop = DeliveryRecord.nextStep(r) {} else { Issue.record("expected stop") }
        r.criteria[0].status = .met
        #expect(DeliveryRecord.nextStep(r) == .done)
    }

    @Test func withoutTesterTheVerifierChecksFixesAndRoundsRunOut() throws {
        var r = record(cycle: true, tester: nil)
        try r.openFinding(id: nil, text: "x", anchor: "a:1", severity: nil, by: "Verificador")
        try r.updateFinding("P1", status: .fixed, commit: "c", note: nil, by: "Developer")
        #expect(DeliveryRecord.nextStep(r) == .verify)
        r.findings[0].status = .reopened
        r.cycle?.round = 2
        if case .stop(let why) = DeliveryRecord.nextStep(r) { #expect(why.contains("2 fix rounds")) } else { Issue.record("expected stop") }
        r.cycle?.state = .done
        #expect(DeliveryRecord.nextStep(r) == .wait)
    }

    @Test func tasksGroupByConversationThenSlackThreadThenRoot() {
        let agent = UUID(), project = UUID()
        func task(_ origin: TaskOrigin, root: UUID? = nil) -> AgentTask {
            var t = AgentTask(agentID: agent, agentName: "A", projectID: project, projectName: "P", instruction: "Revisa el PR 117",
                              origin: origin, runtime: .claudeCode, model: "m", permission: .readOnly)
            t.rootTaskID = root ?? t.id
            return t
        }
        // Old tasks of one Slack request (coordinator turns + delegated work) share the thread.
        var slack = TaskOrigin(kind: .slack); slack.slackChannel = "C1"; slack.slackThreadTS = "1.1"
        let pm1 = task(slack)
        var child = slack; child.kind = .agent; child.parentTaskID = pm1.id
        let v = task(child, root: pm1.id)
        var follow = slack; follow.automatic = true
        let pm2 = task(follow)
        // A plain chat (no delegation) is not a delivery.
        var other = TaskOrigin(kind: .slack); other.slackChannel = "C1"; other.slackThreadTS = "2.2"
        let chat = task(other)
        // New tasks carry the conversation id.
        let conv = UUID()
        var o = TaskOrigin.local; o.conversationID = conv
        let a = task(o)
        var oc = o; oc.kind = .agent; oc.parentTaskID = a.id
        let b = task(oc)

        let groups = Delivery.group([pm1, v, pm2, chat, a, b], records: [:])
        #expect(groups.count == 2)
        #expect(Set(groups.map { $0.tasks.count }) == [3, 2])
        #expect(groups.contains { $0.id == conv })
        #expect(Delivery.key(pm1) == Delivery.key(pm2) && Delivery.key(pm1) == UUID.stable("slack:C1:1.1"))
        // A record alone (criteria set without delegating) also makes it a delivery.
        var rec = DeliveryRecord(id: Delivery.key(chat)); rec.worktrees = ["/x/.worktrees/a"]
        #expect(Delivery.group([chat], records: [rec.id: rec]).count == 1)
    }

    @Test func worktreesAndBackgroundCommandsAreReadFromCommands() {
        #expect(CommandFacts.worktreesAdded("git worktree add --detach .worktrees/revision-pr117 b28f74f", cwd: "/p")
                == ["/p/.worktrees/revision-pr117"])
        #expect(CommandFacts.worktreesAdded("git fetch origin && git worktree add .worktrees/b20 -b fix/b20 origin/main", cwd: "/p")
                == ["/p/.worktrees/b20"])
        #expect(CommandFacts.worktreesAdded("git worktree add -b fix/x ../wt origin/main", cwd: "/p/app") == ["/p/wt"])
        #expect(CommandFacts.worktreesAdded("cd /p && git -C sub worktree add .wt/a", cwd: "/elsewhere") == ["/p/sub/.wt/a"])
        #expect(CommandFacts.worktreesAdded("git worktree list", cwd: "/p").isEmpty)
        #expect(CommandFacts.backgroundCommand("node servidor-prueba.mjs 18517", runInBackground: true) == "node servidor-prueba.mjs 18517")
        #expect(CommandFacts.backgroundCommand("npm run dev &", runInBackground: false) == "npm run dev")
        #expect(CommandFacts.backgroundCommand("npm test && echo ok", runInBackground: false) == nil)
    }
}

/// The work zone and own background processes in the approval policy.
struct WorkZonePolicyTests {
    let project = "/Users/test/Developer/pavirigido"
    private func ctx(zone: [String] = [".agentes", ".worktrees"], cwd: String? = nil, own: [String] = []) -> ApprovalPolicy.Context {
        .init(permission: .editProject, projectPath: project, cwd: cwd ?? project, autonomy: .balanced,
              workZone: zone, ownBackground: own)
    }
    private func deny(_ t: ApprovalTier) -> Bool { if case .deny = t { return true }; return false }

    @Test func writesStayInsideTheZone() {
        let c = ctx()
        #expect(ApprovalPolicy.decide(tool: "Write", input: ["file_path": "\(project)/.agentes/rev/entrega.md", "content": "x"], c) == .allow)
        #expect(ApprovalPolicy.decide(tool: "Edit", input: ["file_path": "\(project)/.worktrees/rev/saas/src/a.ts"], c) == .allow)
        let code = ApprovalPolicy.decide(tool: "Edit", input: ["file_path": "\(project)/saas/src/a.ts"], c)
        #expect(deny(code) && code.reason.contains("work zone") && code.reason.contains(".agentes"))
        #expect(deny(ApprovalPolicy.decide(tool: "Write", input: ["file_path": "/private/tmp/claude-501/x/pr117.diff", "content": "x"], c)))
        // Prefix tricks don't count as inside.
        #expect(deny(ApprovalPolicy.decide(tool: "Write", input: ["file_path": "\(project)/.agentes-otra/x", "content": "x"], c)))
    }

    @Test func redirectsCopiesAndTeeAreChecked() {
        let c = ctx()
        #expect(deny(ApprovalPolicy.decide(tool: "Bash", input: ["command": "gh pr diff 117 > /private/tmp/claude-501/x/pr117.diff"], c)))
        #expect(ApprovalPolicy.decide(tool: "Bash", input: ["command": "gh pr diff 117 > .agentes/rev/evidencia/pr117.diff"], c) == .allow)
        #expect(ApprovalPolicy.decide(tool: "Bash", input: ["command": "npm test 2>&1 >/dev/null"], c) == .allow)
        // After `cd`, relative paths are judged from that folder.
        #expect(ApprovalPolicy.decide(tool: "Bash", input: ["command": "cd .worktrees/rev/saas && npm test > ../../../.agentes/rev/evidencia/t.txt"], c) == .allow)
        #expect(deny(ApprovalPolicy.decide(tool: "Bash", input: ["command": "cd .worktrees/rev/saas && echo x > ../../../README.md"], c)))
        #expect(deny(ApprovalPolicy.decide(tool: "Bash", input: ["command": "npm test | tee salida.txt"], c)))
        #expect(deny(ApprovalPolicy.decide(tool: "Bash", input: ["command": "cp .agentes/a.md docs/a.md"], c)))
        #expect(ApprovalPolicy.decide(tool: "Bash", input: ["command": "mkdir -p .agentes/rev/evidencia"], c) == .allow)
    }

    @Test func noZoneKeepsTheOldBehaviour() {
        let c = ctx(zone: [])
        #expect(ApprovalPolicy.decide(tool: "Edit", input: ["file_path": "\(project)/saas/src/a.ts"], c) == .allow)
        #expect(ApprovalPolicy.decide(tool: "Bash", input: ["command": "gh pr diff 117 > /private/tmp/x.diff"], c) == .allow)
    }

    @Test func stoppingItsOwnBackgroundServerDoesNotAsk() {
        let own = ctx(own: ["node scripts/servidor-prueba.mjs 18517 > .agentes/rev/qa-servidor.log 2>&1"])
        #expect(ApprovalPolicy.decide(tool: "Bash", input: ["command": "pkill -f \"servidor-prueba.mjs 18517\""], own) == .allow)
        if case .user = ApprovalPolicy.decide(tool: "Bash", input: ["command": "pkill -f \"postgres\""], own) {} else { Issue.record("expected user") }
        // Too short a pattern would match anything.
        if case .user = ApprovalPolicy.decide(tool: "Bash", input: ["command": "pkill -f no"], own) {} else { Issue.record("expected user") }
        if case .user = ApprovalPolicy.decide(tool: "Bash", input: ["command": "pkill -f \"servidor-prueba.mjs 18517\""], ctx()) {} else { Issue.record("expected user") }
    }
}

/// The tools and the automatic cycle through the real `pn-agent` helper and fake `claude` sessions.
@Suite(.serialized)
@MainActor
struct DeliveryCycleTests {
    typealias Env = AgentHarnessTests.Env

    private func waitUntil(_ seconds: Double = 20, line: Int = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(condition(), "waited at line \(line)")
    }

    private func helper(_ mode: String, stdin: String, task: UUID, env: Env) async -> String {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("pn-out-\(UUID()).txt")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: TestHome.helper)
        p.arguments = [mode]
        var e = ProcessInfo.processInfo.environment
        e["PROJECTN_AGENT_PORT"] = String(env.harness.bridge.port ?? 0)
        e["PROJECTN_AGENT_TOKEN"] = env.harness.tokenOfTask[task] ?? ""
        p.environment = e
        let inPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = try? FileHandle(forWritingTo: out)
        return await withCheckedContinuation { cont in
            p.terminationHandler = { _ in cont.resume(returning: (try? String(contentsOf: out, encoding: .utf8)) ?? "") }
            try? p.run()
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
    }

    private func hook(_ tool: String, _ input: [String: Any], task: UUID, env: Env) async -> String {
        let payload: [String: Any] = ["tool_name": tool, "tool_input": input, "hook_event_name": "PreToolUse",
                                      "cwd": env.project.path, "session_id": "x"]
        let out = await helper("hook", stdin: String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!, task: task, env: env)
        let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])?["hookSpecificOutput"] as? [String: Any]
        return (obj?["permissionDecision"] as? String ?? "?") + " " + (obj?["permissionDecisionReason"] as? String ?? out)
    }

    private func mcp(_ calls: [(String, [String: Any])], task: UUID, env: Env) async -> (tools: [String], results: [String]) {
        var lines = [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
                     #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                     #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#]
        for (i, c) in calls.enumerated() {
            let msg: [String: Any] = ["jsonrpc": "2.0", "id": i + 2, "method": "tools/call", "params": ["name": c.0, "arguments": c.1]]
            lines.append(String(data: try! JSONSerialization.data(withJSONObject: msg), encoding: .utf8)!)
        }
        let out = await helper("mcp", stdin: lines.joined(separator: "\n") + "\n", task: task, env: env)
        var tools: [String] = [], results: [String] = []
        for line in out.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let r = o["result"] as? [String: Any] else { continue }
            if let t = r["tools"] as? [[String: Any]] { tools = t.compactMap { $0["name"] as? String } }
            if let c = (r["content"] as? [[String: Any]])?.first?["text"] as? String { results.append(c) }
        }
        return (tools, results)
    }

    private func setUp(_ ts: String) async throws -> (Env, AgentTask, AgentProfile, AgentProfile) {
        let env = try await AgentHarnessTests.makeSharedEnv()
        var dev = AgentProfile(name: "Developer", role: "Developer", model: "claude-opus-5-5", instructions: "Code.")
        dev.permission = .editProject; dev.allProjects = true; dev.concurrencyLimit = 3
        env.harness.saveProfile(dev)
        var ver = AgentProfile(name: "Verificador", role: "QA", model: "claude-opus-5-5", instructions: "Verify.")
        ver.permission = .editProject; ver.allProjects = true; ver.workZone = [".agentes", ".worktrees"]
        env.harness.saveProfile(ver)
        env.slack.handle(event: ["type": "app_mention", "user": "U1", "channel": "C1", "ts": ts,
                                 "text": "<@UBOT> Project Manager, coordina el trabajo en Demo SLOW"], eventID: "Ev\(ts)")
        let pm = try #require(env.harness.tasks.last)
        try await waitUntil { env.harness.task(pm.id)?.status == .running }
        return (env, pm, dev, ver)
    }

    @Test func coordinatorSetsCriteriaAndTheCycleVerifiesThenReportsDone() async throws {
        let (env, pm, _, _) = try await setUp("9100.1")
        defer { env.store.terminateAll() }
        #expect(env.harness.task(pm.id)?.origin.conversationID == pm.id)

        let r = await mcp([("criteria_set", ["criteria": [["text": "El login funciona", "check": "npm test"]]]),
                           ("criterion_update", ["id": "C1", "status": "met", "evidence": "npm test: 10/10"]),
                           ("start_cycle", ["fixer": "Developer", "verifier": "Verificador"])], task: pm.id, env: env)
        #expect(r.tools.contains("start_cycle") && r.tools.contains("finding_open"))
        #expect(r.results.count == 3)
        #expect(r.results[2].contains("\"cycle\":\"started\"") && r.results[2].contains("verify"))

        // Verify step runs (fake session finishes at once), the verifier ran after the last change → done.
        try await waitUntil { env.harness.deliveryRecords[pm.id]?.cycle?.state == .done }
        let steps = env.harness.tasks.filter { $0.cycleStep != nil }
        #expect(steps.map(\.cycleStep) == [.verify] && steps.first?.agentName == "Verificador")
        #expect(steps.first?.origin.conversationID == pm.id && steps.first?.origin.parentTaskID == pm.id)
        // The coordinator (still working) gets one report in its session.
        try await waitUntil { (env.harness.task(pm.id)?.inbox ?? []).contains { $0.contains("Automatic cycle finished") }
            || (env.harness.task(pm.id)?.followUps ?? []).contains { $0.contains("Automatic cycle finished") } }
        // It's one delivery with the coordinator and the step.
        let d = try #require(env.harness.delivery(pm.id))
        #expect(d.tasks.count == 2 && d.record?.criteriaMet == 1)
    }

    @Test func openFindingsGoToTheFixerUntilTheRoundsRunOut() async throws {
        let (env, pm, _, _) = try await setUp("9200.1")
        defer { env.store.terminateAll() }
        let r = await mcp([("finding_open", ["text": "La alerta se pierde en ráfaga", "anchor": "saas/src/avisos.ts:86", "severity": "P1"]),
                           ("start_cycle", ["fixer": "Developer", "verifier": "Verificador", "max_rounds": 2])], task: pm.id, env: env)
        #expect(r.results.first?.contains("\"id\":\"P1\"") == true)
        // The fake developer never marks P1 fixed: two fix rounds, then the cycle stops and says why.
        try await waitUntil { env.harness.deliveryRecords[pm.id]?.cycle?.state == .stopped }
        let c = try #require(env.harness.deliveryRecords[pm.id]?.cycle)
        #expect(c.round == 2 && (c.stopReason ?? "").contains("2 fix rounds"))
        let fixes = env.harness.tasks.filter { $0.cycleStep == .fix }
        #expect(fixes.count == 2 && fixes.allSatisfy { $0.agentName == "Developer" && $0.instruction.contains("P1") })
        // Steps aren't handed back to the coordinator one by one.
        #expect(!(env.harness.task(pm.id)?.inbox ?? []).contains { $0.contains("Result of a task you delegated") })
    }

    @Test func fixerCantVerifyItselfAndOnlyCoordinatorsStartCycles() async throws {
        let (env, pm, _, _) = try await setUp("9300.1")
        defer { env.store.terminateAll() }
        let bad = await mcp([("start_cycle", ["fixer": "Developer", "verifier": "Developer"])], task: pm.id, env: env)
        #expect(bad.results.first?.contains("can't test or verify its own work") == true)

        let dev = try #require(env.harness.profiles.first { $0.name == "Developer" })
        let t = try env.harness.submit(.init(agentID: dev.id, projectID: env.project.id, instruction: "SLOW edit", origin: .local)).get()
        try await waitUntil { env.harness.task(t.id)?.status == .running }
        let tools = await mcp([("start_cycle", ["fixer": "Developer", "verifier": "Verificador"])], task: t.id, env: env)
        #expect(!tools.tools.contains("start_cycle") && tools.tools.contains("criteria_set"))
        #expect(tools.results.first?.contains("can't delegate") == true)

        // The hook records worktrees the agent creates, for the clean-up in Deliveries.
        let added = await hook("Bash", ["command": "git worktree add .worktrees/b20 -b fix/b20"], task: t.id, env: env)
        #expect(added.hasPrefix("allow"))
        let key = Delivery.key(try #require(env.harness.task(t.id)))
        try await waitUntil { env.harness.deliveryRecords[key]?.worktrees.contains { $0.hasSuffix("/.worktrees/b20") } == true }
    }

    @Test func workZoneIsEnforcedThroughTheHook() async throws {
        let (env, _, _, ver) = try await setUp("9400.1")
        defer { env.store.terminateAll() }
        let t = try env.harness.submit(.init(agentID: ver.id, projectID: env.project.id, instruction: "SLOW verifica", origin: .local)).get()
        try await waitUntil { env.harness.task(t.id)?.status == .running }
        #expect(await hook("Write", ["file_path": env.project.path + "/.agentes/rev/entrega.md", "content": "x"], task: t.id, env: env).hasPrefix("allow"))
        let code = await hook("Edit", ["file_path": env.project.path + "/README.md"], task: t.id, env: env)
        #expect(code.hasPrefix("deny") && code.contains("work zone"))
        #expect(await hook("Bash", ["command": "gh pr diff 117 > /private/tmp/pr117.diff"], task: t.id, env: env).hasPrefix("deny"))
        // A server it started in the background may be stopped without asking.
        #expect(await hook("Bash", ["command": "node scripts/servidor-prueba.mjs 18517", "run_in_background": true], task: t.id, env: env).hasPrefix("allow"))
        #expect(await hook("Bash", ["command": "pkill -f 'servidor-prueba.mjs 18517'"], task: t.id, env: env).hasPrefix("allow"))
    }
}
