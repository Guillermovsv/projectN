import AppKit
import Foundation
import Testing
@testable import ProjectN

/// The acceptance test against the real Claude Code CLI and your Claude login (costs a little usage).
/// Off by default. Run with:  PROJECTN_LIVE_CLAUDE=1 ./scripts/test.sh --filter LiveAcceptance
/// Slack itself is simulated (the event goes into SlackConnector.handle and replies are captured), because
/// a real workspace needs your tokens; everything after that is real: model list, launch, session, transcript.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PROJECTN_LIVE_CLAUDE"] == "1"))
@MainActor
struct LiveAcceptanceTests {
    @Test func projectManagerReadsTheReadmeWithRealClaude() async throws {
        _ = TestHome.url
        _ = NSApplication.shared
        AppHome.bootstrap()
        for f in [AgentStore.profilesFile, AgentStore.tasksFile, AgentStore.slackSeenFile, AgentStore.integrationsFile] {
            try? FileManager.default.removeItem(at: f)
        }
        var settings = AppSettings()
        settings.shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        settings.claudeUseAppMCP = false
        settings.voiceEnabled = false
        settings.notificationSound = false
        AppHome.save(settings, to: AppHome.settingsFile)
        AppHome.save(PersistedState(), to: AppHome.stateFile)
        let store = Store()
        defer { store.terminateAll() }
        // This repository is the project (it has a README and is already trusted by Claude Code here).
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let project = store.addProject(url: repo)
        store.openProject(project)

        let harness = AgentHarness()
        harness.attach(store, refreshModels: true)
        let deadline = Date().addingTimeInterval(20)
        while ModelCatalog.shared.claude.source != .live, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        print("Model list source: \(ModelCatalog.shared.claude.source) — \(ModelCatalog.shared.claude.models.map(\.id))")
        #expect(ModelCatalog.shared.claude.source == .live)

        let slack = SlackConnector()
        var posts: [(String?, String)] = []
        slack.sender = { _, thread, text in posts.append((thread, text)) }
        slack.attach(store: store, harness: harness)
        var s = SlackSettings(); s.authorizedUsers = ["U1"]; s.authorizedChannels = ["C1"]; s.replyInThreads = true
        slack.settings = s
        slack.setTestIdentity(botUserID: "UBOT")

        slack.handle(event: ["type": "app_mention", "user": "U1", "channel": "C1", "ts": "1.1",
                             "text": "<@UBOT> Project Manager, revisa el proyecto seleccionado, consulta su README y dime qué tareas pendientes identificas"],
                     eventID: "EvLive")
        let t0 = try #require(harness.tasks.first)
        print("Task \(t0.id) status \(t0.status) model \(t0.model) effort \(t0.effort ?? "-")")
        let end = Date().addingTimeInterval(420)
        var lastStatus = ""
        while Date() < end {
            let t = harness.task(t0.id)!
            if t.status.rawValue != lastStatus { print("→ \(t.status.rawValue) \(t.lastApprovalNotice ?? "")"); lastStatus = t.status.rawValue }
            if t.status.isFinished { break }
            try await Task.sleep(for: .seconds(1))
        }
        let t = try #require(harness.task(t0.id))
        print("Final: \(t.status) in \(Int(t.duration ?? 0))s, tokens \(t.usage?.total ?? 0)\nERROR: \(t.error ?? "-")\nRESULT:\n\(t.result ?? "-")")
        if let p = t.paneID { print("Screen tail:\n" + (store.runtimes[p]?.scrollbackText(maxLines: 25) ?? "")) }
        #expect(t.status == .completed)
        #expect(t.model == "claude-opus-5-5" && t.effort == "high")
        #expect(!(t.result ?? "").isEmpty)
        try await Task.sleep(for: .seconds(1))
        print("Slack thread:\n" + posts.map { "[\($0.0 ?? "-")] \($0.1)" }.joined(separator: "\n---\n"))
        #expect(posts.contains { $0.0 == "1.1" && $0.1.contains("_Project Manager · projectN") })
    }

    /// Real delegation: the Project Manager hands work to a Developer through ProjectN's MCP tools; the Developer
    /// tries to delete a file; the hook routes that to "you", and the test (playing you) rejects it in Slack.
    @Test func projectManagerDelegatesAndDeletionIsBlockedUntilTheUserDecides() async throws {
        _ = TestHome.url
        _ = NSApplication.shared
        AppHome.bootstrap()
        for f in [AgentStore.profilesFile, AgentStore.tasksFile, AgentStore.slackSeenFile, AgentStore.integrationsFile] {
            try? FileManager.default.removeItem(at: f)
        }
        var settings = AppSettings()
        settings.shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        settings.claudeUseAppMCP = false
        settings.voiceEnabled = false
        settings.notificationSound = false
        AppHome.save(settings, to: AppHome.settingsFile)
        AppHome.save(PersistedState(), to: AppHome.stateFile)
        let store = Store()
        defer { store.terminateAll() }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let victim = repo.appendingPathComponent("pn-delete-me.txt")
        try "scratch file for the live delegation test\n".write(to: victim, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: victim) }
        let project = store.addProject(url: repo)
        store.openProject(project)

