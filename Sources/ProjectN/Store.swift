import AppKit
import SwiftUI

@MainActor
final class Store: ObservableObject {
    @Published var state: PersistedState { didSet { scheduleSave() } }
    @Published var settings: AppSettings {
        didSet {
            AppHome.save(settings, to: AppHome.settingsFile)
            applyFontSize()
            if settings.theme != oldValue.theme { applyTheme() }
            if settings.voiceEnabled != oldValue.voiceEnabled || settings.voiceMenuBarIcon != oldValue.voiceMenuBarIcon {
                applyVoice()
            }
        }
    }
    /// Live terminals keyed by Pane.id. They survive switching spaces/workspaces.
    @Published private(set) var runtimes: [UUID: TerminalSession] = [:]
    /// Panes waiting on a prompt. Only this set is published app-wide (working/idle changes are
    /// observed per pane), so the whole window no longer redraws on every activity flicker.
    @Published private(set) var needsInputIDs: Set<UUID> = []
    /// Space ID → the pane currently expanded to fill that space (not persisted).
    @Published var maximizedPanes: [UUID: UUID] = [:]

    func toggleMaximize(_ paneID: UUID, inSpace sid: UUID) {
        if maximizedPanes[sid] == paneID { maximizedPanes[sid] = nil } else { maximizedPanes[sid] = paneID }
    }

    private var saveWork: DispatchWorkItem?
    private var housekeeping: Timer?
    private let launchQueue = DispatchQueue(label: "dev.projectn.launch", qos: .userInitiated)
    private var pendingLaunches: [UUID: UUID] = [:]
    private var pendingMessages: [UUID: [String]] = [:]
    /// Pane ID → first message passed on the command line at its next launch (agent tasks).
    var initialPrompts: [UUID: String] = [:]

    /// What an agent pane gets instead of the app-wide defaults (set by the agent harness).
    struct AgentLaunchContext {
        /// Added to the environment (bridge port + task token, MCP tool timeout…).
        var env: [String: String] = [:]
        /// Only these Keychain API keys are exported (not every key like ordinary panes).
        var apiKeyNames: [String] = []
    }
    var agentLaunchContext: ((Pane) -> AgentLaunchContext)?
    private let discoveryQueue = DispatchQueue(label: "dev.projectn.discovery", qos: .utility)
    private var discoveryInFlight = false
    /// Shared with PromptTracker's Store extension; a slow scan must not queue another.
    var promptRefreshInFlight = false

