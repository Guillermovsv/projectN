import Foundation

/// Receives Slack messages over Socket Mode, checks who sent them, routes them to an agent + project,
/// queues the task in the harness and posts progress/results back in the message's thread.
/// Runs inside the ProjectN process: when ProjectN quits, the connection closes.
@MainActor
final class SlackConnector: ObservableObject {
    enum Status: Equatable {
        case off
        case missingTokens
        case connecting
        case connected(team: String, bot: String)
        case error(String)

        var label: String {
            switch self {
            case .off: return "Off"
            case .missingTokens: return "Add both tokens to connect"
            case .connecting: return "Connecting…"
            case .connected(let team, let bot): return "Connected to \(team) as @\(bot)"
            case .error(let e): return e
            }
        }
    }

    @Published private(set) var status: Status = .off
    @Published var settings: SlackSettings {
        didSet {
            guard settings != oldValue else { return }
            var all = IntegrationSettings.load()
            all.slack = settings
            all.save()
            if settings.enabled != oldValue.enabled { restart() }
        }
    }
    /// Recent routing decisions, newest first (for the settings screen).
    @Published private(set) var activity: [String] = []

    private weak var harness: AgentHarness?
    private weak var store: Store?
    private let socket = SlackSocketClient()
    private var botUserID: String?
    private var botToken: String?
    private var seen = SeenEvents()

    /// Threads waiting for "which project?" answers.
    struct PendingClarification {
        let agentID: UUID
        let instruction: String
        let user: String
        let candidates: [Project]
        let createdAt: Date
        let resume: Bool
    }
    private var pending: [String: PendingClarification] = [:]

    init() {
        settings = IntegrationSettings.load().slack
    }

    func attach(store: Store, harness: AgentHarness) {
        guard self.harness == nil else { return }
        self.store = store
        self.harness = harness
        harness.observe("slack") { [weak self] task, event in self?.taskEvent(task, event) }
        socket.onState = { [weak self] s in self?.socketState(s) }
        socket.onEnvelope = { [weak self] type, payload, retry in self?.envelope(type, payload, retry: retry) }
        restart()
    }

    // MARK: Connection

    var hasTokens: Bool {
        !(IntegrationSecrets.get(IntegrationSecrets.slackAppToken) ?? "").isEmpty
            && !(IntegrationSecrets.get(IntegrationSecrets.slackBotToken) ?? "").isEmpty
    }

