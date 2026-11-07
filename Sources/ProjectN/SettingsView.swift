import AppKit
import SwiftUI

/// Settings shown inside the main window (sidebar lists the sections, the panels area shows one).
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case appearance, accounts, agents, integrations, voice, mcp, tools
        var id: String { rawValue }
        var label: String {
            switch self {
            case .appearance: return "Appearance"
            case .accounts: return "Accounts & Connections"
            case .agents: return "Agents"
            case .integrations: return "Integrations"
            case .voice: return "Voice (NVoice)"
            case .mcp: return "MCP Servers"
            case .tools: return "Tools"
            }
        }
        var symbol: String {
            switch self {
            case .appearance: return "paintpalette"
            case .accounts: return "person.crop.circle"
            case .agents: return "person.2.badge.gearshape"
            case .integrations: return "point.3.connected.trianglepath.dotted"
            case .voice: return "waveform"
            case .mcp: return "puzzlepiece.extension"
            case .tools: return "gearshape"
            }
        }
    }

    let tab: Tab

    var body: some View {
        Group {
            switch tab {
            case .appearance: AppearanceSettingsView()
            case .accounts: AccountsSettingsView()
            case .agents: AgentsSettingsView()
            case .integrations: IntegrationsSettingsView()
            case .voice: VoiceSettingsView()
            case .mcp: MCPServersView()
            case .tools: ToolsSettingsView()
            }
        }
        .frame(maxWidth: 860, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The panels area while Settings is open.
struct SettingsDetailView: View {
    @EnvironmentObject var nav: NavigationModel
    @Environment(\.sidebarVisible) private var sidebarVisible
    @Environment(\.showSidebar) private var showSidebar

    var body: some View {
        let tab = nav.settingsTab ?? .appearance
        VStack(spacing: 0) {
            TopBar(leadingInset: !sidebarVisible) {
                if !sidebarVisible {
                    Button { nav.closeSettings() } label: { Label("Back", systemImage: "chevron.backward") }
                        .buttonStyle(.hover)
                }
                Image(systemName: tab.symbol).foregroundStyle(.secondary)
                Text(tab.label).font(.headline)
                Spacer()
            }
            SettingsView(tab: tab)
                .id(tab)
        }
        .background(Color.appSurface)
    }
}

/// Sidebar while Settings is open: Back + the list of sections.
struct SettingsSidebar: View {
    @EnvironmentObject var nav: NavigationModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Spacer().frame(width: Chrome.trafficLightsWidth)
                Button { nav.closeSettings() } label: {
                    Label("Back", systemImage: "chevron.backward").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.hover)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Back to your workspace (Esc)")
                Spacer()
            }
            .padding(.trailing, 10)
            .frame(height: Chrome.topBarHeight)
            .background(WindowDragArea())
            VStack(alignment: .leading, spacing: 2) {
                Text("SETTINGS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                ForEach(SettingsView.Tab.allCases) { t in
                    SidebarRow(isSelected: nav.settingsTab == t, indent: 0) {
                        Image(systemName: t.symbol).frame(width: 16)
                        Text(t.label).lineLimit(1)
                        Spacer()
                    }
                    .onTapGesture { nav.settingsTab = t }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            Spacer()
        }
        .background(Color.appSidebar)
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Theme").font(.title2.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                    ForEach(AppTheme.all) { t in
                        ThemePreview(theme: t, selected: store.settings.theme == t.id)
                            .onTapGesture { store.settings.theme = t.id }
                            .handCursor()
                    }
                }
                Text("Changes the app (light/dark, accent, surfaces) and every terminal's colors instantly. Claude Code and Codex also have their own theme (/theme in Claude) — pick a light one there when using Daylight.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Terminal").font(.title3.bold())
                HStack {
                    Text("Font size")
                    Slider(value: $store.settings.fontSize, in: 9...24, step: 1).frame(width: 220)
                    Text("\(Int(store.settings.fontSize)) pt").monospacedDigit().foregroundStyle(.secondary)
                }
                Divider()
                Text("Notifications").font(.title3.bold())
                Toggle("Play a sound when a chat needs input or finishes", isOn: $store.settings.notificationSound)
                HStack {
                    Picker("Sound", selection: $store.settings.notificationSoundName) {
                        ForEach(NotificationSound.available, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 220)
                    Button("Preview") { NotificationSound.preview(store.settings.notificationSoundName) }
                }
                .disabled(!store.settings.notificationSound)
            }
            .padding(8)
        }
    }
}

