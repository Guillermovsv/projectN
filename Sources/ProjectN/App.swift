import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI installs its own NSApp.delegate, so reach ours through this.
    private(set) static weak var shared: AppDelegate?
    override init() { super.init(); AppDelegate.shared = self }

    var store: Store?
    var agents: AgentHarness?
    /// Set once the user already confirmed (e.g. the updater asked before staging its install script).
    var quitConfirmed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run); harmless inside the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Everything (layout, conversations, terminal output) is saved and restored on next launch, so an
        // idle quit needs no confirmation. Agents mid-turn would be cut off, so ask first (e.g. a stray ⌘Q).
        if !quitConfirmed, !confirmQuitWhileWorking() { return .terminateCancel }
        if let store { MainActor.assumeIsolated { store.terminateAll() } }
        if let agents { MainActor.assumeIsolated { agents.saveNow() } }
        NVoiceController.shared.shutdown()
        return .terminateNow
    }

    /// True when it's fine to quit: nothing is working, or the user confirmed.
    func confirmQuitWhileWorking() -> Bool {
        guard let store else { return true }
        let working = MainActor.assumeIsolated { store.workingPaneTitles }
        guard !working.isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = working.count == 1
            ? "An agent is still working. Quit ProjectN?"
            : "\(working.count) agents are still working. Quit ProjectN?"
        let shown = working.prefix(6).map { "• \($0)" }
        let more = working.count > shown.count ? ["…and \(working.count - shown.count) more"] : []
        alert.informativeText = (shown + more).joined(separator: "\n")
            + "\n\nQuitting stops them mid-task. Conversations are restored on next launch, but the current turn is lost."
        alert.addButton(withTitle: "Cancel")
        let quit = alert.addButton(withTitle: "Quit Anyway")
        quit.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
}

@main
struct ProjectNApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store()
    @StateObject private var panel = RightPanelModel()
    @StateObject private var usage = UsageModel()
    @StateObject private var updates = UpdateModel()
    @StateObject private var nav = NavigationModel()
    @StateObject private var agents = AgentHarness()
    @StateObject private var slack = SlackConnector()
    @StateObject private var assistant = AssistantController()

    var body: some Scene {
        WindowGroup("ProjectN") {
            RootView()
                .environmentObject(store)
                .environmentObject(panel)
                .environmentObject(usage)
                .environmentObject(updates)
                .environmentObject(nav)
                .environmentObject(agents)
                .environmentObject(slack)
                .environmentObject(assistant)
                .frame(minWidth: 960, minHeight: 600)
                .sheet(isPresented: $updates.showWhatsNew) {
                    WhatsNewView().environmentObject(updates)
                }
                .sheet(isPresented: $nav.showAddFromGitHub) {
                    AddFromGitHubSheet()
                        .environmentObject(store)
                        .environmentObject(panel)
                        .environmentObject(nav)
                        .environmentObject(agents)
                }
                .onAppear {
                    delegate.store = store
                    delegate.agents = agents
                    // Agent harness + Slack (Socket Mode) live only while ProjectN runs.
                    panel.attach(store)
                    BrowserAutomation.shared.start(panel: panel)
                    agents.attach(store)
                    slack.attach(store: store, harness: agents)
                    assistant.attach(store: store, harness: agents, panel: panel, nav: nav)
                    FloatingAssistant.shared.configure(assistant: assistant, panel: panel) {
                        AnyView(AssistantView(inWindow: true)
                            .environmentObject(store)
                            .environmentObject(panel)
                            .environmentObject(nav)
                            .environmentObject(agents)
                            .environmentObject(assistant)
                            .frame(minWidth: 290, minHeight: 380))
                    }
                    usage.start(store: store)
                    updates.start()
                    NVoiceController.shared.onOpenSettings = { [weak nav, weak panel] in
                        guard let nav, let panel else { return }
                        nav.openSettings(.voice, panel: panel)
                    }
                    store.applyVoice()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 880)
        .commands { AppCommands(store: store, panel: panel, nav: nav, assistant: assistant) }
    }
}

