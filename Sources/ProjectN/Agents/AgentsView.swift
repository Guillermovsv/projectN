import AppKit
import SwiftUI

// MARK: - Status

/// What an agent is doing right now, for the sidebar and the header.
enum AgentLiveStatus: Equatable {
    case off, needsYou(Int), working(String), queued, idle(String?), failed(String)

    var color: Color {
        switch self {
        case .off: return .secondary.opacity(0.5)
        case .needsYou: return .yellow
        case .working: return .green
        case .queued: return .blue
        case .idle: return .secondary
        case .failed: return .red
        }
    }

    var pill: String {
        switch self {
        case .off: return "Off"
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .queued: return "Queued"
        case .idle: return "Ready"
        case .failed: return "Ready"
        }
    }
}

extension AgentHarness {
    /// This agent's tasks, newest first.
    func tasks(of agentID: UUID) -> [AgentTask] { tasks.filter { $0.agentID == agentID }.reversed() }

    func pendingForUser(agent agentID: UUID) -> [AgentRequest] {
        let ids = Set(tasks.filter { $0.agentID == agentID }.map(\.id))
        return pendingUserRequests().filter { ids.contains($0.taskID) }
    }

    func liveStatus(of p: AgentProfile) -> (status: AgentLiveStatus, line: String) {
        let mine = tasks(of: p.id)
        let waiting = pendingForUser(agent: p.id)
        if !waiting.isEmpty {
            return (.needsYou(waiting.count), waiting[0].kind == .question ? "Asks: \(Self.oneLine(waiting[0].summary))" : "Approve: \(Self.oneLine(waiting[0].summary))")
        }
        let active = mine.filter { $0.status.isActive }
        if !active.isEmpty {
            let projects = Array(Set(active.map(\.projectName))).sorted().joined(separator: ", ")
            return (.working(projects), "Working · \(projects)")
        }
        if mine.contains(where: { $0.status == .queued }) { return (.queued, "Queued") }
        guard p.enabled else { return (.off, "Off") }
        if let (s, next) = nextScheduledRun(of: p.id), next.timeIntervalSinceNow < 36 * 3600 {
            return (.idle(nil), "🗓 \(s.name) · \(next.formatted(date: .omitted, time: .shortened))")
        }
        if let last = mine.first {
            let ago = (last.finishedAt ?? last.createdAt).formatted(.relative(presentation: .named))
            if last.status != .completed { return (.failed(last.status.label), "\(last.status.label) \(ago) · \(last.projectName)") }
            return (.idle(ago), "\(Self.oneLine(last.instruction)) · \(ago)")
        }
        return (.idle(nil), p.role.isEmpty ? "No tasks yet" : p.role)
    }

    static func oneLine(_ s: String, max: Int = 60) -> String {
        let l = s.split(separator: "\n").first.map(String.init) ?? s
        return l.count > max ? String(l.prefix(max)) + "…" : l
    }
}

// MARK: - Avatar

struct AgentAvatar: View {
    let profile: AgentProfile
    var size: CGFloat = 34
    var status: AgentLiveStatus?

    static let palette: [Color] = [
        Color(red: 0.95, green: 0.45, blue: 0.40), Color(red: 0.36, green: 0.62, blue: 0.98), Color(red: 0.40, green: 0.78, blue: 0.55),
        Color(red: 0.96, green: 0.62, blue: 0.27), Color(red: 0.64, green: 0.52, blue: 0.96), Color(red: 0.30, green: 0.74, blue: 0.80),
        Color(red: 0.92, green: 0.45, blue: 0.70), Color(red: 0.78, green: 0.70, blue: 0.35),
    ]

    var color: Color {
        let sum = withUnsafeBytes(of: profile.id.uuid) { $0.reduce(0) { $0 &+ Int($1) } }
        return Self.palette[sum % Self.palette.count]
    }

