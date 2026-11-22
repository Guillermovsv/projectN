import AppKit
import Foundation
import Testing
@testable import ProjectN

@MainActor
struct BrowserAutomationTests {
    @Test func toolDefinitionsAreValidJSON() throws {
        let data = try JSONSerialization.data(withJSONObject: ["tools": BrowserAutomation.tools])
        #expect(data.count > 0)
        let names = BrowserAutomation.tools.compactMap { $0["name"] as? String }
        #expect(names.contains("browser_navigate") && names.contains("browser_screenshot"))
    }

    @Test func mergesIntoExistingClaudeFlags() throws {
        try FileManager.default.createDirectory(at: AppHome.root, withIntermediateDirectories: true)
        try "{}".write(to: BrowserAutomation.configFile, atomically: true, encoding: .utf8)
        BrowserAutomation.port = 4242
        defer { BrowserAutomation.port = nil }
        var parts = ["claude", "--append-system-prompt", "You are X", "--strict-mcp-config", "--mcp-config", "/a.json"]
        BrowserAutomation.applyToClaude(&parts)
        #expect(parts.filter { $0 == "--mcp-config" }.count == 1)
        #expect(parts[parts.firstIndex(of: "--mcp-config")! + 1] == BrowserAutomation.configFile.path)
        #expect(parts.filter { $0 == "--append-system-prompt" }.count == 1)
        #expect(parts[2].hasPrefix("You are X\n\n# ProjectN built-in browser"))
        var bare = ["claude"]
        BrowserAutomation.applyToClaude(&bare)
        #expect(bare == ["claude", "--mcp-config", BrowserAutomation.configFile.path, "--append-system-prompt", BrowserAutomation.systemPrompt])
        #expect(BrowserAutomation.environment()["PROJECTN_BROWSER_PORT"] == "4242")
    }
}

@MainActor
struct BrowserPageScriptTests {
    @Test func snapshotTypeClickAndConsoleWorkInAWebView() async throws {
        let b = BrowserModel()
        b.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let html = """
        <html><body><h1>Hello</h1>
        <input id=q placeholder="Search">
        <button onclick="document.getElementById('out').textContent = 'got ' + document.getElementById('q').value; console.log('clicked', 42)">Go</button>
        <p id=out></p></body></html>
        """
        b.webView.loadHTMLString(html, baseURL: URL(string: "http://localhost/"))
        try await Task.sleep(nanoseconds: 300_000_000)
        await b.waitForLoad(timeout: 10)
        let snap = try await b.js(BrowserAutomation.snapshotJS, ["maxText": 1000]) as? String ?? ""
        #expect(snap.contains("[1] input[text] \\\"Search\\\""))
        #expect(snap.contains("[2] button \\\"Go\\\""))
        let typed = try await b.js(BrowserAutomation.findJS + BrowserAutomation.typeJS,
                                   ["ref": "1", "selector": NSNull(), "text": NSNull(), "value": "cats", "clear": true, "submit": false]) as? String
        #expect(typed?.hasPrefix("Typed into input") == true)
        let clicked = try await b.js(BrowserAutomation.findJS + BrowserAutomation.clickJS,
                                     ["ref": NSNull(), "selector": NSNull(), "text": "go"]) as? String
        #expect(clicked == "Clicked button \"Go\".")
        let out = try await b.js("return document.getElementById('out').textContent", [:]) as? String
        #expect(out == "got cats")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(b.consoleLines.contains("log: clicked 42"))
        await #expect(throws: (any Error).self) {
            _ = try await b.js(BrowserAutomation.findJS + BrowserAutomation.clickJS, ["ref": "99", "selector": NSNull(), "text": NSNull()])
        }
    }
}

@Suite(.serialized)
@MainActor
struct PerWorkspaceBrowserTests {
    @Test func eachWorkspaceHasItsOwnBrowserThatFollowsTheSelection() throws {
        _ = TestHome.url
        _ = NSApplication.shared
        let store = Store()
        defer { store.terminateAll() }
        let project = Project(name: "Browser fixture", path: TestHome.url.path)
        let a = Workspace(name: "A", projectIDs: [project.id])
        let b = Workspace(name: "B", projectIDs: [project.id])
        var state = PersistedState()
        state.projects = [project]
        state.workspaces = [a, b]
        store.state = state
        let panel = RightPanelModel()
        panel.attach(store)

        let home = panel.browser
        #expect(home.key == "home")
        store.state.ui.selectedWorkspaceID = a.id
        let ba = panel.browser
        #expect(ba !== home && ba.key == a.id.uuidString)
        store.state.ui.selectedWorkspaceID = b.id
        let bb = panel.browser
        #expect(bb !== ba)
        // An agent in A keeps working in A's browser while B is on screen.
        #expect(panel.browser(for: a.id) === ba)
        store.state.ui.selectedWorkspaceID = a.id
        #expect(panel.browser === ba)
        // A deleted workspace's browser is dropped; an unknown id falls back to the home browser.
        store.deleteWorkspace(b.id)
        #expect(panel.browser(for: b.id) === home)
    }

    @Test func panesCarryTheirWorkspaceID() {
        let id = UUID()
        let env = Launcher.environment(project: Project(name: "p", path: "/tmp"), workspaceName: "W", workspaceID: id, settings: AppSettings())
        #expect(env.contains("PROJECTN_WORKSPACE_ID=\(id.uuidString)"))
        let none = Launcher.environment(project: Project(name: "p", path: "/tmp"), workspaceName: "", settings: AppSettings())
        #expect(!none.contains { $0.hasPrefix("PROJECTN_WORKSPACE_ID=") })
    }
}