    init() {
        AppHome.bootstrap()
        state = AppHome.load(PersistedState.self, from: AppHome.stateFile) ?? PersistedState()
        settings = AppHome.load(AppSettings.self, from: AppHome.settingsFile) ?? AppSettings()
        AppHome.save(settings, to: AppHome.settingsFile)
        AppTheme.current = AppTheme.named(settings.theme)
        applyAppAppearance()
        makeLaunchOptionsExplicit()
        // Drop a stale selection.
        if let ws = state.ui.selectedWorkspaceID, let sp = state.ui.selectedSpaceID, space(sp, in: ws) == nil {
            state.ui.selectedWorkspaceID = nil
            state.ui.selectedSpaceID = nil
        }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        housekeeping = t
        let a = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshActivity() }
        }
        RunLoop.main.add(a, forMode: .common)
        activityTimer = a
    }

    private var activityTimer: Timer?

    private func refreshActivity() {
        var waiting = Set<UUID>()
        var alert = false
        for ws in state.workspaces {
            for sp in ws.spaces {
                for p in sp.panes where p.tool != .terminal {
                    guard let rt = runtimes[p.id] else { continue }
                    let before = rt.activity
                    let changed = rt.refreshActivity()
                    if rt.needsInput { waiting.insert(p.id) }
                    guard changed else { continue }
                    switch (before, rt.activity) {
                    case (.needsInput, .needsInput): break
                    // Stopped for input (unless Auto · Complete will answer it).
                    case (_, .needsInput): if !rt.autoComplete { alert = true }
                    // Finished a turn.
                    case (.working, .idle): alert = true
                    default: break
                    }
                }
            }
        }
        if waiting != needsInputIDs { needsInputIDs = waiting }
        if alert { NotificationSound.play(settings) }
    }

    /// One row per Claude/Codex pane, across all workspaces.
    struct AgentEntry: Identifiable {
        var id: UUID { pane.id }
        let workspace: Workspace
        let space: Space
        let pane: Pane
        let runtime: TerminalSession?
    }

    var agents: [AgentEntry] {
        state.workspaces.flatMap { w in
            w.spaces.flatMap { s in
                s.panes.filter { $0.tool != .terminal }.map { AgentEntry(workspace: w, space: s, pane: $0, runtime: runtimes[$0.id]) }
            }
        }
    }

    var needsInputCount: Int { needsInputIDs.count }

    func spaceNeedsInput(_ s: Space) -> Bool {
        s.panes.contains { needsInputIDs.contains($0.id) }
    }

    /// Jump to a pane wherever it lives.
    func reveal(pane id: UUID, in wid: UUID) {
        guard let (s, _) = pane(id, in: wid) else { return }
        selectSpace(s.id, in: wid)
        updateSpace(s.id, in: wid) { $0.focusedPaneID = id }
    }

    /// Set by the Agents view: the selected task's pane / project take the place of the selected space's
    /// (Files panel, "insert path", the project Slack calls "selected"). nil in the Workspaces view.
    @Published var focusOverride: (paneID: UUID?, projectID: UUID)? = nil

    /// The focused pane's runtime in the selected space (for "insert path" etc).
    var focusedRuntime: TerminalSession? {
        if let o = focusOverride { return o.paneID.flatMap { runtimes[$0] } }
        guard let s = selectedSpace, let id = s.focusedPaneID ?? s.panes.first?.id else { return nil }
        return runtimes[id]
    }

    /// The project shown by default in the file tree: the focused pane's, else the workspace's first.
    var focusedProjectID: UUID? {
        if let o = focusOverride { return o.projectID }
        guard let w = selectedWorkspace else { return nil }
        if let s = selectedSpace, let p = s.panes.first(where: { $0.id == s.focusedPaneID }) ?? s.panes.first { return p.projectID }
        return w.projectIDs.first
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func saveNow() {
        AppHome.save(state, to: AppHome.stateFile)
    }

    private var tickCount = 0
    private func tick() {
        tickCount += 1
        discoverCodexSessions()
        refreshLastPrompts()
        if tickCount % 12 == 0 { saveScrollback() }   // every ~60s
    }

    /// Saves terminal panes' output so it can be shown again after relaunch.
    func saveScrollback() {
        for ws in state.workspaces {
            for sp in ws.spaces {
                for pane in sp.panes where pane.tool == .terminal {
                    guard let rt = runtimes[pane.id] else { continue }
                    let text = rt.scrollbackText()
                    try? text.write(to: scrollbackURL(pane.id), atomically: true, encoding: .utf8)
                }
            }
        }
    }

    private func scrollbackURL(_ id: UUID) -> URL {
        AppHome.scrollbackDir.appendingPathComponent("\(id.uuidString).txt")
    }

    // MARK: Projects

    func project(_ id: UUID) -> Project? { state.projects.first { $0.id == id } }

    @discardableResult
    func addProject(url: URL) -> Project {
        let path = url.standardizedFileURL.path
        if let existing = state.projects.first(where: { $0.path == path }) { return existing }
        let p = Project(name: url.lastPathComponent, path: path)
        state.projects.append(p)
        return p
    }

    func pickProjectFolders() -> [Project] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = "Add Project"
        panel.message = "Choose one or more folders to declare as projects"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map { addProject(url: $0) }
    }

    func renameProject(_ id: UUID, to name: String) {
        guard let i = state.projects.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        state.projects[i].name = name
    }

    func removeProject(_ id: UUID) {
        for wi in state.workspaces.indices {
            for si in state.workspaces[wi].spaces.indices {
                for p in state.workspaces[wi].spaces[si].panes where p.projectID == id { discardPane(p.id) }
                state.workspaces[wi].spaces[si].panes.removeAll { $0.projectID == id }
            }
            state.workspaces[wi].projectIDs.removeAll { $0 == id }
        }
        state.projects.removeAll { $0.id == id }
    }

    /// Opens (or creates) a workspace containing just this project.
    func openProject(_ p: Project) {
        if let w = state.workspaces.first(where: { $0.projectIDs == [p.id] }) {
            selectWorkspace(w.id)
        } else {
            let w = createWorkspace(name: p.name, projectIDs: [p.id])
            selectWorkspace(w.id)
        }
    }

    // MARK: Workspaces

    func workspace(_ id: UUID) -> Workspace? { state.workspaces.first { $0.id == id } }

    func updateWorkspace(_ id: UUID, _ mutate: (inout Workspace) -> Void) {
        guard let i = state.workspaces.firstIndex(where: { $0.id == id }) else { return }
        mutate(&state.workspaces[i])
    }

    @discardableResult
    func createWorkspace(name: String, projectIDs: [UUID]) -> Workspace {
        let w = Workspace(name: name.isEmpty ? "Workspace \(state.workspaces.count + 1)" : name, projectIDs: projectIDs)
        state.workspaces.append(w)
        return w
    }

    func deleteWorkspace(_ id: UUID) {
        if let w = workspace(id) { w.spaces.flatMap(\.panes).forEach { discardPane($0.id) } }
        state.workspaces.removeAll { $0.id == id }
        if state.ui.selectedWorkspaceID == id { goHome() }
    }

    func runningCount(in w: Workspace) -> Int {
        w.spaces.flatMap(\.panes).filter { runtimes[$0.id]?.isRunning == true }.count
    }

    func runningCount(in s: Space) -> Int {
        s.panes.filter { runtimes[$0.id]?.isRunning == true }.count
    }

    // MARK: Spaces & selection

    var selectedWorkspace: Workspace? { state.ui.selectedWorkspaceID.flatMap(workspace) }
    var selectedSpace: Space? {
        guard let w = selectedWorkspace, let sid = state.ui.selectedSpaceID else { return nil }
        return w.spaces.first { $0.id == sid }
    }

    func space(_ sid: UUID, in wid: UUID) -> Space? { workspace(wid)?.spaces.first { $0.id == sid } }

    func updateSpace(_ sid: UUID, in wid: UUID, _ mutate: (inout Space) -> Void) {
        updateWorkspace(wid) { w in
            if let i = w.spaces.firstIndex(where: { $0.id == sid }) { mutate(&w.spaces[i]) }
        }
    }

    func selectSpace(_ sid: UUID, in wid: UUID) {
        state.ui.selectedWorkspaceID = wid
        state.ui.selectedSpaceID = sid
        updateWorkspace(wid) { $0.lastOpened = Date(); $0.expanded = true }
    }

    /// Enter a workspace: its most recently used (or first) space.
    func selectWorkspace(_ wid: UUID) {
        guard var w = workspace(wid) else { return }
        if w.spaces.isEmpty {
            let s = Space(name: w.nextSpaceName())
            updateWorkspace(wid) { $0.spaces.append(s) }
            w.spaces = [s]
        }
        let sid = (state.ui.selectedWorkspaceID == wid ? state.ui.selectedSpaceID : nil) ?? w.spaces[0].id
        selectSpace(sid, in: wid)
    }

    func goHome() {
        state.ui.selectedWorkspaceID = nil
        state.ui.selectedSpaceID = nil
    }

    @discardableResult
    func newSpace(in wid: UUID) -> Space? {
        guard let w = workspace(wid) else { return nil }
        let s = Space(name: w.nextSpaceName())
        updateWorkspace(wid) { $0.spaces.append(s) }
        selectSpace(s.id, in: wid)
        return s
    }

    func deleteSpace(_ sid: UUID, in wid: UUID) {
        guard let w = workspace(wid), let idx = w.spaces.firstIndex(where: { $0.id == sid }) else { return }
        w.spaces[idx].panes.forEach { discardPane($0.id) }
        updateWorkspace(wid) { $0.spaces.remove(at: idx) }
        if state.ui.selectedSpaceID == sid {
            if let rest = workspace(wid)?.spaces, !rest.isEmpty {
                selectSpace(rest[min(idx, rest.count - 1)].id, in: wid)
            } else {
                goHome()
            }
        }
    }

    func cycleSpace(_ delta: Int) {
        let all = state.workspaces.flatMap { w in w.spaces.map { (w.id, $0.id) } }
        guard !all.isEmpty else { return }
        let cur = all.firstIndex { $0.1 == state.ui.selectedSpaceID } ?? -1
        let next = all[(cur + delta + all.count) % all.count]
        selectSpace(next.1, in: next.0)
    }

    // MARK: Panes

    func defaultProjectID(in wid: UUID, space sid: UUID) -> UUID? {
        guard let w = workspace(wid) else { return nil }
        let sp = w.spaces.first { $0.id == sid }
        return sp?.panes.first { $0.id == sp?.focusedPaneID }?.projectID ?? sp?.panes.last?.projectID ?? w.projectIDs.first
    }

    @discardableResult
    func addPane(tool: Tool, projectID: UUID? = nil, in wid: UUID, space sid: UUID) -> Pane? {
        guard let sp = space(sid, in: wid), !sp.isFull,
              let pid = projectID ?? defaultProjectID(in: wid, space: sid) else { return nil }
        var pane = Pane(tool: tool, projectID: pid)
        let used = Set(state.workspaces.flatMap { $0.spaces.flatMap { $0.panes.map(paneTitle) } })
        pane.title = PaneNames.pick(avoiding: used)
        switch tool {
        case .claude: pane.launchOptions = LaunchCatalog.explicit(settings.claudeDefaults, tool: .claude, settings: settings)
        case .codex: pane.launchOptions = LaunchCatalog.explicit(settings.codexDefaults, tool: .codex, settings: settings)
        case .cursor: pane.launchOptions = LaunchCatalog.explicit(settings.cursorDefaults, tool: .cursor, settings: settings)
        case .terminal: break
        }
        updateWorkspace(wid) { if !$0.projectIDs.contains(pid) { $0.projectIDs.append(pid) } }
        updateSpace(sid, in: wid) { $0.panes.append(pane); $0.focusedPaneID = pane.id }
        start(pane, in: wid, resume: false)
        return pane
    }

    func pane(_ id: UUID, in wid: UUID) -> (Space, Pane)? {
        guard let w = workspace(wid) else { return nil }
        for s in w.spaces { if let p = s.panes.first(where: { $0.id == id }) { return (s, p) } }
        return nil
    }

    func updatePane(_ id: UUID, in wid: UUID, _ mutate: (inout Pane) -> Void) {
        updateWorkspace(wid) { w in
            for si in w.spaces.indices {
                if let pi = w.spaces[si].panes.firstIndex(where: { $0.id == id }) { mutate(&w.spaces[si].panes[pi]); return }
            }
        }
    }

    /// Starts the pane's process. `resume: true` continues the pane's own conversation if one exists.
    func start(_ pane: Pane, in wid: UUID, resume: Bool) {
        guard let w = workspace(wid), let project = project(pane.projectID) else { return }
        let previous = killRuntime(pane.id)

        var mode: Launcher.SessionMode = .fresh
        switch pane.tool {
        case .claude:
            if resume, let id = pane.claudeSessionID {
                mode = .claudeResume(id: id)
            } else {
                // New conversation bound to this pane (reuse an id that never got a transcript).
                let id = (resume ? pane.claudeSessionID : nil) ?? UUID().uuidString.lowercased()
                if id != pane.claudeSessionID { updatePane(pane.id, in: wid) { $0.claudeSessionID = id } }
                mode = .claudeNew(id: id)
            }
        case .codex:
            if resume, let id = pane.codexSessionID {
                mode = .codexResume(id: id)
            } else if pane.codexSessionID != nil {
                updatePane(pane.id, in: wid) { $0.codexSessionID = nil }
            }
        case .cursor:
            // Resume the pane's chat; a fresh pane gets a new chat id in the background (see below).
            if resume, let id = pane.cursorSessionID { mode = .cursorResume(id: id) }
        case .terminal:
            break
        }

        let options = LaunchCatalog.explicit(pane.launchOptions, tool: pane.tool, settings: settings)
        var settings = self.settings
        var agentEnv: [String: String] = [:]
        if pane.isAgentPane {
            // Agents get their own MCP servers (in agentArgs) and only their own API keys.
            let ctx = agentLaunchContext?(pane) ?? AgentLaunchContext()
            settings.apiKeyNames = ctx.apiKeyNames
            settings.claudeUseAppMCP = false
            settings.codexUseAppMCP = false
            agentEnv = ctx.env
        }
        let requestedMode = mode
        let extraArgs = pane.agentArgs ?? []
        // A first message handed over by the agent harness; consumed by this launch only.
        let initialPrompt = initialPrompts.removeValue(forKey: pane.id)
        let exitMarker = pane.isAgentPane ? AgentStore.exitMarker(pane.id) : nil
        let scrollback = scrollbackURL(pane.id)
        let token = UUID()
        pendingLaunches[pane.id] = token
        // Configuration, transcript lookup, scrollback and Keychain access can all
        // block. Only constructing/attaching the AppKit terminal belongs on main.
        launchQueue.async { [weak self] in
            var mode = requestedMode
            if case .claudeResume(let id) = mode,
               !SessionDiscovery.claudeTranscriptExists(id: id, settings: settings) {
                mode = .claudeNew(id: id)
            }
            var newCursorChat: String?
            if pane.tool == .cursor, case .fresh = mode, let id = LaunchCatalog.createCursorChat(settings: settings) {
                newCursorChat = id
                mode = .cursorResume(id: id)
            }
            let restored = pane.tool == .terminal && resume
                ? try? String(contentsOf: scrollback, encoding: .utf8) : nil
            if let exitMarker { try? FileManager.default.removeItem(at: exitMarker) }
            let plan = Launcher.plan(tool: pane.tool, mode: mode, options: options,
                                     project: project, workspaceName: w.name, settings: settings,
                                     extraArgs: extraArgs, prompt: initialPrompt, exitMarker: exitMarker,
                                     extraEnv: agentEnv)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingLaunches[pane.id] == token,
                      let (_, current) = self.pane(pane.id, in: wid) else { return }
                self.pendingLaunches.removeValue(forKey: pane.id)
                if let newCursorChat { self.updatePane(pane.id, in: wid) { $0.cursorSessionID = newCursorChat } }
                let rt = TerminalSession(id: pane.id, plan: plan, fontSize: self.settings.fontSize,
                                         restoredText: restored, waitFor: previous)
                rt.onExit = { [weak self] _ in self?.objectWillChange.send() }
                rt.setAutoComplete(current.isAutoComplete && pane.tool != .terminal)
                rt.shiftReturnInsertsNewline = pane.tool != .terminal
                self.runtimes[pane.id] = rt
                let messages = self.pendingMessages.removeValue(forKey: pane.id) ?? []
                for (index, message) in messages.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5 + Double(index) * 0.5) { [weak self, weak rt] in
                        guard let self, let rt, self.runtimes[pane.id] === rt, rt.isRunning else { return }
                        if pane.tool == .terminal {
                            rt.send(message.replacingOccurrences(of: "\n", with: " ") + "\r")
                        } else {
                            rt.submit(message)
                        }
                    }
                }
            }
        }
    }

    /// Called when a pane becomes visible: after an app relaunch its process isn't running yet,
    /// so start it and resume its conversation / scrollback.
    func ensureStarted(_ paneID: UUID, in wid: UUID) {
        guard runtimes[paneID] == nil, pendingLaunches[paneID] == nil,
              let (_, p) = pane(paneID, in: wid) else { return }
        start(p, in: wid, resume: true)
    }

    func hasPendingLaunch(_ id: UUID) -> Bool { pendingLaunches[id] != nil }

    func closePane(_ id: UUID, in wid: UUID) {
        discardPane(id)
        updateWorkspace(wid) { w in
            for si in w.spaces.indices {
                guard let idx = w.spaces[si].panes.firstIndex(where: { $0.id == id }) else { continue }
                w.spaces[si].panes.remove(at: idx)
                if w.spaces[si].focusedPaneID == id {
                    let rest = w.spaces[si].panes
                    w.spaces[si].focusedPaneID = rest.isEmpty ? nil : rest[min(idx, rest.count - 1)].id
                }
            }
        }
    }

    func focusPane(_ id: UUID, in wid: UUID) {
        guard let (s, p) = pane(id, in: wid) else { return }
        if p.tool.hasUsageMeter { UserDefaults.standard.set(p.tool.rawValue, forKey: "lastAgentTool") }
        guard s.focusedPaneID != id else { return }
        updateSpace(s.id, in: wid) { $0.focusedPaneID = id }
    }

    func renamePane(_ id: UUID, in wid: UUID, to title: String) {
        updatePane(id, in: wid) { $0.title = title.isEmpty ? nil : title }
    }

    func setAutoComplete(_ on: Bool, pane id: UUID, in wid: UUID) {
        updatePane(id, in: wid) { $0.autoComplete = on }
        runtimes[id]?.setAutoComplete(on)
    }

    /// Change model / effort / permissions. The flags apply at launch, so the pane restarts and resumes its conversation.
    func setLaunchOptions(_ options: LaunchOptions, pane id: UUID, in wid: UUID) {
        guard let (_, stored) = pane(id, in: wid) else { return }
        let current = LaunchCatalog.explicit(stored.launchOptions, tool: stored.tool, settings: settings)
        guard current != options else { return }

        // Claude can switch model and effort inside the running session (/model, /effort) — no restart, no reload.
        if stored.tool == .claude, options.permission == current.permission, let rt = runtimes[id], rt.isRunning {
            updatePane(id, in: wid) { $0.launchOptions = options }
            var commands: [String] = []
            if options.model != current.model, let m = options.model { commands.append("/model \(m)") }
            // Re-assert effort after a model switch too (Claude may apply that model's own effort setting).
            if let e = options.effort, options.effort != current.effort || options.model != current.model { commands.append("/effort \(e)") }
            // Claude's /model and /effort also save themselves as your global default in settings.json.
            // A per-pane change shouldn't do that, so put the previous values back once the commands have run.
            let settingsFile = SessionDiscovery.claudeConfigDir(settings).appendingPathComponent("settings.json")
            let before = try? Data(contentsOf: settingsFile)
            rt.runSlashCommands(commands)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2 * Double(commands.count) + 1.5) {
                Store.restoreClaudeDefaults(file: settingsFile, original: before)
            }
            return
        }

        if runtimes[id]?.activity == .working {
            let alert = NSAlert()
            alert.messageText = "Restart this pane now?"
            alert.informativeText = "\(stored.tool.label) is working. This change needs a restart (the conversation is resumed), which interrupts the current task."
            alert.addButton(withTitle: "Restart")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        updatePane(id, in: wid) { $0.launchOptions = options }
        if let (_, updated) = pane(id, in: wid), runtimes[id] != nil || pendingLaunches[id] != nil {
            start(updated, in: wid, resume: true)
        }
    }

    /// Replace every unset model / effort / permission (panes and new-pane defaults) with concrete values.
    private func makeLaunchOptionsExplicit() {
        let c = LaunchCatalog.explicit(settings.claudeDefaults, tool: .claude, settings: settings)
        let x = LaunchCatalog.explicit(settings.codexDefaults, tool: .codex, settings: settings)
        let k = LaunchCatalog.explicit(settings.cursorDefaults, tool: .cursor, settings: settings)
        if c != settings.claudeDefaults { settings.claudeDefaults = c }
        if x != settings.codexDefaults { settings.codexDefaults = x }
        if k != settings.cursorDefaults { settings.cursorDefaults = k }
        var st = state
        var changed = false
        for wi in st.workspaces.indices {
            for si in st.workspaces[wi].spaces.indices {
                for pi in st.workspaces[wi].spaces[si].panes.indices {
                    let p = st.workspaces[wi].spaces[si].panes[pi]
                    guard p.tool != .terminal else { continue }
                    let e = LaunchCatalog.explicit(p.launchOptions, tool: p.tool, settings: settings)
                    if e != p.launchOptions { st.workspaces[wi].spaces[si].panes[pi].launchOptions = e; changed = true }
                }
            }
        }
        if changed { state = st }
    }

    /// Undo only the model / effort keys Claude wrote ("model", "effortLevel", per-model "modelSettings"); keep any other change.
    nonisolated static func restoreClaudeDefaults(file: URL, original: Data?) {
        guard let original,
              let old = try? JSONSerialization.jsonObject(with: original) as? [String: Any],
              let nowData = try? Data(contentsOf: file),
              var now = try? JSONSerialization.jsonObject(with: nowData) as? [String: Any] else { return }
        let keys = ["model", "effortLevel", "modelSettings"]
        func same(_ a: Any?, _ b: Any?) -> Bool { (a as? NSObject) == (b as? NSObject) }
        guard keys.contains(where: { !same(old[$0], now[$0]) }) else { return }
        var rest = now, oldRest = old
        keys.forEach { rest.removeValue(forKey: $0); oldRest.removeValue(forKey: $0) }
        if NSDictionary(dictionary: rest).isEqual(to: oldRest) {
            try? original.write(to: file, options: .atomic)          // nothing else changed: restore byte-for-byte
        } else {
            for k in keys { now[k] = old[k] }
            if let data = try? JSONSerialization.data(withJSONObject: now, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    func setDefaults(_ options: LaunchOptions, for tool: Tool) {
        switch tool {
        case .claude: settings.claudeDefaults = options
        case .codex: settings.codexDefaults = options
        case .cursor: settings.cursorDefaults = options
        case .terminal: break
        }
    }

    // MARK: Chat box & agent-to-agent messages

    /// Reference to a pane anywhere (panes can message panes in other workspaces).
    struct PaneRef: Hashable {
        let workspaceID: UUID
        let paneID: UUID
    }

    /// Draft state of a pane's chat box. Kept per pane so drafts survive switching spaces.
    final class ComposerState: ObservableObject {
        @Published var text = ""
        @Published var attachments: [URL] = []
        @Published var recipients: [PaneRef] = []
        @Published var hidden = false

        var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty }

        func attach(_ urls: [URL]) {
            for u in urls where !attachments.contains(u) { attachments.append(u) }
        }

        func addRecipient(_ r: PaneRef) {
            if !recipients.contains(r) { recipients.append(r) }
        }
    }

    private var composers: [UUID: ComposerState] = [:]

    func composer(_ paneID: UUID) -> ComposerState {
        if let c = composers[paneID] { return c }
        let c = ComposerState()
        composers[paneID] = c
        return c
    }

    /// Every other pane, for @-mentions: (workspace, space, pane).
    func mentionCandidates(excluding paneID: UUID) -> [(Workspace, Space, Pane)] {
        state.workspaces.flatMap { w in w.spaces.flatMap { s in s.panes.filter { $0.id != paneID }.map { (w, s, $0) } } }
    }

    func paneLocation(_ ref: PaneRef) -> (Workspace, Space, Pane)? {
        guard let w = workspace(ref.workspaceID), let (s, p) = pane(ref.paneID, in: ref.workspaceID) else { return nil }
        return (w, s, p)
    }

    /// Sends the pane's chat box: to the pane itself, or — if agents are tagged — to each tagged pane.
    func sendComposer(paneID: UUID, in wid: UUID) {
        let c = composer(paneID)
        let message = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = c.attachments.map { Shell.quote($0.path) }.joined(separator: " ")
        var body = message
        if !files.isEmpty { body += (body.isEmpty ? "" : "\n\n") + files }
        guard !body.isEmpty else { return }

        if c.recipients.isEmpty {
            updatePane(paneID, in: wid) { $0.lastPrompt = body }
            deliver(body, to: PaneRef(workspaceID: wid, paneID: paneID))
        } else {
            let from = pane(paneID, in: wid).map { "\(paneTitle($0.1)) (\($0.0.name))" } ?? "another agent"
            for r in c.recipients {
                updatePane(r.paneID, in: r.workspaceID) { $0.lastPrompt = body }
                deliver("[Message from \(from), via ProjectN]\n\(body)", to: r)
            }
        }
        c.text = ""
        c.attachments = []
        c.recipients = []
    }

    /// Puts text into a pane's input and submits it. Starts (and resumes) the pane first if needed.
    func deliver(_ text: String, to ref: PaneRef) {
        if let rt = runtimes[ref.paneID], rt.isRunning {
            if paneLocation(ref)?.2.tool == .terminal {
                rt.send(text.replacingOccurrences(of: "\n", with: " ") + "\r")
            } else {
                rt.submit(text)
            }
            return
        }
        guard let (_, _, p) = paneLocation(ref) else { return }
        if pendingLaunches[ref.paneID] == nil { start(p, in: ref.workspaceID, resume: true) }
        pendingMessages[ref.paneID, default: []].append(text)
    }

    /// Writes a pane's recent output to ~/.projectn/handoffs so another agent can read it.
    func writeHandoff(from paneID: UUID, in wid: UUID) -> URL? {
        guard let rt = runtimes[paneID], let (s, p) = pane(paneID, in: wid) else { return nil }
        let normal = rt.scrollbackText(maxLines: 400, kind: .normal)
        let active = rt.scrollbackText(maxLines: 400, kind: .active)
        let output = active.count > normal.count ? active : normal
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(p.tool.rawValue)-\(project(p.projectID)?.name ?? "pane")-\(f.string(from: Date())).md"
            .replacingOccurrences(of: " ", with: "_")
        let url = AppHome.handoffsDir.appendingPathComponent(name)
        let doc = """
        # Handoff from \(paneTitle(p))
        Workspace: \(workspace(wid)?.name ?? "") › \(s.name)
        Project folder: \(project(p.projectID)?.path ?? "")
        Captured: \(Date().formatted(date: .abbreviated, time: .shortened))

        ## Recent terminal output
        ```
        \(output)
        ```
        """
        do { try doc.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }

    /// The agent type whose usage the top bar shows: the focused pane's, else the last agent you focused.
    var activeAgentTool: Tool {
        if let s = selectedSpace, let p = s.panes.first(where: { $0.id == s.focusedPaneID }) ?? s.panes.first, p.tool.hasUsageMeter {
            return p.tool
        }
        if let s = selectedSpace, let p = s.panes.last(where: { $0.tool.hasUsageMeter }), s.focusedPaneID == nil { return p.tool }
        return Tool(rawValue: UserDefaults.standard.string(forKey: "lastAgentTool") ?? "") ?? .claude
    }

    func paneTitle(_ p: Pane) -> String {
        p.title ?? "\(p.tool.label) · \(project(p.projectID)?.name ?? "?")"
    }

    /// Kill the process and forget saved output.
    private func discardPane(_ id: UUID) {
        initialPrompts.removeValue(forKey: id)
        killRuntime(id)
        try? FileManager.default.removeItem(at: scrollbackURL(id))
    }

    /// Stops the pane's process; returns its process groups so a restart can wait for them to exit.
    @discardableResult
    func killRuntime(_ id: UUID) -> [pid_t] {
        pendingLaunches.removeValue(forKey: id)
        pendingMessages.removeValue(forKey: id)
        let groups = runtimes[id]?.terminate() ?? []
        runtimes.removeValue(forKey: id)
        return groups
    }

    /// Before quitting: persist output + state, then stop all processes.
    func terminateAll() {
        pendingLaunches.removeAll()
        pendingMessages.removeAll()
        saveScrollback()
        saveWork?.cancel()
        saveNow()
        runtimes.values.forEach { $0.terminate() }
    }

    // MARK: Codex session discovery

    /// Codex picks its own session id; match new rollout files to running Codex panes by folder + start time.
    private func discoverCodexSessions() {
        guard !discoveryInFlight else { return }
        struct Waiting {
            let workspaceID: UUID
            let paneID: UUID
            let startedAt: Date
            let path: String
        }
        var waiting: [Waiting] = []
        for w in state.workspaces {
            for s in w.spaces {
                for p in s.panes where p.tool == .codex && p.codexSessionID == nil {
                    if let rt = runtimes[p.id], rt.isRunning, let project = project(p.projectID) {
                        waiting.append(Waiting(workspaceID: w.id, paneID: p.id, startedAt: rt.startedAt, path: project.path))
                    }
                }
            }
        }
        guard !waiting.isEmpty else { return }
        let claimed = Set(state.workspaces.flatMap { $0.spaces.flatMap { $0.panes.compactMap(\.codexSessionID) } })
        let jobs = waiting.sorted { $0.startedAt < $1.startedAt }
        let settings = self.settings
        discoveryInFlight = true
        discoveryQueue.async { [weak self] in
            var candidates = SessionDiscovery.codexSessions(since: jobs[0].startedAt, settings: settings)
                .filter { !claimed.contains($0.id) }
            var matches: [(Waiting, String)] = []
            for job in jobs {
                if let idx = candidates.firstIndex(where: {
                    $0.created >= job.startedAt.addingTimeInterval(-3) && SessionDiscovery.samePath($0.cwd, job.path)
                }) {
                    matches.append((job, candidates.remove(at: idx).id))
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.discoveryInFlight = false
                for (job, id) in matches {
                    guard let rt = self.runtimes[job.paneID], rt.isRunning, rt.startedAt == job.startedAt,
                          let (_, pane) = self.pane(job.paneID, in: job.workspaceID), pane.codexSessionID == nil,
                          !self.state.workspaces.contains(where: { $0.spaces.contains { $0.panes.contains { $0.codexSessionID == id } } })
                    else { continue }
                    self.updatePane(job.paneID, in: job.workspaceID) { $0.codexSessionID = id }
                }
            }
        }
    }

    private func applyTheme() {
        AppTheme.current = AppTheme.named(settings.theme)
        applyAppAppearance()
        runtimes.values.forEach { $0.applyTheme(AppTheme.current) }
    }

    private func applyAppAppearance() {
        NSApp?.appearance = NSAppearance(named: AppTheme.current.dark ? .darkAqua : .aqua)
    }

    private func applyFontSize() {
        runtimes.values.forEach { $0.setFontSize(settings.fontSize) }
    }
}

extension Store {
    /// Starts/stops the built-in NVoice dictation to match the settings.
    func applyVoice() {
        NVoiceController.shared.apply(enabled: settings.voiceEnabled, menuBarIcon: settings.voiceMenuBarIcon)
    }
}