    var initials: String {
        let words = profile.name.split(separator: " ").prefix(2)
        return words.compactMap(\.first).map(String.init).joined().uppercased()
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(Text(initials).font(.system(size: size * 0.38, weight: .bold, design: .rounded)).foregroundStyle(.white))
            .opacity(profile.enabled ? 1 : 0.45)
            .overlay(alignment: .bottomTrailing) {
                if let status, status != .off {
                    Circle().fill(status.color).frame(width: size * 0.3, height: size * 0.3)
                        .overlay(Circle().stroke(Color.appSidebar, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            }
    }
}

// MARK: - Sidebar

/// Agents view, left: every agent with what it's doing, and its active projects/terminals.
struct AgentsSidebar: View {
    @EnvironmentObject var agents: AgentHarness
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavigationModel
    @EnvironmentObject var panel: RightPanelModel
    var onHide: () -> Void
    @State private var creating = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Spacer().frame(width: Chrome.trafficLightsWidth)
                ViewModeSwitch()
                Spacer()
                Button(action: onHide) { Image(systemName: "sidebar.left") }
                    .buttonStyle(ChromeButtonStyle())
                    .help("Hide sidebar")
                Menu {
                    Button { creating = true } label: { Label("Create with AI…", systemImage: "sparkles") }
                    Button { newAgent() } label: { Label("Blank Agent", systemImage: "plus") }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("New agent")
            }
            .padding(.trailing, 10)
            .frame(height: Chrome.topBarHeight)
            .background(WindowDragArea())

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("AGENTS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        let active = agents.tasks.filter { $0.status.isActive }.count
                        if active > 0 { Text("\(active) working").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    if agents.profiles.isEmpty {
                        Text("No agents yet.").font(.callout).foregroundStyle(.secondary).padding(8)
                    }
                    ForEach(agents.profiles) { p in agentRow(p) }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
            SidebarFooter()
        }
        .background(Color.appSidebar)
        .onAppear { if nav.selectedAgentID.flatMap(agents.profile) == nil { nav.selectedAgentID = agents.profiles.first?.id } }
        .sheet(isPresented: $creating) {
            AgentCreatorSheet(harness: agents, store: store) { id in nav.selectedAgentID = id }
        }
    }

    private func agentRow(_ p: AgentProfile) -> some View {
        let (status, line) = agents.liveStatus(of: p)
        let selected = nav.selectedAgentID == p.id
        let active = agents.tasks(of: p.id).filter { $0.status.isActive || $0.status == .queued }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                AgentAvatar(profile: p, size: selected ? 38 : 32, status: status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.callout.weight(selected ? .semibold : .medium)).lineLimit(1)
                    Text(line).font(.caption)
                        .foregroundStyle({ if case .needsYou = status { return Color.yellow }; return Color.secondary }())
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if case .needsYou(let n) = status { CountBadge(count: n) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, selected ? 9 : 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Color.primary.opacity(0.1) : .clear))
            .contentShape(Rectangle())
            .onTapGesture { nav.selectedAgentID = p.id }
            .contextMenu {
                Button("Edit Agent…") { openSettings(p.id) }
                Button(p.enabled ? "Turn Off" : "Turn On") { var x = p; x.enabled.toggle(); agents.saveProfile(x) }
            }
            // Projects / terminals it's working on.
            ForEach(active.prefix(4)) { t in
                HStack(spacing: 6) {
                    Image(systemName: t.paneID.flatMap { store.runtimes[$0] } != nil ? "terminal" : "folder")
                        .font(.caption).frame(width: 14)
                    Text(t.projectName).font(.caption).lineLimit(1)
                    Text("· \(t.status.label)").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.leading, 50)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    nav.selectedAgentID = p.id
                    nav.selectedTaskByAgent[p.id] = t.id
                }
            }
        }
    }