/// In-app Settings: remembers what you were looking at so Back returns you there.
@MainActor
final class NavigationModel: ObservableObject {
    @Published var settingsTab: SettingsView.Tab?
    /// "Add Project from GitHub…" sheet (menu, ⇧⌘O, sidebar).
    @Published var showAddFromGitHub = false

    /// Workspaces (projects → spaces → panes), Agents (agents → their tasks) or Office (running panes as pixel-art
    /// characters). Remembered across launches.
    enum Mode: String, CaseIterable, Identifiable {
        case workspaces, agents, office
        var id: String { rawValue }
        var label: String {
            switch self {
            case .workspaces: return "Workspaces"
            case .agents: return "Agents"
            case .office: return "Office"
            }
        }
        var symbol: String {
            switch self {
            case .workspaces: return "rectangle.3.group"
            case .agents: return "person.2"
            case .office: return "building.2"
            }
        }
        /// ⌃⌘ + this digit.
        var shortcut: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
    }
    @Published var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .workspaces {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "viewMode") }
    }
    /// Agents view selection.
    @Published var selectedAgentID: UUID? = UUID(uuidString: UserDefaults.standard.string(forKey: "selectedAgentID") ?? "") {
        didSet { UserDefaults.standard.set(selectedAgentID?.uuidString, forKey: "selectedAgentID") }
    }
    /// Task tab per agent (an id that matches no task = the new-task page).
    @Published var selectedTaskByAgent: [UUID: UUID] = [:]
    /// Agents view shows Deliveries (requests agents worked on together) instead of one agent.
    @Published var showDeliveries = false
    @Published var selectedDeliveryID: UUID?
    /// Pane whose terminal floats over the Office.
    @Published var officePaneID: UUID?
    /// Agent to show when Settings → Agents opens.
    @Published var focusAgentInSettings: UUID?

    /// All views stay mounted (RootView hides the inactive ones), so this only cross-fades their opacity:
    /// no rebuilding the pane grid or re-parenting every terminal.
    static let switchDuration: TimeInterval = 0.15

    func switchMode(_ m: Mode) {
        if settingsTab != nil { closeSettings() }
        guard mode != m else { return }
        // Don't leave keyboard focus in a view that's about to be hidden (a terminal or chat box there would
        // keep receiving keystrokes). The newly shown focused pane takes focus again (TerminalHostView).
        NSApp.keyWindow?.makeFirstResponder(nil)
        withAnimation(.easeInOut(duration: Self.switchDuration)) { mode = m }
    }
    private var panelWasVisible = false

    var settingsOpen: Bool { settingsTab != nil }

    func openSettings(_ tab: SettingsView.Tab = .appearance, panel: RightPanelModel) {
        if settingsTab == nil {
            panelWasVisible = panel.visible
            if panel.visible { panel.visible = false }
        }
        withAnimation(.easeInOut(duration: 0.15)) { settingsTab = tab }
    }

    /// Back: the same workspace/space/focused pane (selection is untouched) and the right panel as it was.
    func closeSettings(panel: RightPanelModel? = nil) {
        withAnimation(.easeInOut(duration: 0.15)) { settingsTab = nil }
        if panelWasVisible { (panel ?? restorePanel)?.visible = true }
        panelWasVisible = false
    }

    weak var restorePanel: RightPanelModel?
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var panel: RightPanelModel
    @EnvironmentObject var nav: NavigationModel
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 260
    @AppStorage("sidebarVisible") private var sidebarVisible = true

    /// Narrowest the centre column may get when the right panel is dragged wide.
    private let detailMinWidth: Double = 320

    var body: some View {
        GeometryReader { geo in
            content(maxPanelWidth: maxPanelWidth(windowWidth: geo.size.width))
        }
        .background(Color.appWindow)
        .background(TrafficLightsAligner())
        .preferredColorScheme(AppTheme.current.dark ? .dark : .light)
        .tint(Color.appAccent)
        .ignoresSafeArea()
        .onAppear { nav.restorePanel = panel }
        .environment(\.sidebarVisible, sidebarVisible)
        .environment(\.showSidebar, { withAnimation(.easeInOut(duration: 0.18)) { sidebarVisible = true } })
    }

    /// The right panel can grow leftwards until only `detailMinWidth` is left for the centre column.
    private func maxPanelWidth(windowWidth: Double) -> Double {
        let sidebar = sidebarVisible ? sidebarWidth + 1 : 0
        let rail: Double = 44
        return max(280, windowWidth - sidebar - rail - 1 - detailMinWidth)
    }

    @ViewBuilder
    private func content(maxPanelWidth: Double) -> some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                ZStack {
                    SidebarView(onHide: { withAnimation(.easeInOut(duration: 0.18)) { sidebarVisible = false } })
                        .modeLayer(active: !nav.settingsOpen && nav.mode == .workspaces)
                    AgentsSidebar(onHide: { withAnimation(.easeInOut(duration: 0.18)) { sidebarVisible = false } })
                        .modeLayer(active: !nav.settingsOpen && nav.mode == .agents)
                    OfficeSidebar(onHide: { withAnimation(.easeInOut(duration: 0.18)) { sidebarVisible = false } })
                        .modeLayer(active: !nav.settingsOpen && nav.mode == .office)
                    if nav.settingsOpen { SettingsSidebar() }
                }
                .frame(width: sidebarWidth)
                .transition(.move(edge: .leading))
                ColumnResizeHandle(width: $sidebarWidth, range: 210...420, direction: 1)
            }
            detail
                .frame(minWidth: detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
            if !nav.settingsOpen {
                if panel.visible {
                    ColumnResizeHandle(width: $panel.width, range: 280...maxPanelWidth, direction: -1)
                    RightPanelView()
                        .frame(width: min(panel.width, maxPanelWidth))
                        .transition(.move(edge: .trailing))
                }
                RightRail()
            }
        }
    }

    /// Workspaces, Agents and Office stay mounted; only the active one is shown. Swapping them used to tear down
    /// the whole pane grid (and detach/re-attach every terminal) on each switch, which is what felt laggy.
    private var detail: some View {
        ZStack {
            workspacesDetail
                .modeLayer(active: !nav.settingsOpen && nav.mode == .workspaces)
            AgentsDetailView()
                .modeLayer(active: !nav.settingsOpen && nav.mode == .agents)
            OfficeDetailView()
                .modeLayer(active: !nav.settingsOpen && nav.mode == .office)
            if nav.settingsOpen { SettingsDetailView() }
        }
    }

    @ViewBuilder
    private var workspacesDetail: some View {
        if let w = store.selectedWorkspace, let s = store.selectedSpace {
            SpaceView(workspaceID: w.id, spaceID: s.id)
        } else {
            DashboardView()
        }
    }
}

