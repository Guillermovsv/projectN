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
        // The program's name alone (or a loose word) would kill the user's own processes too.
        let node = ctx(own: ["node server.js --port 3000"])
        #expect(ApprovalPolicy.decide(tool: "Bash", input: ["command": "pkill -f server.js"], node) == .allow)
        for loose in ["pkill -f node", "pkill node", "pkill -f server", "pkill -f \"node serv\""] {
            if case .user = ApprovalPolicy.decide(tool: "Bash", input: ["command": loose], node) {} else { Issue.record("expected user: \(loose)") }
        }
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
        // A Slack request is its thread: the conversation id is the thread's.
        let conv = try #require(env.harness.task(pm.id)?.origin.conversationID)
        #expect(conv == UUID.stable("slack:C1:9100.1"))

        let r = await mcp([("criteria_set", ["criteria": [["text": "El login funciona", "check": "npm test"]]]),
                           ("criterion_update", ["id": "C1", "status": "met", "evidence": "npm test: 10/10"]),
                           ("start_cycle", ["fixer": "Developer", "verifier": "Verificador"])], task: pm.id, env: env)
        #expect(r.tools.contains("start_cycle") && r.tools.contains("finding_open"))
        #expect(r.results.count == 3)
        #expect(r.results[2].contains("\"cycle\":\"started\"") && r.results[2].contains("verify"))

        // Verify step runs (fake session finishes at once), the verifier ran after the last change → done.
        try await waitUntil { env.harness.deliveryRecords[Delivery.key(pm)]?.cycle?.state == .done }
        let steps = env.harness.tasks.filter { $0.cycleStep != nil }
        #expect(steps.map(\.cycleStep) == [.verify] && steps.first?.agentName == "Verificador")
        #expect(steps.first?.origin.conversationID == conv && steps.first?.origin.parentTaskID == pm.id)
        // The coordinator (still working) gets one report in its session.
        try await waitUntil { (env.harness.task(pm.id)?.inbox ?? []).contains { $0.contains("Automatic cycle finished") }
            || (env.harness.task(pm.id)?.followUps ?? []).contains { $0.contains("Automatic cycle finished") } }
        // It's one delivery with the coordinator and the step.
        let d = try #require(env.harness.delivery(conv))
        #expect(d.tasks.count == 2 && d.record?.criteriaMet == 1)
    }

    @Test func openFindingsGoToTheFixerUntilTheRoundsRunOut() async throws {
        let (env, pm, _, _) = try await setUp("9200.1")
        defer { env.store.terminateAll() }
        let r = await mcp([("finding_open", ["text": "La alerta se pierde en ráfaga", "anchor": "saas/src/avisos.ts:86", "severity": "P1"]),
                           ("start_cycle", ["fixer": "Developer", "verifier": "Verificador", "max_rounds": 2])], task: pm.id, env: env)
        #expect(r.results.first?.contains("\"id\":\"P1\"") == true)
        // The fake developer never marks P1 fixed: two fix rounds, then the cycle stops and says why.
        try await waitUntil { env.harness.deliveryRecords[Delivery.key(pm)]?.cycle?.state == .stopped }
        let c = try #require(env.harness.deliveryRecords[Delivery.key(pm)]?.cycle)
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
        // Only coordinators reword criteria.
        let amend = await mcp([("criteria_set", ["criteria": [["text": "A", "check": "b"]]]),
                               ("criterion_amend", ["id": "C1", "text": "A bien escrito", "reason": "era ambiguo"])], task: pm.id, env: env)
        #expect(amend.results.count == 2 && amend.results[1].contains("\"amended\":\"C1\""))

        let dev = try #require(env.harness.profiles.first { $0.name == "Developer" })
        let t = try env.harness.submit(.init(agentID: dev.id, projectID: env.project.id, instruction: "SLOW edit", origin: .local)).get()
        try await waitUntil { env.harness.task(t.id)?.status == .running }
        let tools = await mcp([("start_cycle", ["fixer": "Developer", "verifier": "Verificador"])], task: t.id, env: env)
        #expect(!tools.tools.contains("start_cycle") && !tools.tools.contains("criterion_amend") && tools.tools.contains("criteria_set"))
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

/// Until merge, review lists and decisions: the pure parts.
struct ShipAndReviewRuleTests {
    static let failingJSON = #"{"state":"OPEN","mergeable":"MERGEABLE","reviewDecision":"REVIEW_REQUIRED","headRefName":"seguridad/webhook-workos","url":"https://github.com/o/r/pull/117","statusCheckRollup":[{"__typename":"CheckRun","name":"pruebas","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"saas","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"StatusContext","context":"coolify","state":"PENDING"}],"comments":[{"body":"x"}],"reviews":[{"state":"COMMENTED","body":""},{"state":"CHANGES_REQUESTED","body":"cambia esto"}]}"#

    @Test func readsThePullRequest() throws {
        let s = try #require(PRSnapshot.parse(Self.failingJSON))
        #expect(s.state == "OPEN" && s.branch == "seguridad/webhook-workos" && s.failing == ["saas"] && s.pending == ["coolify"])
        #expect(s.passed == 1 && s.comments == 2)
        #expect(ShipWatch.prNumber("https://github.com/o/r/pull/117") == 117 && ShipWatch.prNumber("#42") == 42 && ShipWatch.prNumber("x") == nil)
    }

    @Test func decidesWhatTheWatchDoes() throws {
        var w = ShipWatch(pr: 117, agent: "Developer", projectID: UUID(), coordinatorTaskID: UUID())
        var s = try #require(PRSnapshot.parse(Self.failingJSON))
        w.seenComments = 2
        #expect(w.evaluate(s) == .fix(["Failing checks: saas"]))
        s.failing = []; s.mergeable = "CONFLICTING"
        #expect(w.evaluate(s) == .fix(["The branch conflicts with the base branch"]))
        s.mergeable = "MERGEABLE"; s.comments = 3
        if case .fix(let r) = w.evaluate(s) { #expect(r.first?.contains("1 new review comment") == true) } else { Issue.record("expected fix") }
        w.seenComments = 3
        #expect(w.evaluate(s) == .wait("Checks running: coolify"))
        s.pending = []
        if case .ready(let why) = w.evaluate(s) { #expect(why.contains("waiting for a reviewer")) } else { Issue.record("expected ready") }
        s.reviewDecision = "APPROVED"
        if case .ready(let why) = w.evaluate(s) { #expect(why.contains("ready to merge")) } else { Issue.record("expected ready") }
        s.failing = ["saas"]; w.fixes = 5
        if case .stop = w.evaluate(s) {} else { Issue.record("expected stop") }
        s.state = "MERGED"
        #expect(w.evaluate(s) == .merged)
    }

    @Test func pushesOnlyToThePRBranchWithoutForce() {
        let b = ["seguridad/webhook-workos"]
        #expect(ShipWatch.pushAllowed(args: ["origin", "HEAD:seguridad/webhook-workos"], branches: b))
        #expect(ShipWatch.pushAllowed(args: ["origin", "seguridad/webhook-workos"], branches: b))
        #expect(ShipWatch.pushAllowed(args: ["origin", "HEAD:refs/heads/seguridad/webhook-workos"], branches: b))
        #expect(!ShipWatch.pushAllowed(args: ["--force", "origin", "HEAD:seguridad/webhook-workos"], branches: b))
        #expect(!ShipWatch.pushAllowed(args: ["origin", "+HEAD:seguridad/webhook-workos"], branches: b))
        #expect(!ShipWatch.pushAllowed(args: ["origin", "HEAD:main"], branches: b))
        #expect(!ShipWatch.pushAllowed(args: ["upstream", "HEAD:seguridad/webhook-workos"], branches: b))
        #expect(!ShipWatch.pushAllowed(args: [], branches: b))
        #expect(!ShipWatch.pushAllowed(args: ["origin", "HEAD:seguridad/webhook-workos"], branches: []))
        let ctx = ApprovalPolicy.Context(permission: .editProject, projectPath: "/p", cwd: "/p", pushBranches: b)
        #expect(ApprovalPolicy.decide(tool: "Bash", input: ["command": "git push origin HEAD:seguridad/webhook-workos"], ctx) == .allow)
        if case .user = ApprovalPolicy.decide(tool: "Bash", input: ["command": "git push origin HEAD:main"], ctx) {} else { Issue.record("expected user") }
        if case .user = ApprovalPolicy.decide(tool: "Bash", input: ["command": "git push -f origin HEAD:seguridad/webhook-workos"], ctx) {} else { Issue.record("expected user") }
    }

    @Test func reviewListsMatchChangedFiles() {
        #expect(ReviewLists.glob("saas/src/**", matches: "saas/src/rutas/avisos.ts"))
        #expect(ReviewLists.glob("**/*.sql", matches: "saas/migraciones/006.sql") && ReviewLists.glob("**/*.sql", matches: "a.sql"))
        #expect(!ReviewLists.glob("saas/src/*", matches: "saas/src/rutas/avisos.ts"))
        #expect(ReviewLists.glob("app/web/js/motor/", matches: "app/web/js/motor/aashto.js"))
        let seg = ReviewLists.parse(name: "seguridad-saas", "when: saas/src/**, saas/migraciones/**\n- Concurrencia\n- Reintentos")
        let calc = ReviewLists.parse(name: "calculo", "cuando: app/web/js/motor/**\n- Cita la fuente")
        let always = ReviewLists.parse(name: "general", "- CHANGELOG")
        #expect(seg.patterns.count == 2 && seg.text == "- Concurrencia\n- Reintentos" && always.patterns.isEmpty)
        #expect(ReviewLists.matching([seg, calc, always], changed: ["saas/src/rutas/avisos-identidad.ts"]).map(\.name) == ["seguridad-saas", "general"])
        #expect(ReviewLists.instructionBlock([seg]).contains("### seguridad-saas"))
    }
}

/// Until merge and decisions through the harness (gh replaced by canned answers).
@Suite(.serialized)
@MainActor
struct ShipAndDecisionTests {
    typealias Env = AgentHarnessTests.Env

    private func waitUntil(_ seconds: Double = 20, line: Int = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(condition(), "waited at line \(line)")
    }

    private func mcp(_ calls: [(String, [String: Any])], task: UUID, env: Env) async -> [String] {
        var lines = [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
                     #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#]
        for (i, c) in calls.enumerated() {
            let msg: [String: Any] = ["jsonrpc": "2.0", "id": i + 2, "method": "tools/call", "params": ["name": c.0, "arguments": c.1]]
            lines.append(String(data: try! JSONSerialization.data(withJSONObject: msg), encoding: .utf8)!)
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("pn-out-\(UUID()).txt")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: TestHome.helper)
        p.arguments = ["mcp"]
        var e = ProcessInfo.processInfo.environment
        e["PROJECTN_AGENT_PORT"] = String(env.harness.bridge.port ?? 0)
        e["PROJECTN_AGENT_TOKEN"] = env.harness.tokenOfTask[task] ?? ""
        p.environment = e
        let inPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = try? FileHandle(forWritingTo: out)
        let text: String = await withCheckedContinuation { cont in
            p.terminationHandler = { _ in cont.resume(returning: (try? String(contentsOf: out, encoding: .utf8)) ?? "") }
            try? p.run()
            inPipe.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        return text.split(separator: "\n").compactMap { line in
            ((try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["result"] as? [String: Any])
                .flatMap { ($0["content"] as? [[String: Any]])?.first?["text"] as? String }
        }
    }

    /// Canned `gh pr view` answers, switched by the test (read off the main thread).
    final class FakeGH: @unchecked Sendable {
        private let lock = NSLock()
        /// Answers in order; the last one repeats.
        var answers: [String] = []
        private(set) var calls = 0
        func run(_ cmd: String) -> (out: String, code: Int32) {
            lock.withLock {
                calls += 1
                return (answers.count > 1 ? answers.removeFirst() : (answers.first ?? ""), 0)
            }
        }
    }

    private func start(_ ts: String) async throws -> (Env, AgentTask) {
        let env = try await AgentHarnessTests.makeSharedEnv()
        var dev = AgentProfile(name: "Developer", role: "Developer", model: "claude-opus-5-5", instructions: "Code.")
        dev.permission = .editProject; dev.allProjects = true; dev.concurrencyLimit = 3
        env.harness.saveProfile(dev)
        env.slack.handle(event: ["type": "app_mention", "user": "U1", "channel": "C1", "ts": ts,
                                 "text": "<@UBOT> Project Manager, coordina el trabajo en Demo SLOW"], eventID: "Ev\(ts)")
        let pm = try #require(env.harness.tasks.last)
        try await waitUntil { env.harness.task(pm.id)?.status == .running }
        return (env, pm)
    }

    @Test func failingChecksGoToTheAgentThenReadyIsReported() async throws {
        let (env, pm) = try await start("9500.1")
        defer { env.store.terminateAll(); env.harness.shipFetcher = nil; env.harness.shipInterval = 120 }
        let gh = FakeGH()
        let green = ShipAndReviewRuleTests.failingJSON
            .replacingOccurrences(of: "\"FAILURE\"", with: "\"SUCCESS\"").replacingOccurrences(of: "\"PENDING\"", with: "\"SUCCESS\"")
        gh.answers = [ShipAndReviewRuleTests.failingJSON, green]
        env.harness.shipFetcher = { gh.run($0) }
        env.harness.shipInterval = 0.3

        let r = await mcp([("ship_pr", ["pr": "https://github.com/o/r/pull/117", "agent": "Developer"])], task: pm.id, env: env)
        #expect(r.first?.contains("\"watching\":\"PR #117\"") == true)
        // The failing check → a fix task for the developer, who may push to the PR branch only.
        try await waitUntil { env.harness.tasks.contains { $0.cycleStep == .ship } }
        let fix = try #require(env.harness.tasks.first { $0.cycleStep == .ship })
        #expect(fix.agentName == "Developer" && fix.instruction.contains("Failing checks: saas")
                && fix.instruction.contains("git push origin HEAD:seguridad/webhook-workos"))
        #expect(env.harness.deliveryRecords[Delivery.key(pm)]?.ship?.branch == "seguridad/webhook-workos")

        // After the fix everything is green: ready, reported once to the coordinator; merging stays with the user.
        try await waitUntil { env.harness.deliveryRecords[Delivery.key(pm)]?.ship?.state == .ready }
        try await waitUntil { ((env.harness.task(pm.id)?.inbox ?? []) + (env.harness.task(pm.id)?.followUps ?? [])).contains { $0.contains("Until merge: PR #117 — ready") } }
        #expect(env.harness.tasks.filter { $0.cycleStep == .ship }.count == 1)
        // Stop from the Deliveries view.
        env.harness.stopShip(Delivery.key(pm), reason: "test")
        #expect(env.harness.deliveryRecords[Delivery.key(pm)]?.ship?.state == .stopped)
    }

    @Test func yourAnswerToAQuestionIsSavedAsADecision() async throws {
        let (env, _) = try await start("9600.1")
        defer { env.store.terminateAll() }
        let dev = try #require(env.harness.profiles.first { $0.name == "Developer" })
        let t = try env.harness.submit(.init(agentID: dev.id, projectID: env.project.id, instruction: "SLOW csv", origin: .local)).get()
        try await waitUntil { env.harness.task(t.id)?.status == .running }
        _ = await mcp([("ask", ["question": "¿Qué formato de fecha uso en el CSV?"])], task: t.id, env: env)
        let q = try #require(env.harness.pendingUserRequests().first { $0.taskID == t.id })
        env.harness.resolveRequest(q.id, answer: "dd/mm/aaaa, como en pantalla", by: "U1")
        let notes = AgentStore.projectNotes(env.project.id)
        #expect(notes.contains("Decisión") && notes.contains("formato de fecha") && notes.contains("dd/mm/aaaa"))
        #expect(env.harness.deliveryRecords[Delivery.key(t)]?.decisions.count == 1)
    }

    @Test func theVerifierGetsTheProjectsReviewLists() async throws {
        let (env, pm) = try await start("9700.1")
        defer { env.store.terminateAll() }
        var ver = AgentProfile(name: "Verificador", role: "QA", model: "claude-opus-5-5", instructions: "Verify.")
        ver.permission = .editProject; ver.allProjects = true
        env.harness.saveProfile(ver)
        let dir = ReviewLists.folder(for: env.project.path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "- Concurrencia: lo que se cuenta es correcto en paralelo".write(to: dir.appendingPathComponent("seguridad.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await mcp([("start_cycle", ["fixer": "Developer", "verifier": "Verificador"])], task: pm.id, env: env)
        try await waitUntil { env.harness.tasks.contains { $0.cycleStep == .verify } }
        let v = try #require(env.harness.tasks.first { $0.cycleStep == .verify })
        #expect(v.instruction.contains("### seguridad") && v.instruction.contains("Concurrencia"))
        #expect(env.harness.deliveryRecords[Delivery.key(pm)]?.reviewsApplied == ["seguridad"])
    }
}

/// What the PR #117 run showed: a criterion that needs rewording, a finding the fixer can't solve in code, and a
/// worktree ProjectN didn't see being created.
struct DecisionAndAmendRuleTests {
    private func record() throws -> DeliveryRecord {
        var r = DeliveryRecord(id: UUID())
        r.cycle = DeliveryCycle(fixer: "Developer", tester: "QA", verifier: "Verificador", projectID: UUID(), coordinatorTaskID: UUID())
        try r.setCriteria([(nil, "Login OK", "npm test"), (nil, "La migración 006 crea el índice único", "psql pg_indexes")], by: "Verificador")
        try r.updateCriterion("C2", status: .unmet, evidence: "no existe en 006", by: "Verificador")
        try r.openFinding(id: nil, text: "C2 no se cumple", anchor: "criterion C2 · saas/migraciones/006.sql", severity: "P3", by: "Verificador")
        return r
    }

    @Test func theFixerAsksForADecisionAndTheCycleStopsAtOnce() throws {
        var r = try record()
        #expect(DeliveryRecord.nextStep(r) == .fix(["P1"]))
        #expect(throws: DeliveryError.self) { try r.updateFinding("P1", status: .needsDecision, commit: nil, note: " ", by: "Developer") }
        try r.updateFinding("P1", status: .needsDecision, commit: nil, note: "El índice pasó a la 007: ajustar C2", by: "Developer")
        if case .stop(let why) = DeliveryRecord.nextStep(r) { #expect(why.contains("Needs a decision") && why.contains("007")) } else { Issue.record("expected stop") }
        // Someone else decides it.
        #expect(throws: DeliveryError.self) { try r.updateFinding("P1", status: .closed, commit: nil, note: "ok", by: "Developer") }
        try r.updateFinding("P1", status: .reopened, commit: nil, note: "Sí hace falta el índice en 006", by: "Project Manager")
        #expect(DeliveryRecord.nextStep(r) == .fix(["P1"]))
        #expect(r.endReport().contains("criterion_amend"))
    }

    @Test func amendingACriterionKeepsTheOldWordingAndSettlesItsFindings() throws {
        var r = try record()
        try r.updateFinding("P1", status: .needsDecision, commit: nil, note: "ajustar C2", by: "Developer")
        #expect(throws: DeliveryError.self) { try r.amendCriterion("C2", text: "x", check: nil, reason: "", by: "Project Manager") }
        #expect(throws: DeliveryError.self) { try r.amendCriterion("C9", text: "x", check: nil, reason: "y", by: "Project Manager") }
        try r.amendCriterion("c2", text: "La migración 007 crea la tabla con llave primaria por id", check: "psql \\d avisos_workos_recibidos",
                             reason: "La unicidad pasó a la 007 (P9)", by: "Project Manager")
        let c = r.criteria[1]
        #expect(c.status == .pending && c.evidence == nil && c.text.contains("007") && c.check.contains("avisos_workos"))
        #expect(c.amendments?.first?.contains("006") == true && c.amendments?.first?.contains("P9") == true)
        #expect(r.findings[0].status == .closed)
        // Criteria stay locked for setCriteria, but the verifier checks C2 again.
        r.cycle?.verifiedSinceChange = true
        try r.amendCriterion("C1", text: nil, check: "npm test && npx playwright test login", reason: "faltaba e2e", by: "Project Manager")
        #expect(DeliveryRecord.nextStep(r) == .verify)
    }

    @Test func pathsAreReadFromAnchorsAndChecks() {
        #expect(ReviewLists.paths(in: "saas/src/rutas/avisos-identidad.ts:76 · page: #x") == ["saas/src/rutas/avisos-identidad.ts"])
        #expect(ReviewLists.paths(in: "criterion C3 · avisos-identidad.ts:90").isEmpty)
        #expect(ReviewLists.paths(in: "cd .worktrees/rev/saas && npm test; ver app/web/js/motor/ y https://x.com/a/b").contains("app/web/js/motor/"))
        #expect(!ReviewLists.paths(in: "https://x.com/a/b").contains { $0.contains("x.com") })
    }

    @Test func worktreesHoldingAFixCommitAreFound() throws {
        let fm = FileManager.default
        let repo = fm.temporaryDirectory.appendingPathComponent("wt-repo-\(UUID())").path
        func git(_ dir: String, _ args: String...) throws -> String {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", dir] + args
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            try p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return String(data: d, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: repo) }
        _ = try git(repo, "init", "-q", "-b", "main")
        _ = try git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "base")
        _ = try git(repo, "worktree", "add", "-q", ".worktrees/fix", "-b", "fix")
        let wt = repo + "/.worktrees/fix"
        try "x".write(toFile: wt + "/a.ts", atomically: true, encoding: .utf8)
        _ = try git(wt, "add", "a.ts")
        _ = try git(wt, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "fix")
        let sha = try git(wt, "rev-parse", "--short", "HEAD")
        let found = ReviewLists.worktrees(of: repo)
        #expect(found.count == 1 && found[0].hasSuffix("/.worktrees/fix"))
        #expect(ReviewLists.contains(found[0], commit: sha))
        #expect(!ReviewLists.contains(repo, commit: sha))
        #expect(!ReviewLists.contains(found[0], commit: "zz"))
    }
}

/// What the Deliveries view reads out of the coordinator's answers (real text from the PaviRígido #117 run).
struct DeliveryInsightTests {
    static let pmAnswer = """
    **Veredicto: el #117 no cumple del todo lo que dice (6 de 8 criterios).**

    ## Preguntas
    1. El PR se cerró sin motivo registrado y no hay nada corriendo. ¿Qué hacemos con él?
    - a) Retomarlo: el Developer corrige P1–P8 y se vuelve a probar y verificar
    - b) Dejarlo cerrado
    2. Si se retoma, ¿los eventos de Radar deben contar como inicios de sesión fallidos para la alerta?
    - a) Sí, como ahora
    - b) No, solo los fallos de autenticación

    Para reabrirlo: `gh pr reopen 117`. Nunca `git push --force origin main` ni `git branch -D x`.
    """

    @Test func readsTheCoordinatorsQuestions() {
        let qs = DeliveryInsights.questions(in: Self.pmAnswer)
        #expect(qs.count == 2)
        #expect(qs[0].number == "1" && qs[0].text.contains("¿Qué hacemos con él?"))
        #expect(qs[0].options.map(\.key) == ["a", "b"] && qs[0].options[1].text == "Dejarlo cerrado")
        #expect(qs[1].options[0].text == "Sí, como ahora")
        #expect(DeliveryInsights.questions(in: "Todo listo, sin preguntas.").isEmpty)
    }

    @Test func offersOnlySafeCommands() {
        #expect(DeliveryInsights.commands(in: Self.pmAnswer) == ["gh pr reopen 117"])
    }

    @Test func readsWhichFindingsAStepWorksOn() {
        let r = DeliveryRecord(id: UUID())
        let text = CycleInstructions.text(.fix, ids: ["P4", "P9"], record: {
            var x = r
            _ = try? x.openFinding(id: "P4", text: "racha", anchor: "a.ts:1", severity: "P2", by: "QA")
            _ = try? x.openFinding(id: "P9", text: "migración", anchor: "006.sql", severity: nil, by: "QA")
            return x
        }())
        #expect(DeliveryInsights.findingIDs(inStep: text) == ["P4", "P9"])
    }
}
