import Foundation

/// Who decides about one tool call an agent wants to make. Pure: (tool, input, profile, project) → tier.
///
///   allow         routine work inside the project (reading, editing for agents that may edit, tests/builds,
///                 the agent's own CLI tools, ProjectN's agent tools)
///   orchestrator  gray area: decided by the agent that delegated the task (or by you — see AgentPolicy)
///   user          always you: deleting anything, publishing / deploying / pushing, anything outside the
///                 project folder, sudo / permission changes
///   deny          not allowed for this agent at all (e.g. edits by a read-only agent)
///
/// The most restrictive verdict of all parts of a command wins (deny > user > orchestrator > allow).
enum ApprovalTier: Equatable, Comparable {
    case allow
    case orchestrator(String)
    case user(String)
    case deny(String)

    private var rank: Int {
        switch self { case .allow: return 0; case .orchestrator: return 1; case .user: return 2; case .deny: return 3 }
    }
    static func < (a: ApprovalTier, b: ApprovalTier) -> Bool { a.rank < b.rank }
    var reason: String {
        switch self { case .allow: return "Routine"; case .orchestrator(let r), .user(let r), .deny(let r): return r }
    }
    var isDeletion: Bool { if case .user(let r) = self { return r.hasPrefix("Deletes") }; return false }
}

enum ApprovalPolicy {
    struct Context {
        var permission: AgentPermission
        var projectPath: String
        /// Commands this agent may run without asking (its CLI tools), e.g. ["gh", "wp", "vercel"].
        var cliTools: [String] = []
        var cwd: String?
        /// How much runs without asking (see AgentAutonomy).
        var autonomy: AgentAutonomy = .balanced
    }

    /// Applies the agent's autonomy to a verdict for a top-level decision (nobody coordinating it):
    /// gray-area work runs on its own unless the agent is cautious; `high` also lets publishing / sending /
    /// remote work and writes in your home folder through. Deleting, admin/system changes and secrets always ask.
    static func decide(tool: String, input: [String: Any], _ ctx: Context) -> ApprovalTier {
        let tier = classify(tool: tool, input: input, ctx)
        switch (tier, ctx.autonomy) {
        case (.orchestrator, .balanced), (.orchestrator, .high):
            return .allow
        case (.user(let why), .high) where highMayDecide(why):
            return .allow
        default:
            return tier
        }
    }

    /// Reasons `high` autonomy decides by itself. Everything else (deleting, admin rights, system state,
    /// secrets, system folders) still asks.
    private static func highMayDecide(_ why: String) -> Bool {
        let ok = ["Publishes", "Sends data", "Pushes to a remote", "Publishes a package", "Changes GitHub", "Deploys",
                  "Publishes an image", "Acts on a remote system", "Copies to a remote system", "Writes outside the project",
                  "Touches a path outside the project", "Reads outside the project", "Creates a new project"]
        return ok.contains { why.hasPrefix($0) } && !why.contains(" [protected]")
    }

    static func classify(tool: String, input: [String: Any], _ ctx: Context) -> ApprovalTier {
        if tool.hasPrefix("mcp__projectn__") { return .allow }
        if tool.hasPrefix("mcp__") { return classifyMCP(tool) }
        let path = (input["file_path"] ?? input["path"] ?? input["notebook_path"]) as? String
        switch tool {
        case "Read", "Glob", "Grep", "LS", "NotebookRead":
            if let path, !inside(path, ctx) {
                if isProtected(path) { return .user("Reads outside the project: \(path) [protected]") }
                return ctx.autonomy == .cautious ? .user("Reads outside the project: \(path)") : .allow
            }
            return .allow
        case "TodoWrite", "WebSearch", "Task", "Agent", "TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "ToolSearch", "Skill":
            return .allow
        case "WebFetch":
            return .orchestrator("Fetches \(input["url"] as? String ?? "a web page")")
        case "ExitPlanMode":
            guard ctx.permission.canWrite else { return .deny("This agent is read-only: give the plan as your answer (or delegate it) instead of leaving plan mode.") }
            return .orchestrator("Wants to leave plan mode and start working")
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            guard ctx.permission.canWrite else { return .deny("\(roleLabel(ctx)) can't modify files. Give your findings as text instead.") }
            if let path, !inside(path, ctx) { return .user("Writes outside the project: \(path)" + (isProtected(path) || !inHome(path) ? " [protected]" : "")) }
            if tool == "Write", let path, input["content"] as? String == "" { return .user("Deletes the contents of \(path)") }
            return ctx.permission == .askBeforeChanges ? .user("Edits \(path.map(relative(ctx)) ?? "a file")") : .allow
        case "Bash":
            return classifyCommand(input["command"] as? String ?? "", ctx)
        default:
            return .orchestrator("Uses \(tool)")
        }
    }

