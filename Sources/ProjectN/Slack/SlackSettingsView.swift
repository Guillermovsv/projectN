import AppKit
import SwiftUI

/// Settings → Integrations (currently: Slack).
struct IntegrationsSettingsView: View {
    var body: some View {
        ScrollView { SlackSettingsView().padding(8) }
    }
}

struct SlackSettingsView: View {
    @EnvironmentObject var slack: SlackConnector
    @EnvironmentObject var agents: AgentHarness
    @State private var appToken = ""
    @State private var botToken = ""
    @State private var usersText = ""
    @State private var channelsText = ""
    @State private var showSetup = false
    @State private var hasTokens = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "number.square.fill").font(.title2).foregroundStyle(.purple)
                Text("Slack").font(.title2.bold())
                Spacer()
                Toggle("Enable Slack", isOn: $slack.settings.enabled).toggleStyle(.switch)
            }
            Text("Receives direct messages and @mentions over Slack Socket Mode (an outbound connection — no public server). It only works while ProjectN is open.")
                .font(.callout).foregroundStyle(.secondary)

            statusRow

            GroupBox("Credentials (stored in the macOS Keychain)") {
                VStack(alignment: .leading, spacing: 8) {
                    tokenField("App Token", placeholder: "xapp-…  (App-Level Token, scope connections:write)", text: $appToken)
                    tokenField("Bot Token", placeholder: "xoxb-…  (Bot User OAuth Token)", text: $botToken)
                    HStack {
                        Text(hasTokens ? "Both tokens are saved. Leave a field empty to keep its saved value." : "No tokens saved yet.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if hasTokens {
                            Button("Remove Tokens", role: .destructive) { slack.removeTokens(); refreshTokenState() }
                        }
                        Button("Save Tokens") {
                            slack.saveTokens(appToken: appToken.isEmpty ? nil : appToken, botToken: botToken.isEmpty ? nil : botToken)
                            appToken = ""; botToken = ""
                            refreshTokenState()
                        }
                        .disabled(appToken.isEmpty && botToken.isEmpty)
                    }
                }
                .padding(6)
            }

            GroupBox("Who can give instructions") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Authorized users") {
                        TextField("U0123ABCD, U0456EFGH", text: $usersText).textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Authorized channels") {
                        TextField("C0123ABCD", text: $channelsText).textFieldStyle(.roundedBorder)
                    }
                    Toggle("Allow direct messages to the bot", isOn: $slack.settings.allowDirectMessages)
                    Toggle("Tell unauthorized users they aren't allowed", isOn: $slack.settings.replyToUnauthorized)
                    HStack {
                        Text("Slack IDs, separated by commas. Member ID: profile → ⋮ → Copy member ID. Channel ID: channel name → bottom of About. Nobody is authorized while the list is empty.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Save Access") {
                            slack.settings.authorizedUsers = SlackSettings.parseIDs(usersText)
                            slack.settings.authorizedChannels = SlackSettings.parseIDs(channelsText)
                            loadAccess()
                        }
                        .disabled(SlackSettings.parseIDs(usersText) == slack.settings.authorizedUsers
                                  && SlackSettings.parseIDs(channelsText) == slack.settings.authorizedChannels)
                    }
                }
                .padding(6)
            }

            GroupBox("Routing & notifications") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Default agent", selection: $slack.settings.defaultAgentID) {
                        Text("First enabled agent").tag(UUID?.none)
                        ForEach(agents.profiles) { Text($0.name + ($0.enabled ? "" : " (disabled)")).tag(UUID?.some($0.id)) }
                    }
                    .frame(maxWidth: 420)
                    Text("Used when a message doesn't start with an agent's name (“Project Manager, …”).")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Post when a task is queued or starts", isOn: $slack.settings.notifyOnStart)
                    Toggle("Post approval requests and proposed plans", isOn: $slack.settings.notifyApprovals)
                    Toggle("Post errors, timeouts and cancellations", isOn: $slack.settings.notifyErrors)
                    Toggle("Reply in threads", isOn: $slack.settings.replyInThreads)
                    Text(slack.settings.replyInThreads
                         ? "Replies go in a thread under your message; answer questions and approvals in that thread."
                         : "Replies go straight into the conversation; answer questions and approvals by just writing there.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Results are always posted in the thread of the original message.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AgentSlackChannelsSection()

            DisclosureGroup("How to create and connect the Slack app", isExpanded: $showSetup) { setupGuide }

            if !slack.activity.isEmpty {
                GroupBox("Recent activity") {
                    Text(slack.activity.prefix(30).joined(separator: "\n"))
                        .font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled).padding(4)
                }
            }
        }
        .onAppear { loadAccess(); refreshTokenState() }
    }

    private func loadAccess() {
        usersText = slack.settings.authorizedUsers.joined(separator: ", ")
        channelsText = slack.settings.authorizedChannels.joined(separator: ", ")
    }

    private func refreshTokenState() { hasTokens = slack.hasTokens }

    private func tokenField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        LabeledContent(label) {
            SecureField(placeholder, text: text).textFieldStyle(.roundedBorder).font(.callout.monospaced())
        }
    }

    @ViewBuilder private var statusRow: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 9, height: 9)
            Text("Connection status: \(Text(slack.status.label).fontWeight(.medium))").font(.callout)
            Spacer()
            Button {
                slack.checkConnection()
            } label: {
                if slack.checking { ProgressView().controlSize(.small) } else { Text("Check Connection") }
            }
            .disabled(slack.checking)
            Button("Reconnect") { slack.restart() }.disabled(!slack.settings.enabled)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        if !slack.checks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(slack.checks) { c in
                    Label(c.label, systemImage: c.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(c.ok ? Color.green : Color.red)
                        .font(.callout)
                }
            }
            .padding(.horizontal, 10)
        }
    }

    private var statusColor: Color {
        switch slack.status {
        case .connected: return .green
        case .connecting: return .yellow
        case .off: return .secondary
        case .missingTokens, .error: return .red
        }
    }

    static let manifest = manifest(name: "ProjectN Agents", botName: "ProjectN", description: "Talk to your ProjectN agents")

    /// Socket Mode app manifest; used for the general bot and for each agent's own app.
    static func manifest(name: String, botName: String, description: String) -> String {
        let safe = { (s: String) in s.replacingOccurrences(of: "\"", with: "'") }
        return """
        display_information:
          name: "\(safe(String(name.prefix(35))))"
          description: "\(safe(String(description.prefix(120))))"
        features:
          bot_user:
            display_name: "\(safe(String(botName.prefix(80))))"
            always_online: false
          app_home:
            messages_tab_enabled: true
            messages_tab_read_only_enabled: false
        oauth_config:
          scopes:
            bot:
              - app_mentions:read
              - chat:write
              - im:history
              - im:read
              - channels:history
              - groups:history
              - groups:read
              - groups:write
              - chat:write.customize
        settings:
          event_subscriptions:
            bot_events:
              - app_mention
              - message.im
              - message.channels
              - message.groups
          interactivity:
            is_enabled: true
          org_deploy_enabled: false
          socket_mode_enabled: true
          token_rotation_enabled: false
        """
    }

    private var setupGuide: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                Text("1. Go to api.slack.com/apps → **Create New App** → **From a manifest**, pick your workspace and paste:")
                HStack(alignment: .top) {
                    Text(Self.manifest).font(.caption.monospaced()).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.manifest, forType: .string)
                    }
                }
                Text("2. **Basic Information → App-Level Tokens → Generate Token and Scopes**: add the scope `connections:write`. Copy the `xapp-…` token into *App Token*.")
                Text("3. **Install App** (OAuth & Permissions) → Install to Workspace. Copy the *Bot User OAuth Token* `xoxb-…` into *Bot Token*. Save Tokens.")
                Text("4. Add your Slack member ID under *Authorized users*. For channels: invite the bot (`/invite @ProjectN`) and add the channel ID under *Authorized channels*.")
                Text("Already created the app before? Turn on **Interactivity & Shortcuts** in its settings (no URL needed with Socket Mode) so the Approve / Reject buttons work, then reinstall.")
                Text("5. Press **Check Connection**, then turn on **Enable Slack**. Then DM the bot or mention it: “@ProjectN Project Manager, revisa el proyecto seleccionado, consulta su README y dime qué tareas pendientes identificas”.")
            }
            .font(.callout)
            Text("message.channels / message.groups only let the bot read replies in threads where it's waiting on you (which project, a question, an approval); everything else in a channel needs an @mention.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }
}

