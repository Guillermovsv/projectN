import Foundation

/// The app's own directory: ~/.projectn
///
///   ~/.projectn/
///     state.json      projects, workspaces, spaces, panes (+ their Claude/Codex session ids)
///     scrollback/     saved terminal output, restored on relaunch
///     settings.json   app settings
///     mcp.json        MCP servers ({"mcpServers": {...}}) shared by Claude & Codex sessions
///     mcp/            npm prefix where MCP server packages get installed
///     bin/            your own scripts; added to PATH in every session
///     claude/         CLAUDE_CONFIG_DIR when "isolate Claude config" is on
///     codex/          CODEX_HOME when "isolate Codex home" is on
enum AppHome {
    static let root: URL = {
        if let custom = ProcessInfo.processInfo.environment["PROJECTN_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".projectn")
    }()

    static var stateFile: URL { root.appendingPathComponent("state.json") }
    static var settingsFile: URL { root.appendingPathComponent("settings.json") }
    static var mcpFile: URL { root.appendingPathComponent("mcp.json") }
    static var mcpDir: URL { root.appendingPathComponent("mcp") }
    static var binDir: URL { root.appendingPathComponent("bin") }
    static var claudeConfigDir: URL { root.appendingPathComponent("claude") }
    static var codexHomeDir: URL { root.appendingPathComponent("codex") }
    static var scrollbackDir: URL { root.appendingPathComponent("scrollback") }
    static var handoffsDir: URL { root.appendingPathComponent("handoffs") }

    static func bootstrap() {
        let fm = FileManager.default
        for dir in [root, mcpDir, binDir, scrollbackDir, handoffsDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: mcpFile.path) {
            try? "{\n  \"mcpServers\": {}\n}\n".write(to: mcpFile, atomically: true, encoding: .utf8)
        }
        let pkg = mcpDir.appendingPathComponent("package.json")
        if !fm.fileExists(atPath: pkg.path) {
            try? "{\n  \"name\": \"projectn-mcp\",\n  \"private\": true\n}\n".write(to: pkg, atomically: true, encoding: .utf8)
        }
        let readme = root.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: readme.path) {
            try? """
            ProjectN home directory
            =======================
            mcp.json   MCP servers available to every Claude/Codex session launched by ProjectN.
                       Same format as Claude's .mcp.json: {"mcpServers": {"name": {"command": "...", "args": [...], "env": {...}}}}
                       HTTP servers: {"name": {"type": "http", "url": "https://..."}}
            mcp/       `npm install --prefix ~/.projectn/mcp <pkg>` installs here; mcp/node_modules/.bin is on PATH in sessions.
            bin/       Put your own scripts here; it's on PATH in every session.
            claude/    Used as CLAUDE_CONFIG_DIR when "Isolate Claude config" is enabled.
            codex/     Used as CODEX_HOME when "Isolate Codex home" is enabled.

            """.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.app.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder.app.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    static let app: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let app: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
