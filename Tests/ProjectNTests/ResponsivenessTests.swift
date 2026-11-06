import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ProjectN

/// All fixtures and shell processes live under a disposable ProjectN home.
@Suite(.serialized)
@MainActor
struct ResponsivenessTests {
    private static let home: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("projectn-tests-\(UUID())")
        setenv("PROJECTN_HOME", url.path, 1)
        return url
    }()

    private func makeStore() throws -> Store {
        let home = Self.home
        #expect(AppHome.root == home)
        _ = NSApplication.shared
        AppHome.bootstrap()
        var settings = AppSettings()
        settings.shell = "/bin/sh"
        settings.claudeCommand = "/usr/bin/true"
        settings.isolateClaudeConfig = true
        settings.isolateCodexHome = true
        settings.voiceEnabled = false
        settings.notificationSound = false
        settings.claudeDefaults = LaunchOptions(model: "test", effort: "low", permission: "manual")
        settings.codexDefaults = LaunchOptions(model: "test", effort: "low", permission: "workspace")
        AppHome.save(settings, to: AppHome.settingsFile)
        AppHome.save(PersistedState(), to: AppHome.stateFile)
        return Store()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }

    @Test func openingEightPanesDefersLaunchAndStillTracksOutput() async throws {
        let store = try makeStore()
        defer { store.terminateAll() }
        let project = store.addProject(url: Self.home)
        let workspace = store.createWorkspace(name: "Load test", projectIDs: [project.id])
        let space = workspace.spaces[0]
        let start = ContinuousClock.now
        for _ in 0..<8 {
            let pane = try #require(store.addPane(tool: .terminal, in: workspace.id, space: space.id))
            store.ensureStarted(pane.id, in: workspace.id)
        }
        // No terminal/config/Keychain work may complete inline on the caller's UI turn.
        #expect(store.runtimes.isEmpty)
        print("Eight pane requests on main: \(start.duration(to: .now))")
        try await waitUntil { store.runtimes.count == 8 }
        for runtime in store.runtimes.values {
            runtime.view.feed(text: "\u{1b}[2J\u{1b}[999;1HEsc to interrupt")
            runtime.refreshActivity()
        }
        try await waitUntil {
            for runtime in store.runtimes.values { runtime.refreshActivity() }
            return store.runtimes.values.allSatisfy { $0.activity == .working }
        }
    }

    @Test func closingAndRestartingPendingPanesDoesNotReviveOldLaunches() async throws {
        let store = try makeStore()
        defer { store.terminateAll() }
        let project = store.addProject(url: Self.home)
        let workspace = store.createWorkspace(name: "Cancellation", projectIDs: [project.id])
        let space = workspace.spaces[0]
        let closed = try #require(store.addPane(tool: .terminal, in: workspace.id, space: space.id))
        store.closePane(closed.id, in: workspace.id)
        let survivor = try #require(store.addPane(tool: .terminal, in: workspace.id, space: space.id))
        store.start(survivor, in: workspace.id, resume: true)
        store.ensureStarted(survivor.id, in: workspace.id)
        try await waitUntil { store.runtimes[survivor.id] != nil }
        #expect(store.runtimes.count == 1)
        #expect(store.runtimes[closed.id] == nil)
    }

    @Test func transcriptScanCannotOverwriteANewerComposerMessage() async throws {
        let store = try makeStore()
        defer { store.terminateAll() }
        let project = store.addProject(url: Self.home)
        let workspace = store.createWorkspace(name: "Prompts", projectIDs: [project.id])
        let pane = try #require(store.addPane(tool: .claude, in: workspace.id, space: workspace.spaces[0].id))
        try await waitUntil { store.runtimes[pane.id] != nil }
        let stored = try #require(store.pane(pane.id, in: workspace.id)?.1)
        let session = try #require(stored.claudeSessionID)
        let transcript = AppHome.claudeConfigDir.appendingPathComponent("projects/fixture/\(session).jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"type\":\"user\",\"message\":{\"content\":\"older transcript prompt\"}}\n".utf8).write(to: transcript)
        store.refreshLastPrompts()
        #expect(store.promptRefreshInFlight)
        store.refreshLastPrompts() // Must not start an overlapping job.
        store.updatePane(pane.id, in: workspace.id) { $0.lastPrompt = "new composer message" }
        try await waitUntil { !store.promptRefreshInFlight }
        #expect(store.pane(pane.id, in: workspace.id)?.1.lastPrompt == "new composer message")
    }

    @Test func transcriptCacheHandlesAppendTruncateAndDifferentTools() throws {
        let store = try makeStore()
        defer { store.terminateAll() }
        let id = UUID().uuidString
        let claude = AppHome.claudeConfigDir.appendingPathComponent("projects/fixture/\(id).jsonl")
        let codex = AppHome.codexHomeDir.appendingPathComponent("sessions/fixture/rollout-\(id).jsonl")
        for url in [claude, codex] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let first = "{\"type\":\"user\",\"message\":{\"content\":\"first\"}}\n"
        try Data(first.utf8).write(to: claude)
        #expect(PromptTracker.lastPrompt(tool: .claude, sessionID: id, settings: store.settings) == "first")
        #expect(PromptTracker.lastPrompt(tool: .claude, sessionID: id, settings: store.settings) == "first")
        let modified = try claude.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        let second = "{\"type\":\"user\",\"message\":{\"content\":\"second\"}}\n"
        try Data((first + second).utf8).write(to: claude)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: claude.path)
        #expect(PromptTracker.lastPrompt(tool: .claude, sessionID: id, settings: store.settings) == "second")
        try Data(first.utf8).write(to: claude, options: .atomic)
        #expect(PromptTracker.lastPrompt(tool: .claude, sessionID: id, settings: store.settings) == "first")
        try Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"codex prompt\"}]}}\n".utf8).write(to: codex)
        #expect(PromptTracker.lastPrompt(tool: .codex, sessionID: id, settings: store.settings) == "codex prompt")
    }

    @Test func autoModeAnswersOnceDespiteContinuousTitleUpdates() async throws {
        let store = try makeStore()
        defer { store.terminateAll() }
        let script = "printf '\\033[999;1HContinue? (y/n)'; i=0; while [ \"$i\" -lt 50 ]; do printf '\\033]0;working\\007'; sleep 0.05; i=$((i+1)); done; sleep 2"
        let plan = Launcher.Plan(executable: "/bin/sh", args: ["-c", script], environment: ["TERM=xterm-256color"],
                                 directory: Self.home.path, commandLine: "auto-mode fixture")
        let runtime = TerminalSession(id: UUID(), plan: plan, fontSize: 13)
        defer { runtime.terminate() }
        runtime.setAutoComplete(true)
        try await waitUntil { runtime.autoAnswerCount == 1 }
        try await Task.sleep(for: .milliseconds(800))
        #expect(runtime.autoAnswerCount == 1)
    }

    @Test func messagesQueuedDuringLaunchReachTheSamePane() async throws {
        let store = try makeStore()
        defer { store.terminateAll() }
        let project = store.addProject(url: Self.home)
        let workspace = store.createWorkspace(name: "Delivery", projectIDs: [project.id])
        let pane = try #require(store.addPane(tool: .terminal, in: workspace.id, space: workspace.spaces[0].id))
        let ref = Store.PaneRef(workspaceID: workspace.id, paneID: pane.id)
        let first = Self.home.appendingPathComponent("first-\(UUID()).txt")
        let second = Self.home.appendingPathComponent("second-\(UUID()).txt")
        store.deliver("printf first > \(Shell.quote(first.path))", to: ref)
        store.deliver("printf second > \(Shell.quote(second.path))", to: ref)
        try await waitUntil { FileManager.default.fileExists(atPath: second.path) }
        #expect(try String(contentsOf: first, encoding: .utf8) == "first")
        #expect(try String(contentsOf: second, encoding: .utf8) == "second")
        #expect(store.runtimes.count == 1)
    }

    @Test func idlePaneTypingAndPanelLayout() async throws {
        for count in [3, 4, 8] {
            let store = try makeStore()
            let project = store.addProject(url: Self.home)
            let workspace = store.createWorkspace(name: "Layout fixture", projectIDs: [project.id])
            let spaceID = workspace.spaces[0].id
            for _ in 0..<count { store.addPane(tool: .claude, in: workspace.id, space: spaceID) }
            try await waitUntil { store.runtimes.count == count }
            let host = NSHostingView(rootView: LayoutFixture(store: store, workspaceID: workspace.id, spaceID: spaceID))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer {
                window.contentView = nil
                window.close()
                store.terminateAll()
            }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            let pane = try #require(store.space(spaceID, in: workspace.id)?.panes.first)
            var durations: [Double] = []
            for i in 0..<20 {
                let start = Date()
                store.composer(pane.id).text += "x"
                host.setFrameSize(NSSize(width: i.isMultiple(of: 2) ? 900 : 1200, height: 700))
                host.layoutSubtreeIfNeeded()
                durations.append(Date().timeIntervalSince(start) * 1000)
                try await Task.sleep(for: .milliseconds(15))
            }
            durations.sort()
            print("Idle layout \(count) panes: median=\(durations[10])ms max=\(durations.last!)ms")
            #expect(store.composer(pane.id).text == String(repeating: "x", count: 20))
            #expect(editors(in: host).count == count)
            #expect(editors(in: host).contains { $0.string == String(repeating: "x", count: 20) })
            try await Task.sleep(for: .milliseconds(200))
            for runtime in store.runtimes.values {
                let container = try #require(runtime.view.superview)
                #expect(abs(runtime.view.frame.width - container.bounds.width) < 1)
                #expect(abs(runtime.view.frame.height - container.bounds.height) < 1)
            }
            if count == 4, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("projectn-four-pane-layout.png")
                try bitmap.representation(using: .png, properties: [:])?.write(to: url)
                print("Four-pane layout snapshot: \(url.path)")
            }
        }
    }

    @Test func addingFourthPanePreservesExistingEditors() async throws {
        let store = try makeStore()
        defer { store.terminateAll() }
        let project = store.addProject(url: Self.home)
        let workspace = store.createWorkspace(name: "Stable editors", projectIDs: [project.id])
        let spaceID = workspace.spaces[0].id
        for index in 0..<3 {
            let pane = try #require(store.addPane(tool: .claude, in: workspace.id, space: spaceID))
            store.composer(pane.id).text = "Draft \(index)"
        }
        try await waitUntil { store.runtimes.count == 3 }
        let host = NSHostingView(rootView: LayoutFixture(store: store, workspaceID: workspace.id, spaceID: spaceID))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let original = editors(in: host)
        #expect(original.count == 3)
        for editor in original { editor.setSelectedRange(NSRange(location: 3, length: 0)) }
        store.addPane(tool: .claude, in: workspace.id, space: spaceID)
        try await waitUntil { store.runtimes.count == 4 }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let updated = editors(in: host)
        #expect(updated.count == 4)
        for editor in original {
            #expect(updated.contains { $0 === editor })
            #expect(editor.string.hasPrefix("Draft "))
            #expect(editor.selectedRange().location == 3)
        }
    }

    @Test func repeatedLayoutDoesNotDelayResizeOrRetainReplacedTerminal() async throws {
        let container = TerminalContainer(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let terminal = ResizeCountingView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let initialCount = terminal.resizeCount
        container.attach(terminal)
        for _ in 0..<8 {
            container.layout()
            container.attach(terminal)
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(terminal.frame.size == container.bounds.size)
        #expect(terminal.resizeCount == initialCount + 1)
        let replacement = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        container.attach(replacement)
        #expect(terminal.superview == nil)
        #expect(container.subviews.count == 1)
        container.detach()
        try await Task.sleep(for: .milliseconds(150))
        #expect(replacement.superview == nil)
        #expect(replacement.frame.size == NSSize(width: 800, height: 500))
    }

    private func editors(in view: NSView) -> [PromptInput.InputTextView] {
        (view as? PromptInput.InputTextView).map { [$0] } ?? view.subviews.flatMap { editors(in: $0) }
    }
}

private final class ResizeCountingView: NSView {
    var resizeCount = 0
    override func setFrameSize(_ newSize: NSSize) {
        resizeCount += 1
        super.setFrameSize(newSize)
    }
}

private struct LayoutFixture: View {
    @ObservedObject var store: Store
    let workspaceID: UUID
    let spaceID: UUID

    var body: some View {
        if let workspace = store.workspace(workspaceID), let space = store.space(spaceID, in: workspaceID) {
            PaneGrid(workspace: workspace, space: space, onRename: { _ in })
                .environmentObject(store)
        }
    }
}