        let harness = AgentHarness()
        harness.attach(store, refreshModels: true)
        var pm = try #require(harness.profiles.first)
        pm.model = "claude-sonnet-5-5"; pm.effort = "low"
        harness.saveProfile(pm)
        var dev = AgentProfile(name: "Developer", role: "Developer", model: "claude-sonnet-5-5", effort: "low",
                               instructions: "You are a developer. Do exactly what you are asked, then report briefly.")
        dev.permission = .editProject
        dev.allProjects = true
        harness.saveProfile(dev)
        let deadline = Date().addingTimeInterval(20)
        while (ModelCatalog.shared.claude.source != .live || harness.bridge.port == nil), Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }

        let slack = SlackConnector()
        var posts: [(String?, String)] = []
        slack.sender = { _, thread, text in posts.append((thread, text)) }
        slack.attach(store: store, harness: harness)
        var s = SlackSettings(); s.authorizedUsers = ["U1"]; s.authorizedChannels = ["C1"]; s.replyInThreads = true
        slack.settings = s
        slack.setTestIdentity(botUserID: "UBOT")

        slack.handle(event: ["type": "app_mention", "user": "U1", "channel": "C1", "ts": "7.1",
                             "text": "<@UBOT> Project Manager, delega al Developer esta tarea en el proyecto projectN: contar cuántos archivos .swift hay en Sources/ProjectN/Agents y luego borrar el archivo pn-delete-me.txt de la raíz del proyecto con rm. Espera su resultado y dime qué pasó."],
                     eventID: "EvLive2")
        let root = try #require(harness.tasks.first)
        var rejected = Set<UUID>()
        let end = Date().addingTimeInterval(540)
        var seen = Set<String>()
        while Date() < end {
            for t in harness.tasks where !seen.contains("\(t.id)\(t.status)") {
                seen.insert("\(t.id)\(t.status)")
                print("[\(Int(Date().timeIntervalSince(root.createdAt)))s] \(t.agentName) depth \(t.depth): \(t.status.rawValue)")
            }
            // Play the user: reject every deletion request that reaches us, approve nothing else.
            for r in harness.pendingUserRequests() where !rejected.contains(r.id) {
                rejected.insert(r.id)
                print("→ request to user from \(r.agentName): \(r.summary) [\(r.reason)]")
                if r.reason.hasPrefix("Deletes") {
                    slack.handleInteraction(["type": "block_actions", "user": ["id": "U1"],
                                             "actions": [["action_id": "pn_deny", "value": r.id.uuidString]]])
                } else {
                    harness.resolveRequest(r.id, approve: false, by: "test user")
                }
            }
            if harness.task(root.id)?.status.isFinished == true { break }
            try await Task.sleep(for: .seconds(1))
        }
        for t in harness.tasks {
            print("\n== \(t.agentName) (depth \(t.depth)) \(t.status.rawValue) \(Int(t.duration ?? 0))s\nERROR: \(t.error ?? "-")\nRESULT: \(t.result ?? "-")")
        }
        print("\nRequests:\n" + harness.requests.map { "\($0.agentName) \($0.kind) \($0.status) by \($0.decidedBy ?? "-"): \($0.summary)" }.joined(separator: "\n"))
        print("\nSlack thread:\n" + posts.map { "[\($0.0 ?? "-")] \($0.1)" }.joined(separator: "\n---\n"))
        let audit = AuditLog.readRecent(limit: 400).reversed().filter { $0.contains("tool.") || $0.contains("request.") }
        print("\nAudit (tools/requests):\n" + audit.joined(separator: "\n"))

        let child = harness.tasks.first { $0.origin.parentTaskID == root.id }
        #expect(child != nil)                                                   // it delegated
        #expect(child?.agentName == "Developer")
        #expect(harness.requests.contains { $0.route == .user && $0.reason.hasPrefix("Deletes") && $0.status == .denied })
        #expect(FileManager.default.fileExists(atPath: victim.path))            // the deletion was blocked
        #expect(harness.task(root.id)?.status == .completed)
    }

    /// Two messages about the same project: the second is typed into the same live session (no new process,
    /// no context reload). Prints the token use of each.
    @Test func secondMessageContinuesTheSameSession() async throws {
        _ = TestHome.url
        _ = NSApplication.shared
        AppHome.bootstrap()
        for f in [AgentStore.profilesFile, AgentStore.tasksFile, AgentStore.slackSeenFile, AgentStore.integrationsFile] {
            try? FileManager.default.removeItem(at: f)
        }
        var settings = AppSettings()
        settings.shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        settings.claudeUseAppMCP = false
        settings.voiceEnabled = false
        settings.notificationSound = false
        AppHome.save(settings, to: AppHome.settingsFile)
        AppHome.save(PersistedState(), to: AppHome.stateFile)
        let store = Store()
        defer { store.terminateAll() }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let project = store.addProject(url: repo)
        store.openProject(project)
        let harness = AgentHarness()
        harness.attach(store, refreshModels: true)
        var pm = try #require(harness.profiles.first)
        pm.model = "claude-sonnet-5-5"; pm.effort = "low"; pm.sessionPolicy = .perProject
        harness.saveProfile(pm)
        let deadline = Date().addingTimeInterval(20)
        while (ModelCatalog.shared.claude.source != .live || harness.bridge.port == nil), Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        let slack = SlackConnector()
        var posts: [String] = []
        slack.sender = { _, _, text in posts.append(text) }
        slack.attach(store: store, harness: harness)
        var s = SlackSettings(); s.authorizedUsers = ["U1"]; s.replyInThreads = false
        slack.settings = s
        slack.setTestIdentity(botUserID: "UBOT")
        func say(_ text: String, _ ts: String) {
            slack.handle(event: ["type": "message", "channel_type": "im", "user": "U1", "channel": "D1", "ts": ts, "text": text], eventID: "EvL\(ts)")
        }
        func waitDone(_ id: UUID) async throws {
            let end = Date().addingTimeInterval(240)
            while harness.task(id)?.status.isFinished != true, Date() < end { try await Task.sleep(for: .seconds(1)) }
        }
        say("Project Manager, en el proyecto projectN: lee el README y dime en UNA línea de qué trata la app.", "1")
        let first = try #require(harness.tasks.last)
        try await waitDone(first.id)
        say("Project Manager, ¿cuántas secciones de nivel 2 (##) tiene ese README? Responde solo el número.", "2")
        let second = try #require(harness.tasks.last)
        try await waitDone(second.id)
        let a = try #require(harness.task(first.id)), b = try #require(harness.task(second.id))
        print("1st: \(a.status) \(Int(a.duration ?? 0))s usage \(String(describing: a.usage))\n   \(a.result ?? a.error ?? "-")")
        print("2nd: \(b.status) \(Int(b.duration ?? 0))s usage \(String(describing: b.usage)) continued=\(b.continuedSession ?? false)\n   \(b.result ?? b.error ?? "-")")
        print("Slack:\n" + posts.joined(separator: "\n---\n"))
        #expect(a.status == .completed && b.status == .completed)
        #expect(b.continuedSession == true && b.paneID == a.paneID && b.sessionID == a.sessionID)
        #expect(!(b.result ?? "").isEmpty)
    }

    /// The AI agent creator against real Claude Code: questions, then a full design.
    @Test func agentCreatorWithRealClaude() async throws {
        let env = try await AgentHarnessTests.makeSharedEnv()
        defer { env.store.terminateAll() }
        var real = env.store.settings   // the shared test env uses a fake `claude`; this test wants the real one
        real.claudeCommand = "claude"
        real.isolateClaudeConfig = false
        real.shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        env.store.settings = real
        let creator = AgentCreator(harness: env.harness, store: env.store)
        creator.description = "Quiero un agente SEO que cada lunes revise el sitio de Florina y me diga qué mejorar, sin tocar archivos."
        creator.askQuestions()
        var deadline = Date().addingTimeInterval(120)
        while creator.stage == .asking, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        print("Stage: \(creator.stage)")
        for q in creator.questions { print("Q: \(q.text)  options: \(q.options)") }
        #expect(creator.stage == .questions)
        if let first = creator.questions.first { creator.questions[0].answer = first.options.first ?? "" }
        creator.design()
        deadline = Date().addingTimeInterval(180)
        while creator.stage == .designing, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        print("Stage: \(creator.stage)")
        let p = try #require(creator.draft)
        print("Name: \(p.name) · role \(p.role) · \(p.model) \(p.effort ?? "-") · \(p.permission) · emoji \(p.slackEmoji) · tools \(AgentToolCatalog.effective(p).count) · schedules \(p.schedules.map { "\($0.name): \($0.summary)" })")
        print("Summary: \(creator.summary)\nInstructions:\n\(p.instructions.prefix(900))")
        #expect(p.permission == .readOnly && !p.instructions.isEmpty)
    }
}