    // MARK: MCP tools

    static let deleteWords = ["delete", "remove", "destroy", "drop", "trash", "purge", "erase", "wipe", "unpublish", "uninstall", "revoke", "archive"]
    static let publishWords = ["publish", "deploy", "send", "boost", "activate", "release", "push", "merge", "pay", "charge", "upload", "reply", "forward"]
    static let readWords = ["get", "list", "read", "search", "query", "fetch", "find", "inspect", "check", "detect", "status", "describe", "preview", "validate", "show", "view", "suggest", "answer", "overview"]

    /// Tools of other MCP servers, judged by their name: deleting / publishing → you, reading → allowed, else gray.
    static func classifyMCP(_ tool: String) -> ApprovalTier {
        let name = (tool.components(separatedBy: "__").last ?? tool).lowercased()
        let words = name.split(whereSeparator: { "_-.".contains($0) }).map(String.init)
        if words.contains(where: deleteWords.contains) { return .user("Deletes via \(tool)") }
        if words.contains(where: publishWords.contains)
            || (words.contains { $0 == "post" || $0 == "posts" } && words.contains { ["create", "schedule", "cross", "update", "edit"].contains($0) }) {
            return .user("Publishes / sends via \(tool)")
        }
        if words.contains(where: readWords.contains) { return .allow }
        return .orchestrator("Uses \(tool)")
    }

    // MARK: Shell commands

    /// Read-only commands: fine for every agent.
    static let readOnlyCommands: Set<String> = [
        "ls", "cat", "head", "tail", "less", "more", "grep", "egrep", "fgrep", "rg", "ag", "find", "fd", "wc", "pwd", "echo", "printf",
        "which", "type", "file", "stat", "du", "df", "tree", "sort", "uniq", "cut", "tr", "awk", "jq", "yq", "diff", "cmp", "date",
        "basename", "dirname", "realpath", "readlink", "true", "false", "test", "[", "cd", "sleep", "env", "printenv", "uname",
        "whoami", "id", "column", "nl", "fold", "hexdump", "xxd", "md5", "shasum", "sha256sum", "plutil", "defaults-read", "sw_vers",
    ]
    /// Project work that writes inside the project (builds, tests, formatting, git commits): agents that may edit.
    static let projectCommands: Set<String> = [
        "npm", "npx", "pnpm", "yarn", "bun", "node", "deno", "swift", "xcodebuild", "make", "cmake", "cargo", "go", "rustc",
        "python", "python3", "pip", "pip3", "pytest", "uv", "poetry", "ruby", "bundle", "rake", "php", "composer", "tsc",
        "eslint", "prettier", "black", "ruff", "mkdir", "touch", "cp", "mv", "ln", "sed", "patch", "git", "tar", "zip", "unzip",
        "gzip", "gunzip", "open", "xcrun", "swiftc", "clang", "gcc", "javac", "java", "mvn", "gradle", "dotnet", "flutter", "dart",
    ]
    static let gitReadOnly: Set<String> = ["status", "log", "diff", "show", "rev-parse", "ls-files", "blame", "describe", "shortlog",
                                           "reflog", "grep", "remote", "config", "branch", "tag", "fetch", "cat-file", "ls-tree", "whatchanged"]

