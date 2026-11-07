import Foundation
import SwiftUI

/// "Create an agent with AI": you describe the agent in a few words, Claude asks a few short questions, then
/// designs the whole profile (instructions, access, tools, model, MCP servers, projects, schedules). You review
/// and edit it before it's created. Runs `claude -p` with your Claude Code login, no tools, structured JSON output.
@MainActor
final class AgentCreator: ObservableObject {
    enum Stage: Equatable { case describe, asking, questions, designing, review, failed(String) }

    struct Question: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let options: [String]
        var answer: String = ""
    }

    @Published var stage: Stage = .describe
    @Published var description = ""
    @Published var questions: [Question] = []
    @Published var draft: AgentProfile?
    @Published var summary = ""

    /// (prompt, JSON schema) → structured output. Replaced in tests.
    var runner: (String, [String: Any]) async throws -> [String: Any] = AgentCreator.runClaude
    private let harness: AgentHarness
    private let store: Store

    init(harness: AgentHarness, store: Store) {
        self.harness = harness
        self.store = store
    }

    // MARK: Steps

    func askQuestions() {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        stage = .asking
        let prompt = Self.questionsPrompt(description: text, context: context)
        Task {
            do {
                let out = try await runner(prompt, Self.questionsSchema)
                let qs = (out["questions"] as? [[String: Any]] ?? []).prefix(4).compactMap { q -> Question? in
                    guard let t = q["question"] as? String, !t.isEmpty else { return nil }
                    return Question(text: t, options: (q["options"] as? [String] ?? []).prefix(5).map { $0 })
                }
                questions = Array(qs)
                stage = questions.isEmpty ? .designing : .questions
                if questions.isEmpty { design() }
            } catch {
                stage = .failed("\(error)")
            }
        }
    }

    func design() {
        stage = .designing
        let answers = questions.filter { !$0.answer.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "- \($0.text)\n  → \($0.answer)" }.joined(separator: "\n")
        let prompt = Self.designPrompt(description: description, answers: answers, context: context)
        Task {
            do {
                let spec = try await runner(prompt, Self.designSchema(context))
                draft = Self.profile(from: spec, context: context)
                summary = spec["summary"] as? String ?? ""
                stage = .review
            } catch {
                stage = .failed("\(error)")
            }
        }
    }

    /// Saves the agent and returns its id.
    @discardableResult
    func create() -> UUID? {
        guard var p = draft else { return nil }
        var n = 2
        let base = p.name
        while harness.profiles.contains(where: { $0.name.folded == p.name.folded }) { p.name = "\(base) \(n)"; n += 1 }
        harness.saveProfile(p)
        AuditLog.record("agent.created_with_ai", ["agent": p.name, "role": p.role])
        return p.id
    }

    // MARK: Context

    struct Context {
        var projects: [Project]
        var mcpServers: [MCPServer]
        var models: [ModelCatalog.Model]
        var existingAgents: [String]
    }

    var context: Context {
        Context(projects: store.state.projects, mcpServers: MCPConfig.load(),
                models: harness.catalog.listing(for: .claudeCode, settings: store.settings).models,
                existingAgents: harness.profiles.map { "\($0.name) (\($0.role))" })
    }

    private static func contextText(_ c: Context) -> String {
        """
        Projects in ProjectN: \(c.projects.map(\.name).joined(separator: ", ").ifEmpty("none"))
        MCP servers available: \(c.mcpServers.map { "\($0.name) [\($0.summary)]" }.joined(separator: "; ").ifEmpty("none"))
        Claude models: \(c.models.prefix(8).map { "\($0.id) (\($0.label))" }.joined(separator: ", "))
        Existing agents: \(c.existingAgents.joined(separator: ", ").ifEmpty("none"))
        """
    }

    // MARK: Prompts

    static func questionsPrompt(description: String, context: Context) -> String {
        """
        You help a non-technical user of ProjectN (a macOS app that runs AI coding/marketing agents on local projects)
        create a new agent. They described it like this:

        \"\"\"\(description)\"\"\"

        \(contextText(context))

        Ask at most 4 short, concrete questions whose answers would most improve the agent (its exact responsibilities,
        which projects, whether it may change files or only read/plan, tools or services it needs, how often / when it
        should work on its own, tone or output format). Skip anything already clear. For each question give 2–4 short
        answer options the user can just pick. Write in the same language the user wrote in.
        """
    }

    static func designPrompt(description: String, answers: String, context: Context) -> String {
        """
        Design a complete ProjectN agent profile from this request.

        Request:
        \"\"\"\(description)\"\"\"

        Answers to follow-up questions:
        \(answers.isEmpty ? "(none)" : answers)

        \(contextText(context))

        Rules:
        - Write name, role, instructions and summary in the user's language. name: 1–4 words. role: 1–3 words (e.g. "SEO", "Desarrollador").
        - instructions: a clear operating manual in second person: mission; responsibilities; how to work step by step;
          quality bar; what to deliver and in which format; what NOT to do. 150–400 words. Don't restate ProjectN's
          safety rules (approvals for deleting/publishing are enforced automatically).
        - permission: readOnly unless the agent must change files; editProject if it must edit project files on its
          own; askBeforeChanges if changes should always be approved.
        - canDelegate only for coordinator / manager agents.
        - tools: pick from the list; for read-only agents never include Edit, Write, MultiEdit, NotebookEdit.
        - model: a Claude model id from the list (stronger models for complex reasoning, faster ones for simple tasks);
          effort low/medium/high/xhigh/max.
        - mcpServers / projects: only names from the lists above (allProjects true if it should work everywhere).
        - schedules: only if the user wants it to work on its own at set times; otherwise empty. For weekly schedules
          list the days by name in "days" (mon, tue, wed, thu, fri, sat, sun).
        - emoji: one Slack emoji code like ":mag:".
        """
    }

    static let questionsSchema: [String: Any] = [
        "type": "object",
        "properties": ["questions": ["type": "array", "maxItems": 4, "items": [
            "type": "object",
            "properties": ["question": ["type": "string"], "options": ["type": "array", "items": ["type": "string"]]],
            "required": ["question", "options"],
        ]]],
        "required": ["questions"],
    ]

    static func designSchema(_ c: Context) -> [String: Any] {
        let str: [String: Any] = ["type": "string"]
        let strings: [String: Any] = ["type": "array", "items": ["type": "string"]]
        return [
            "type": "object",
            "properties": [
                "name": str, "role": str, "emoji": str, "instructions": str, "summary": str,
                "permission": ["type": "string", "enum": AgentPermission.allCases.map(\.rawValue)],
                "canDelegate": ["type": "boolean"],
                "model": str,
                "effort": ["type": "string", "enum": LaunchCatalog.claudeEfforts],
                "tools": ["type": "array", "items": ["type": "string", "enum": AgentToolCatalog.claude]],
                "contextSources": strings, "mcpServers": strings, "cliTools": strings,
                "allProjects": ["type": "boolean"], "projects": strings,
                "schedules": ["type": "array", "items": [
                    "type": "object",
                    "properties": [
                        "name": str, "instruction": str, "project": str,
                        "frequency": ["type": "string", "enum": AgentSchedule.Frequency.allCases.map(\.rawValue)],
                        "hour": ["type": "integer"], "minute": ["type": "integer"],
                        "days": ["type": "array", "items": ["type": "string", "enum": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]]],
                        "everyHours": ["type": "integer"],
                    ],
                    "required": ["name", "instruction", "frequency"],
                ]],
            ],
            "required": ["name", "role", "instructions", "permission", "model", "tools", "summary"],
        ]
    }

    // MARK: Spec → profile

    /// Turns Claude's design into a profile, keeping only values that exist here (models, tools, servers, projects).
    static func profile(from s: [String: Any], context c: Context) -> AgentProfile {
        let modelIDs = c.models.map(\.id)
        var model = s["model"] as? String ?? ""
        if !modelIDs.contains(model) { model = modelIDs.first { $0.contains("sonnet") } ?? modelIDs.first ?? "claude-sonnet-5-5" }
        var effort = s["effort"] as? String
        if let e = effort, let m = c.models.first(where: { $0.id == model }), !m.efforts.isEmpty, !m.efforts.contains(e) { effort = nil }
        var p = AgentProfile(name: (s["name"] as? String).nonEmpty ?? "New Agent", role: s["role"] as? String ?? "",
                             model: model, effort: effort, instructions: s["instructions"] as? String ?? "")
        p.permission = AgentPermission(rawValue: s["permission"] as? String ?? "") ?? .readOnly
        p.canDelegate = s["canDelegate"] as? Bool ?? false
        p.sessionPolicy = .perProject
        var tools = (s["tools"] as? [String] ?? []).filter(AgentToolCatalog.claude.contains)
        if p.permission == .readOnly { tools.removeAll { AgentToolCatalog.writing.contains($0) } }
        // Same set as the access level's preset → store "follow the preset".
        p.tools = tools.isEmpty || Set(tools) == Set(AgentToolCatalog.preset(for: p.permission)) ? [] : tools
        let sources = (s["contextSources"] as? [String] ?? []).filter { !$0.hasPrefix("/") && !$0.contains("..") }
        p.contextSources = sources.isEmpty ? ["README.md"] : Array(Set(["README.md"] + sources)).sorted { $0 == "README.md" || ($1 != "README.md" && $0 < $1) }
        let serverNames = Set(c.mcpServers.map(\.name))
        p.mcpServers = (s["mcpServers"] as? [String] ?? []).filter(serverNames.contains)
        p.cliTools = (s["cliTools"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } }
        let projectByName = { (n: String) in c.projects.first { $0.name.folded == n.folded } }
        let named = (s["projects"] as? [String] ?? []).compactMap(projectByName)
        p.allProjects = (s["allProjects"] as? Bool ?? false) || named.isEmpty
        p.projectIDs = p.allProjects ? [] : named.map(\.id)
        if let e = (s["emoji"] as? String)?.trimmingCharacters(in: .whitespaces), e.count > 2 {
            p.slackIcon = e.hasPrefix(":") ? e : ":\(e.trimmingCharacters(in: CharacterSet(charactersIn: ":"))):"
        }
        p.schedules = (s["schedules"] as? [[String: Any]] ?? []).prefix(5).compactMap { x in
            guard let name = x["name"] as? String, let instruction = x["instruction"] as? String, !instruction.isEmpty else { return nil }
            var sch = AgentSchedule()
            sch.name = name
            sch.instruction = instruction
            sch.frequency = AgentSchedule.Frequency(rawValue: x["frequency"] as? String ?? "") ?? .weekdays
            sch.hour = min(23, max(0, x["hour"] as? Int ?? 9))
            sch.minute = min(59, max(0, x["minute"] as? Int ?? 0))
            // Calendar weekdays: 1 = Sunday … 7 = Saturday.
            let byName = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
            sch.weekdays = (x["days"] as? [String] ?? []).compactMap { byName[$0.lowercased().prefix(3).description] }
            if sch.weekdays.isEmpty { sch.weekdays = [2] }
            sch.everyHours = min(12, max(1, x["everyHours"] as? Int ?? 4))
            sch.projectID = (x["project"] as? String).flatMap(projectByName)?.id ?? (p.allProjects ? c.projects.first?.id : p.projectIDs.first)
            return sch
        }
        return p
    }

    // MARK: Claude

    struct CreatorError: Error, CustomStringConvertible {
        let description: String
    }

    /// `claude -p` with no tools, no MCP, no saved session, structured output. Uses your Claude Code login.
    nonisolated static func runClaude(prompt: String, schema: [String: Any]) async throws -> [String: Any] {
        let settings = await MainActor.run { AppHome.load(AppSettings.self, from: AppHome.settingsFile) ?? AppSettings() }
        let schemaJSON = String(data: try JSONSerialization.data(withJSONObject: schema), encoding: .utf8) ?? "{}"
        let args = Shell.split(settings.claudeCommand) + ["-p", "--model", "claude-sonnet-5-5", "--output-format", "json",
                    "--no-session-persistence", "--tools", "", "--strict-mcp-config", "--json-schema", schemaJSON, "--", prompt]
        let shell = settings.shell.isEmpty ? "/bin/zsh" : settings.shell
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("projectn-agent-creator")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let env = Dictionary(Launcher.environment(project: Project(name: "creator", path: workDir.path), workspaceName: "", settings: settings)
            .compactMap { kv -> (String, String)? in
                guard let i = kv.firstIndex(of: "=") else { return nil }
                return (String(kv[..<i]), String(kv[kv.index(after: i)...]))
            }, uniquingKeysWith: { a, _ in a })
        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: shell)
            p.arguments = ["-l", "-c", args.map(Shell.quote).joined(separator: " ")]
            p.environment = env
            p.currentDirectoryURL = workDir
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            p.terminationHandler = { proc in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    cont.resume(throwing: CreatorError(description: "Claude Code didn't answer (exit \(proc.terminationStatus)). \(errText.suffix(300))"))
                    return
                }
                if obj["is_error"] as? Bool == true {
                    cont.resume(throwing: CreatorError(description: (obj["result"] as? String) ?? "Claude Code reported an error"))
                    return
                }
                if let s = obj["structured_output"] as? [String: Any] { cont.resume(returning: s); return }
                if let r = obj["result"] as? String, let d = r.data(using: .utf8),
                   let s = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { cont.resume(returning: s); return }
                cont.resume(throwing: CreatorError(description: "Unexpected answer from Claude Code"))
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}

private extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? { self.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
}

// MARK: - UI

struct AgentCreatorSheet: View {
    @StateObject private var creator: AgentCreator
    @Environment(\.dismiss) private var dismiss
    let onCreated: (UUID) -> Void

    init(harness: AgentHarness, store: Store, onCreated: @escaping (UUID) -> Void) {
        _creator = StateObject(wrappedValue: AgentCreator(harness: harness, store: store))
        self.onCreated = onCreated
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(Color.appAccent)
                Text("Create an Agent with AI").font(.title3.bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.hover)
            }
            switch creator.stage {
            case .describe: describe
            case .asking: working("Thinking about what to ask you…")
            case .questions: questionsView
            case .designing: working("Designing the agent: instructions, access, tools, schedules…")
            case .review: review
            case .failed(let e):
                VStack(alignment: .leading, spacing: 10) {
                    Label(e, systemImage: "xmark.octagon").foregroundStyle(.red)
                    HStack { Spacer(); Button("Back") { creator.stage = .describe } }
                }
            }
        }
        .padding(20)
        .frame(width: 620, height: 640, alignment: .top)
    }

    private var describe: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Describe the agent in a few words — what it should do and for whom. You'll get a couple of quick questions, then a complete agent to review.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $creator.description)
                .font(.body).frame(height: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Text("Ideas: “Un agente SEO que cada lunes revise las páginas de mis clientes y me proponga mejoras” · “Un redactor que escriba posts de blog con el tono de la marca” · “Un desarrollador que arregle bugs en los sitios web”")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
            HStack {
                Spacer()
                Button("Continue") { creator.askQuestions() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(creator.description.trimmingCharacters(in: .whitespacesAndNewlines).count < 8)
            }
        }
    }

    private func working(_ text: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var questionsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A few quick questions (pick an option or write your own; you can skip any):").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach($creator.questions) { $q in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(q.text).fontWeight(.medium)
                            FlowRow(spacing: 6) {
                                ForEach(q.options, id: \.self) { o in
                                    let on = q.answer == o
                                    Button(o) { q.answer = on ? "" : o }
                                        .buttonStyle(.plain)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(Capsule().fill(on ? Color.appAccent : Color.primary.opacity(0.07)))
                                        .foregroundStyle(on ? .white : .primary)
                                }
                            }
                            TextField("Your answer", text: $q.answer).textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .padding(.trailing, 6)
            }
            HStack {
                Button("Back") { creator.stage = .describe }
                Spacer()
                Button("Create Agent") { creator.design() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder private var review: some View {
        if let p = creator.draft {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    AgentAvatar(profile: p, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Name", text: Binding(get: { creator.draft?.name ?? "" }, set: { creator.draft?.name = $0 }))
                            .font(.title3.weight(.semibold)).textFieldStyle(.plain)
                        Text("\(p.role) · \(LaunchCatalog.modelLabel(p.model, tool: .claude))\(p.effort.map { " · \($0)" } ?? "") · \(p.permission.label)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !creator.summary.isEmpty { Text(creator.summary).font(.callout) }
                let facts: [String] = [
                    p.canDelegate ? "Coordinates other agents" : nil,
                    p.allProjects ? "All projects" : "Projects: \(p.projectIDs.count)",
                    p.mcpServers.isEmpty ? nil : "MCP: \(p.mcpServers.joined(separator: ", "))",
                    p.cliTools.isEmpty ? nil : "CLI: \(p.cliTools.joined(separator: ", "))",
                    p.schedules.isEmpty ? nil : "Schedules: " + p.schedules.map { "\($0.name) (\($0.summary))" }.joined(separator: "; "),
                    "Context: \(p.contextSources.joined(separator: ", "))",
                    "Slack: #\(SlackRouter.channelName(for: p.name)) \(p.slackEmoji)",
                ].compactMap { $0 }
                ForEach(facts, id: \.self) { Label($0, systemImage: "checkmark.circle").font(.caption) }
                Text("Instructions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { creator.draft?.instructions ?? "" }, set: { creator.draft?.instructions = $0 }))
                    .font(.callout)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                HStack {
                    Button("Start Over") { creator.stage = .describe }
                    Button("Regenerate") { creator.design() }
                    Spacer()
                    Text("You can fine-tune everything later in its settings.").font(.caption).foregroundStyle(.secondary)
                    Button("Create Agent") {
                        if let id = creator.create() { onCreated(id); dismiss() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

/// Wrapping row of small views (answer chips).
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 500
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
