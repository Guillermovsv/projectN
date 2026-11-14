import Foundation
import Security

/// Integration credentials (in ~/.projectn/secrets.json under "ProjectN Integrations", see `SecretStore`).
/// Kept apart from `Secrets` on purpose: those are exported into every pane's environment; these never are.
enum IntegrationSecrets {
    private static let service = "ProjectN Integrations"
    static let slackAppToken = "slack.appToken"
    static let slackBotToken = "slack.botToken"

    static func get(_ account: String) -> String? { SecretStore.get(service: service, account: account) }

    @discardableResult
    static func set(_ account: String, value: String) -> Bool { SecretStore.set(service: service, account: account, value: value) }

    static func delete(_ account: String) { SecretStore.delete(service: service, account: account) }
}

/// ~/.projectn/integrations.json — no credentials in here.
struct IntegrationSettings: Codable, Equatable {
    var slack = SlackSettings()

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slack = (try? c.decode(SlackSettings.self, forKey: .slack)) ?? SlackSettings()
    }

    static func load() -> IntegrationSettings { AppHome.load(IntegrationSettings.self, from: AgentStore.integrationsFile) ?? IntegrationSettings() }
    func save() { AppHome.save(self, to: AgentStore.integrationsFile) }
}

struct SlackSettings: Codable, Equatable {
    var enabled = false
    /// Slack member IDs (U…/W…) allowed to give instructions. Empty = nobody.
    var authorizedUsers: [String] = []
    /// Channel IDs (C…/G…) where mentions are accepted. Empty = no channels (DMs only, if allowed).
    var authorizedChannels: [String] = []
    var allowDirectMessages = true
    /// Agent used when the message doesn't name one.
    var defaultAgentID: UUID?
    // Notification preferences.
    var notifyOnStart = true
    var notifyApprovals = true
    var notifyErrors = true
    /// Tell unauthorised users they aren't allowed (otherwise ignore them silently).
    var replyToUnauthorized = true
    /// Replies in a thread under your message (off = straight into the channel / DM).
    var replyInThreads = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SlackSettings()
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        authorizedUsers = (try? c.decode([String].self, forKey: .authorizedUsers)) ?? d.authorizedUsers
        authorizedChannels = (try? c.decode([String].self, forKey: .authorizedChannels)) ?? d.authorizedChannels
        allowDirectMessages = (try? c.decode(Bool.self, forKey: .allowDirectMessages)) ?? d.allowDirectMessages
        defaultAgentID = try? c.decode(UUID.self, forKey: .defaultAgentID)
        notifyOnStart = (try? c.decode(Bool.self, forKey: .notifyOnStart)) ?? d.notifyOnStart
        notifyApprovals = (try? c.decode(Bool.self, forKey: .notifyApprovals)) ?? d.notifyApprovals
        notifyErrors = (try? c.decode(Bool.self, forKey: .notifyErrors)) ?? d.notifyErrors
        replyToUnauthorized = (try? c.decode(Bool.self, forKey: .replyToUnauthorized)) ?? d.replyToUnauthorized
        replyInThreads = (try? c.decode(Bool.self, forKey: .replyInThreads)) ?? d.replyInThreads
    }

    /// Accepts "U123ABC", "<@U123ABC>", "<@U123ABC|name>", "<#C123|general>", commas/newlines.
    static func parseIDs(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",\n ;"))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>@#! \t")) }
            .map { $0.split(separator: "|").first.map(String.init) ?? $0 }
            .filter { !$0.isEmpty }
            .map { $0.uppercased() }
    }
}
