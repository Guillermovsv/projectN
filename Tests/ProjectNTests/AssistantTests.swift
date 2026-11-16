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
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        // Talking from the first buffer, with the usual dips between syllables.
        for (i, l) in [0.8, 0.15, 0.8, 0.75, 0.2, 0.7].enumerated() { #expect(v.push(Float(l), now: at(Double(i) * 0.06)) == .listening) }
        #expect(v.push(0.7, now: at(0.5)) == .listening)
        #expect(v.push(0.1, now: at(1.0)) == .listening)
        #expect(v.push(0.1, now: at(1.5)) == .endOfSpeech)
    }

    @Test func vadIgnoresAConstantlyNoisyRoom() {
        var v = AssistantVAD()
        let t0 = Date()
        // A loud fan (after the mic's first silent buffer): never speech, so it gives up instead of listening
        // until the 45 s limit.
        for i in 0..<150 {
            let t = 0.03 + Double(i) * 0.05
            let r = v.push(i == 0 ? 0 : 0.55, now: t0.addingTimeInterval(t))
            if i != 140 { #expect(r == (i > 140 ? .nothingSaid : .listening)) }   // 140 is the 7 s mark itself
        }
        // Speaking over it is heard, and going back to just the fan ends the turn.
        var w = AssistantVAD()
        for i in 0..<10 { _ = w.push(0.55, now: t0.addingTimeInterval(Double(i) * 0.05)) }
        #expect(w.push(0.85, now: t0.addingTimeInterval(1.0)) == .listening)
        #expect(w.push(0.85, now: t0.addingTimeInterval(1.05)) == .listening)
        #expect(w.heardSpeech)
        #expect(w.push(0.55, now: t0.addingTimeInterval(1.5)) == .listening)
        #expect(w.push(0.55, now: t0.addingTimeInterval(2.1)) == .endOfSpeech)
    }

    @Test func bargeInIgnoresItsOwnVoiceAndHearsYou() {
        var b = AssistantBargeIn()
        let t0 = Date()
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        // The answer through the speakers: loud-ish and steady, for 3 s — never an interruption.
        for i in 0..<60 { let r = b.push(i.isMultiple(of: 3) ? 0.5 : 0.55, now: at(Double(i) * 0.05)); #expect(!r) }
        // A cough: loud but short.
        do { let r = b.push(0.9, now: at(3.05)); #expect(!r) }
        do { let r = b.push(0.55, now: at(3.3)); #expect(!r) }
        // You talking over it, with a dip between syllables.
        do { let r = b.push(0.85, now: at(3.5)); #expect(!r) }
        do { let r = b.push(0.8, now: at(3.6)); #expect(!r) }
        do { let r = b.push(0.6, now: at(3.7)); #expect(!r) }
        do { let r = b.push(0.85, now: at(3.85)); #expect(r) }
    }

    @Test func bargeInWaitsForTheAnswerToStart() {
        var b = AssistantBargeIn()
        let t0 = Date()
        // The tail of your own last sentence right when it starts answering.
        for i in 0..<8 { let r = b.push(0.9, now: t0.addingTimeInterval(Double(i) * 0.05)); #expect(!r) }
    }

    @Test func stripEchoDropsTheAnswerFromTheStart() {
        let spoken = "Abrí Claude en Opus como Claude 2. ¿Algo más?"
        #expect(AssistantBargeIn.stripEcho("como Claude 2 no espera ábrelo en Codex", spoken: spoken) == "no espera ábrelo en Codex")
        #expect(AssistantBargeIn.stripEcho("No, ábrelo en Codex", spoken: spoken) == "No, ábrelo en Codex")
        #expect(AssistantBargeIn.stripEcho("algo más", spoken: spoken) == "")
        #expect(AssistantBargeIn.stripEcho("detente", spoken: spoken) == "detente")
    }

    @Test func vadCanStartMidSentence() {
        var v = AssistantVAD()
        let t0 = Date()
        v.startSpeaking(floor: 0.1, now: t0)
        #expect(v.heardSpeech)
        #expect(v.push(0.7, now: t0.addingTimeInterval(0.3)) == .listening)
        #expect(v.push(0.1, now: t0.addingTimeInterval(1.5)) == .endOfSpeech)
    }

    @Test func vadIgnoresASingleClick() {
        var v = AssistantVAD()
        let t0 = Date()
        for i in 0..<10 { _ = v.push(0.05, now: t0.addingTimeInterval(Double(i) * 0.05)) }
        _ = v.push(0.9, now: t0.addingTimeInterval(0.6))        // a key press
        _ = v.push(0.05, now: t0.addingTimeInterval(0.65))
        #expect(!v.heardSpeech)
        #expect(v.push(0.05, now: t0.addingTimeInterval(2)) == .listening)
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

/// The phrases from a real session's log (speech recognition included) that the Assistant didn't understand.
@MainActor
struct AssistantHeardTests {
    init() { _ = TestHome.url }
    let names = ["SEO Core App", "NUEVO 4vmarketing", "NVoice", "Client Finder", "dr-sergio", "Florina", "projectN",
                 "HR-System", "Ralero", "Airedinamica", "Hotel system", "Canal de Youtube", "Solar Devs"]
    var projects: [Project] { names.map { Project(name: $0, path: "/tmp/\($0)") } }
    let crm = (id: UUID(), name: "CRM 4VMarketing")
    let videos = (id: UUID(), name: "Videos")

    func parse(_ s: String) -> AssistantIntent {
        AssistantCommands.parse(s, .init(projects: projects, workspaces: [crm], spaces: [(UUID(), "Space 1"), videos]))
    }
    func opens(_ s: String, _ name: String) -> Bool {
        if case .openProject(let p) = parse(s) { return p.name == name }
        return false
    }

    @Test func projectsSaidLoosely() {
        #expect(opens("Change to SEO app", "SEO Core App"))
        #expect(opens("Change to solar debs", "Solar Devs"))
        #expect(opens("Change to solar devs", "Solar Devs"))
        #expect(opens("Change to Nvoice", "NVoice"))
        #expect(opens("Abre aire dinámica?", "Airedinamica"))
        #expect(opens("Abre el proyecto aire dinámica", "Airedinamica"))
        #expect(opens("Abre el proyecto doctor-Sergio", "dr-sergio"))
        #expect(opens("Hotel system", "Hotel system"))
        #expect(opens("Cambia el proyecto Florina", "Florina"))
        #expect(opens("switch to HR system", "HR-System"))
        #expect(opens("go to the blog project", "") == false)
    }

    @Test func workspacesSpacesAndAgents() {
        #expect(parse("cambia a CRM") == .openWorkspace(id: crm.id, name: crm.name))
        #expect(parse("ve a Videos") == .selectSpace(id: videos.id, name: videos.name))
        #expect(parse("Abre el proyecto Agents?") == .agentsView)
        #expect(parse("Which two agents view") == .agentsView)
    }

    @Test func claudeMisheard() {
        #expect(parse("Launch tree cloud agents") == .newPane(PaneRequest(tool: .claude, count: 3)))
        #expect(parse("Open three clouds in this space") == .newPane(PaneRequest(tool: .claude, count: 3)))
        #expect(parse("Lounge three code terminals in this space") == .newPane(PaneRequest(tool: .claude, count: 3)))
        #expect(parse("Lancha Cloud Code agent") == .newPane(PaneRequest(tool: .claude)))
        #expect(parse("Open three codes in this page") == .newPane(PaneRequest(tool: .codex, count: 3)))
        #expect(parse("abre tres terminales en este espacio") == .newPane(PaneRequest(tool: .terminal, count: 3)))
        // The prompt keeps what was said.
        #expect(parse("abre un claude que revise el cloud setup")
                == .newPane(PaneRequest(tool: .claude, prompt: "revise el cloud setup")))
    }
}
