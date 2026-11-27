import Foundation
import Testing
@testable import ProjectN

/// The default agent pack (PM, Developer, QA, Verificador): what each agent may do and that its template
/// instructions only name ProjectN tools that exist.
struct AgentStarterPackTests {
    let project = "/Users/test/Documents/client-site"

    private var pack: [String: AgentProfile] {
        Dictionary(uniqueKeysWithValues: AgentStarterPack.profiles().map { ($0.name, $0) })
    }

    @Test func packHasFourAgentsThatWorkInEveryProject() throws {
        let all = AgentStarterPack.profiles()
        #expect(all.map(\.name) == ["Project Manager", "Developer", "QA", "Verificador"])
        #expect(Set(all.map(\.id)).count == 4)
        for p in all {
            #expect(p.allProjects && p.enabled && p.sessionPolicy == .perProject && p.runtime == .claudeCode)
            #expect(!p.instructions.isEmpty && !p.autoMode && p.autonomy == .balanced)
        }
        let pm = try #require(pack["Project Manager"])
        #expect(pm.canDelegate && pm.worksOutsideProjects && pm.permission == .readOnly)
        let dev = try #require(pack["Developer"])
        #expect(!dev.canDelegate && dev.permission == .editProject && dev.workZone.isEmpty)
        for name in ["QA", "Verificador"] {
            let p = try #require(pack[name])
            #expect(!p.canDelegate && p.permission == .editProject && p.workZone == [".qa"])
        }
        #expect(pack["Verificador"]?.slackEmoji == ":ballot_box_with_check:")
        #expect(AgentStarterPack.summaries.map(\.name) == all.map(\.name))
    }

    @Test func instructionsOnlyNameToolsTheAgentHas() throws {
        let workerTools = Set(AgentTools.definitions(canDelegate: false).compactMap { $0["name"] as? String })
        let coordinatorTools = Set(AgentTools.definitions(canDelegate: true).compactMap { $0["name"] as? String })
        let uses: [(String, Set<String>, [String])] = [
            ("Project Manager", coordinatorTools, ["project_info", "project_notes", "criteria_set", "list_agents", "delegate_task",
                                                   "start_cycle", "ship_pr", "save_project_note"]),
            ("Developer", workerTools, ["delivery_status", "criteria_set", "finding_update"]),
            ("QA", workerTools, ["delivery_status", "review_lists", "finding_open"]),
            ("Verificador", workerTools, ["delivery_status", "criterion_update", "finding_open", "review_lists"]),
        ]
        for (name, available, tools) in uses {
            let text = try #require(pack[name]).instructions
            for t in tools {
                #expect(text.contains(t), "\(name) should mention \(t)")
                #expect(available.contains(t), "\(name) mentions \(t), which it doesn't get")
            }
        }
        // The cycle's agent names in the PM's instructions are the pack's names.
        #expect(pack["Project Manager"]?.instructions.contains("fixer: Developer, tester: QA, verifier: Verificador") == true)
        #expect(AgentProfile.projectManager().instructions == AgentStarterPack.projectManagerInstructions)
    }

    @Test func qaAndVerifierRunTestsButOnlyWriteEvidence() throws {
        for name in ["QA", "Verificador"] {
            let p = try #require(pack[name])
            let ctx = ApprovalPolicy.Context(permission: p.permission, projectPath: project, cwd: project,
                                             autonomy: p.autonomy, workZone: p.workZone)
            #expect(ApprovalPolicy.classify(tool: "Bash", input: ["command": "npm test"], ctx) == .allow)
            #expect(ApprovalPolicy.classify(tool: "Write", input: ["file_path": "\(project)/.qa/report.md", "content": "ok"], ctx) == .allow)
            if case .deny = ApprovalPolicy.classify(tool: "Edit", input: ["file_path": "\(project)/src/app.ts"], ctx) {} else {
                Issue.record("\(name) may not edit the project's code")
            }
        }
    }

    @Test func missingMatchesNamesLooselyAndKeepsExistingAgents() {
        var mine = AgentProfile(name: " developer", role: "Dev", model: "claude-opus-5-5", instructions: "mine")
        mine.permission = .readOnly
        let missing = AgentStarterPack.missing(in: [mine, AgentStarterPack.qa()])
        #expect(missing.map(\.name) == ["Project Manager", "Verificador"])
        #expect(AgentStarterPack.missing(in: AgentStarterPack.profiles()).isEmpty)
    }

    @Test func agentsYouAlreadyHaveUnderAnotherCommonNameCount() {
        func named(_ n: String) -> AgentProfile { AgentProfile(name: n, role: "x", model: "claude-opus-5-5", instructions: "") }
        #expect(AgentStarterPack.missing(in: [named("PM"), named("Dev"), named("verifier")]).map(\.name) == ["QA"])
        #expect(AgentStarterPack.missing(in: [named("project-manager"), named("Desarrollador"), named("Q.A."), named("VERIFICADORA")]).isEmpty)
        #expect(AgentStarterPack.existing("Developer", in: [named("SEO"), named(" dev ")])?.name == " dev ")
        // Different agents don't count: a "Developer 2" or a "Dev Ops" isn't the Developer.
        #expect(AgentStarterPack.missing(in: [named("Developer 2"), named("DevOps"), named("QA Lead")]).count == 4)
    }

    @Test func installsFromBeforeThePackDontGetTheOffer() throws {
        let old = try JSONDecoder().decode(AgentPolicy.self, from: Data(#"{"autonomyMigrated": true}"#.utf8))
        #expect(!old.starterPackOffered)
        var fresh = AgentPolicy(); fresh.starterPackOffered = true
        let back = try JSONDecoder().decode(AgentPolicy.self, from: JSONEncoder().encode(fresh))
        #expect(back.starterPackOffered)
    }
}