    private func newAgent() {
        var p = AgentProfile(name: "New Agent", role: "Developer", model: "claude-sonnet-5-5", effort: "medium",
                             instructions: "Describe what this agent does, how it should work and what it must not do.")
        p.sessionPolicy = .perProject
        var n = 2
        while agents.profiles.contains(where: { $0.name == p.name }) { p.name = "New Agent \(n)"; n += 1 }
        agents.saveProfile(p)
        nav.selectedAgentID = p.id
        openSettings(p.id)
    }

    private func openSettings(_ id: UUID) {
        nav.focusAgentInSettings = id
        nav.openSettings(.agents, panel: panel)
    }
}

// MARK: - Detail

/// Agents view, center: the selected agent, its conversations (one per task) as a vertical list, the task's terminal or result, and a message box.
struct AgentsDetailView: View {
    @EnvironmentObject var agents: AgentHarness
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavigationModel
    @EnvironmentObject var panel: RightPanelModel
    @Environment(\.sidebarVisible) private var sidebarVisible
    @Environment(\.showSidebar) private var showSidebar
    @Environment(\.modeActive) private var active

    var body: some View {
        Group {
            if let id = nav.selectedAgentID, let p = agents.profile(id) {
                AgentPage(profile: p)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "person.2").font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text(agents.profiles.isEmpty ? "No agents yet" : "Select an agent").font(.title3)
                    Text("Agents run tasks in your projects — from here or from Slack.").foregroundStyle(.secondary)
                    Button("Agent Settings") { nav.openSettings(.agents, panel: panel) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.appSurface)
        // Stays mounted behind the Workspaces view: hand the Files panel etc. back to the selected space.
        .onChange(of: active) { _, isActive in if !isActive { store.focusOverride = nil } }
        .onDisappear { store.focusOverride = nil }
    }
}

private struct AgentPage: View {
    @EnvironmentObject var agents: AgentHarness
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavigationModel
    @EnvironmentObject var panel: RightPanelModel
    @Environment(\.sidebarVisible) private var sidebarVisible
    @Environment(\.showSidebar) private var showSidebar
    @Environment(\.modeActive) private var active
    @AppStorage("agentChatListWidth") private var chatListWidth: Double = 250
    let profile: AgentProfile

    /// Every conversation (task) of this agent: running ones first, then newest first.
    private var taskList: [AgentTask] {
        let all = agents.tasks(of: profile.id)
        return all.filter { !$0.status.isFinished } + all.filter { $0.status.isFinished }
    }

    private var selectedTask: AgentTask? {
        if let id = nav.selectedTaskByAgent[profile.id] { return agents.task(id) }
        return taskList.first
    }