// MARK: - Accounts & connections

struct AccountsSettingsView: View {
    @EnvironmentObject var store: Store
    @StateObject private var model = AccountsModel()
    @State private var authCommand: AuthCommand?
    @State private var newKeyName = ""
    @State private var newKeyValue = ""
    @State private var confirmSignOut: AccountProvider?

    struct AuthCommand: Identifiable {
        let id = UUID()
        let title: String
        let command: String
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Accounts").font(.title2.bold())
                    Spacer()
                    Button { model.refresh(settings: store.settings) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                VStack(spacing: 8) {
                    ForEach(AccountProvider.all) { p in accountRow(p) }
                }
                Divider()
                apiKeys
            }
            .padding(8)
        }
        .onAppear { model.refresh(settings: store.settings) }
        .sheet(item: $authCommand, onDismiss: { model.refresh(settings: store.settings) }) { c in
            AuthTerminalSheet(title: c.title, command: c.command)
        }
        .alert("Sign out of \(confirmSignOut?.name ?? "")?", isPresented: Binding(get: { confirmSignOut != nil }, set: { if !$0 { confirmSignOut = nil } })) {
            Button("Sign Out", role: .destructive) {
                if let p = confirmSignOut, let cmd = p.logoutCommand { authCommand = AuthCommand(title: "Sign out of \(p.name)", command: cmd) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Running panes keep working until restarted.")
        }
    }

    private func accountRow(_ p: AccountProvider) -> some View {
        let status = model.statuses[p.id] ?? .checking
        return HStack(spacing: 12) {
            Image(systemName: p.symbol)
                .font(.title3)
                .foregroundStyle(p.color)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(p.color.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.headline)
                switch status {
                case .checking:
                    Text("Checking…").font(.caption).foregroundStyle(.secondary)
                case .notInstalled:
                    Text("Not installed — \(p.installHint)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                case .signedIn(let account, let detail):
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                        Text([account, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption)
                    }
                case .signedOut:
                    HStack(spacing: 5) {
                        Circle().fill(Color.orange).frame(width: 7, height: 7)
                        Text("Not signed in").font(.caption)
                    }
                case .unknown(let text):
                    Text(text.isEmpty ? "Status unavailable" : text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            switch status {
            case .signedIn:
                if p.logoutCommand != nil {
                    Button("Sign Out…") { confirmSignOut = p }
                }
                Button("Switch Account…") { authCommand = AuthCommand(title: "Sign in to \(p.name)", command: p.loginCommand) }
            case .signedOut, .unknown:
                Button("Sign In…") { authCommand = AuthCommand(title: "Sign in to \(p.name)", command: p.loginCommand) }
                    .buttonStyle(.borderedProminent)
            case .notInstalled:
                Button("Copy Install Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(p.installHint, forType: .string)
                }
            case .checking:
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    // MARK: API keys

    private static let presets = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY", "GITHUB_TOKEN", "OPENROUTER_API_KEY"]

    private var apiKeys: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("API keys & tokens").font(.title3.bold())
            Text("Stored in your macOS Keychain and added to the environment of every pane started from ProjectN.")
                .font(.caption).foregroundStyle(.secondary)
            if store.settings.apiKeyNames.isEmpty {
                Text("No keys yet.").font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(store.settings.apiKeyNames, id: \.self) { name in
                HStack {
                    Image(systemName: "key.fill").foregroundStyle(.secondary)
                    Text(name).font(.callout.monospaced())
                    Text(Secrets.get(name).map(Secrets.masked) ?? "missing").font(.caption.monospaced()).foregroundStyle(.secondary)
                    if name == "ANTHROPIC_API_KEY" {
                        Label("Claude Code will bill this API key instead of your subscription", systemImage: "exclamationmark.triangle")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    if name == "OPENAI_API_KEY" {
                        Label("Codex may use this key instead of your ChatGPT sign-in", systemImage: "exclamationmark.triangle")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        Secrets.delete(name)
                        store.settings.apiKeyNames.removeAll { $0 == name }
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.hover)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
            HStack {
                TextField("NAME", text: $newKeyName)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .frame(width: 210)
                Menu {
                    ForEach(Self.presets.filter { !store.settings.apiKeyNames.contains($0) }, id: \.self) { n in
                        Button(n) { newKeyName = n }
                    }
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().hoverHighlight()
                SecureField("Value", text: $newKeyValue)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    let n = newKeyName.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: " ", with: "_")
                    guard !n.isEmpty, !newKeyValue.isEmpty, Secrets.set(n, value: newKeyValue) else { return }
                    if !store.settings.apiKeyNames.contains(n) { store.settings.apiKeyNames.append(n) }
                    newKeyName = ""; newKeyValue = ""
                }
                .disabled(newKeyName.isEmpty || newKeyValue.isEmpty)
            }
            Text("New and restarted panes pick up changes. MCP servers and their connections are under MCP Servers.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// Runs a CLI sign-in / sign-out flow in a small embedded terminal.
struct AuthTerminalSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let title: String
    let command: String
    @State private var session: TerminalSession?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let s = session, !s.isRunning { Text("Finished").font(.caption).foregroundStyle(.secondary) }
                Button("Done") { session?.terminate(); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ZStack {
                Color.appTerminal
                if let session { TerminalHostView(session: session, focused: true).padding(6) }
            }
            Text("Follow the steps above — a browser window may open to finish signing in.")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .frame(width: 720, height: 460)
        .onAppear {
            guard session == nil else { return }
            let plan = Launcher.commandPlan(command, settings: store.settings)
            session = TerminalSession(id: UUID(), plan: plan, fontSize: store.settings.fontSize)
        }
        .onDisappear { session?.terminate() }
    }
}

// MARK: - MCP

struct MCPServersView: View {
    @State private var servers: [MCPServer] = MCPConfig.load()
    @State private var editing: EditTarget?
    @State private var installPkg = ""
    @StateObject private var installer = NPMInstaller()

    struct EditTarget: Identifiable {
        let id = UUID()
        var server: MCPServer
        var originalName: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MCP Servers").font(.title2.bold())
                    Text("Stored in \(AppHome.mcpFile.path.abbreviatingWithTilde) and passed to every Claude & Codex session launched here.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { editing = EditTarget(server: MCPServer(name: "")) } label: { Label("Add Server", systemImage: "plus") }
            }

            List {
                if servers.isEmpty {
                    Text("No MCP servers yet.").foregroundStyle(.secondary)
                }
                ForEach(servers) { s in
                    HStack {
                        Image(systemName: s.isRemote ? "globe" : "shippingbox").foregroundStyle(Color.appAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).bold()
                            Text(s.summary).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Edit") { editing = EditTarget(server: s, originalName: s.name) }
                        Button(role: .destructive) { MCPConfig.remove(s.name); reload() } label: { Image(systemName: "trash") }
                            .buttonStyle(.hover)
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(minHeight: 160)

            GroupBox("Install an MCP server package (npm) into \(AppHome.mcpDir.path.abbreviatingWithTilde)") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("e.g. @modelcontextprotocol/server-filesystem", text: $installPkg)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(install)
                        Button("Install", action: install).disabled(installPkg.isEmpty || installer.running)
                    }
                    Text("Installed binaries land in mcp/node_modules/.bin, which is on PATH inside every session — so a server's command can be just its bin name.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !installer.log.isEmpty {
                        ScrollView {
                            Text(installer.log).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                        .frame(height: 90)
                        .padding(6)
                        .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(4)
            }

            HStack {
                Button("Open App Folder") { NSWorkspace.shared.open(AppHome.root) }
                Button("Edit mcp.json") { NSWorkspace.shared.open(AppHome.mcpFile) }
                Button("Reload") { reload() }
                Spacer()
            }
        }
        .padding(8)
        .sheet(item: $editing) { target in
            MCPServerEditor(server: target.server, originalName: target.originalName) { reload() }
        }
    }

    private func reload() { servers = MCPConfig.load() }

    private func install() {
        let pkg = installPkg.trimmingCharacters(in: .whitespaces)
        guard !pkg.isEmpty else { return }
        installer.install(pkg)
    }
}

struct MCPServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var server: MCPServer
    let originalName: String?
    let onSave: () -> Void
    @State private var argsText: String
    @State private var envText: String

    init(server: MCPServer, originalName: String?, onSave: @escaping () -> Void) {
        _server = State(initialValue: server)
        self.originalName = originalName
        self.onSave = onSave
        _argsText = State(initialValue: server.args.joined(separator: "\n"))
        _envText = State(initialValue: server.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(originalName == nil ? "Add MCP Server" : "Edit MCP Server").font(.title3.bold())
            Form {
                TextField("Name", text: $server.name)
                Picker("Transport", selection: $server.type) {
                    Text("stdio (local command)").tag("stdio")
                    Text("HTTP").tag("http")
                    Text("SSE").tag("sse")
                }
                if server.isRemote {
                    TextField("URL", text: $server.url)
                } else {
                    TextField("Command", text: $server.command, prompt: Text("npx"))
                    LabeledContent("Arguments\n(one per line)") {
                        TextEditor(text: $argsText).font(.body.monospaced()).frame(height: 70)
                    }
                }
                LabeledContent("Environment\n(KEY=VALUE)") {
                    TextEditor(text: $envText).font(.body.monospaced()).frame(height: 60)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    server.args = argsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    var env: [String: String] = [:]
                    for line in envText.split(separator: "\n") {
                        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                        if parts.count == 2 { env[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1] }
                    }
                    server.env = env
                    server.name = server.name.trimmingCharacters(in: .whitespaces)
                    MCPConfig.upsert(server, replacing: originalName)
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(server.name.trimmingCharacters(in: .whitespaces).isEmpty || (server.isRemote ? server.url.isEmpty : server.command.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

@MainActor
final class NPMInstaller: ObservableObject {
    @Published var log = ""
    @Published var running = false

    func install(_ pkg: String) {
        running = true
        log = "$ npm install --prefix \(AppHome.mcpDir.path.abbreviatingWithTilde) \(pkg)\n"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-i", "-c", "npm install --prefix \(Shell.quote(AppHome.mcpDir.path)) \(Shell.quote(pkg)) 2>&1"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.log += s }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                self?.log += proc.terminationStatus == 0 ? "\n✓ Installed.\n" : "\n✗ npm exited with \(proc.terminationStatus)\n"
                self?.running = false
            }
        }
        do { try p.run() } catch {
            log += "Failed to start: \(error.localizedDescription)\n"
            running = false
        }
    }
}

// MARK: - Tools

struct ToolsSettingsView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Form {
            Section("Claude") {
                TextField("Command", text: $store.settings.claudeCommand)
                TextField("Extra arguments", text: $store.settings.claudeExtraArgs, prompt: Text("e.g. --model opus"))
                Toggle("Pass ProjectN MCP servers (--mcp-config)", isOn: $store.settings.claudeUseAppMCP)
                Toggle("Isolate config in \(AppHome.claudeConfigDir.path.abbreviatingWithTilde) (separate login)", isOn: $store.settings.isolateClaudeConfig)
            }
            Section("Codex") {
                TextField("Command", text: $store.settings.codexCommand)
                TextField("Extra arguments", text: $store.settings.codexExtraArgs, prompt: Text("e.g. -m gpt-5"))
                Toggle("Pass ProjectN MCP servers (-c mcp_servers.*)", isOn: $store.settings.codexUseAppMCP)
                Toggle("Isolate CODEX_HOME in \(AppHome.codexHomeDir.path.abbreviatingWithTilde) (separate login)", isOn: $store.settings.isolateCodexHome)
            }
            Section("Cursor") {
                TextField("Command", text: $store.settings.cursorCommand)
                TextField("Extra arguments", text: $store.settings.cursorExtraArgs, prompt: Text("e.g. --model gpt-5"))
            }
            Section("Terminal") {
                TextField("Shell", text: $store.settings.shell)
            }
            Section {
                Text("Changes apply to sessions started or restarted after saving. Sessions also get PROJECTN_HOME, PROJECTN_WORKSPACE, PROJECTN_PROJECT and PROJECTN_MCP_CONFIG, and \(AppHome.binDir.path.abbreviatingWithTilde) on PATH.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