/// Each agent's private channel, created by ProjectN's app and signed with the agent's name and emoji.
struct AgentSlackChannelsSection: View {
    @EnvironmentObject var slack: SlackConnector
    @EnvironmentObject var agents: AgentHarness

    var body: some View {
        GroupBox("Agent channels") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Every agent gets its own private channel, named after it (#project-manager…), with you invited. Whatever you write there goes to that agent — no need to mention it — and it answers signed with its name and emoji. Renaming an agent renames its channel. Change the emoji in Settings → Agents → General.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(agents.profiles) { p in
                    HStack(spacing: 10) {
                        AgentAvatar(profile: p, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).fontWeight(.medium)
                            if let err = slack.channelErrors[p.id] {
                                Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                            } else if let name = p.slackChannelName {
                                Text("#\(name) · \(p.slackEmoji)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            } else {
                                Text(p.enabled ? (slack.settings.enabled ? "Channel will be created when Slack connects" : "Slack is off") : "Agent is off — no channel")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let id = p.slackChannelID, let team = slack.teamID {
                            Button("Open in Slack") { NSWorkspace.shared.open(URL(string: "slack://channel?team=\(team)&id=\(id)")!) }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Sync Channels Now") { slack.syncAgentChannels() }
                        .disabled({ if case .connected = slack.status { return false }; return true }())
                }
            }
            .padding(6)
        }
    }
}