    var body: some View {
        let (status, _) = agents.liveStatus(of: profile)
        VStack(spacing: 0) {
            TopBar(leadingInset: !sidebarVisible) {
                if !sidebarVisible {
                    Button { showSidebar() } label: { Image(systemName: "sidebar.left") }.buttonStyle(ChromeButtonStyle())
                }
                AgentAvatar(profile: profile, size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(profile.name).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(status.color).frame(width: 7, height: 7)
                    Text(status.pill).font(.caption.weight(.medium))
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                Button {
                    nav.focusAgentInSettings = profile.id
                    nav.openSettings(.agents, panel: panel)
                } label: { Image(systemName: "gearshape") }
                .buttonStyle(ChromeButtonStyle())
                .help("Edit \(profile.name)")
            }
            Divider()
            HStack(spacing: 0) {
                AgentChatList(profile: profile, tasks: taskList, selectedID: selectedTask?.id,
                              onSelect: { nav.selectedTaskByAgent[profile.id] = $0 })
                    .frame(width: chatListWidth)
                ColumnResizeHandle(width: $chatListWidth, range: 190...420, direction: 1)
                conversation
            }
        }
        .onAppear(perform: syncFocus)
        .onChange(of: active) { _, isActive in if isActive { syncFocus() } }
        .onChange(of: selectedTask?.id) { _, _ in syncFocus() }
        .onChange(of: selectedTask?.paneID) { _, _ in syncFocus() }
    }

    /// The selected conversation: its terminal or result, and the message box.
    private var conversation: some View {
        VStack(spacing: 0) {
            if !profile.enabled {
                HStack {
                    Image(systemName: "pause.circle")
                    Text("\(profile.name) is off. Tasks won't start until you turn it on.")
                    Spacer()
                    Button("Turn On") { var x = profile; x.enabled = true; agents.saveProfile(x) }
                }
                .font(.callout).padding(10).background(Color.orange.opacity(0.1))
            }
            Group {
                if let t = selectedTask { AgentTaskView(task: t) } else { newTaskPlaceholder }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            AgentMessageBox(profile: profile, task: selectedTask) { newID in nav.selectedTaskByAgent[profile.id] = newID }
        }
    }

    private var subtitle: String {
        var parts = ["\(profile.runtime.label)", LaunchCatalog.modelLabel(profile.model, tool: profile.runtime.tool)]
        if let e = profile.effort { parts.append(e) }
        parts.append(profile.permission.label)
        if profile.canDelegate { parts.append("delegates") }
        return parts.joined(separator: " · ")
    }

    /// The right panel's Files (and "insert path") follow the selected task.
    private func syncFocus() {
        guard active else { return }
        let wanted: (paneID: UUID?, projectID: UUID)?
        if let t = selectedTask {
            wanted = (t.paneID, t.projectID)
        } else if let pid = store.state.projects.first(where: { profile.mayAccess($0.id) })?.id {
            wanted = (nil, pid)
        } else {
            wanted = nil
        }
        // focusOverride is published app-wide: only touch it when it actually changes.
        if store.focusOverride?.paneID != wanted?.paneID || store.focusOverride?.projectID != wanted?.projectID {
            store.focusOverride = wanted
        }
    }

    private var newTaskPlaceholder: some View {
        VStack(spacing: 10) {
            AgentAvatar(profile: profile, size: 56)
            Text("New task for \(profile.name)").font(.title3.weight(.semibold))
            Text(profile.sessionPolicy == .perProject
                 ? "Messages about a project continue \(profile.name)'s session there (one terminal per project).\nWhat you send while it works reaches it right away."
                 : "Each task starts a new session in the project you pick below.\nIt runs as a pane in the Agents workspace; its terminal shows up here.")
                .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Agents view: the agent's conversations as a vertical chat history (newest first, grouped by day),
/// with "New chat" on top. Each conversation is one task.
private struct AgentChatList: View {
    @EnvironmentObject var agents: AgentHarness
    @EnvironmentObject var store: Store
    let profile: AgentProfile
    let tasks: [AgentTask]
    let selectedID: UUID?
    let onSelect: (UUID) -> Void

    var body: some View {
        // Computed once per render, not once per row.
        let pending = Set(agents.requests.filter(\.isPending).map(\.taskID))
        VStack(spacing: 0) {
            Button { onSelect(UUID()) } label: {   // an id that matches no task = the "new chat" page
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil")
                    Text("New chat")
                    Spacer()
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 10).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selectedID == nil || !tasks.contains { $0.id == selectedID } ? Color.primary.opacity(0.1) : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: 8, inset: 0)
            .padding(8)

            if tasks.isEmpty {
                Text("No conversations yet").font(.callout).foregroundStyle(.secondary).padding(.top, 20)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: []) {
                        ForEach(Self.sections(tasks), id: \.title) { section in
                            Text(section.title)
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 3)
                            ForEach(section.tasks) { t in row(t, pending: pending.contains(t.id)) }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 12)
                }
            }
        }
        .background(Color.appSidebar.opacity(0.5))
    }

    private func row(_ t: AgentTask, pending: Bool) -> some View {
        let selected = t.id == selectedID
        return Button { onSelect(t.id) } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(Self.dotColor(t, pending: pending)).frame(width: 7, height: 7).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if t.depth > 0 { Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.secondary) }
                        if t.origin.kind == .slack { Image(systemName: "number").font(.caption2).foregroundStyle(.secondary) }
                        Text(AgentHarness.oneLine(t.instruction, max: 80).isEmpty ? "(files)" : AgentHarness.oneLine(t.instruction, max: 80))
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                    }
                    Text(Self.detail(t, pending: pending))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.primary.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(t.projectName) · \(t.status.label)\n\(t.instruction)")
        .contextMenu {
            if t.paneID != nil {
                Button(t.status.isFinished ? "Close Session" : "Stop and Close Session") { agents.closeSession(t.id) }
            }
        }
    }

