import Foundation

/// Files (images, PDFs, Markdown, anything) attached to a Slack message, for the agent that gets the message.
///
/// They're downloaded with the bot token (scope `files:read`) to a temporary folder as soon as the message
/// arrives, then moved into the project the task runs in — `<project>/.slack-files/<message>/` — because agents
/// may read anything in their project without asking, while ~/.projectn is protected. The folder ignores
/// itself in git. The paths are appended to the instruction, so Claude/Codex open them with their own tools
/// (Read shows images and PDFs to Claude; Codex views images).
struct SlackFile: Equatable {
    var name: String
    var mimetype: String
    var size: Int
    /// The downloaded copy (temporary, then inside the project).
    var local: URL?
    var permalink: String?
    /// Why it couldn't be downloaded.
    var error: String?

    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
}

enum SlackFiles {
    static let maxFiles = 10
    static let maxBytes = 50 * 1024 * 1024
    static let folderName = ".slack-files"

    /// Downloads a file's bytes with the bot token; returns the data and the response's MIME type.
    typealias Fetch = (URL) async throws -> (Data, String?)

    /// The `files` of a message event (`file_share` messages and mentions carry them).
    static func entries(_ event: [String: Any]) -> [[String: Any]] {
        (event["files"] as? [[String: Any]]) ?? []
    }

    static func fetcher(token: String) -> Fetch {
        { url in
            var req = URLRequest(url: url)
            req.timeoutInterval = 120
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            guard let code = http?.statusCode, (200..<300).contains(code) else {
                throw SlackAPI.APIError(message: "HTTP \(http?.statusCode ?? 0)")
            }
            return (data, http?.mimeType)
        }
    }

    /// Downloads every file into a fresh temporary folder. `info` is `files.info` (when the event only carries
    /// the file's id). Never throws: a file that can't be fetched comes back with `error` set.
    static func download(_ entries: [[String: Any]], fetch: Fetch,
                         info: (String) async throws -> [String: Any]) async -> [SlackFile] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("projectn-slack-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [SlackFile] = []
        var used = Set<String>()
        for var e in entries.prefix(maxFiles) {
            // Some events only say {"id": "F…", "file_access": "check_file_info"}.
            if e["url_private_download"] == nil && e["url_private"] == nil, let id = e["id"] as? String,
               let full = try? await info(id)["file"] as? [String: Any] {
                e = full
            }
            let name = safeName(e["name"] as? String ?? e["title"] as? String ?? (e["id"] as? String ?? "file"))
            var f = SlackFile(name: name,
                              mimetype: e["mimetype"] as? String ?? "application/octet-stream",
                              size: e["size"] as? Int ?? 0,
                              permalink: e["permalink"] as? String)
            let mode = e["mode"] as? String ?? ""
            if mode == "tombstone" || mode == "hidden_by_limit" || e["is_external"] as? Bool == true || mode == "external" {
                f.error = mode == "hidden_by_limit" ? "hidden by the workspace's plan limits" : "not stored in Slack (external or deleted)"
                out.append(f); continue
            }
            if f.size > maxBytes {
                f.error = "too large (\(f.sizeLabel), limit \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)))"
                out.append(f); continue
            }
            guard let s = (e["url_private_download"] as? String) ?? (e["url_private"] as? String), let url = URL(string: s) else {
                f.error = "Slack didn't send a download link"
                out.append(f); continue
            }
            do {
                let (data, type) = try await fetch(url)
                // Without files:read Slack answers with its sign-in page instead of the file.
                if type == "text/html", !f.mimetype.contains("html") {
                    throw SlackAPI.APIError(message: "Slack returned a sign-in page — the bot needs the files:read scope")
                }
                if data.count > maxBytes { throw SlackAPI.APIError(message: "too large") }
                if f.size == 0 { f.size = data.count }
                let file = dir.appendingPathComponent(unique(name, &used))
                try data.write(to: file, options: .atomic)
                f.local = file
            } catch {
                f.error = (error as? SlackAPI.APIError)?.message ?? error.localizedDescription
            }
            out.append(f)
        }
        return out
    }

    /// Moves the downloaded files into `<project>/.slack-files/<stamp>/`. Files already there stay put.
    static func place(_ files: [SlackFile], in project: Project, stamp: String) -> [SlackFile] {
        guard files.contains(where: { $0.local != nil }) else { return files }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: project.path, isDirectory: true).appendingPathComponent(folderName, isDirectory: true)
        let dir = root.appendingPathComponent(safeName(stamp), isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ignore = root.appendingPathComponent(".gitignore")
        if !fm.fileExists(atPath: ignore.path) {
            try? "# Files sent to ProjectN agents from Slack\n*\n".write(to: ignore, atomically: true, encoding: .utf8)
        }
        var used = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        return files.map { f in
            guard let src = f.local, !src.path.hasPrefix(root.path + "/") else { return f }
            var f = f
            let dest = dir.appendingPathComponent(unique(f.name, &used))
            do {
                try fm.moveItem(at: src, to: dest)
                f.local = dest
            } catch {
                // Moving can fail across volumes / permissions: a copy is just as good.
                if (try? fm.copyItem(at: src, to: dest)) != nil { f.local = dest } else { f.error = "couldn't save it in the project: \(error.localizedDescription)" }
            }
            return f
        }
    }

    /// Appended to the instruction (empty without files).
    static func note(_ files: [SlackFile], hasText: Bool) -> String {
        guard !files.isEmpty else { return "" }
        var lines: [String] = []
        let ok = files.filter { $0.local != nil && $0.error == nil }
        if !ok.isEmpty {
            lines.append(hasText
                ? "Files attached to this Slack message (saved on disk; open them with your tools — images and PDFs can be viewed directly):"
                : "The user sent these files from Slack without a message (saved on disk; open them with your tools — images and PDFs can be viewed directly):")
            lines += ok.map { "- \($0.local!.path) (\($0.mimetype), \($0.sizeLabel))" }
        }
        let failed = files.filter { $0.local == nil || $0.error != nil }
        if !failed.isEmpty {
            lines.append("Attached in Slack but not available to you:")
            lines += failed.map { "- \($0.name): \($0.error ?? "not downloaded")" }
        }
        return (hasText ? "\n\n" : "") + lines.joined(separator: "\n")
    }

    static func safeName(_ s: String) -> String {
        var n = s.components(separatedBy: CharacterSet(charactersIn: "/\\:\0\n\r")).joined(separator: "_")
        while n.hasPrefix(".") { n.removeFirst() }
        n = n.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { n = "file" }
        if n.utf8.count > 180 {
            let ext = (n as NSString).pathExtension
            n = String(n.prefix(150)) + (ext.isEmpty ? "" : ".\(ext)")
        }
        return n
    }

    private static func unique(_ name: String, _ used: inout Set<String>) -> String {
        var candidate = name
        var i = 2
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while used.contains(candidate) {
            candidate = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            i += 1
        }
        used.insert(candidate)
        return candidate
    }
}
