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
        #expect(parse("abre un Claude en web shop") == .newPane(PaneRequest(tool: .claude, project: shop)))
        #expect(parse("nueva terminal") == .newPane(PaneRequest(tool: .terminal)))
    }

    @Test func panesWithModelEffortAndPrompt() {
        #expect(parse("abre cinco claude en Opus 5.5 low")
                == .newPane(PaneRequest(tool: .claude, count: 5, model: "claude-opus-5-5", effort: "low")))
        #expect(parse("abre 3 claudes en sonnet con esfuerzo alto en web shop que revisen el Login.")
                == .newPane(PaneRequest(tool: .claude, project: shop, count: 3, model: "claude-sonnet-5-5", effort: "high",
                                        prompt: "revisen el Login.")))
        #expect(parse("abre dos claude en opus cinco punto cinco extra alto")
                == .newPane(PaneRequest(tool: .claude, count: 2, model: "claude-opus-5-5", effort: "xhigh")))
        #expect(parse("open a claude on fable 5.1 max to fix the README")
                == .newPane(PaneRequest(tool: .claude, model: "claude-fable-5-1", effort: "max", prompt: "fix the README")))
        // A prompt that mentions spaces or projects stays part of the prompt.
        #expect(parse("nuevo claude: crea un nuevo espacio de trabajo en blog")
                == .newPane(PaneRequest(tool: .claude, prompt: "crea un nuevo espacio de trabajo en blog")))
        // Terminals only take a clearly introduced command.
        #expect(parse("abre una terminal y ejecuta npm test") == .newPane(PaneRequest(tool: .terminal, prompt: "npm test")))
        #expect(parse("abre una terminal que corra") == .newPane(PaneRequest(tool: .terminal)))
    }

    @Test func promptsToOpenPanes() {
        let ada = Store.PaneRef(workspaceID: UUID(), paneID: UUID())
        let ken = Store.PaneRef(workspaceID: ada.workspaceID, paneID: UUID())
        let ctx = AssistantCommands.Context(projects: [shop], agents: [dev],
                                            panes: [(ada, "Ada"), (ken, "Ken")], lastOpened: [ada, ken])
        #expect(AssistantCommands.parse("dile a Ada que corra los Tests", ctx) == .sendToPanes([ada], names: ["Ada"], prompt: "corra los Tests"))
        #expect(AssistantCommands.parse("tell ken to fix the build", ctx) == .sendToPanes([ken], names: ["Ken"], prompt: "fix the build"))
        #expect(AssistantCommands.parse("diles a todos que hagan commit", ctx) == .sendToPanes([ada, ken], names: ["Ada", "Ken"], prompt: "hagan commit"))
        #expect(AssistantCommands.parse("escríbele al último: revisa el diff", ctx) == .sendToPanes([ken], names: ["Ken"], prompt: "revisa el diff"))
        // Agents keep priority over panes.
        if case .askAgent = AssistantCommands.parse("dile a Developer que revise", ctx) {} else { Issue.record("expected askAgent") }
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

    @Test func parsesPaneActions() {
        let p = AssistantAI.parse("""
        Abro cinco Claude y le paso el login a Ada.
        ACTION {"do":"new_pane","tool":"claude","count":"5","model":"Opus 5.5","effort":"Low","prompt":"Review the login"}
        ACTION {"do":"send_to_pane","pane":"Ada","prompt":"Run the tests"}
        """)
        #expect(p.actions.count == 2)
        #expect(p.actions[0].count == 5 && p.actions[0].model == "Opus 5.5" && p.actions[0].effort == "low")
        #expect(p.actions[0].prompt == "Review the login")
        #expect(p.actions[1].pane == "Ada" && p.actions[1].prompt == "Run the tests")
        let said = AssistantCommands.digitize(AssistantCommands.normalize("Opus 5.5"))
        #expect(AssistantCommands.model(in: said, LaunchCatalog.claudeModelChoices)?.0 == "claude-opus-5-5")
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

struct AssistantRealtimeTests {
    @Test func splitterSpeaksSentencesAsTheyArrive() {
        var s = AssistantAI.StreamSplitter()
        #expect(s.feed("Claro, abro el pro").isEmpty)
        #expect(s.feed("yecto Blog ahora. Y le pido") == ["Claro, abro el proyecto Blog ahora."])
        #expect(s.feed(" a Developer que lo revise.\nACT").isEmpty == false)
        #expect(s.feed("ION {\"do\":\"open_project\",\"project\":\"Blog\"}\n").isEmpty)
        #expect(s.finish().isEmpty)
        #expect(!s.speakable.contains("ACTION"))
        let plan = AssistantAI.parse(s.full)
        #expect(plan.actions.map(\.kind) == ["open_project"])
        #expect(plan.say.contains("Developer"))
    }

    @Test func splitterHoldsBackAPossibleActionLine() {
        var s = AssistantAI.StreamSplitter()
        _ = s.feed("Hecho, ya está abierto el proyecto.\nAC")
        #expect(!s.speakable.contains("AC"))
        #expect(s.finish().isEmpty)
    }

    @Test func splitterFlushesTheTailAtTheEnd() {
        var s = AssistantAI.StreamSplitter()
        #expect(s.feed("Hay dos terminales corriendo").isEmpty)
        #expect(s.finish() == ["Hay dos terminales corriendo"])
    }

    @Test func splitterNeverSpeaksJSON() {
        var s = AssistantAI.StreamSplitter()
        #expect(s.feed("{\"say\": \"Hola.\", \"actions\": []}").isEmpty)
        #expect(s.finish().isEmpty)
        #expect(AssistantAI.parse(s.full).say == "Hola.")
    }

    @Test func vadEndsAfterAPauseOnceYouSpoke() {
        var v = AssistantVAD()
        let t0 = Date()
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        for i in 0..<6 { #expect(v.push(0.1, now: at(Double(i) * 0.05)) == .listening) }   // room
        #expect(v.push(0.7, now: at(0.5)) == .listening)                                  // talking
        #expect(v.push(0.65, now: at(1.2)) == .listening)
        #expect(v.push(0.1, now: at(1.8)) == .listening)                                  // short pause
        #expect(v.push(0.1, now: at(2.2)) == .endOfSpeech)
    }

    @Test func vadGivesUpWhenNothingIsSaid() {
        var v = AssistantVAD()
        let t0 = Date()
        #expect(v.push(0.1, now: t0) == .listening)
        #expect(v.push(0.15, now: t0.addingTimeInterval(3)) == .listening)
        #expect(v.push(0.1, now: t0.addingTimeInterval(7.5)) == .nothingSaid)
    }

    @Test func vadHandlesSpeakingRightAway() {
        var v = AssistantVAD()
        let t0 = Date()
        #expect(v.push(0.8, now: t0) == .listening)
        #expect(v.push(0.1, now: t0.addingTimeInterval(1.0)) == .endOfSpeech)
    }

    @Test func streamDeltaReadsClaudeChunks() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" Uno, d"}},"session_id":"x"}"#
        #expect(Enhancer.streamDelta(Substring(line)) == " Uno, d")
        #expect(Enhancer.streamDelta(#"{"type":"assistant","message":{}}"#) == nil)
    }

    @MainActor @Test func endConversationPhrases() {
        let ctx = AssistantCommands.Context(projects: [])
        #expect(AssistantCommands.parse("Gracias", ctx) == .endConversation)
        #expect(AssistantCommands.parse("eso es todo.", ctx) == .endConversation)
        #expect(AssistantCommands.parse("that's all", ctx) == .endConversation)
    }
}