    private static func detail(_ t: AgentTask, pending: Bool) -> String {
        let status = pending ? "Needs you" : (t.status == .completed ? nil : t.status.label)
        let when = (t.finishedAt ?? t.createdAt).formatted(date: .omitted, time: .shortened)
        return [t.projectName, status, when].compactMap { $0 }.joined(separator: " · ")
    }

    static func dotColor(_ t: AgentTask, pending: Bool) -> Color {
        if pending { return .yellow }
        switch t.status {
        case .running, .starting: return .green
        case .needsApproval, .waitingForUser: return .yellow
        case .queued: return .blue
        case .completed: return .secondary.opacity(0.6)
        default: return .red
        }
    }

    struct Section { let title: String; let tasks: [AgentTask] }

    /// Running · Today · Yesterday · Previous 7 days · Older (by when each conversation was last active).
    static func sections(_ tasks: [AgentTask], now: Date = Date(), calendar: Calendar = .current) -> [Section] {
        let live = tasks.filter { !$0.status.isFinished }
        let done = tasks.filter { $0.status.isFinished }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let week = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        func when(_ t: AgentTask) -> Date { t.finishedAt ?? t.createdAt }
        let groups: [(String, [AgentTask])] = [
            ("In progress", live),
            ("Today", done.filter { when($0) >= today }),
            ("Yesterday", done.filter { when($0) >= yesterday && when($0) < today }),
            ("Previous 7 days", done.filter { when($0) >= week && when($0) < yesterday }),
            ("Older", done.filter { when($0) < week }),
        ]
        return groups.filter { !$0.1.isEmpty }.map { Section(title: $0.0, tasks: $0.1) }
    }
}

/// One task: request, pending approvals, then its live terminal or its result.
private struct AgentTaskView: View {
    @EnvironmentObject var agents: AgentHarness
    @EnvironmentObject var store: Store
    let task: AgentTask
    @State private var showResult = false

