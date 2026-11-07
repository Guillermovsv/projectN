import AppKit
import SwiftUI

/// Settings → Agents: profiles (create / edit / duplicate / delete), task history and the audit log.
struct AgentsSettingsView: View {
    @EnvironmentObject var agents: AgentHarness
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavigationModel
    @State private var section: Section = .profiles
    @State private var selection: UUID?

    enum Section: String, CaseIterable, Identifiable {
        case profiles = "Profiles", tasks = "Tasks", autonomy = "Autonomy", audit = "Audit Log"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 440)
            switch section {
            case .profiles: profiles
            case .tasks: AgentTasksView()
            case .autonomy: AutonomySettingsView()
            case .audit: AuditLogView()
            }
        }
        .padding(8)
        .onAppear {
            if let id = nav.focusAgentInSettings, agents.profile(id) != nil { selection = id; nav.focusAgentInSettings = nil }
            if selection == nil { selection = agents.profiles.first?.id }
        }
    }

    private var profiles: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                List(selection: $selection) {
                    ForEach(agents.profiles) { p in
                        HStack(spacing: 8) {
                            Circle().fill(p.enabled ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(.callout.weight(.medium)).lineLimit(1)
                                Text("\(p.role) · \(p.runtime.label)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .tag(p.id)
                    }
                }
                .frame(minHeight: 260)
                HStack(spacing: 4) {
                    Menu {
                        Button { creatingWithAI = true } label: { Label("Create with AI…", systemImage: "sparkles") }
                        Button { selection = newProfile() } label: { Label("Blank Agent", systemImage: "plus") }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("New agent")
                    Button { selection = selection.flatMap { agents.duplicateProfile($0)?.id } ?? selection } label: {
                        Image(systemName: "plus.square.on.square")
                    }
                    .help("Duplicate").disabled(selection == nil)
                    Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                        .help("Delete").disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.hover)
            }
            .frame(width: 230)
            if let id = selection, let p = agents.profile(id) {
                AgentEditor(profile: p).id(id)
            } else {
                Text("Select or create an agent.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $creatingWithAI) {
            AgentCreatorSheet(harness: agents, store: store) { id in selection = id }
        }
        .alert("Delete \(selection.flatMap { agents.profile($0)?.name } ?? "agent")?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let id = selection { agents.deleteProfile(id); selection = agents.profiles.first?.id }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its running tasks are cancelled. Task history is kept.")
        }
    }

    @State private var confirmDelete = false
    @State private var creatingWithAI = false

    private func newProfile() -> UUID {
        var p = AgentProfile(name: "New Agent", role: "Developer", model: "claude-sonnet-5-5", effort: "medium",
                             instructions: "Describe what this agent does, how it should work and what it must not do.")
        p.sessionPolicy = .perProject
        var n = 2
        while agents.profiles.contains(where: { $0.name == p.name }) { p.name = "New Agent \(n)"; n += 1 }
        agents.saveProfile(p)
        return p.id
    }
}

/// Edits a draft in tabs; nothing changes until Save.
struct AgentEditor: View {
    @EnvironmentObject var agents: AgentHarness
    @EnvironmentObject var store: Store
    @ObservedObject private var catalog = ModelCatalog.shared
    @State private var draft: AgentProfile
    @State private var contextText: String
    @State private var cliText: String
    @State private var runSheet = false
    @State private var tab: EditorTab = .general
    @State private var editingSchedule: AgentSchedule?
    @State private var importingMCP = false
    @State private var claudeMCP: [ClaudeMCPEntry] = []
    private let original: AgentProfile

    enum EditorTab: String, CaseIterable, Identifiable {
        case general = "General", instructions = "Instructions", access = "Access", integrations = "Integrations",
             projects = "Projects", schedules = "Schedules"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: return "person.crop.circle"
            case .instructions: return "text.alignleft"
            case .access: return "lock.shield"
            case .integrations: return "puzzlepiece.extension"
            case .projects: return "folder"
            case .schedules: return "calendar.badge.clock"
            }
        }
    }

    static let rolePresets = ["Project Manager", "Developer", "SEO", "Designer", "Copywriter", "QA / Reviewer", "Analyst"]
    static let emojiPresets: [(String, String)] = [
        (":card_index_dividers:", "🗂️"), (":computer:", "💻"), (":mag:", "🔍"), (":art:", "🎨"), (":pencil2:", "✏️"),
        (":white_check_mark:", "✅"), (":bar_chart:", "📊"), (":mega:", "📣"), (":rocket:", "🚀"), (":robot_face:", "🤖"),
        (":brain:", "🧠"), (":briefcase:", "💼"),
    ]

    init(profile: AgentProfile, initialTab: EditorTab = .general) {
        original = profile
        _draft = State(initialValue: profile)
        _contextText = State(initialValue: profile.contextSources.joined(separator: "\n"))
        _cliText = State(initialValue: profile.cliTools.joined(separator: ", "))
        _tab = State(initialValue: initialTab)
    }

    private var listing: ModelCatalog.Listing { catalog.listing(for: draft.runtime, settings: store.settings) }
    private var selectedModel: ModelCatalog.Model? { listing.models.first { $0.id == draft.model } }
    private var dirty: Bool { normalized != original }
    private var normalized: AgentProfile {
        var p = draft
        p.contextSources = contextText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        p.cliTools = cliText.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init).filter { !$0.isEmpty }
        return p
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(EditorTab.allCases) { t in
                    Button { tab = t } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.symbol).font(.body)
                            Text(t.rawValue).font(.caption)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(tab == t ? Color.primary.opacity(0.1) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(tab == t ? .primary : .secondary)
                    .overlay(alignment: .topTrailing) {
                        if t == .schedules, !draft.schedules.isEmpty {
                            Text("\(draft.schedules.count)").font(.caption2.bold()).padding(.horizontal, 5)
                                .background(Capsule().fill(Color.appAccent)).foregroundStyle(.white).offset(x: -6, y: 2)
                        }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.top, 4)
            Form {
                switch tab {
                case .general: generalTab
                case .instructions: instructionsTab
                case .access: accessTab
                case .integrations: integrationsTab
                case .projects: projectsTab
                case .schedules: schedulesTab
                }
            }
            .formStyle(.grouped)
            HStack {
                Button { runSheet = true } label: { Label("Run Task…", systemImage: "play") }
                    .disabled(dirty || !original.enabled)
                    .help(dirty ? "Save first" : "Run a task locally, without Slack")
                Spacer()
                if dirty { Text("Unsaved changes").font(.caption).foregroundStyle(.secondary) }
                Button("Revert") {
                    draft = original
                    contextText = original.contextSources.joined(separator: "\n")
                    cliText = original.cliTools.joined(separator: ", ")
                }.disabled(!dirty)
                Button("Save") { agents.saveProfile(normalized) }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!dirty || draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.model.isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .sheet(isPresented: $runSheet) { RunTaskSheet(profile: original) }
        .sheet(isPresented: $importingMCP) {
            // Imported servers join ProjectN's list and are switched on for this agent.
            MCPImportSheet { names in for n in names where !draft.mcpServers.contains(n) { draft.mcpServers.append(n) } }
        }
        .sheet(item: $editingSchedule) { s in
            ScheduleEditor(schedule: s, profile: draft) { saved in
                if let i = draft.schedules.firstIndex(where: { $0.id == saved.id }) { draft.schedules[i] = saved } else { draft.schedules.append(saved) }
            }
        }
    }

    // MARK: General

    @ViewBuilder private var generalTab: some View {
        Section {
            Toggle("Enabled", isOn: $draft.enabled)
            TextField("Name", text: $draft.name)
            HStack {
                TextField("Role", text: $draft.role)
                Menu {
                    ForEach(Self.rolePresets, id: \.self) { r in Button(r) { draft.role = r } }
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            HStack {
                TextField("Slack emoji", text: $draft.slackIcon, prompt: Text(draft.slackEmoji))
                    .font(.body.monospaced())
                Menu {
                    ForEach(Self.emojiPresets, id: \.0) { e in Button("\(e.1)  \(e.0)") { draft.slackIcon = e.0 } }
                    Divider()
                    Button("From its role") { draft.slackIcon = "" }
                } label: { Image(systemName: "face.smiling") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        } footer: {
            Text("In Slack it signs as “\(draft.name)” with \(draft.slackEmoji), in its own channel #\(SlackRouter.channelName(for: draft.name)).")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Model") {
            Picker("Provider", selection: $draft.provider) {
                ForEach(AgentProvider.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: draft.provider) { _, p in
                if !draft.runtime.providers.contains(p) { draft.runtime = AgentRuntime.defaultRuntime(for: p) }
            }
            Picker("Runtime", selection: $draft.runtime) {
                ForEach(AgentRuntime.allCases.filter { $0.providers.contains(draft.provider) }) { Text($0.label).tag($0) }
            }
            .onChange(of: draft.runtime) { _, _ in
                if selectedModel == nil, let first = listing.models.first { draft.model = first.id }
            }
            modelRow
            Picker("Reasoning effort", selection: Binding(get: { draft.effort ?? "" }, set: { draft.effort = $0.isEmpty ? nil : $0 })) {
                Text("Model default").tag("")
                ForEach(effortChoices, id: \.self) { Text($0).tag($0) }
            }
            if let e = draft.effort, let m = selectedModel, !m.efforts.contains(e) {
                Label("\(m.label) doesn't support “\(e)”; the model's default is used.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        Section("Sessions & limits") {
            Picker("Session policy", selection: $draft.sessionPolicy) {
                ForEach(SessionPolicy.selectable) { Text($0.label).tag($0) }
                if !SessionPolicy.selectable.contains(draft.sessionPolicy) { Text(draft.sessionPolicy.label).tag(draft.sessionPolicy) }
            }
            Text(draft.sessionPolicy == .perProject
                 ? "Messages about the same project continue one conversation; what you send while it works reaches it right away. Say “sesión nueva” to start over."
                 : "Every message starts a new conversation with no memory of earlier ones.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper("Tasks at the same time: \(draft.concurrencyLimit)", value: $draft.concurrencyLimit, in: 1...8)
            Stepper("Stop a task after \(draft.timeoutMinutes) min", value: $draft.timeoutMinutes, in: 1...240, step: draft.timeoutMinutes < 10 ? 1 : 5)
        }
    }

    // MARK: Instructions

    @ViewBuilder private var instructionsTab: some View {
        Section {
            TextEditor(text: $draft.instructions)
                .font(.body)
                .frame(minHeight: 320)
        } footer: {
            Text("Sent as the agent's system prompt (Claude Code) or as a trusted header (Codex). ProjectN adds its own safety rules after it — deleting, publishing and leaving the project always need your approval.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Access

    @ViewBuilder private var accessTab: some View {
        Section {
            ForEach(AgentPermission.allCases) { level in
                Button {
                    draft.permission = level
                    draft.tools = []   // follow the level's preset
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: draft.permission == level ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(draft.permission == level ? Color.appAccent : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level.label).fontWeight(.medium)
                            Text(level.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("What it may do")
        } footer: {
            Text("Modes that skip approvals are never used for agents.").font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Toggle(isOn: $draft.autoMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto mode").fontWeight(.medium)
                    Text("Works without asking questions or permission: approves its own actions and decides ambiguities itself.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            Picker("Autonomy", selection: $draft.autonomy) {
                ForEach(AgentAutonomy.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(draft.autoMode)
            Text(draft.autoMode ? AgentAutonomy.autoModeDetail : draft.autonomy.detail).font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("How much it asks")
        } footer: {
            Text("Deleting anything, administrator / system changes and secret files (keys, tokens, ~/.ssh…) always ask you, at every level.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if draft.runtime == .claudeCode {
            toolsSection
        } else {
            Section { Text("Codex limits tools through its sandbox, set by the access level.").font(.caption).foregroundStyle(.secondary) }
        }
        Section("Delegation") {
            Toggle("Can delegate to other agents", isOn: $draft.canDelegate)
            Text(draft.canDelegate
                 ? "Can list agents, hand them tasks, follow them, create projects (with your approval), and decide its agents' gray-area approvals and questions. Claude Code only."
                 : "Works on its own. It can still ask whoever gave it the task.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var effectiveTools: [String] { draft.tools.isEmpty ? AgentToolCatalog.preset(for: draft.permission) : draft.tools }

    private var toolsSection: some View {
        let preset = AgentToolCatalog.preset(for: draft.permission)
        let custom = Set(effectiveTools) != Set(preset)
        return Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(AgentToolCatalog.claude, id: \.self) { t in
                    let blocked = draft.permission == .readOnly && AgentToolCatalog.writing.contains(t)
                    Toggle(t, isOn: Binding(
                        get: { effectiveTools.contains(t) },
                        set: { on in
                            var list = effectiveTools
                            if on { if !list.contains(t) { list.append(t) } } else { list.removeAll { $0 == t } }
                            // Back on the preset → store "follow the preset" again.
                            draft.tools = Set(list) == Set(preset) ? [] : AgentToolCatalog.claude.filter(list.contains)
                        }))
                        .toggleStyle(.checkbox)
                        .disabled(blocked)
                        .help(blocked ? "Read-only agents can't change files" : "")
                }
            }
        } header: {
            HStack {
                Text("Tools")
                Spacer()
                if custom {
                    Text("Custom").font(.caption).foregroundStyle(.orange)
                    Button("Reset to “\(draft.permission.label)”") { draft.tools = [] }.font(.caption)
                } else {
                    Text("Preset for “\(draft.permission.label)”").font(.caption).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Ticked automatically for the access level; untick anything you don't want this agent to have. Every use still goes through ProjectN's approval rules.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Integrations

    private func loadClaudeMCP() {
        let projects = store.state.projects.filter { draft.mayAccess($0.id) }.map { (name: $0.name, path: $0.path) }
        claudeMCP = AgentHarness.claudeMCPCatalog(projects: projects)
    }

    @ViewBuilder private var integrationsTab: some View {
        if draft.runtime == .claudeCode {
            Section {
                Toggle("Use Claude Code's MCP servers", isOn: $draft.useClaudeMCP)
                if draft.useClaudeMCP {
                    if claudeMCP.count <= 1 {
                        Text("No MCP servers set up in Claude Code for this agent's projects.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(claudeMCP) { m in
                        Toggle(isOn: Binding(get: { !draft.claudeMCPDisabled.contains(m.name) },
                                             set: { on in
                                                 draft.claudeMCPDisabled.removeAll { $0 == m.name }
                                                 if !on { draft.claudeMCPDisabled.append(m.name) }
                                             })) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(m.name)
                                    Text(m.scopeLabel).font(.caption2).foregroundStyle(.secondary)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                }
                                Text(m.summary).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Claude Code MCP servers")
                    Spacer()
                    if draft.useClaudeMCP, claudeMCP.count > 1 {
                        Button("All on") { draft.claudeMCPDisabled.removeAll { n in claudeMCP.contains { $0.name == n } } }.font(.caption)
                        Button("All off") {
                            draft.claudeMCPDisabled = Array(Set(draft.claudeMCPDisabled + claudeMCP.map(\.name))).sorted()
                        }.font(.caption)
                    }
                }
            } footer: {
                Text("From Claude Code: yours (~/.claude.json, every project) and each project's (~/.claude.json, .mcp.json). Every server adds its tools to each step of the session: turn off the ones this agent doesn't need to save tokens.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onAppear(perform: loadClaudeMCP)
            .onChange(of: draft.allProjects) { _, _ in loadClaudeMCP() }
            .onChange(of: draft.projectIDs) { _, _ in loadClaudeMCP() }
        }
        Section {
            let library = MCPConfig.load()
            if library.isEmpty {
                Text("No MCP servers in ProjectN yet — add them in Settings → MCP Servers.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(library) { m in
                Toggle(isOn: Binding(get: { draft.mcpServers.contains(m.name) },
                                     set: { on in if on { draft.mcpServers.append(m.name) } else { draft.mcpServers.removeAll { $0 == m.name } } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.name)
                        Text(m.summary).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            Button { importingMCP = true } label: { Label("Add from JSON…", systemImage: "curlybraces") }
        } header: { Text("MCP servers") } footer: {
            Text("The checked servers (plus ProjectN's own\(draft.useClaudeMCP && draft.runtime == .claudeCode ? " and the Claude Code ones turned on above" : "")) are loaded for this agent. Tools that read run freely; tools that delete or publish ask you.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            TextField("Commands", text: $cliText, prompt: Text("gh, wp, vercel"))
                .font(.body.monospaced())
        } header: { Text("CLI tools") } footer: {
            Text("Commands this agent may run without asking. Their deleting / publishing subcommands still ask you.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            if store.settings.apiKeyNames.isEmpty {
                Text("No API keys stored (Settings → Accounts & Connections).").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.settings.apiKeyNames, id: \.self) { k in
                Toggle(k, isOn: Binding(get: { draft.apiKeys.contains(k) },
                                        set: { on in if on { draft.apiKeys.append(k) } else { draft.apiKeys.removeAll { $0 == k } } }))
                    .font(.callout.monospaced())
            }
        } header: { Text("API keys") } footer: {
            Text("Only checked keys are in this agent's environment.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Projects

    @ViewBuilder private var projectsTab: some View {
        Section("Where it may work") {
            Toggle("All projects", isOn: $draft.allProjects)
            if !draft.allProjects {
                if store.state.projects.isEmpty { Text("No projects yet.").foregroundStyle(.secondary) }
                ForEach(store.state.projects) { p in
                    Toggle(isOn: Binding(get: { draft.projectIDs.contains(p.id) },
                                         set: { on in if on { draft.projectIDs.append(p.id) } else { draft.projectIDs.removeAll { $0 == p.id } } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name)
                            Text(p.path.abbreviatingWithTilde).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        Section {
            TextEditor(text: $contextText).font(.body.monospaced()).frame(height: 80)
        } header: { Text("Context files read into every new task (one per line)") } footer: {
            Text("Relative to the project folder; files outside it, folders and secret files (.env, keys) are refused. Up to 60 KB in total.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Schedules

    @ViewBuilder private var schedulesTab: some View {
        Section {
            if draft.schedules.isEmpty {
                Text("No schedules. Add one to have \(draft.name) run a task by itself — e.g. a weekly SEO report or a daily inbox triage.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(draft.schedules) { s in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { s.enabled }, set: { on in
                        if let i = draft.schedules.firstIndex(where: { $0.id == s.id }) { draft.schedules[i].enabled = on }
                    }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name).fontWeight(.medium)
                        Text([s.summary, s.projectID.flatMap(store.project)?.name ?? "no project",
                              s.slackTarget.isEmpty ? nil : "→ Slack"].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(nextLine(s)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Run Now") {
                        if let e = agents.runSchedule(s, of: original) { runError = e.description }
                    }
                    .disabled(dirty || !original.schedules.contains { $0.id == s.id } || !original.enabled)
                    .help(dirty ? "Save first" : "Run this schedule's task now")
                    Button("Edit") { editingSchedule = s }
                    Button(role: .destructive) { draft.schedules.removeAll { $0.id == s.id } } label: { Image(systemName: "trash") }
                        .buttonStyle(.hover)
                }
            }
            Button { editingSchedule = newSchedule() } label: { Label("Add Schedule", systemImage: "plus") }
            if let runError { Label(runError, systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption) }
        } header: { Text("Scheduled tasks") } footer: {
            Text("Each run is a new task with the same rules as any other (approvals go to Slack or ProjectN). Schedules run while ProjectN is open; a run missed while it was closed happens once at the next launch if “Run if missed” is on.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @State private var runError: String?

    private func nextLine(_ s: AgentSchedule) -> String {
        var parts: [String] = []
        if !s.enabled || !draft.enabled { parts.append("Paused") }
        else if let n = s.upcoming() { parts.append("Next: " + n.formatted(date: .abbreviated, time: .shortened)) }
        if let l = s.lastRun ?? agents.profile(draft.id)?.schedules.first(where: { $0.id == s.id })?.lastRun {
            parts.append("Last: " + l.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    private func newSchedule() -> AgentSchedule {
        var s = AgentSchedule()
        s.projectID = store.state.projects.first { draft.mayAccess($0.id) }?.id
        return s
    }

    // MARK: Model helpers

    private var effortChoices: [String] {
        if let m = selectedModel { return m.efforts }
        return draft.runtime == .claudeCode ? LaunchCatalog.claudeEfforts : ["low", "medium", "high", "xhigh"]
    }

    @ViewBuilder private var modelRow: some View {
        if draft.provider == .other {
            TextField("Model", text: $draft.model, prompt: Text("model id as the CLI expects it"))
        } else {
            Picker("Model", selection: $draft.model) {
                if selectedModel == nil, !draft.model.isEmpty { Text("\(draft.model) (not available)").tag(draft.model) }
                ForEach(listing.models) { m in Text(m.label == m.id ? m.id : "\(m.label)  ·  \(m.id)").tag(m.id) }
            }
        }
        HStack(spacing: 6) {
            switch listing.source {
            case .live: Label("Live list from your Claude account", systemImage: "checkmark.circle").foregroundStyle(.green)
            case .cache: Label("Cached list from your Claude account", systemImage: "clock")
            case .codexCache: Label("From Codex's model cache", systemImage: "checkmark.circle").foregroundStyle(.green)
            case .builtIn: Label("Built-in list (live list unavailable)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            case .none: Label(listing.error ?? "No models found", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let e = listing.error, listing.source != .none { Text(e).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            if draft.runtime == .claudeCode {
                Button { catalog.refresh() } label: {
                    if catalog.refreshing { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.hover).help("Reload models")
            }
        }
        .font(.caption)
    }
}

/// Add / edit one schedule.
struct ScheduleEditor: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var slack: SlackConnector
    @Environment(\.dismiss) private var dismiss
    @State var schedule: AgentSchedule
    let profile: AgentProfile
    let onSave: (AgentSchedule) -> Void

    private var time: Binding<Date> {
        Binding(get: { Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: Date()) ?? Date() },
                set: { d in
                    schedule.hour = Calendar.current.component(.hour, from: d)
                    schedule.minute = Calendar.current.component(.minute, from: d)
                })
    }

    var body: some View {
        let allowed = store.state.projects.filter { profile.mayAccess($0.id) }
        VStack(alignment: .leading, spacing: 12) {
            Text(schedule.instruction.isEmpty && schedule.name == "New schedule" ? "New Schedule" : "Edit Schedule").font(.title3.bold())
            Form {
                TextField("Name", text: $schedule.name, prompt: Text("Weekly SEO report"))
                Picker("Project", selection: $schedule.projectID) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(allowed) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                Picker("Repeat", selection: $schedule.frequency) {
                    ForEach(AgentSchedule.Frequency.allCases) { Text($0.label).tag($0) }
                }
                if schedule.frequency == .hourly {
                    Stepper("Every \(schedule.everyHours) hours", value: $schedule.everyHours, in: 1...12)
                    Stepper("At minute :\(String(format: "%02d", schedule.minute))", value: $schedule.minute, in: 0...55, step: 5)
                } else {
                    DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                }
                if schedule.frequency == .weekly {
                    HStack(spacing: 4) {
                        ForEach(Array(Calendar.current.veryShortWeekdaySymbols.enumerated()), id: \.offset) { i, sym in
                            let day = i + 1
                            let on = schedule.weekdays.contains(day)
                            Button(sym) {
                                if on { schedule.weekdays.removeAll { $0 == day } } else { schedule.weekdays.append(day) }
                            }
                            .buttonStyle(.plain)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(on ? Color.appAccent : Color.primary.opacity(0.08)))
                            .foregroundStyle(on ? .white : .primary)
                        }
                    }
                }
                LabeledContent("Task") {
                    TextEditor(text: $schedule.instruction).font(.body).frame(height: 110)
                }
                HStack {
                    TextField("Post to Slack", text: $schedule.slackTarget, prompt: Text("channel ID (C…) or member ID — empty: ProjectN only"))
                    if profile.slackChannelID != nil {
                        Button("\(profile.name)'s channel") { schedule.slackTarget = "agent" }
                    }
                    if let me = slack.settings.authorizedUsers.first {
                        Button("Me (DM)") { schedule.slackTarget = me }
                    }
                }
                Toggle("Run if missed (once, when ProjectN opens)", isOn: $schedule.runIfMissed)
                Toggle("Enabled", isOn: $schedule.enabled)
            }
            .formStyle(.grouped)
            if let next = schedule.upcoming() {
                Text("Next run: \(next.formatted(date: .complete, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") {
                    schedule.slackTarget = schedule.slackTarget.trimmingCharacters(in: .whitespaces)
                    onSave(schedule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(schedule.name.trimmingCharacters(in: .whitespaces).isEmpty || schedule.projectID == nil
                          || schedule.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || (schedule.frequency == .weekly && schedule.weekdays.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 560, height: 620)
    }
}

/// Run a task without Slack (also the quickest way to test a profile).
struct RunTaskSheet: View {
    @EnvironmentObject var agents: AgentHarness
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let profile: AgentProfile
    @State private var projectID: UUID?
    @State private var instruction = ""
    @State private var error: String?

    var body: some View {
        let allowed = store.state.projects.filter { profile.mayAccess($0.id) }
        VStack(alignment: .leading, spacing: 12) {
            Text("Run \(profile.name)").font(.title3.bold())
            Picker("Project", selection: $projectID) {
                Text("Choose…").tag(UUID?.none)
                ForEach(allowed) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            Text("Instruction").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $instruction).font(.body).frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            if let error { Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).font(.callout) }
            HStack {
                Text("Starts a new session in the Agents workspace.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Run") {
                    guard let pid = projectID else { return }
                    switch agents.submit(AgentTaskRequest(agentID: profile.id, projectID: pid, instruction: instruction, origin: .local)) {
                    case .success: dismiss()
                    case .failure(let e): error = e.description
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(projectID == nil || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { if projectID == nil { projectID = allowed.first { $0.id == store.focusedProjectID }?.id ?? allowed.first?.id } }
    }
}

/// Task history: status, where it ran, result, usage.
struct AgentTasksView: View {
    @EnvironmentObject var agents: AgentHarness
    @EnvironmentObject var nav: NavigationModel
    @State private var expanded: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(agents.tasks.filter { $0.status.isActive }.count) active · \(agents.tasks.filter { $0.status == .queued }.count) queued · \(agents.tasks.count) total")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Clear Finished") { agents.clearFinishedTasks() }.disabled(!agents.tasks.contains { $0.status.isFinished })
            }
            let pending = agents.requests.filter(\.isPending)
            if !pending.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Waiting on a decision", systemImage: "hand.raised.fill").font(.headline).foregroundStyle(.yellow)
                    ForEach(pending) { r in RequestRow(request: r) }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.08)))
            }
            List {
                if agents.tasks.isEmpty { Text("No tasks yet.").foregroundStyle(.secondary) }
                ForEach(agents.tasks.reversed()) { t in row(t) }
            }
        }
    }

    private func color(_ s: AgentTaskStatus) -> Color {
        switch s {
        case .completed: return .green
        case .running, .starting: return .blue
        case .needsApproval, .waitingForUser: return .yellow
        case .queued: return .secondary
        case .failed, .timedOut: return .red
        case .cancelled, .interrupted: return .orange
        }
    }

    private func row(_ t: AgentTask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(t.status.label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(color(t.status).opacity(0.18)))
                    .foregroundStyle(color(t.status))
                Text("\(t.agentName) → \(t.projectName)").font(.callout.weight(.medium))
                Text(t.depth > 0 ? "↳ " + t.origin.label : t.origin.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(t.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                if t.paneID != nil {
                    Button { agents.reveal(t.id); nav.closeSettings() } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.hover).help("Open the task's pane")
                }
                if !t.status.isFinished {
                    Button { agents.cancel(t.id) } label: { Image(systemName: "stop.circle") }.buttonStyle(.hover).help("Cancel")
                }
            }
            Text(t.instruction).font(.callout).lineLimit(expanded == t.id ? nil : 2)
            HStack(spacing: 10) {
                Text(t.model + (t.effort.map { " · \($0)" } ?? "")).font(.caption.monospaced())
                if let d = t.duration { Text("\(Int(d))s").font(.caption) }
                if let u = t.usage {
                    Text("\(u.outputTokens.formatted()) out · \(u.total.formatted()) total tokens").font(.caption)
                        .help("Input \(u.inputTokens) · output \(u.outputTokens) · cache read \(u.cacheReadTokens) · cache write \(u.cacheWriteTokens)")
                }
                if t.resumedFromTaskID != nil { Text("resumed session").font(.caption) }
            }
            .foregroundStyle(.secondary)
            if expanded == t.id {
                if !t.notes.isEmpty { Text(t.notes.map { "• \($0)" }.joined(separator: "\n")).font(.caption).foregroundStyle(.orange) }
                if let e = t.error { Text(e).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled) }
                if let r = t.result, !r.isEmpty {
                    Text(r).font(.callout).textSelection(.enabled)
                        .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    Button("Copy Result") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(r, forType: .string)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { expanded = expanded == t.id ? nil : t.id }
    }
}

struct AuditLogView: View {
    @State private var lines: [String] = AuditLog.readRecent()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Newest first. \(AgentStore.auditFile.path.abbreviatingWithTilde) — tokens are never written here.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AgentStore.auditFile]) }
                Button { lines = AuditLog.readRecent() } label: { Image(systemName: "arrow.clockwise") }
            }
            ScrollView {
                Text(lines.isEmpty ? "Nothing logged yet." : lines.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        }
    }
}

/// One pending approval / question, decided here (same effect as the Slack buttons).
struct RequestRow: View {
    @EnvironmentObject var agents: AgentHarness
    let request: AgentRequest
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: request.kind == .approval ? "lock.shield" : "questionmark.bubble")
                Text(request.agentName).font(.callout.weight(.semibold))
                Text(request.route == .user ? "asks you" : "asks its orchestrator").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(request.createdAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Text(request.summary).font(request.kind == .approval ? .callout.monospaced() : .callout).textSelection(.enabled)
            Text(request.reason).font(.caption).foregroundStyle(.secondary)
            HStack {
                if request.kind == .question {
                    TextField("Answer", text: $answer).textFieldStyle(.roundedBorder)
                        .onSubmit { send() }
                    Button("Send") { send() }.disabled(answer.isEmpty)
                } else {
                    Spacer()
                    Button("Deny", role: .destructive) { agents.resolveRequest(request.id, approve: false, by: "you (ProjectN)") }
                    Button("Approve") { agents.resolveRequest(request.id, approve: true, by: "you (ProjectN)") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    private func send() {
        guard !answer.isEmpty else { return }
        agents.resolveRequest(request.id, answer: answer, by: "you (ProjectN)")
    }
}

/// Settings → Agents → Autonomy: who decides what.
struct AutonomySettingsView: View {
    @EnvironmentObject var agents: AgentHarness

    var body: some View {
        let binding = Binding(get: { agents.policy }, set: { agents.savePolicy($0) })
        Form {
            Section("Who decides") {
                tierRow("checkmark.circle", .green, "Automatic",
                        "Reading the project, editing it (agents allowed to edit), builds/tests/lint, the agent's own CLI tools, MCP tools that only read.")
                tierRow("person.2.circle", .blue, "Gray area",
                        "Other commands, web fetches, MCP tools that change things. Decided by:")
                Picker("Gray area decided by", selection: binding.grayApprover) {
                    ForEach(AgentPolicy.GrayApprover.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("The orchestrator is the agent that delegated the task. Tasks you start directly have none, so their gray-area actions come to you.")
                    .font(.caption).foregroundStyle(.secondary)
                tierRow("hand.raised.circle", .orange, "Always you",
                        "Deleting anything (files, folders, branches, packages, records, posts — inside the project too), publishing, deploying, pushing, sending, anything outside the project folder, sudo and system changes.")
            }
            Section("New projects") {
                Toggle("Allow creating projects", isOn: binding.allowProjectCreation)
                HStack {
                    Text("Projects folder")
                    Spacer()
                    Text(agents.projectsFolder.abbreviatingWithTilde).font(.callout.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        panel.directoryURL = URL(fileURLWithPath: agents.projectsFolder)
                        panel.prompt = "Use for New Projects"
                        if panel.runModal() == .OK, let url = panel.url { binding.wrappedValue.newProjectsFolder = url.path }
                    }
                    if !agents.policy.newProjectsFolder.isEmpty {
                        Button("Automatic") { binding.wrappedValue.newProjectsFolder = "" }
                    }
                }
                .disabled(!agents.policy.allowProjectCreation)
                Text("“Project Manager, crea el proyecto Landing García y …” in Slack creates the folder (with a README) right away, since you asked. When an agent wants a new project, you approve it first. Folders are only created here, never replaced.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Limits") {
                Stepper("Delegation depth: \(agents.policy.maxDelegationDepth)", value: binding.maxDelegationDepth, in: 1...3)
                Text("1: only agents you message delegate. 2: their delegates may delegate once more.").font(.caption).foregroundStyle(.secondary)
                Stepper("Max delegated tasks per request: \(agents.policy.maxTasksPerRequest)", value: binding.maxTasksPerRequest, in: 1...50)
                Stepper("Approvals & questions expire after \(agents.policy.requestTimeoutMinutes) min", value: binding.requestTimeoutMinutes, in: 5...480, step: 5)
                Stepper("Project sessions start fresh after \(agents.policy.sessionIdleHours) h unused", value: binding.sessionIdleHours, in: 1...168)
                Stepper("…or once their conversation passes \(agents.policy.maxSessionContextK)k tokens (saves tokens)", value: binding.maxSessionContextK, in: 40...400, step: 20)
                Stepper("Stop an idle session's process after \(agents.policy.idleCloseMinutes) min", value: binding.idleCloseMinutes, in: 5...240, step: 5)
                Stepper("Idle sessions kept running per agent: \(agents.policy.maxIdleSessionsPerAgent)", value: binding.maxIdleSessionsPerAgent, in: 1...8)
                Text("A stopped session keeps its terminal and conversation: the next message resumes it.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Unanswered approvals count as “no”; unanswered questions tell the agent to continue with the safest assumption.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Enforced by ProjectN for Claude Code agents (every tool call passes a PreToolUse hook), not by the prompt. Codex agents use Codex's own sandbox and prompts in their pane.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func tierRow(_ icon: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
