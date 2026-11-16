import Foundation
import Testing
@testable import ProjectN

@MainActor
struct AssistantCommandsTests {
    init() { _ = TestHome.url }
    let shop = Project(name: "Web Shop", path: "/tmp/web-shop")
    let blog = Project(name: "Blog", path: "/tmp/blog")
    var dev: AgentProfile { var p = AgentProfile(name: "Developer", role: "Developer", model: "claude-opus-5-5", instructions: ""); p.enabled = true; return p }

    func parse(_ s: String) -> AssistantIntent {
        AssistantCommands.parse(s, .init(projects: [shop, blog], workspaces: [], agents: [dev]))
    }

    @Test func openProjects() {
        #expect(parse("abre web shop") == .openProject(shop))
        #expect(parse("Hey ProjectN, go to the blog project") == .openProject(blog))
        #expect(parse("ve al proyecto Blog.") == .openProject(blog))
    }

    @Test func spacesAndPanes() {
        #expect(parse("nuevo espacio") == .newSpace(nil))
        #expect(parse("new space in blog") == .newSpace(blog))
        #expect(parse("espacio dos") == .gotoSpace(2))
        #expect(parse("go to space 3") == .gotoSpace(3))
        #expect(parse("siguiente espacio") == .nextSpace)
        #expect(parse("abre un Claude en web shop") == .newPane(.claude, shop))
        #expect(parse("nueva terminal") == .newPane(.terminal, nil))
    }

    @Test func panelAndStatus() {
        #expect(parse("muestra la actividad") == .showPanel(.activity))
        #expect(parse("open files") == .showPanel(.files))
        #expect(parse("¿qué está corriendo?") == .status)
        #expect(parse("what needs my approval") == .pending)
        #expect(parse("silencio") == .stopSpeaking)
        #expect(parse("ayuda") == .help)
    }

    @Test func agents() {
        if case .askAgent(_, let name, let ins) = parse("Developer, arregla el login") {
            #expect(name == "Developer"); #expect(ins == "arregla el login")
        } else { Issue.record("expected askAgent") }
        if case .askAgent(_, _, let ins) = parse("pide a Developer que revise los tests") {
            #expect(ins == "revise los tests")
        } else { Issue.record("expected askAgent") }
        if case .askAgent(_, _, let ins) = parse("tell developer to update the readme") {
            #expect(ins == "update the readme")
        } else { Issue.record("expected askAgent") }
        if case .cancelAgent(_, let name) = parse("detén a Developer") { #expect(name == "Developer") }
        else { Issue.record("expected cancelAgent") }
    }

    @Test func unknownGoesToAI() {
        if case .unknown = parse("how do I connect Slack?") {} else { Issue.record("expected unknown") }
    }

    @Test func spokenStripsMarkdown() {
        let s = AssistantCommands.spoken("## Done\nFixed `login()` in /src/auth.swift. See https://x.y\n```\ncode\n```\n- All tests pass.")
        #expect(!s.contains("`") && !s.contains("http") && !s.contains("/src") && !s.contains("#"))
        #expect(s.contains("Fixed") && s.contains("All tests pass"))
    }

    @Test func language() {
        #expect(AssistantCommands.language("abre el proyecto y crea un espacio nuevo") == .es)
        #expect(AssistantCommands.language("open the project and create a new space") == .en)
        #expect(AssistantCommands.language("x", localeID: "en_US") == .en)
    }
}

struct AssistantAITests {
    @Test func parsesJSONPlan() {
        let raw = """
        ```json
        {"say": "Abriendo Blog y pidiéndole a Developer que lo revise.",
         "actions": [{"do": "open_project", "project": "Blog"},
                     {"do": "ask_agent", "agent": "Developer", "instruction": "Review the blog", "project": "Blog"},
                     {"do": "goto_space", "n": "2"}]}
        ```
        """
        let p = AssistantAI.parse(raw)
        #expect(p.say.hasPrefix("Abriendo Blog"))
        #expect(p.actions.map(\.kind) == ["open_project", "ask_agent", "goto_space"])
        #expect(p.actions[1].instruction == "Review the blog")
        #expect(p.actions[2].n == 2)
    }

    @Test func plainTextBecomesSpeech() {
        let p = AssistantAI.parse("Use **⌥⌘0** to toggle the panel.")
        #expect(p.actions.isEmpty)
        #expect(p.say.contains("toggle the panel"))
    }

    @Test func findsProjectsByLooseName() {
        let all = [Project(name: "Web Shop", path: "/a"), Project(name: "Blog", path: "/b")]
        #expect(AssistantAI.findProject("web shop", all)?.name == "Web Shop")
        #expect(AssistantAI.findProject("the Blog", all)?.name == "Blog")
    }
}