    var body: some View {
        let runtime = task.paneID.flatMap { store.runtimes[$0] }
        let pending = agents.requests.filter { $0.taskID == task.id && $0.isPending }
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(task.instruction).font(.callout).lineLimit(showResult ? nil : 3).textSelection(.enabled)
                HStack(spacing: 8) {
                    Label(task.projectName, systemImage: "folder")
                    Text(task.origin.label)
                    Text(task.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if let u = task.usage { Text("\(u.outputTokens.formatted()) out tokens") }
                    Spacer()
                    Text(task.status.label).fontWeight(.medium)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))

            ForEach(pending) { r in RequestRow(request: r) }

            if runtime != nil, task.result?.isEmpty == false {
                Picker("", selection: $showResult) {
                    Text("Terminal").tag(false)
                    Text("Result").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            }

            if let runtime, !showResult {
                TerminalHostView(session: runtime, focused: false)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.appTerminal))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultView(runtime: runtime)
            }
        }
        .padding(14)
        .id(task.id)
    }

    @ViewBuilder private func resultView(runtime: TerminalSession?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if task.status == .queued {
                    Label("Waiting to start — the agent is at its concurrency limit, another agent is editing this project, or a task it depends on hasn't finished.",
                          systemImage: "clock").foregroundStyle(.secondary)
                } else if task.status.isActive && runtime == nil {
                    ProgressView("Starting the session…")
                }
                if let r = task.result, !r.isEmpty {
                    Text(Self.markdown(r)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let e = task.error { Text(e).font(.callout.monospaced()).foregroundStyle(.red).textSelection(.enabled) }
                if !task.notes.isEmpty {
                    Text(task.notes.map { "• \($0)" }.joined(separator: "\n")).font(.caption).foregroundStyle(.orange)
                }
                if runtime == nil, let pid = task.paneID, let wid = task.workspaceID, store.pane(pid, in: wid) != nil, task.status.isFinished {
                    Button { store.ensureStarted(pid, in: wid) } label: { Label("Reopen Session", systemImage: "terminal") }
                        .help("Resume this conversation in its pane (approvals then happen in the terminal)")
                }
            }
            .padding(.horizontal, 4)
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Bottom message box: starts a new task, or continues the selected running session.
private struct AgentMessageBox: View {
    @EnvironmentObject var agents: AgentHarness
    @EnvironmentObject var store: Store
    let profile: AgentProfile
    let task: AgentTask?
    let onNewTask: (UUID) -> Void
    @State private var text = ""
    @State private var projectID: UUID?
    @State private var error: String?

    private var liveRuntime: TerminalSession? {
        guard let t = task, t.status.isActive, let p = t.paneID, let rt = store.runtimes[p], rt.isRunning else { return nil }
        return rt
    }

    private var allowed: [Project] { store.state.projects.filter { profile.mayAccess($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error { Label(error, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red) }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(liveRuntime != nil ? "Message \(profile.name) in this session…" : "Message \(profile.name) — starts a new task…")
                        .foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5)
                }
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .font(.body)
                    .frame(minHeight: 40, maxHeight: 110)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if liveRuntime != nil {
                    Label("Continues this session", systemImage: "arrow.uturn.right").font(.caption).foregroundStyle(.secondary)
                } else {
                    Menu {
                        ForEach(allowed) { p in Button(p.name) { projectID = p.id } }
                    } label: {
                        Label(allowed.first { $0.id == projectID }?.name ?? "Choose project", systemImage: "folder")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(allowed.isEmpty)
                }
                Text(LaunchCatalog.modelLabel(profile.model, tool: profile.runtime.tool) + (profile.effort.map { " · \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("⌘↩").font(.caption2).foregroundStyle(.tertiary)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.body.weight(.bold)).frame(width: 30, height: 30)
                        .background(Circle().fill(canSend ? Color.appAccent : Color.primary.opacity(0.1)))
                        .foregroundStyle(canSend ? .white : .secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.appElevated))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08)))
        .padding(.horizontal, 14).padding(.bottom, 14).padding(.top, 4)
        .onAppear(perform: defaultProject)
        .onChange(of: profile.id) { _, _ in defaultProject() }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (liveRuntime != nil || (projectID != nil && profile.enabled))
    }

    private func defaultProject() {
        if let id = projectID, allowed.contains(where: { $0.id == id }) { return }
        projectID = allowed.first { $0.id == task?.projectID }?.id ?? allowed.first?.id
    }

    private func send() {
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }
        error = nil
        if liveRuntime != nil, let t = task {
            // Same path as Slack: answers its open question, or is typed in as soon as the session can take it.
            if let q = t.awaitingAnswer, agents.requests.contains(where: { $0.id == q && $0.isPending }) {
                agents.resolveRequest(q, answer: msg, by: "you (ProjectN)")
            } else {
                agents.deliverMessage(msg, to: t.id)
            }
            text = ""
            return
        }
        guard let pid = projectID else { return }
        switch agents.submit(AgentTaskRequest(agentID: profile.id, projectID: pid, instruction: msg, origin: .local)) {
        case .success(let t):
            text = ""
            onNewTask(t.id)
        case .failure(let e):
            error = e.description
        }
    }
}