    static func classifyCommand(_ command: String, _ ctx: Context) -> ApprovalTier {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .allow }
        var verdict = ApprovalTier.allow
        let lower = trimmed.lowercased()
        // SQL / data deletion anywhere in the command.
        if lower.range(of: #"\b(drop\s+(table|database|schema|collection)|delete\s+from|truncate\s+table)\b"#, options: .regularExpression) != nil {
            return .user("Deletes data: \(clip(trimmed))")
        }
        if trimmed.contains("$(") || trimmed.contains("`") || trimmed.contains("<(") {
            // The commands inside $(…), `…` and <(…) are judged like the rest.
            let inner = substitutions(trimmed)
            for c in inner where c != trimmed {
                verdict = max(verdict, classifyCommand(c, ctx))
                if case .deny = verdict { return verdict }
            }
            if inner.isEmpty { verdict = max(verdict, .orchestrator("Runs a command with substitutions: \(clip(trimmed))")) }
        }
        for segment in segments(trimmed) {
            verdict = max(verdict, classifySegment(segment, ctx))
            if case .deny = verdict { return verdict }
        }
        return verdict
    }

    /// Bodies of $(…), <(…) and `…` (outermost level; nested ones are found when the body is classified).
    static func substitutions(_ s: String) -> [String] {
        var out: [String] = []
        let chars = Array(s)
        var i = 0
        var single = false
        while i < chars.count {
            let c = chars[i]
            if c == "'" { single.toggle(); i += 1; continue }
            if single { i += 1; continue }
            if (c == "$" || c == "<"), i + 1 < chars.count, chars[i + 1] == "(" {
                var depth = 1, j = i + 2
                while j < chars.count, depth > 0 {
                    if chars[j] == "(" { depth += 1 } else if chars[j] == ")" { depth -= 1 }
                    j += 1
                }
                guard depth == 0 else { return [] }   // unbalanced: can't judge it
                out.append(String(chars[(i + 2)..<(j - 1)]).trimmingCharacters(in: .whitespaces))
                i = j
                continue
            }
            if c == "`" {
                guard let end = chars[(i + 1)...].firstIndex(of: "`") else { return [] }
                out.append(String(chars[(i + 1)..<end]).trimmingCharacters(in: .whitespaces))
                i = end + 1
                continue
            }
            i += 1
        }
        return out.filter { !$0.isEmpty }
    }

    /// Splits on ; && || | & and newlines (outside quotes).
    static func segments(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var single = false, double = false
        let chars = Array(s)
        var i = 0
        func flush() { let t = cur.trimmingCharacters(in: .whitespaces); if !t.isEmpty { out.append(t) }; cur = "" }
        while i < chars.count {
            let c = chars[i]
            if c == "'" && !double { single.toggle() }
            else if c == "\"" && !single { double.toggle() }
            if !single && !double && (c == ";" || c == "\n" || c == "|" || c == "&") {
                // keep "2>&1" / ">&2" redirections intact
                if c == "&", i > 0, chars[i - 1] == ">" { cur.append(c); i += 1; continue }
                if c == "&", i + 1 < chars.count, chars[i + 1] == ">" { cur.append(c); i += 1; continue }
                flush()
                i += 1
                continue
            }
            cur.append(c)
            i += 1
        }
        flush()
        return out
    }

    static func classifySegment(_ segment: String, _ ctx: Context) -> ApprovalTier {
        var tokens = Shell.split(segment)
        // Leading VAR=value assignments, `command`, `time`, `nohup`, `exec`.
        while let t = tokens.first, t.contains("="), !t.hasPrefix("-"), !t.hasPrefix("/") { tokens.removeFirst() }
        while let t = tokens.first, ["command", "time", "nohup", "exec", "builtin", "xargs"].contains(t) { tokens.removeFirst() }
        guard let first = tokens.first else { return .allow }
        let cmd = (first as NSString).lastPathComponent
        let args = Array(tokens.dropFirst())
        let argsLower = args.map { $0.lowercased() }
        let sub = argsLower.first { !$0.hasPrefix("-") } ?? ""
        let clipped = clip(segment)

        if ["sudo", "su", "doas"].contains(cmd) { return .user("Needs administrator rights: \(clipped)") }

        // ── Deleting anything: always you ─────────────────────────────────────────────
        if ["rm", "rmdir", "unlink", "shred", "srm", "trash", "truncate", "dd"].contains(cmd) { return .user("Deletes: \(clipped)") }
        if cmd == "find", argsLower.contains("-delete") || (argsLower.contains("-exec") && argsLower.contains { ["rm", "unlink", "rmdir"].contains($0) }) {
            return .user("Deletes: \(clipped)")
        }
        if cmd == "git" {
            let a = argsLower
            if ["rm", "clean", "restore", "prune", "gc"].contains(sub)
                || (sub == "reset" && a.contains("--hard"))
                || (sub == "checkout" && (a.contains("--") || a.contains(".")))
                || (sub == "stash" && a.contains { ["drop", "clear"].contains($0) })
                || (sub == "branch" && a.contains { ["-d", "--delete"].contains($0) })
                || (sub == "tag" && a.contains { ["-d", "--delete"].contains($0) })
                || (sub == "worktree" && a.contains("remove"))
                || (sub == "push" && (a.contains("--delete") || a.contains("-d") || a.contains { $0.hasPrefix(":") } || a.contains("--force") || a.contains("-f")))
                || (sub == "remote" && a.contains { ["remove", "rm"].contains($0) }) {
                return .user("Deletes / discards in git: \(clipped)")
            }
        }
        if ["npm", "pnpm", "yarn", "bun"].contains(cmd), ["uninstall", "remove", "rm", "un", "prune", "unpublish", "dedupe"].contains(sub) { return .user("Deletes packages: \(clipped)") }
        if ["pip", "pip3", "brew", "gem", "cargo"].contains(cmd), ["uninstall", "remove", "rm", "cleanup"].contains(sub) { return .user("Deletes packages: \(clipped)") }
        if cmd == "docker", ["rm", "rmi", "prune"].contains(sub) || argsLower.contains("prune") || (argsLower.contains("volume") && argsLower.contains("rm")) { return .user("Deletes Docker data: \(clipped)") }
        if cmd == "kubectl", sub == "delete" { return .user("Deletes cluster resources: \(clipped)") }
        if cmd == "rsync", argsLower.contains(where: { $0.hasPrefix("--delete") }) { return .user("Deletes while syncing: \(clipped)") }
        if cmd == "terraform", sub == "destroy" { return .user("Deletes infrastructure: \(clipped)") }
        if cmd == "gh", argsLower.contains("delete") || argsLower.contains("close") { return .user("Deletes / closes on GitHub: \(clipped)") }
        if cmd == "mv", let dest = args.last, args.count >= 2, dest == "/dev/null" { return .user("Deletes: \(clipped)") }
        if ctx.cliTools.contains(cmd), argsLower.contains(where: { a in deleteWords.contains { a == $0 || a.hasPrefix($0 + "-") || a.hasSuffix("-" + $0) } }) {
            return .user("Deletes via \(cmd): \(clipped)")
        }

        // ── Publishing / deploying / sending: always you ──────────────────────────────
        if cmd == "git", sub == "push" { return .user("Pushes to a remote: \(clipped)") }
        if ["npm", "pnpm", "yarn", "bun", "cargo", "gem", "twine", "poetry"].contains(cmd), sub == "publish" || sub == "upload" { return .user("Publishes a package: \(clipped)") }
        if cmd == "gh", ["release", "pr", "repo", "workflow", "secret", "api"].contains(sub), !argsLower.contains(where: { ["list", "view", "status", "diff", "checks"].contains($0) }) {
            return .user("Changes GitHub: \(clipped)")
        }
        if ["vercel", "netlify", "firebase", "fly", "flyctl", "heroku", "wrangler", "surge", "eas", "fastlane", "amplify"].contains(cmd),
           !argsLower.contains(where: { ["dev", "login", "whoami", "list", "ls", "logs", "status", "build"].contains($0) }) {
            return .user("Deploys / publishes: \(clipped)")
        }
        if cmd == "docker", sub == "push" { return .user("Publishes an image: \(clipped)") }
        if cmd == "terraform", sub == "apply" { return .user("Changes infrastructure: \(clipped)") }
        if cmd == "kubectl", ["apply", "create", "replace", "patch", "scale", "rollout"].contains(sub) { return .user("Changes a cluster: \(clipped)") }
        if ["aws", "gcloud", "az", "scp", "sftp", "ssh", "ftp", "osascript"].contains(cmd) { return .user("Acts on a remote system: \(clipped)") }
        if cmd == "rsync", args.contains(where: { $0.contains(":") && !$0.hasPrefix("-") }) { return .user("Copies to a remote system: \(clipped)") }
        if cmd == "curl" || cmd == "wget" || cmd == "http" {
            let mutating = argsLower.contains { ["-d", "--data", "--data-raw", "--data-binary", "-f", "--form", "-t", "--upload-file", "--json"].contains($0) || $0.hasPrefix("--data") }
                || zip(argsLower, argsLower.dropFirst()).contains { ($0 == "-x" || $0 == "--request") && ["post", "put", "patch", "delete"].contains($1) }
            if mutating { return .user("Sends data to a server: \(clipped)") }
            return .orchestrator("Downloads from the network: \(clipped)")
        }
        if ["chmod", "chown", "chflags", "xattr", "launchctl", "crontab", "defaults", "security", "killall", "kill", "pkill", "shutdown", "reboot", "diskutil"].contains(cmd) {
            return .user("Changes system state: \(clipped)")
        }

        // ── Paths outside the project ────────────────────────────────────────────────
        // Reading elsewhere (ls, cat, grep… on another folder) is fine unless the agent is cautious or it's a secret.
        let reads = readOnlyCommands.contains(cmd) || (cmd == "git" && gitReadOnly.contains(sub))
        for a in args where !a.hasPrefix("-") {
            let arg = a.split(separator: "=", maxSplits: 1).last.map(String.init) ?? a
            guard arg.hasPrefix("/") || arg.hasPrefix("~") || arg.contains("..") else { continue }
            guard !inside(arg, ctx) && !harmlessPath(arg) else { continue }
            if isProtected(arg) { return .user("Touches a path outside the project: \(arg) [protected]") }
            if reads && ctx.autonomy != .cautious { continue }
            return .user("Touches a path outside the project: \(arg)" + (inHome(arg) ? "" : " [protected]"))
        }
        if segment.range(of: #"(^|[^<>&0-9])>{1,2}\s*([^\s&|;]+)"#, options: .regularExpression) != nil {
            let targets = matches(#">{1,2}\s*([^\s&|;]+)"#, in: segment)
            for t in targets where !t.hasPrefix("&") && !harmlessPath(t) {
                if !inside(t, ctx) { return .user("Writes outside the project: \(t)" + (isProtected(t) || !inHome(t) ? " [protected]" : "")) }
                if !ctx.permission.canWrite { return .deny("\(roleLabel(ctx)) can't write files (redirect to \(t)).") }
            }
        }

        // ── Routine ──────────────────────────────────────────────────────────────────
        if cmd == "git", gitReadOnly.contains(sub) || sub.isEmpty { return .allow }
        if cmd == "sed", argsLower.contains(where: { $0 == "-i" || $0.hasPrefix("-i") }) {
            return ctx.permission.canWrite ? .allow : .deny("\(roleLabel(ctx)) can't modify files.")
        }
        if readOnlyCommands.contains(cmd) { return .allow }
        if ctx.cliTools.contains(cmd) { return .allow }
        if projectCommands.contains(cmd) || first.hasPrefix("./") || first.hasPrefix("scripts/") {
            return ctx.permission.canWrite ? .allow : .deny("\(roleLabel(ctx)) only reads and plans; it can't run \(cmd). Describe what should be run instead.")
        }
        return .orchestrator("Runs `\(cmd)`: \(clipped)")
    }

    // MARK: Helpers

    static func inside(_ path: String, _ ctx: Context) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        let base = PathGuard.canonical(ctx.projectPath)
        let abs = expanded.hasPrefix("/") ? expanded : ((ctx.cwd ?? ctx.projectPath) as NSString).appendingPathComponent(expanded)
        let p = PathGuard.canonical(abs)
        return p == base || p.hasPrefix(base + "/")
    }

    /// Secrets and credentials outside the project: reading or writing them always asks you.
    static func isProtected(_ path: String) -> Bool {
        let c = PathGuard.canonical((path as NSString).expandingTildeInPath)
        let home = PathGuard.canonical(NSHomeDirectory())
        let dirs = [".ssh", ".aws", ".gnupg", ".kube", ".docker", ".config/gcloud", ".config/gh", "Library/Keychains",
                    "Library/Cookies", ".projectn", "Library/Application Support/Google/Chrome"]
        if dirs.contains(where: { c == "\(home)/\($0)" || c.hasPrefix("\(home)/\($0)/") }) { return true }
        if [".claude.json", ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".zsh_history", ".bash_history"].contains(where: { c == "\(home)/\($0)" }) { return true }
        return PathGuard.looksSecret(URL(fileURLWithPath: c))
    }

    static func inHome(_ path: String) -> Bool {
        let c = PathGuard.canonical((path as NSString).expandingTildeInPath)
        let home = PathGuard.canonical(NSHomeDirectory())
        return c.hasPrefix(home + "/") && !c.hasPrefix(home + "/Library/")
    }

    static func harmlessPath(_ p: String) -> Bool {
        let c = PathGuard.canonical((p as NSString).expandingTildeInPath)
        return ["/dev/null", "/dev/stdout", "/dev/stderr", "/dev/stdin"].contains(c)
            || c.hasPrefix("/private/tmp/") || c.hasPrefix("/tmp/") || c.hasPrefix("/private/var/folders/")
    }

    private static func relative(_ ctx: Context) -> (String) -> String {
        { p in p.hasPrefix(ctx.projectPath) ? String(p.dropFirst(ctx.projectPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : p }
    }

    private static func roleLabel(_ ctx: Context) -> String { ctx.permission == .readOnly ? "This agent is read-only and" : "This agent" }

    static func clip(_ s: String) -> String {
        let r = Redactor.redact(s)
        return r.count > 160 ? String(r.prefix(160)) + "…" : r
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }
}

/// Hides secrets (tokens, passwords, Authorization headers, base64 credentials) in text shown in Slack, ProjectN
/// and the audit log. Heuristic: better to over-redact a random-looking string than to leak a credential.
enum Redactor {
    private static let rules: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            // Authorization: Bearer xxx / Basic xxx (headers, curl -H, JSON)
            (#"(?i)(authorization["']?\s*[:=]\s*["']?\s*(?:bearer|basic|token)?\s*)[^\s"',;}]+"#, "$1•••"),
            (#"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 •••"),
            // key=value / "key": "value" for secret-looking names
            (#"(?i)((?:api[_-]?key|apikey|access[_-]?token|refresh[_-]?token|auth[_-]?token|token|secret|client[_-]?secret|password|passwd|pwd|app[_-]?password)["']?\s*[:=]\s*["']?)[^\s"'&,;}]+"#, "$1•••"),
            // Well-known token formats
            (#"\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}"#, "•••"),
            (#"\bxox[abposr]-[A-Za-z0-9-]{10,}"#, "•••"),
            (#"\bxapp-[A-Za-z0-9-]{10,}"#, "•••"),
            (#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, "•••"),
            (#"\bAKIA[0-9A-Z]{16}\b"#, "•••"),
            (#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}"#, "•••"),
            // user:password@host in URLs
            (#"(://[^/\s:@]+:)[^@\s/]+@"#, "$1•••@"),
        ]
        return specs.compactMap { p, t in (try? NSRegularExpression(pattern: p)).map { ($0, t) } }
    }()

    static func redact(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var out = s
        for (re, template) in rules {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return redactOpaqueTokens(out)
    }

    /// Long random-looking runs (upper + lower + digits, ≥ 24 chars, no path separators): base64 credentials, keys.
    private static func redactOpaqueTokens(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"[A-Za-z0-9+=_-]{24,}"#) else { return s }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            let w = out[r]
            let hasUpper = w.contains { $0.isUppercase }, hasLower = w.contains { $0.isLowercase }, hasDigit = w.contains { $0.isNumber }
            // UUIDs, paths written with dashes and plain words don't qualify.
            let dashed = w.split(separator: "-").count > 3
            if hasUpper && hasLower && hasDigit && !dashed { out.replaceSubrange(r, with: "•••") }
        }
        return out
    }
}
