import Foundation
import Testing
@testable import ProjectN

/// Codex agents only get the MCP servers their settings allow; Claude Code agents don't stop at "trust this folder?".
struct CodexMCPAndTrustTests {
    @Test func parsesCodexConfigServers() {
        let toml = """
        model = "gpt-6"
        [mcp_servers.seo-core]
        command = "npx"
        [mcp_servers.seo-core.env]
        KEY = "x"
        [mcp_servers.violet-caribou-elementor]
        url = "https://violet.example/mcp"
        [mcp_servers.violet-caribou-elementor.tools.elementor-create-page]
        approval_mode = "approve"
        [mcp_servers."odd name"]
        command = "x"
        [mcp_servers.projectn]
        command = "pn-agent"
        [projects."/tmp"]
        trust_level = "trusted"
        """
        let s = MCPConfig.parseCodexServers(toml)
        #expect(Set(s.keys) == ["seo-core", "violet-caribou-elementor", "odd name"])
        #expect(s["seo-core"] == "npx")
        #expect(s["violet-caribou-elementor"] == "HTTP  https://violet.example/mcp")
    }

    @Test func disablesServersByName() {
        #expect(MCPConfig.codexDisableOverrides(["a-b", "odd name"])
                == ["-c", "mcp_servers.a-b.enabled=false", "-c", "mcp_servers.\"odd name\".enabled=false"])
    }

    @Test func trustAcceptKeepsOtherKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".claude.json")
        try Data(#"{"oauthAccount":{"id":1},"projects":{"/a":{"hasTrustDialogAccepted":false,"x":2}}}"#.utf8).write(to: file)
        #expect(ClaudeTrust.accept(path: "/a", file: file))
        #expect(ClaudeTrust.accept(path: "/b/c/", file: file))
        #expect(!ClaudeTrust.accept(path: "/a", file: file))   // already trusted: untouched
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect((json["oauthAccount"] as? [String: Any])?["id"] as? Int == 1)
        let projects = try #require(json["projects"] as? [String: [String: Any]])
        #expect(projects["/a"]?["hasTrustDialogAccepted"] as? Bool == true)
        #expect(projects["/a"]?["x"] as? Int == 2)
        #expect(projects["/b/c"]?["hasTrustDialogAccepted"] as? Bool == true)
    }

    @Test func unreadableConfigIsNeverOverwritten() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).json")
        try Data("{not json".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(!ClaudeTrust.accept(path: "/a", file: file))
        #expect(try String(contentsOf: file, encoding: .utf8) == "{not json")
    }

    @Test func codexCommentaryIsProgressNotTheAnswer() {
        func msg(_ phase: String, _ text: String) -> String {
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"\#(phase)","content":[{"type":"output_text","text":"\#(text)"}]}}"#
        }
        let started = #"{"type":"event_msg","payload":{"type":"task_started"}}"#
        let working = [started, msg("commentary", "Voy a revisar el sitio."), msg("commentary", "Ya tengo dos borradores.")]
        let w = TranscriptReader.parseCodex(Data(working.joined(separator: "\n").utf8))
        #expect(w.progress == ["Voy a revisar el sitio.", "Ya tengo dos borradores."])
        #expect(!w.finished)
        let done = working + [msg("final_answer", "Listo."),
                              #"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Listo."}}"#]
        let d = TranscriptReader.parseCodex(Data(done.joined(separator: "\n").utf8))
        #expect(d.finished && d.result == "Listo.")
        #expect(d.progress.count == 2)
    }

    @MainActor @Test func progressTextIsOneShortLine() {
        let t = SlackConnector.progressText("Voy a **crear** la página.\nLuego la reviso.", agent: "PM", delegated: false)
        #expect(t == "💬 *PM*: Voy a *crear* la página. Luego la reviso.")
        let long = SlackConnector.progressText(String(repeating: "a", count: 500), agent: "Dev", delegated: true)
        #expect(long.hasPrefix("↳ 💬 *Dev*: ") && long.hasSuffix("…") && long.count < 330)
    }
}
