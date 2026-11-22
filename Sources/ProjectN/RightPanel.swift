import AppKit
import SwiftUI

/// State of the right-hand panel (Assistant · Files · Activity · Browser). Owned by the app so menu commands can drive it.
@MainActor
final class RightPanelModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case assistant, files, activity, browser
        var id: String { rawValue }
        var label: String {
            switch self {
            case .assistant: return "Assistant"
            case .files: return "Files"
            case .activity: return "Activity"
            case .browser: return "Browser"
            }
        }
        var symbol: String {
            switch self {
            case .assistant: return "circle.hexagongrid.circle"
            case .files: return "folder"
            case .activity: return "waveform.path.ecg"
            case .browser: return "globe"
            }
        }
    }

    @Published var visible: Bool { didSet { UserDefaults.standard.set(visible, forKey: "rightPanelVisible") } }
    @Published var tab: Tab { didSet { UserDefaults.standard.set(tab.rawValue, forKey: "rightPanelTab") } }
    @Published var width: Double { didSet { UserDefaults.standard.set(width, forKey: "rightPanelWidth") } }

    /// One browser per workspace (key: workspace id; nil = the dashboard / no workspace selected).
    private var browsers: [UUID?: BrowserModel] = [:]
    private weak var store: Store?

    /// The browser of the workspace on screen — what the Browser tab shows.
    var browser: BrowserModel { browser(for: store?.state.ui.selectedWorkspaceID) }

    /// The browser that belongs to a workspace, created on first use. Browsers of deleted workspaces are dropped.
    func browser(for workspaceID: UUID?) -> BrowserModel {
        let id = workspaceID.flatMap { id in store?.workspace(id) == nil ? nil : id }
        if let b = browsers[id] { return b }
        if let store {
            for key in browsers.keys where key.map({ store.workspace($0) == nil }) == true {
                browsers.removeValue(forKey: key)?.webView.removeFromSuperview()
            }
        }
        let b = BrowserModel(key: id?.uuidString ?? "home")
        browsers[id] = b
        return b
    }

    /// The workspace currently shown, if any.
    var activeWorkspaceID: UUID? { store?.state.ui.selectedWorkspaceID }

    func attach(_ store: Store) {
        self.store = store
        // Before browsers were per workspace there was one remembered URL: give it to the workspace on screen.
        let d = UserDefaults.standard
        if let old = d.string(forKey: "browserURL") {
            let key = "browserURL.\(store.state.ui.selectedWorkspaceID?.uuidString ?? "home")"
            if d.string(forKey: key) == nil { d.set(old, forKey: key) }
            d.removeObject(forKey: "browserURL")
        }
    }

    init() {
        let d = UserDefaults.standard
        visible = d.object(forKey: "rightPanelVisible") as? Bool ?? false
        tab = Tab(rawValue: d.string(forKey: "rightPanelTab") ?? "") ?? .activity
        width = d.object(forKey: "rightPanelWidth") as? Double ?? 360
    }

    func toggle() { withAnimation(.easeInOut(duration: 0.18)) { visible.toggle() } }

    func show(_ tab: Tab) {
        self.tab = tab
        if !visible { withAnimation(.easeInOut(duration: 0.18)) { visible = true } }
    }

    func open(url: URL) {
        browser.load(url)
        show(.browser)
    }
}

struct RightPanelView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var panel: RightPanelModel
    @EnvironmentObject var assistant: AssistantController

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch panel.tab {
                case .assistant:
                    if assistant.floating { FloatingAssistantNotice() } else { AssistantView() }
                case .files: FileTreeView()
                case .activity: ActivityView()
                case .browser:
                    // A new view per workspace so the old browser is told it's hidden and the new one it's shown.
                    BrowserView(model: panel.browser).id(ObjectIdentifier(panel.browser))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.appWindow)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: panel.tab.symbol).foregroundStyle(.secondary)
            Text(panel.tab.label).font(.headline)
            if panel.tab == .browser, let w = store.selectedWorkspace {
                Text(w.name).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help("Each workspace has its own browser")
            }
            Spacer(minLength: 4)
            Button { panel.toggle() } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                .buttonStyle(ChromeButtonStyle())
                .help("Close panel (⌥⌘0)")
        }
        .padding(.horizontal, 12)
        .frame(height: Chrome.topBarHeight)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Always-visible icon rail on the window's right edge: Assistant · Files · Activity · Browser.
/// Click an icon to open that tab; click the active one again to close the panel.
struct RightRail: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var panel: RightPanelModel
    @EnvironmentObject var assistant: AssistantController

    var body: some View {
        VStack(spacing: 6) {
            Color.clear.frame(height: Chrome.topBarHeight - 6)
                .background(WindowDragArea())
            ForEach(Array(RightPanelModel.Tab.allCases.enumerated()), id: \.element) { i, tab in
                let floats = tab == .assistant && assistant.floating
                RailButton(tab: tab,
                           active: floats ? assistant.floatingVisible : panel.visible && panel.tab == tab,
                           badge: tab == .activity ? store.needsInputCount : 0,
                           shortcut: "⌥⌘\(i + 1)") {
                    if tab == .assistant { assistant.userOpened() }
                    if floats { FloatingAssistant.shared.toggle() }
                    else if panel.visible && panel.tab == tab { panel.toggle() } else { panel.show(tab) }
                }
            }
            Spacer()
            Button { panel.toggle() } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 14))
                    .frame(width: 32, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(inset: -1)
            .foregroundStyle(.secondary)
            .help(panel.visible ? "Hide panel (⌥⌘0)" : "Show panel (⌥⌘0)")
            .padding(.bottom, 10)
        }
        .frame(width: 44)
        .frame(maxHeight: .infinity)
        .background(Color.appSidebar)
        .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1) }
    }
}

private struct RailButton: View {
    let tab: RightPanelModel.Tab
    let active: Bool
    let badge: Int
    let shortcut: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.symbol)
                .font(.system(size: 15, weight: active ? .semibold : .regular))
                .frame(width: 32, height: 32)
                .foregroundStyle(active ? Color.appAccent : (hover ? Color.primary : Color.secondary))
                .background(RoundedRectangle(cornerRadius: 7).fill(active ? Color.appAccent.opacity(0.16) : (hover ? Color.primary.opacity(0.07) : .clear)))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(Capsule().fill(Color.yellow))
                            .offset(x: 4, y: -3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .handCursor()
        .help("\(tab.label) (\(shortcut))" + (badge > 0 ? " — \(badge) need your input" : ""))
    }
}

/// Vertical drag handle used between columns.
struct ColumnResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// +1 when dragging right grows the column (left sidebar), -1 when it shrinks it (right panel).
    let direction: Double
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { v in
                            if start == nil { start = width }
                            width = min(range.upperBound, max(range.lowerBound, (start ?? width) + direction * v.translation.width))
                        }
                        .onEnded { _ in start = nil })
            )
    }
}

/// Right panel › Assistant while the Assistant lives in its floating window.
private struct FloatingAssistantNotice: View {
    @EnvironmentObject var assistant: AssistantController

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "macwindow.on.rectangle").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("The Assistant is in its own floating window.").font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button(assistant.floatingVisible ? "Bring to Front" : "Show Window") { FloatingAssistant.shared.show() }
                Button("Dock Here") { FloatingAssistant.shared.setFloating(false) }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
