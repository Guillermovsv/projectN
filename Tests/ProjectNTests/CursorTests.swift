import Foundation
import Testing
@testable import ProjectN

@MainActor
struct CursorTests {
    @Test func parsesModelList() {
        let out = """
        Available models

        auto - Auto
        gpt-5 - GPT-5
        \u{1B}[1msonnet-4.5 - Claude 4.5 Sonnet (current)\u{1B}[0m
        Tip: use --model <id>
        """
        let models = LaunchCatalog.parseCursorModels(out)
        #expect(models.map(\.value) == ["auto", "gpt-5", "sonnet-4.5"])
        #expect(models.last?.label == "Claude 4.5 Sonnet")
    }

    @Test func buildsFlags() {
        #expect(LaunchCatalog.cursorArgs(LaunchOptions(model: "auto", effort: "", permission: "manual")) == [])
        #expect(LaunchCatalog.cursorArgs(LaunchOptions(model: "gpt-5", effort: nil, permission: "plan")) == ["--model", "gpt-5", "--mode", "plan"])
        #expect(LaunchCatalog.cursorArgs(LaunchOptions(model: nil, effort: nil, permission: "force")) == ["--force"])
    }

    @Test func launchesWithResume() {
        var settings = AppSettings()
        settings.cursorCommand = "cursor-agent"
        let project = Project(name: "p", path: NSTemporaryDirectory())
        let plan = Launcher.plan(tool: .cursor, mode: .cursorResume(id: "abc"),
                                 options: LaunchOptions(model: "gpt-5", effort: "", permission: "ask"),
                                 project: project, workspaceName: "w", settings: settings)
        #expect(plan.commandLine == "cursor-agent --resume abc --model gpt-5 --mode ask")
    }
}