extension View {
    /// One of the always-mounted top-level views: hidden, inert and without keyboard shortcuts while inactive.
    /// Terminals inside read `modeActive` to hide themselves (no drawing) and give way to the visible view.
    func modeLayer(active: Bool) -> some View {
        self
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .disabled(!active)
            .accessibilityHidden(!active)
            .environment(\.modeActive, active)
    }
}

private struct ModeActiveKey: EnvironmentKey { static let defaultValue = true }
private struct SidebarVisibleKey: EnvironmentKey { static let defaultValue = true }
private struct ShowSidebarKey: EnvironmentKey { static let defaultValue: () -> Void = {} }
extension EnvironmentValues {
    /// false inside the hidden one of Workspaces / Agents (see `modeLayer`).
    var modeActive: Bool {
        get { self[ModeActiveKey.self] }
        set { self[ModeActiveKey.self] = newValue }
    }
    var sidebarVisible: Bool {
        get { self[SidebarVisibleKey.self] }
        set { self[SidebarVisibleKey.self] = newValue }
    }
    var showSidebar: () -> Void {
        get { self[ShowSidebarKey.self] }
        set { self[ShowSidebarKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @ObservedObject var store: Store
    @ObservedObject var panel: RightPanelModel
    @ObservedObject var nav: NavigationModel
    let assistant: AssistantController

    private var current: (Workspace, Space)? {
        guard let w = store.selectedWorkspace, let s = store.selectedSpace else { return nil }
        return (w, s)
    }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { nav.openSettings(.appearance, panel: panel) }
                .keyboardShortcut(",", modifiers: [.command])
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Project Folder…") { _ = store.pickProjectFolders() }
                .keyboardShortcut("o", modifiers: [.command])
            Button("Add Project from GitHub…") { nav.showAddFromGitHub = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button("Workspaces View") { nav.switchMode(.workspaces) }
                .keyboardShortcut("1", modifiers: [.command, .control])
            Button("Agents View") { nav.switchMode(.agents) }
                .keyboardShortcut("2", modifiers: [.command, .control])
            Button("Office View") { nav.switchMode(.office) }
                .keyboardShortcut("3", modifiers: [.command, .control])
            Divider()
            Button(panel.visible ? "Hide Right Panel" : "Show Right Panel") { panel.toggle() }
                .keyboardShortcut("0", modifiers: [.command, .option])
            ForEach(Array(RightPanelModel.Tab.allCases.enumerated()), id: \.element) { i, tab in
                Button("Show \(tab.label)") {
                    if tab == .assistant { assistant.userOpened() }
                    if tab == .assistant && assistant.floating { FloatingAssistant.shared.show() } else { panel.show(tab) }
                }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
            }
            Button("Talk to Assistant") {
                if assistant.floating {
                    if FloatingAssistant.shared.isVisible { assistant.toggleListening() } else {
                        FloatingAssistant.shared.show()
                        assistant.startListening()
                    }
                } else if panel.visible && panel.tab == .assistant { assistant.toggleListening() } else {
                    panel.show(.assistant)
                    assistant.startListening()
                }
            }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Divider()
        }
        CommandGroup(after: .toolbar) {
            Button("Back") { nav.closeSettings(panel: panel) }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(!nav.settingsOpen)
        }
        CommandMenu("Space") {
            Button("Overview") { store.goHome() }
                .keyboardShortcut("0", modifiers: [.command])
            Divider()
            ForEach(Tool.allCases) { tool in
                Button("New \(tool.label) Pane") {
                    if let (w, s) = current { store.addPane(tool: tool, in: w.id, space: s.id) }
                }
                .keyboardShortcut(shortcut(for: tool), modifiers: [.command])
                .disabled(current == nil || current!.1.isFull || current!.0.projectIDs.isEmpty)
            }
            Button("Close Pane") {
                if let (w, s) = current, let p = s.focusedPaneID { store.closePane(p, in: w.id) }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(current?.1.focusedPaneID == nil)
            Divider()
            Button("New Space") { if let (w, _) = current { store.newSpace(in: w.id) } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(current == nil)
            Button("Next Space") { store.cycleSpace(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Space") { store.cycleSpace(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            ForEach(1...Space.maxPanes, id: \.self) { n in
                Button("Focus Pane \(n)") {
                    if let (w, s) = current, s.panes.indices.contains(n - 1) { store.focusPane(s.panes[n - 1].id, in: w.id) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [.command])
            }
        }
    }

    private func shortcut(for tool: Tool) -> KeyEquivalent {
        switch tool {
        case .claude: return "t"
        case .codex: return "y"
        case .cursor: return "i"
        case .terminal: return "u"
        }
    }
}
