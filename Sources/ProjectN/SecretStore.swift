import Foundation
import Security

/// Tokens and API keys in ~/.projectn/secrets.json (folder 0700, file 0600: only your user can read it).
///
/// Why not the login Keychain: ProjectN is signed without an Apple team ID, so macOS ties every Keychain item to
/// the exact hash of the build that may read it. Each update is a new build, so macOS asked for the Keychain
/// password again for every item after every update. Values saved there by older builds are copied in here the
/// first time they're read (that read may ask one last time) and are never looked up in the Keychain again.
enum SecretStore {
    static var file: URL { AppHome.root.appendingPathComponent("secrets.json") }

    private static let lock = NSLock()
    /// service → account → value
    private static var cache: [String: [String: String]]?

    static func get(service: String, account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var all = loadLocked()
        if let v = all[service]?[account] { return v.isEmpty ? nil : v }
        // Not migrated yet: copy it from the Keychain once, then remember it (or remember that it's not there).
        switch KeychainLegacy.get(service: service, account: account) {
        case .found(let v):
            all[service, default: [:]][account] = v
            saveLocked(all)
            return v.isEmpty ? nil : v
        case .notFound:
            all[service, default: [:]][account] = ""
            saveLocked(all)
            return nil
        case .unavailable:
            return nil   // denied / cancelled / locked: try again next time instead of forgetting it
        }
    }

    @discardableResult
    static func set(service: String, account: String, value: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var all = loadLocked()
        all[service, default: [:]][account] = value
        return saveLocked(all)
    }

    static func delete(service: String, account: String) {
        set(service: service, account: account, value: "")   // "" = removed (and don't look in the Keychain again)
    }

    // MARK: - File

    private static func loadLocked() -> [String: [String: String]] {
        if let cache { return cache }
        let loaded = (try? Data(contentsOf: file))
            .flatMap { try? JSONDecoder().decode([String: [String: String]].self, from: $0) } ?? [:]
        cache = loaded
        return loaded
    }

    @discardableResult
    private static func saveLocked(_ all: [String: [String: String]]) -> Bool {
        cache = all
        let fm = FileManager.default
        try? fm.createDirectory(at: AppHome.root, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: AppHome.root.path)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(all) else { return false }
        // Write to a private temp file first so the secrets are never readable by others, even briefly.
        let tmp = AppHome.root.appendingPathComponent(".secrets.\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        guard rename(tmp.path, file.path) == 0 else { try? fm.removeItem(at: tmp); return false }
        return true
    }

    /// Tests only: forget the in-memory copy.
    static func resetCache() { lock.lock(); cache = nil; lock.unlock() }
}

/// Read-only access to values older builds kept in the login Keychain.
private enum KeychainLegacy {
    enum Result { case found(String), notFound, unavailable }

    static func get(service: String, account: String) -> Result {
        if AppHome.isTestProcess { return .notFound }   // tests never touch the real Keychain
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        switch SecItemCopyMatching(q as CFDictionary, &out) {
        case errSecSuccess:
            guard let d = out as? Data, let v = String(data: d, encoding: .utf8) else { return .unavailable }
            return .found(v)
        case errSecItemNotFound: return .notFound
        default: return .unavailable
        }
    }
}
