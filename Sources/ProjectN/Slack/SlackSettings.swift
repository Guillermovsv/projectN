import Foundation
import Security

/// Integration credentials in the macOS Keychain (service "ProjectN Integrations").
/// Kept apart from `Secrets` on purpose: those are exported into every pane's environment; these never are.
enum IntegrationSecrets {
    private static let service = "ProjectN Integrations"
    static let slackAppToken = "slack.appToken"
    static let slackBotToken = "slack.botToken"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func set(_ account: String, value: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
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
