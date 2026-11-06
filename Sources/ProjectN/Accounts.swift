import Foundation
import Security
import SwiftUI

/// API keys / tokens stored in the macOS Keychain (service "ProjectN API Keys") and exported to sessions.
enum Secrets {
    private static let service = "ProjectN API Keys"

    static func get(_ name: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: name, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func set(_ name: String, value: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ name: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
        SecItemDelete(q as CFDictionary)
    }

    /// NAME=value pairs for every stored key (added to each session's environment).
    static func environment(names: [String]) -> [String: String] {
        var env: [String: String] = [:]
        for n in names { if let v = get(n), !v.isEmpty { env[n] = v } }
        return env
    }

    static func masked(_ v: String) -> String {
        v.count <= 8 ? String(repeating: "•", count: v.count) : "\(v.prefix(4))••••\(v.suffix(4))"
    }
}

/// A CLI account (Claude Code, Codex, GitHub, …): detects install + sign-in status, and the commands to sign in/out.
struct AccountProvider: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let color: SwiftUI.Color
    let binary: String
    let statusCommand: String
    let loginCommand: String
    let logoutCommand: String?
    let installHint: String
    /// Turns the status command's output (+ exit code) into a status.
    let parse: (String, Int32) -> AccountStatus

    static let all: [AccountProvider] = [
        AccountProvider(
            id: "claude", name: "Claude Code", symbol: "sparkle", color: .orange, binary: "claude",
            statusCommand: "claude auth status --json", loginCommand: "claude auth login", logoutCommand: "claude auth logout",
            installHint: "curl -fsSL https://claude.ai/install.sh | bash",
            parse: { out, _ in
                guard let start = out.firstIndex(of: "{"),
                      let obj = try? JSONSerialization.jsonObject(with: Data(out[start...].utf8)) as? [String: Any] else {
                    return .unknown(out.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                guard (obj["loggedIn"] as? Bool) == true else { return .signedOut }
                let plan = (obj["subscriptionType"] as? String).map { $0.capitalized }
                let method = (obj["authMethod"] as? String) == "claude.ai" ? "Claude account" : (obj["authMethod"] as? String)
                return .signedIn(account: obj["email"] as? String, detail: [plan.map { "\($0) plan" }, method].compactMap { $0 }.joined(separator: " · "))
            }),
        AccountProvider(
            id: "codex", name: "Codex", symbol: "chevron.left.forwardslash.chevron.right", color: .teal, binary: "codex",
            statusCommand: "codex login status", loginCommand: "codex login", logoutCommand: "codex logout",
            installHint: "npm install -g @openai/codex",
            parse: { out, code in
                let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.lowercased().contains("not logged in") || (code != 0 && !t.lowercased().contains("logged in")) { return .signedOut }
                if t.lowercased().contains("logged in") {
                    let detail = t.replacingOccurrences(of: "Logged in using ", with: "").replacingOccurrences(of: "Logged in", with: "")
                    return .signedIn(account: nil, detail: detail.isEmpty ? "Signed in" : "via \(detail)")
                }
                return .unknown(t)
            }),
        AccountProvider(
            id: "cursor", name: "Cursor", symbol: "cursorarrow.rays", color: .purple, binary: "cursor-agent",
            statusCommand: "cursor-agent status", loginCommand: "cursor-agent login", logoutCommand: "cursor-agent logout",
            installHint: "curl https://cursor.com/install -fsS | bash",
            parse: { out, _ in
                let t = out.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = t.lowercased()
                if lower.contains("not logged in") || lower.contains("not authenticated") { return .signedOut }
                if lower.contains("logged in") {
                    let email = t.range(of: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]+", options: .regularExpression).map { String(t[$0]) }
                    return .signedIn(account: email, detail: "Cursor account")
                }
                return .unknown(t)
            }),
        AccountProvider(
            id: "github", name: "GitHub", symbol: "arrow.triangle.branch", color: .purple, binary: "gh",
            statusCommand: "gh auth status", loginCommand: "gh auth login", logoutCommand: "gh auth logout",
            installHint: "brew install gh",
            parse: { out, code in
                let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.contains("not logged into") || code != 0 { return .signedOut }
                // "✓ Logged in to github.com account NAME (keyring)"
                if let r = t.range(of: "account ") {
                    let name = t[r.upperBound...].split(separator: " ").first.map(String.init)
                    return .signedIn(account: name, detail: "github.com")
                }
                return .signedIn(account: nil, detail: "github.com")
            }),
        AccountProvider(
            id: "gemini", name: "Gemini CLI", symbol: "diamond", color: .blue, binary: "gemini",
            statusCommand: "test -d ~/.gemini && ls ~/.gemini | grep -qE 'oauth_creds|google_accounts' && echo signed-in || echo signed-out",
            loginCommand: "gemini", logoutCommand: nil,
            installHint: "npm install -g @google/gemini-cli",
            parse: { out, _ in out.contains("signed-in") ? .signedIn(account: nil, detail: "Google account") : .signedOut }),
    ]
}

enum AccountStatus: Equatable {
    case checking
    case notInstalled
    case signedIn(account: String?, detail: String)
    case signedOut
    case unknown(String)
}

@MainActor
final class AccountsModel: ObservableObject {
    @Published var statuses: [String: AccountStatus] = [:]

    func refresh(settings: AppSettings) {
        for p in AccountProvider.all {
            statuses[p.id] = .checking
            let env = Self.environment(settings: settings)
            let shell = settings.shell.isEmpty ? "/bin/zsh" : settings.shell
            Task.detached {
                let installed = Self.run(shell: shell, "command -v \(p.binary) >/dev/null 2>&1", env: env).code == 0
                let status: AccountStatus
                if !installed {
                    status = .notInstalled
                } else {
                    let r = Self.run(shell: shell, p.statusCommand + " 2>&1", env: env)
                    status = p.parse(r.out, r.code)
                }
                await MainActor.run { self.statuses[p.id] = status }
            }
        }
    }

    /// Same environment sessions get (so isolated CLAUDE_CONFIG_DIR / CODEX_HOME are respected).
    nonisolated static func environment(settings: AppSettings) -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let list = Launcher.environment(project: Project(name: "home", path: home), workspaceName: "", settings: settings)
        return Dictionary(list.compactMap { kv -> (String, String)? in
            guard let i = kv.firstIndex(of: "=") else { return nil }
            return (String(kv[..<i]), String(kv[kv.index(after: i)...]))
        }, uniquingKeysWith: { a, _ in a })
    }

    nonisolated static func run(shell: String, _ command: String, env: [String: String]) -> (out: String, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", command]
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return ("", -1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
    }
}