    func saveTokens(appToken: String?, botToken: String?) {
        if let appToken { IntegrationSecrets.set(IntegrationSecrets.slackAppToken, value: appToken.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let botToken { IntegrationSecrets.set(IntegrationSecrets.slackBotToken, value: botToken.trimmingCharacters(in: .whitespacesAndNewlines)) }
        AuditLog.record("slack.tokens_updated", ["app": appToken == nil ? "unchanged" : "set", "bot": botToken == nil ? "unchanged" : "set"])
        restart()
    }

    func removeTokens() {
        IntegrationSecrets.delete(IntegrationSecrets.slackAppToken)
        IntegrationSecrets.delete(IntegrationSecrets.slackBotToken)
        AuditLog.record("slack.tokens_removed")
        restart()
    }

    func restart() {
        socket.disconnect()
        botUserID = nil
        guard settings.enabled else { status = .off; return }
        guard let app = IntegrationSecrets.get(IntegrationSecrets.slackAppToken), !app.isEmpty,
              let bot = IntegrationSecrets.get(IntegrationSecrets.slackBotToken), !bot.isEmpty else {
            status = .missingTokens
            return
        }
        guard app.hasPrefix("xapp-") else { status = .error("The App Token must start with xapp-"); return }
        guard bot.hasPrefix("xoxb-") else { status = .error("The Bot Token must start with xoxb-"); return }
        botToken = bot
        status = .connecting
        Task {
            do {
                let auth = try await SlackAPI(token: bot).call("auth.test")
                self.botUserID = auth["user_id"] as? String
                let team = auth["team"] as? String ?? "Slack"
                let user = auth["user"] as? String ?? "bot"
                guard self.settings.enabled else { return }
                self.status = .connecting
                self.pendingStatus = .connected(team: team, bot: user)
                self.socket.connect(appToken: app)
            } catch {
                self.status = .error("Bot token: \(error)")
                AuditLog.record("slack.error", ["error": "\(error)"])
            }
        }
    }

    private var pendingStatus: Status?

    private func socketState(_ s: SlackSocketClient.State) {
        switch s {
        case .connected:
            status = pendingStatus ?? .connected(team: "Slack", bot: "bot")
            AuditLog.record("slack.connected")
            deliverUndelivered()
        case .connecting: status = .connecting
        case .disconnected: if settings.enabled { status = .connecting }
        case .failed(let e):
            status = .error(e)
            AuditLog.record("slack.error", ["error": e])
        }
    }

    // MARK: Incoming

    private func envelope(_ type: String, _ payload: [String: Any], retry: Int) {
        if type == "interactive" { handleInteraction(payload); return }
        guard type == "events_api", let event = payload["event"] as? [String: Any] else { return }
        let eventID = payload["event_id"] as? String ?? ""
        handle(event: event, eventID: eventID, retry: retry)
    }

    /// Entry point for one Slack event (also used by tests).
    func handle(event: [String: Any], eventID: String, retry: Int = 0) {
        let type = event["type"] as? String ?? ""
        let channel = event["channel"] as? String ?? ""
        let ts = event["ts"] as? String ?? ""
        let user = event["user"] as? String ?? ""
        let channelType = event["channel_type"] as? String
        let threadTS = event["thread_ts"] as? String
        let text = event["text"] as? String ?? ""

        // Never react to bots (including ourselves) or to edits/deletes/joins.
        if event["bot_id"] != nil || (botUserID != nil && user == botUserID) || user.isEmpty { return }
        if let sub = event["subtype"] as? String, sub != "thread_broadcast", sub != "file_share" { return }

        let isDM = channelType == "im"
        let threadKey = "\(channel):\(threadTS ?? ts)"
        let isClarificationReply = threadTS != nil && (pending[threadKey] != nil || !userRequests(channel: channel, thread: threadTS ?? "").isEmpty)
        guard type == "app_mention" || (type == "message" && (isDM || isClarificationReply)) else { return }

        // Slack retries unacknowledged deliveries, and a mention also arrives as a "message" event:
        // dedupe on both the event id and the message itself.
        let messageKey = "\(channel):\(ts)"
        if seen.contains(eventID) || seen.contains(messageKey) {
            AuditLog.record("slack.duplicate_ignored", ["event": eventID, "retry": String(retry)])
            return
        }
        seen.insert(eventID)
        seen.insert(messageKey)

        let reply = threadTS ?? ts
        guard settings.authorizedUsers.contains(user.uppercased()) else {
            log("Ignored message from unauthorised user \(user)")
            AuditLog.record("slack.unauthorized_user", ["user": user, "channel": channel])
            if settings.replyToUnauthorized {
                post(channel, reply, "⛔ No estás autorizado para dar instrucciones a los agentes de ProjectN. Pide a un administrador que agregue tu ID (\(user)) en Settings → Integrations → Slack.")
            }
            return
        }
        if isDM {
            guard settings.allowDirectMessages else {
                AuditLog.record("slack.dm_disabled", ["user": user])
                post(channel, reply, "Los mensajes directos están desactivados. Menciona al bot en un canal autorizado.")
                return
            }
        } else if !settings.authorizedChannels.contains(channel.uppercased()) {
            log("Ignored message in unauthorised channel \(channel)")
            AuditLog.record("slack.unauthorized_channel", ["user": user, "channel": channel])
            post(channel, reply, "⛔ Este canal no está autorizado para ProjectN. Agrega su ID (\(channel)) en Settings → Integrations → Slack.")
            return
        }

        let cleaned = SlackRouter.clean(text)
        AuditLog.record("slack.message", ["user": user, "channel": channel, "ts": ts, "text": cleaned])

        // A reply in a thread where an agent is waiting on you answers it (oldest first).
        if let threadTS, let r = userRequests(channel: channel, thread: threadTS).first, let harness {
            let f = cleaned.folded.trimmingCharacters(in: CharacterSet(charactersIn: " .!¡"))
            switch r.kind {
            case .question:
                harness.resolveRequest(r.id, answer: cleaned, by: "<@\(user)>")
                return
            case .approval:
                if ["aprobar", "aprobado", "apruebo", "approve", "approved", "si", "yes", "ok", "dale"].contains(f) {
                    harness.resolveRequest(r.id, approve: true, by: "<@\(user)>"); return
                }
                if ["rechazar", "rechazado", "deny", "denied", "no", "cancelar"].contains(f) {
                    harness.resolveRequest(r.id, approve: false, by: "<@\(user)>"); return
                }
            }
        }

        if let p = pending[threadKey] {
            if Date().timeIntervalSince(p.createdAt) < 30 * 60, let project = SlackRouter.pickFromReply(cleaned, candidates: p.candidates) {
                pending[threadKey] = nil
                submit(agentID: p.agentID, project: project, instruction: p.instruction, user: user, channel: channel,
                       threadTS: reply, messageTS: ts, resume: p.resume)
                return
            }
            if Date().timeIntervalSince(p.createdAt) >= 30 * 60 { pending[threadKey] = nil }
            else if type == "message" && !isDM {
                post(channel, reply, "No reconozco ese proyecto. Responde con el número o el nombre exacto.")
                return
            }
        }
        route(cleaned, user: user, channel: channel, threadTS: reply, messageTS: ts, inThread: threadTS != nil)
    }

    private func route(_ text: String, user: String, channel: String, threadTS: String, messageTS: String, inThread: Bool) {
        guard let harness, let store else { return }
        guard !text.isEmpty else {
            post(channel, threadTS, "Hola 👋 Escríbeme una instrucción, por ejemplo: “Project Manager, revisa el proyecto X y dime qué tareas pendientes ves”.")
            return
        }
        let (agentOpt, instruction) = SlackRouter.matchAgent(text, agents: harness.profiles, defaultID: settings.defaultAgentID)
        guard let agent = agentOpt else {
            let names = harness.availableAgents().map(\.name).joined(separator: ", ")
            post(channel, threadTS, "No encontré un agente para este mensaje. Empieza con su nombre (\(names.isEmpty ? "no hay agentes activos" : names)) o elige un Default Agent en ProjectN.")
            return
        }
        let wantsResume = SlackRouter.wantsResume(instruction)
        // Explicit resume: the same thread's most recent task for this agent.
        if wantsResume, inThread,
           let prev = harness.tasks.last(where: { $0.origin.slackChannel == channel && $0.origin.slackThreadTS == threadTS && $0.agentID == agent.id && $0.sessionID != nil }),
           let project = store.project(prev.projectID) {
            submit(agentID: agent.id, project: project, instruction: instruction, user: user, channel: channel,
                   threadTS: threadTS, messageTS: messageTS, resume: true, resumeTaskID: prev.id)
            return
        }

        // "crea el proyecto X …": you asked for it explicitly, so ProjectN creates it and starts the task there.
        if let name = SlackRouter.createProjectName(instruction),
           !store.state.projects.contains(where: { $0.name.folded == name.folded }) {
            switch harness.createProject(name: name, description: nil, by: "<@\(user)> via Slack", allowAgent: agent.id) {
            case .success(let p):
                post(channel, threadTS, "📁 Proyecto *\(p.name)* creado en `\(p.path.abbreviatingWithTilde)` y agregado a ProjectN.")
                submit(agentID: agent.id, project: p, instruction: instruction, user: user, channel: channel,
                       threadTS: threadTS, messageTS: messageTS, resume: false)
            case .failure(let e):
                post(channel, threadTS, "❌ No pude crear el proyecto “\(name)”: \(e.description)")
            }
            return
        }

        let allowed = store.state.projects.filter { agent.mayAccess($0.id) }
        switch SlackRouter.resolveProject(instruction, allowed: allowed, selectedProjectID: store.focusedProjectID) {
        case .project(let p):
            submit(agentID: agent.id, project: p, instruction: instruction, user: user, channel: channel,
                   threadTS: threadTS, messageTS: messageTS, resume: wantsResume)
        case .ambiguous(let list):
            ask(list, agent: agent, instruction: instruction, user: user, channel: channel, threadTS: threadTS,
                intro: "Encontré varios proyectos que coinciden. ¿Cuál?", resume: wantsResume)
        case .notFound(let name, let list):
            AuditLog.record("slack.project_not_found", ["name": name, "agent": agent.name])
            if list.isEmpty {
                post(channel, threadTS, "No encuentro el proyecto “\(name)” y \(agent.name) no tiene proyectos autorizados.")
            } else {
                ask(list, agent: agent, instruction: instruction, user: user, channel: channel, threadTS: threadTS,
                    intro: "No encuentro el proyecto “\(name)”. ¿Te refieres a alguno de estos?", resume: wantsResume)
            }
        case .unspecified(let list):
            if list.isEmpty {
                post(channel, threadTS, "\(agent.name) no tiene proyectos autorizados. Agrégalos en Settings → Agents → Project Access.")
            } else {
                ask(list, agent: agent, instruction: instruction, user: user, channel: channel, threadTS: threadTS,
                    intro: "¿En qué proyecto debe trabajar \(agent.name)?", resume: wantsResume)
            }
        }
    }

    private func ask(_ list: [Project], agent: AgentProfile, instruction: String, user: String, channel: String,
                     threadTS: String, intro: String, resume: Bool) {
        let shown = Array(list.prefix(15))
        pending["\(channel):\(threadTS)"] = PendingClarification(agentID: agent.id, instruction: instruction, user: user,
                                                                  candidates: shown, createdAt: Date(), resume: resume)
        let items = shown.enumerated().map { "\($0.offset + 1). \($0.element.name)" }.joined(separator: "\n")
        post(channel, threadTS, "\(intro)\n\(items)\nResponde en este hilo con el número o el nombre.")
        log("Asked which project for \(agent.name)")
    }

    private func submit(agentID: UUID, project: Project, instruction: String, user: String, channel: String,
                        threadTS: String, messageTS: String, resume: Bool, resumeTaskID: UUID? = nil) {
        guard let harness else { return }
        if resume && resumeTaskID == nil {
            post(channel, threadTS, "ℹ️ No hay una sesión anterior en este hilo para reanudar; empiezo una sesión nueva.")
        }
        let origin = TaskOrigin(kind: .slack, slackChannel: channel, slackThreadTS: threadTS, slackMessageTS: messageTS, slackUser: user)
        let req = AgentTaskRequest(agentID: agentID, projectID: project.id, instruction: instruction, origin: origin, resumeTaskID: resumeTaskID)
        switch harness.submit(req) {
        case .success(let t):
            log("Queued \(t.agentName) → \(project.name)")
            if t.status == .queued, settings.notifyOnStart {
                post(channel, threadTS, "🕓 En cola: *\(t.agentName)* empezará en *\(project.name)* cuando haya capacidad.")
            }
        case .failure(let e):
            log("Rejected: \(e)")
            post(channel, threadTS, "❌ No pude iniciar la tarea: \(e.description)")
        }
    }

    // MARK: Outgoing

    private func taskEvent(_ t: AgentTask, _ event: AgentHarness.Event) {
        // A scheduled task that reports to Slack opens its own thread when it starts.
        if t.origin.kind == .schedule, let channel = t.origin.slackChannel, t.origin.slackThreadTS == nil {
            guard case .started = event, case .connected = status else { return }
            let text = "🗓 *\(t.agentName)* — tarea programada *\(t.origin.scheduleName ?? "")* en *\(t.projectName)*:\n> \(Self.firstLine(t.instruction))"
            Task {
                if let ts = await send(channel, nil, text) { harness?.setSlackThread(t.id, channel: channel, ts: ts) }
            }
            return
        }
        guard let channel = t.origin.slackChannel, let thread = t.origin.slackThreadTS else { return }
        let delegated = t.origin.kind == .agent
        switch event {
        case .started:
            guard settings.notifyOnStart else { return }
            if delegated {
                post(channel, thread, "↳ *\(t.origin.delegatedBy ?? "Un agente")* delegó a *\(t.agentName)* (\(t.projectName)): \(Self.firstLine(t.instruction))")
                return
            }
            let label = ModelCatalog.shared.claude.models.first { $0.id == t.model }?.label ?? t.model
            let session = t.resumedFromTaskID == nil ? "sesión nueva" : "sesión reanudada"
            post(channel, thread, "▶️ *\(t.agentName)* trabajando en *\(t.projectName)* — \(session) · \(label)\(t.effort.map { " · effort \($0)" } ?? "") · \(t.permission.label)")
        case .approvalNeeded(let q):
            guard settings.notifyApprovals else { return }
            let quoted = q.split(separator: "\n").prefix(12).map { "> \($0)" }.joined(separator: "\n")
            post(channel, thread, "⏸ *\(t.agentName)* espera una respuesta en su terminal de ProjectN:\n\(quoted)\nÁbrelo en ProjectN → workspace *Agents*.")
        case .planProposed(let plan):
            guard settings.notifyApprovals else { return }
            postLong(channel, thread, "📝 *\(t.agentName)* propone este plan (espera tu aprobación en ProjectN):\n\n" + SlackRouter.toSlack(plan))
        case .finished:
            if delegated {
                if settings.notifyOnStart || (t.status != .completed && settings.notifyErrors) {
                    let icon = t.status == .completed ? "✓" : "✗"
                    post(channel, thread, "↳ \(icon) *\(t.agentName)* — \(t.status.label)\(t.error.map { ": \(Self.firstLine($0))" } ?? "")")
                }
                harness?.markDelivered(t.id)
            } else {
                deliver(t)
            }
        case .requestCreated(let r):
            requestCreated(r, task: t, channel: channel, thread: thread)
        case .requestResolved(let r):
            requestResolved(r, channel: channel, thread: thread)
        }
    }

    // MARK: Approvals & questions

    /// Messages showing a request, so they can be updated when it's decided.
    private var requestMessages: [UUID: (channel: String, ts: String)] = [:]

    func userRequests(channel: String, thread: String) -> [AgentRequest] {
        guard let harness else { return [] }
        return harness.pendingUserRequests().filter { r in
            guard let t = harness.task(r.taskID) else { return false }
            return t.origin.slackChannel == channel && t.origin.slackThreadTS == thread
        }
    }

    static func firstLine(_ s: String) -> String {
        let l = s.split(separator: "\n").first.map(String.init) ?? s
        return l.count > 140 ? String(l.prefix(140)) + "…" : l
    }

    static func approvalBlocks(_ text: String, requestID: UUID) -> [[String: Any]] {
        [["type": "section", "text": ["type": "mrkdwn", "text": text]],
         ["type": "actions", "block_id": "pn_request", "elements": [
            ["type": "button", "text": ["type": "plain_text", "text": "Aprobar"], "style": "primary",
             "action_id": "pn_approve", "value": requestID.uuidString],
            ["type": "button", "text": ["type": "plain_text", "text": "Rechazar"], "style": "danger",
             "action_id": "pn_deny", "value": requestID.uuidString],
         ]]]
    }

    private func requestCreated(_ r: AgentRequest, task t: AgentTask, channel: String, thread: String) {
        switch r.route {
        case .user:
            let text: String
            switch r.kind {
            case .approval:
                text = "🔐 *\(t.agentName)* necesita tu aprobación:\n```\(r.summary)```\n_\(r.reason)_\n(o responde *aprobar* / *rechazar* en este hilo)"
                Task {
                    if let ts = await send(channel, thread, text, blocks: Self.approvalBlocks(text, requestID: r.id)) {
                        requestMessages[r.id] = (channel, ts)
                    }
                }
            case .question:
                text = "❓ *\(t.agentName)* pregunta:\n> \(r.summary.replacingOccurrences(of: "\n", with: "\n> "))\nResponde en este hilo."
                Task { if let ts = await send(channel, thread, text) { requestMessages[r.id] = (channel, ts) } }
            }
            log("Waiting on you: \(t.agentName) — \(r.summary)")
        case .orchestrator:
            guard settings.notifyApprovals else { return }
            post(channel, thread, "🤖 *\(t.agentName)* consulta a *\(t.origin.delegatedBy ?? "su coordinador")*: `\(ApprovalPolicy.clip(r.summary))`")
        }
    }

    private func requestResolved(_ r: AgentRequest, channel: String, thread: String) {
        let outcome: String
        switch r.status {
        case .approved: outcome = "✅ Aprobado por \(r.decidedBy ?? "?")"
        case .denied: outcome = "⛔ Rechazado por \(r.decidedBy ?? "?")"
        case .answered: outcome = "💬 Respondido por \(r.decidedBy ?? "?")"
        case .expired: outcome = "⌛ Sin respuesta — \(r.decidedBy ?? "expiró")"
        case .pending: return
        }
        if let m = requestMessages.removeValue(forKey: r.id) {
            let text = "*\(r.agentName)*: `\(ApprovalPolicy.clip(r.summary))`\n\(outcome)\(r.answer.map { " — \($0)" } ?? "")"
            Task { await update(m.channel, m.ts, text) }
        } else if settings.notifyApprovals, r.route != .user || r.decidedBy?.hasPrefix("ProjectN") == true {
            post(channel, thread, "\(outcome) para *\(r.agentName)*: `\(ApprovalPolicy.clip(r.summary))`\(r.answer.map { " — \($0)" } ?? "")")
        }
    }

    /// Button clicks (Socket Mode "interactive" envelopes).
    func handleInteraction(_ payload: [String: Any]) {
        guard payload["type"] as? String == "block_actions",
              let action = (payload["actions"] as? [[String: Any]])?.first,
              let id = (action["value"] as? String).flatMap(UUID.init(uuidString:)) else { return }
        let user = (payload["user"] as? [String: Any])?["id"] as? String ?? ""
        guard settings.authorizedUsers.contains(user.uppercased()) else {
            AuditLog.record("slack.unauthorized_action", ["user": user])
            if let ch = (payload["channel"] as? [String: Any])?["id"] as? String {
                let thread = ((payload["message"] as? [String: Any])?["thread_ts"] as? String)
                post(ch, thread, "⛔ <@\(user)> no está autorizado para aprobar acciones de los agentes.")
            }
            return
        }
        let approve = action["action_id"] as? String == "pn_approve"
        if let ch = (payload["channel"] as? [String: Any])?["id"] as? String,
           let ts = (payload["message"] as? [String: Any])?["ts"] as? String, requestMessages[id] == nil {
            requestMessages[id] = (ch, ts)
        }
        if harness?.resolveRequest(id, approve: approve, by: "<@\(user)>") != true {
            log("Button for a request that's no longer pending")
        }
    }

    private func deliver(_ t: AgentTask) {
        guard let channel = t.origin.slackChannel, botToken != nil,
              case .connected = status else { return }   // retried by deliverUndelivered() on reconnect
        let thread = t.origin.slackThreadTS   // nil only for a scheduled run whose start couldn't be posted
        var footer: [String] = []
        if let d = t.duration { footer.append("\(Int(d / 60)) min \(Int(d) % 60) s") }
        if let u = t.usage { footer.append("\(u.outputTokens.formatted()) output tokens (\(u.total.formatted()) incl. cache)") }
        let notes = t.notes.isEmpty ? "" : "\n" + t.notes.map { "ℹ️ \($0)" }.joined(separator: "\n")
        switch t.status {
        case .completed:
            let body = (t.result ?? "").isEmpty ? "_(sin texto en la respuesta)_" : SlackRouter.toSlack(t.result ?? "")
            postLong(channel, thread, body + notes + "\n\n_\(t.agentName) · \(t.projectName)\(footer.isEmpty ? "" : " · " + footer.joined(separator: " · "))_")
        case .cancelled, .failed, .timedOut, .interrupted:
            guard settings.notifyErrors else { break }
            let icon = t.status == .interrupted ? "⚠️" : "❌"
            post(channel, thread, "\(icon) *\(t.agentName)* — \(t.status.label): \(t.error ?? "sin detalles")\(notes)"
                 + (t.status == .interrupted ? "\nVuelve a enviar la instrucción para empezar de nuevo." : ""))
        default:
            return
        }
        harness?.markDelivered(t.id)
    }

    /// Outcomes produced while Slack was disconnected (or before a restart) are sent once connected.
    func deliverUndelivered() {
        guard let harness else { return }
        for t in harness.tasks where (t.origin.kind == .slack || (t.origin.kind == .schedule && t.origin.slackChannel != nil)) && t.status.isFinished && !t.delivered {
            // Don't flood a thread with very old outcomes.
            if let f = t.finishedAt, Date().timeIntervalSince(f) > 24 * 3600 { harness.markDelivered(t.id); continue }
            deliver(t)
        }
    }

    private func postLong(_ channel: String, _ thread: String?, _ text: String) {
        let parts = SlackRouter.chunks(text)
        Task {
            for p in parts { await send(channel, thread, p) }
        }
    }

    private func post(_ channel: String, _ thread: String?, _ text: String) {
        Task { await send(channel, thread, text) }
    }

    /// Test hook: replaces the network call.
    var sender: ((String, String?, String) async -> Void)?
    /// Test hook: message updates.
    var updater: ((String, String, String) async -> Void)?

    @discardableResult
    private func send(_ channel: String, _ thread: String?, _ text: String, blocks: [[String: Any]]? = nil) async -> String? {
        if let sender { await sender(channel, thread, text); return "test-\(UUID().uuidString)" }
        guard let token = botToken else { return nil }
        do {
            return try await SlackAPI(token: token).post(channel: channel, threadTS: thread, text: text, blocks: blocks)
        } catch {
            log("Couldn't post to Slack: \(error)")
            AuditLog.record("slack.post_failed", ["channel": channel, "error": "\(error)"])
            return nil
        }
    }

    private func update(_ channel: String, _ ts: String, _ text: String) async {
        if let updater { await updater(channel, ts, text); return }
        guard let token = botToken else { return }
        do { try await SlackAPI(token: token).update(channel: channel, ts: ts, text: text, blocks: [["type": "section", "text": ["type": "mrkdwn", "text": text]]]) }
        catch { AuditLog.record("slack.update_failed", ["error": "\(error)"]) }
    }

    // MARK: Connection check

    struct CheckResult: Identifiable {
        let id = UUID()
        let ok: Bool
        let label: String
    }
    @Published private(set) var checks: [CheckResult] = []
    @Published private(set) var checking = false

    static let requiredScopes = ["app_mentions:read", "chat:write", "im:history", "im:read"]
    static let optionalScopes = ["channels:history", "groups:history"]

    /// Verifies both tokens, the bot's scopes and Socket Mode, without changing anything.
    func checkConnection() {
        checking = true
        checks = []
        let app = IntegrationSecrets.get(IntegrationSecrets.slackAppToken) ?? ""
        let bot = IntegrationSecrets.get(IntegrationSecrets.slackBotToken) ?? ""
        Task {
            var out: [CheckResult] = []
            if bot.hasPrefix("xoxb-") {
                do {
                    let r = try await SlackAPI(token: bot).scopes()
                    out.append(.init(ok: true, label: "Bot token valid — workspace \(r.team), bot @\(r.user)"))
                    let missing = Self.requiredScopes.filter { !r.scopes.contains($0) }
                    out.append(.init(ok: missing.isEmpty, label: missing.isEmpty ? "Required scopes present" : "Missing scopes: \(missing.joined(separator: ", ")) — add them under OAuth & Permissions and reinstall"))
                    let opt = Self.optionalScopes.filter { !r.scopes.contains($0) }
                    if !opt.isEmpty { out.append(.init(ok: true, label: "Optional (thread replies without @mention in channels): \(opt.joined(separator: ", "))")) }
                } catch { out.append(.init(ok: false, label: "Bot token: \(error)")) }
            } else {
                out.append(.init(ok: false, label: bot.isEmpty ? "Bot token not saved" : "Bot token must start with xoxb-"))
            }
            if app.hasPrefix("xapp-") {
                var req = URLRequest(url: URL(string: "https://slack.com/api/apps.connections.open")!)
                req.httpMethod = "POST"
                req.setValue("Bearer \(app)", forHTTPHeaderField: "Authorization")
                let obj = (try? await URLSession.shared.data(for: req)).flatMap { try? JSONSerialization.jsonObject(with: $0.0) as? [String: Any] } ?? [:]
                let ok = obj["ok"] as? Bool == true
                out.append(.init(ok: ok, label: ok ? "App token valid, Socket Mode enabled" : "App token / Socket Mode: \(obj["error"] as? String ?? "no response") — enable Socket Mode and use a token with connections:write"))
            } else {
                out.append(.init(ok: false, label: app.isEmpty ? "App token not saved" : "App token must start with xapp-"))
            }
            out.append(.init(ok: !settings.authorizedUsers.isEmpty, label: settings.authorizedUsers.isEmpty ? "No authorized users yet — nobody can give instructions" : "\(settings.authorizedUsers.count) authorized user(s)"))
            checks = out
            checking = false
            AuditLog.record("slack.check", ["ok": out.allSatisfy(\.ok) ? "yes" : "no"])
        }
    }

    private func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        activity.insert("\(f.string(from: Date()))  \(s)", at: 0)
        if activity.count > 100 { activity.removeLast(activity.count - 100) }
    }

    // MARK: Test hooks

    func setTestIdentity(botUserID: String) {
        self.botUserID = botUserID
        self.botToken = "test"
        self.status = .connected(team: "Test", bot: "bot")
    }
}

/// Event IDs / message keys already handled. Persisted so a Slack retry arriving after a restart is still ignored.
struct SeenEvents {
    private var order: [String] = []
    private var set = Set<String>()
    private let limit = 2000

    init() {
        if let saved = AppHome.load([String].self, from: AgentStore.slackSeenFile) {
            order = saved
            set = Set(saved)
        }
    }

    func contains(_ key: String) -> Bool { !key.isEmpty && set.contains(key) }

    mutating func insert(_ key: String) {
        guard !key.isEmpty, !set.contains(key) else { return }
        order.append(key)
        set.insert(key)
        if order.count > limit {
            let drop = order.count - limit
            order.prefix(drop).forEach { set.remove($0) }
            order.removeFirst(drop)
        }
        AppHome.save(order, to: AgentStore.slackSeenFile)
    }
}
