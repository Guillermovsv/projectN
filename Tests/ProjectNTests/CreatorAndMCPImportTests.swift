import Foundation
import Testing
@testable import ProjectN

@Suite(.serialized)
@MainActor
struct CreatorAndMCPImportTests {
    init() { _ = TestHome.url }

    // MARK: MCP JSON

    @Test func mcpImportAcceptsCommonFormats() throws {
        let claude = try MCPConfig.parseImport(#"{"mcpServers": {"notion": {"type": "http", "url": "https://mcp.notion.com/mcp", "headers": {"Authorization": "Bearer x"}}, "fs": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "."]}}}"#)
        #expect(claude.map(\.name) == ["fs", "notion"])
        #expect((claude[1].entry["headers"] as? [String: String])?["Authorization"] == "Bearer x")   // kept as-is
        let vscode = try MCPConfig.parseImport(#"{"servers": {"gh": {"url": "https://api.githubcopilot.com/mcp/"}}}"#)
        #expect(vscode[0].name == "gh" && vscode[0].entry["type"] as? String == "http")
        let bareMap = try MCPConfig.parseImport(#"{"seo": {"command": "seo-mcp", "env": {"KEY": "1"}}}"#)
        #expect(bareMap[0].name == "seo")
        let fragment = try MCPConfig.parseImport(#""linear": {"serverUrl": "https://mcp.linear.app/sse"}"#)
        #expect(fragment[0].name == "linear" && fragment[0].entry["url"] as? String == "https://mcp.linear.app/sse")
        #expect(throws: MCPConfig.ImportError.self) { try MCPConfig.parseImport(#"{"command": "x"}"#) }   // needs a name
        #expect(try MCPConfig.parseImport(#"{"command": "x"}"#, singleName: "mine")[0].name == "mine")
        #expect(throws: MCPConfig.ImportError.self) { try MCPConfig.parseImport("{not json") }
        #expect(throws: MCPConfig.ImportError.self) { try MCPConfig.parseImport(#"{"a": {"foo": 1}}"#) }

        // Import writes them (replacing same names), readable only by the user.
        defer { ["fs", "notion"].forEach(MCPConfig.remove) }
        MCPConfig.importEntries(claude)
        #expect(Set(MCPConfig.load().map(\.name)).isSuperset(of: ["fs", "notion"]))
        let raw = MCPConfig.loadRaw()["mcpServers"] as? [String: Any]
        #expect(((raw?["notion"] as? [String: Any])?["headers"] as? [String: String])?["Authorization"] == "Bearer x")
        let perms = try FileManager.default.attributesOfItem(atPath: AppHome.mcpFile.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600)
    }

    // MARK: AI agent creator

    private func context() -> AgentCreator.Context {
        AgentCreator.Context(projects: [Project(name: "Florina", path: "/x/florina"), Project(name: "dr-sergio", path: "/x/dr")],
                             mcpServers: [MCPServer(name: "seo-core", command: "seo-core-mcp")],
                             models: [.init(id: "claude-opus-5-5", label: "Opus 5.5", efforts: ["low", "medium", "high"]),
                                      .init(id: "claude-sonnet-5-5", label: "Sonnet 5.5", efforts: ["low", "medium", "high"])],
                             existingAgents: ["Project Manager (Project Manager)"])
    }

    @Test func designedProfileKeepsOnlyValidValues() {
        let spec: [String: Any] = [
            "name": "Analista SEO", "role": "SEO", "emoji": "mag", "instructions": "Eres el analista SEO…", "summary": "Revisa SEO",
            "permission": "readOnly", "canDelegate": false, "model": "gpt-9", "effort": "max",
            "tools": ["Read", "Grep", "Edit", "Hack"], "contextSources": ["docs/seo.md", "/etc/passwd", "../x"],
            "mcpServers": ["seo-core", "missing"], "cliTools": ["gh", "rm -rf /"], "allProjects": false,
            "projects": ["florina", "Nope"],
            "schedules": [["name": "Lunes", "instruction": "Revisa", "frequency": "weekly", "days": ["mon", "fri"], "hour": 9, "minute": 30, "project": "Florina"]],
        ]
        let p = AgentCreator.profile(from: spec, context: context())
        #expect(p.name == "Analista SEO" && p.permission == .readOnly && p.sessionPolicy == .perProject)
        #expect(p.model == "claude-sonnet-5-5")              // unknown model → a real one
        #expect(p.effort == nil)                              // "max" not supported by that model
        #expect(!p.tools.contains("Edit") && !p.tools.contains("Hack"))
        #expect(p.contextSources == ["README.md", "docs/seo.md"])
        #expect(p.mcpServers == ["seo-core"] && p.cliTools == ["gh"])
        #expect(!p.allProjects && p.projectIDs.count == 1)
        #expect(p.slackEmoji == ":mag:")
        #expect(p.schedules.count == 1 && p.schedules[0].frequency == .weekly && p.schedules[0].hour == 9 && p.schedules[0].projectID != nil)
        #expect(p.schedules[0].weekdays == [2, 6])   // Monday and Friday in Calendar numbering
    }

    @Test func creatorAsksThenDesignsThenCreates() async throws {
        let env = try await AgentHarnessTests.makeSharedEnv()
        defer { env.store.terminateAll() }
        let creator = AgentCreator(harness: env.harness, store: env.store)
        var prompts: [String] = []
        creator.runner = { prompt, schema in
            prompts.append(prompt)
            if (schema["properties"] as? [String: Any])?["questions"] != nil {
                return ["questions": [["question": "¿Puede editar archivos?", "options": ["Solo leer", "Sí"]],
                                      ["question": "¿Cada cuánto?", "options": ["Diario", "Semanal"]]]]
            }
            return ["name": "Redactor", "role": "Copywriter", "instructions": "Escribe posts.", "summary": "Escribe posts",
                    "permission": "editProject", "model": "claude-opus-5-5", "tools": AgentToolCatalog.claude,
                    "allProjects": true, "schedules": []]
        }
        creator.description = "Un redactor de blog para mis clientes"
        creator.askQuestions()
        let deadline = Date().addingTimeInterval(5)
        while creator.stage != .questions, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(creator.questions.map(\.text) == ["¿Puede editar archivos?", "¿Cada cuánto?"])
        #expect(prompts[0].contains("Un redactor de blog") && prompts[0].contains("Demo"))   // projects given as context
        creator.questions[0].answer = "Sí"
        creator.design()
        while creator.stage != .review, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(prompts[1].contains("¿Puede editar archivos?\n  → Sí"))
        let id = try #require(creator.create())
        let p = try #require(env.harness.profile(id))
        #expect(p.name == "Redactor" && p.permission == .editProject && p.tools.isEmpty)   // full set = follows the preset
    }
}
