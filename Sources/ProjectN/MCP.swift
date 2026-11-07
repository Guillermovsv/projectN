import Foundation

struct MCPServer: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var type: String = "stdio"          // "stdio" | "http" | "sse"
    var command: String = ""
    var args: [String] = []
    var env: [String: String] = [:]
    var url: String = ""

    var isRemote: Bool { type == "http" || type == "sse" }

    var summary: String {
        isRemote ? "\(type.uppercased())  \(url)" : ([command] + args).map(Shell.quote).joined(separator: " ")
    }
}

/// Reads/writes ~/.projectn/mcp.json while preserving unknown keys of each server entry.
enum MCPConfig {
    static func loadRaw() -> [String: Any] {
        guard let data = try? Data(contentsOf: AppHome.mcpFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["mcpServers": [String: Any]()]
        }
        return obj
    }

    static func load() -> [MCPServer] {
        let raw = loadRaw()
        let servers = raw["mcpServers"] as? [String: Any] ?? [:]
        return servers.compactMap { name, value in
            guard let dict = value as? [String: Any] else { return nil }
            var s = MCPServer(name: name)
            s.command = dict["command"] as? String ?? ""
            s.args = dict["args"] as? [String] ?? []
            s.env = dict["env"] as? [String: String] ?? [:]
            s.url = dict["url"] as? String ?? ""
            s.type = dict["type"] as? String ?? (s.url.isEmpty ? "stdio" : "http")
            return s
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func upsert(_ server: MCPServer, replacing oldName: String? = nil) {
        var raw = loadRaw()
        var servers = raw["mcpServers"] as? [String: Any] ?? [:]
        if let oldName, oldName != server.name { servers.removeValue(forKey: oldName) }
        var entry = servers[server.name] as? [String: Any] ?? [:]
        if server.isRemote {
            entry["type"] = server.type
            entry["url"] = server.url
            entry.removeValue(forKey: "command"); entry.removeValue(forKey: "args")
        } else {
            entry.removeValue(forKey: "type"); entry.removeValue(forKey: "url")
            entry["command"] = server.command
            entry["args"] = server.args
        }
        if server.env.isEmpty { entry.removeValue(forKey: "env") } else { entry["env"] = server.env }
        servers[server.name] = entry
        raw["mcpServers"] = servers
        write(raw)
    }

    static func remove(_ name: String) {
        var raw = loadRaw()
        var servers = raw["mcpServers"] as? [String: Any] ?? [:]
        servers.removeValue(forKey: name)
        raw["mcpServers"] = servers
        write(raw)
    }

    // MARK: Import from JSON

    struct ImportError: Error, CustomStringConvertible { let description: String }

    /// Accepts what MCP docs and other apps hand out:
    ///   {"mcpServers": {"name": {...}}}  (Claude, Cursor, …)   {"servers": {...}}  (VS Code)
    ///   {"name": {"command": …} | {"url": …}}                  a single server {"command": …} / {"url": …} (needs `name`)
    /// Entries are kept as-is (headers, env, type, …), so nothing a server needs is lost.
    static func parseImport(_ text: String, singleName: String? = nil) throws -> [(name: String, entry: [String: Any])] {
        // Tolerate a bare `"name": {…}` fragment (as often copied from docs) by wrapping it in braces.
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("\""), !t.hasPrefix("{") { t = "{" + t + "}" }
        guard let data = t.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw ImportError(description: "That isn't valid JSON (check commas and quotes).")
        }
        func isServer(_ d: [String: Any]) -> Bool { d["command"] is String || d["url"] is String || d["serverUrl"] is String }
        var map: [String: Any]
        if let m = obj["mcpServers"] as? [String: Any] { map = m }
        else if let m = obj["servers"] as? [String: Any] { map = m }
        else if isServer(obj) {
            guard let n = singleName?.trimmingCharacters(in: .whitespaces), !n.isEmpty else {
                throw ImportError(description: "This is a single server: give it a name.")
            }
            map = [n: obj]
        } else { map = obj }
        var out: [(String, [String: Any])] = []
        for (name, value) in map.sorted(by: { $0.key < $1.key }) {
            guard var entry = value as? [String: Any], isServer(entry) else {
                throw ImportError(description: "“\(name)” isn't an MCP server (it needs a \"command\" or a \"url\").")
            }
            if let u = entry.removeValue(forKey: "serverUrl") { entry["url"] = u }
            if entry["url"] != nil, entry["type"] == nil { entry["type"] = "http" }
            out.append((name.trimmingCharacters(in: .whitespaces), entry))
        }
        guard !out.isEmpty else { throw ImportError(description: "No MCP servers found in that JSON.") }
        return out
    }

    /// Adds (or replaces) the servers; returns their names.
    @discardableResult
    static func importEntries(_ entries: [(name: String, entry: [String: Any])]) -> [String] {
        var raw = loadRaw()
        var servers = raw["mcpServers"] as? [String: Any] ?? [:]
        for e in entries { servers[e.name] = e.entry }
        raw["mcpServers"] = servers
        write(raw)
        return entries.map(\.name)
    }

    private static func write(_ raw: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: AppHome.mcpFile, options: .atomic)
        // May hold tokens (headers / env): readable only by you.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppHome.mcpFile.path)
    }

    /// Codex reads MCP servers from config.toml; we inject them per-launch with `-c key=value` (TOML values).
    static func codexOverrides(_ servers: [MCPServer]) -> [String] {
        var out: [String] = []
        for s in servers {
            let key = "mcp_servers.\(tomlKey(s.name))"
            if s.isRemote {
                guard !s.url.isEmpty else { continue }
                out += ["-c", "\(key).url=\(tomlString(s.url))"]
            } else {
                guard !s.command.isEmpty else { continue }
                out += ["-c", "\(key).command=\(tomlString(s.command))"]
                out += ["-c", "\(key).args=[\(s.args.map(tomlString).joined(separator: ","))]"]
            }
            if !s.env.isEmpty {
                let table = s.env.sorted { $0.key < $1.key }
                    .map { "\(tomlKey($0.key))=\(tomlString($0.value))" }.joined(separator: ",")
                out += ["-c", "\(key).env={\(table)}"]
            }
        }
        return out
    }

    private static func tomlKey(_ k: String) -> String {
        let bare = k.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } && k.allSatisfy(\.isASCII)
        return bare && !k.isEmpty ? k : tomlString(k)
    }

    private static func tomlString(_ s: String) -> String {
        var r = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            case "\t": r += "\\t"
            case "\r": r += "\\r"
            default:
                if ch.value < 0x20 { r += String(format: "\\u%04X", ch.value) } else { r.unicodeScalars.append(ch) }
            }
        }
        return r + "\""
    }
}

enum Shell {
    /// POSIX single-quote escaping.
    static func quote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0) }), s.allSatisfy(\.isASCII) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Splits a user-entered argument string respecting single/double quotes and backslashes.
    static func split(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inSingle = false, inDouble = false, escape = false, has = false
        for ch in s {
            if escape { cur.append(ch); escape = false; has = true; continue }
            if ch == "\\" && !inSingle { escape = true; continue }
            if ch == "'" && !inDouble { inSingle.toggle(); has = true; continue }
            if ch == "\"" && !inSingle { inDouble.toggle(); has = true; continue }
            if ch.isWhitespace && !inSingle && !inDouble {
                if has { out.append(cur); cur = ""; has = false }
                continue
            }
            cur.append(ch); has = true
        }
        if has { out.append(cur) }
        return out
    }
}
