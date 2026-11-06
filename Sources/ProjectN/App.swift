import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: Store?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run); harmless inside the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Everything (layout, conversations, terminal output) is saved and restored on next launch,
        // so quitting doesn't need a confirmation.
        if let store { MainActor.assumeIsolated { store.terminateAll() } }
        NVoiceController.shared.shutdown()
        return .terminateNow
    }
}

@main
struct ProjectNApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store()
    @StateObject private var panel = RightPanelModel()
    @StateObject private var usage = UsageModel()
    @StateObject private var nav = NavigationModel()

    var body: some Scene {
        WindowGroup("ProjectN") {
            RootView()
                .environmentObject(store)
                .environmentObject(panel)
                .environmentObject(usage)
                .environmentObject(nav)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear {
                    delegate.store = store
                    usage.start(store: store)
                    NVoiceController.shared.onOpenSettings = { [weak nav, weak panel] in
                        guard let nav, let panel else { return }
                        nav.openSettings(.voice, panel: panel)
                    }
                    store.applyVoice()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 880)
        .commands { AppCommands(store: store, panel: panel, nav: nav) }
    }
}

/// In-app Settings: remembers what you were looking at so Back returns you there.
@MainActor
final class NavigationModel: ObservableObject {
    @Published var settingsTab: SettingsView.Tab?
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

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                Group {
                    if nav.settingsOpen {
                        SettingsSidebar()
                    } else {
                        SidebarView(onHide: { withAnimation(.easeInOut(duration: 0.18)) { sidebarVisible = false } })
                    }
                }
                .frame(width: sidebarWidth)
                .transition(.move(edge: .leading))
                ColumnResizeHandle(width: $sidebarWidth, range: 210...420, direction: 1)
            }
            detail
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            if !nav.settingsOpen {
                if panel.visible {
                    ColumnResizeHandle(width: $panel.width, range: 280...900, direction: -1)
                    RightPanelView()
                        .frame(width: panel.width)
                        .transition(.move(edge: .trailing))
                }
                RightRail()
            }
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

    @ViewBuilder
    private var detail: some View {
        if nav.settingsOpen {
            SettingsDetailView()
        } else if let w = store.selectedWorkspace, let s = store.selectedSpace {
            SpaceView(workspaceID: w.id, spaceID: s.id)
        } else {
            DashboardView()
        }
    }
}

private struct SidebarVisibleKey: EnvironmentKey { static let defaultValue = true }
private struct ShowSidebarKey: EnvironmentKey { static let defaultValue: () -> Void = {} }
extension EnvironmentValues {
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
        }
        CommandGroup(after: .sidebar) {
            Button(panel.visible ? "Hide Right Panel" : "Show Right Panel") { panel.toggle() }
                .keyboardShortcut("0", modifiers: [.command, .option])
            ForEach(Array(RightPanelModel.Tab.allCases.enumerated()), id: \.element) { i, tab in
                Button("Show \(tab.label)") { panel.show(tab) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
            }
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
        case .terminal: return "u"
        }
    }
}
