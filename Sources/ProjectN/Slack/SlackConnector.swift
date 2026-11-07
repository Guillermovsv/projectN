import Foundation

/// One Slack app connected over Socket Mode: the general "ProjectN" bot (routes by agent name), or an agent's
/// own app (its own bot user → its own DM in Slack; everything sent to it goes to that agent).
@MainActor
final class SlackBot {
    nonisolated static let mainKey = "main"

    let key: String
    /// Set for an agent's own app.
    let agentID: UUID?
    let socket = SlackSocketClient()
    var appToken = ""
    var botToken: String?
    var botUserID: String?
    var name: String?
    var team: String?
    var status: SlackConnector.Status = .off

    init(key: String, agentID: UUID?) {
        self.key = key
        self.agentID = agentID
    }

    var isConnected: Bool { if case .connected = status { return true }; return false }
}

/// Receives Slack messages over Socket Mode, checks who sent them, routes them to an agent + project,
/// queues the task in the harness and posts progress/results back — straight into the conversation, or in a
/// thread when `replyInThreads` is on. Runs inside the ProjectN process: when ProjectN quits, the connections close.
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

    /// The bot's status (shown at the top of the Slack settings).
    @Published private(set) var status: Status = .off
    /// Workspace id (for "Open in Slack" links).
    @Published private(set) var teamID: String?
    /// Agent channel sync problems, by agent id (shown in settings).
    @Published private(set) var channelErrors: [UUID: String] = [:]
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
    private var bots: [String: SlackBot] = [:]
    private var seen = SeenEvents()

    /// Conversations waiting for "which project?" answers.
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
        harness.onProfilesChanged = { [weak self] in self?.scheduleChannelSync() }
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

    /// (Re)connects ProjectN's Slack app.
    func restart() {
        for b in bots.values { b.socket.disconnect() }
        bots = [:]
        guard settings.enabled else { status = .off; return }
        connect(SlackBot(key: SlackBot.mainKey, agentID: nil),
                app: IntegrationSecrets.get(IntegrationSecrets.slackAppToken),
                bot: IntegrationSecrets.get(IntegrationSecrets.slackBotToken))
    }

    private func setStatus(_ b: SlackBot, _ s: Status) {
        b.status = s
        status = s
    }

    private func connect(_ b: SlackBot, app: String?, bot: String?) {
        bots[b.key] = b
        guard let app, !app.isEmpty, let bot, !bot.isEmpty else { setStatus(b, .missingTokens); return }
        guard app.hasPrefix("xapp-") else { setStatus(b, .error("The App Token must start with xapp-")); return }
        guard bot.hasPrefix("xoxb-") else { setStatus(b, .error("The Bot Token must start with xoxb-")); return }
        b.appToken = app
        b.botToken = bot
        b.socket.onState = { [weak self, weak b] s in if let b { self?.socketState(b, s) } }
        b.socket.onEnvelope = { [weak self, weak b] type, payload, retry in
            if let b { self?.envelope(type, payload, retry: retry, bot: b) }
        }
        setStatus(b, .connecting)
        Task {
            do {
                let auth = try await SlackAPI(token: bot).call("auth.test")
                b.botUserID = auth["user_id"] as? String
                b.team = auth["team"] as? String ?? "Slack"
                self.teamID = auth["team_id"] as? String
                b.name = auth["user"] as? String ?? "bot"
                guard self.settings.enabled, self.bots[b.key] === b else { return }
                b.socket.connect(appToken: app)
            } catch {
                self.setStatus(b, .error("Bot token: \(error)"))
                AuditLog.record("slack.error", ["bot": b.key, "error": "\(error)"])
            }
        }
    }

    private func socketState(_ b: SlackBot, _ s: SlackSocketClient.State) {
        guard bots[b.key] === b else { return }
        switch s {
        case .connected:
            setStatus(b, .connected(team: b.team ?? "Slack", bot: b.name ?? "bot"))
            AuditLog.record("slack.connected")
            deliverUndelivered()
            syncAgentChannels()
        case .connecting: setStatus(b, .connecting)
        case .disconnected: if settings.enabled { setStatus(b, .connecting) }
        case .failed(let e):
            setStatus(b, .error(e))
            AuditLog.record("slack.error", ["bot": b.key, "error": e])
        }
    }

    // MARK: Conversation keys

    /// Where follow-ups (answers, approvals, "which project?") are matched: the thread, or the whole conversation.
    private func conversationKey(channel: String, thread: String?, ts: String) -> String {
        settings.replyInThreads ? "\(channel):\(thread ?? ts)" : channel
    }

    private var replyHere: String { settings.replyInThreads ? "en este hilo" : "aquí" }

    // MARK: Incoming

    private func envelope(_ type: String, _ payload: [String: Any], retry: Int, bot: SlackBot) {
        if type == "interactive" { handleInteraction(payload, bot: bot.key); return }
        guard type == "events_api", let event = payload["event"] as? [String: Any] else { return }
        let eventID = payload["event_id"] as? String ?? ""
        handle(event: event, eventID: eventID, retry: retry, bot: bot.key)
    }

    /// Entry point for one Slack event received by `bot` (also used by tests).
    func handle(event: [String: Any], eventID: String, retry: Int = 0, bot botKey: String = SlackBot.mainKey) {
        let type = event["type"] as? String ?? ""
        let channel = event["channel"] as? String ?? ""
        let ts = event["ts"] as? String ?? ""
        let user = event["user"] as? String ?? ""
        let channelType = event["channel_type"] as? String
        let threadTS = event["thread_ts"] as? String
        let text = event["text"] as? String ?? ""
        // An agent's own channel: everything said there is for that agent.
        let fixedAgent = agentForChannel(channel)?.id

        // Never react to bots (including ours) or to edits/deletes/joins.
        let botUsers = Set(bots.values.compactMap(\.botUserID))
        if event["bot_id"] != nil || botUsers.contains(user) || user.isEmpty { return }
        if let sub = event["subtype"] as? String, sub != "thread_broadcast", sub != "file_share" { return }

        let isDM = channelType == "im"
        let isAgentChannel = fixedAgent != nil
        let key = conversationKey(channel: channel, thread: threadTS, ts: ts)
        let waitingHere = pending[key] != nil || !userRequests(channel: channel, thread: threadTS ?? ts).isEmpty
        let isFollowUp = waitingHere && (threadTS != nil || !settings.replyInThreads)
        guard type == "app_mention" || (type == "message" && (isDM || isAgentChannel || isFollowUp)) else { return }

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
                post(channel, reply, "⛔ No estás autorizado para dar instrucciones a los agentes de ProjectN. Pide a un administrador que agregue tu ID (\(user)) en Settings → Integrations → Slack.", bot: botKey)
            }
            return
        }
        if isDM {
            guard settings.allowDirectMessages else {
                AuditLog.record("slack.dm_disabled", ["user": user])
                post(channel, reply, "Los mensajes directos están desactivados. Menciona al bot en un canal autorizado.", bot: botKey)
                return
            }
        } else if !isAgentChannel && !settings.authorizedChannels.contains(channel.uppercased()) {
            log("Ignored message in unauthorised channel \(channel)")
            AuditLog.record("slack.unauthorized_channel", ["user": user, "channel": channel])
            post(channel, reply, "⛔ Este canal no está autorizado para ProjectN. Agrega su ID (\(channel)) en Settings → Integrations → Slack.", bot: botKey)
            return
        }

        let cleaned = SlackRouter.clean(text)
        AuditLog.record("slack.message", ["user": user, "channel": channel, "ts": ts, "text": cleaned, "bot": botKey])

        // A reply where an agent is waiting on you answers it (oldest first). Without threads, a message that
        // starts with an agent's name is a new request instead.
        let namesAgent = fixedAgent == nil && SlackRouter.matchAgent(cleaned, agents: harness?.profiles ?? [], defaultID: nil).agent != nil
            && SlackRouter.matchAgent(cleaned, agents: harness?.profiles ?? [], defaultID: nil).instruction != cleaned
        let waiting = userRequests(channel: channel, thread: threadTS ?? ts)
        if !waiting.isEmpty, let harness, settings.replyInThreads ? threadTS != nil : !namesAgent {
            let f = cleaned.folded.trimmingCharacters(in: CharacterSet(charactersIn: " .!¡"))
            let yes = ["aprobar", "aprobado", "apruebo", "approve", "approved", "si", "yes", "ok", "dale"].contains(f)
            let no = ["rechazar", "rechazado", "deny", "denied", "no", "cancelar"].contains(f)
            // "aprobar" / "rechazar" decide the oldest approval; anything else answers the oldest question.
            if yes || no, let a = waiting.first(where: { $0.kind == .approval }) {
                harness.resolveRequest(a.id, approve: yes, by: "<@\(user)>"); return
            }
            if let q = waiting.first(where: { $0.kind == .question }) {
                harness.resolveRequest(q.id, answer: cleaned, by: "<@\(user)>"); return
            }
        }

        if let p = pending[key] {
            if Date().timeIntervalSince(p.createdAt) < 30 * 60, let project = SlackRouter.pickFromReply(cleaned, candidates: p.candidates) {
                pending[key] = nil
                submit(agentID: p.agentID, project: project, instruction: p.instruction, user: user, channel: channel,
                       threadTS: reply, messageTS: ts, resume: p.resume, bot: botKey)
                return
            }
            if Date().timeIntervalSince(p.createdAt) >= 30 * 60 { pending[key] = nil }
            else if type == "message" && !isDM {
                post(channel, reply, "No reconozco ese proyecto. Responde con el número o el nombre exacto.", bot: botKey)
                return
            }
        }
        route(cleaned, user: user, channel: channel, threadTS: reply, messageTS: ts, inThread: threadTS != nil, bot: botKey)
    }

    private func route(_ text: String, user: String, channel: String, threadTS: String, messageTS: String, inThread: Bool, bot botKey: String) {
        guard let harness, let store else { return }
        let fixedAgent = agentForChannel(channel)
        guard !text.isEmpty else {
            post(channel, threadTS, fixedAgent != nil
                 ? "Hola 👋 Soy \(fixedAgent!.name). Escríbeme qué necesitas y en qué proyecto."
                 : "Hola 👋 Escríbeme una instrucción, por ejemplo: “Project Manager, revisa el proyecto X y dime qué tareas pendientes ves”.", bot: botKey)
            return
        }
        // An agent's own channel: everything goes to that agent (its name at the start is optional).
        let (agentOpt, instruction): (AgentProfile?, String) = fixedAgent.map { a in
            let m = SlackRouter.matchAgent(text, agents: [a], defaultID: nil)
            return (a, m.agent != nil ? m.instruction : text)
        } ?? SlackRouter.matchAgent(text, agents: harness.profiles, defaultID: settings.defaultAgentID)
        guard let agent = agentOpt else {
            let names = harness.availableAgents().map(\.name).joined(separator: ", ")
            post(channel, threadTS, "No encontré un agente para este mensaje. Empieza con su nombre (\(names.isEmpty ? "no hay agentes activos" : names)) o elige un Default Agent en ProjectN.", bot: botKey)
            return
        }
        guard agent.enabled else {
            post(channel, threadTS, "⏸ \(agent.name) está desactivado en ProjectN.", bot: botKey)
            return
        }
        let wantsResume = SlackRouter.wantsResume(instruction)
        // Explicit resume: this conversation's (or thread's) most recent task for this agent.
        if wantsResume, inThread || !settings.replyInThreads,
           let prev = harness.tasks.last(where: {
               $0.origin.slackChannel == channel && $0.agentID == agent.id && $0.sessionID != nil
                   && (!settings.replyInThreads || $0.origin.slackThreadTS == threadTS)
           }),
           let project = store.project(prev.projectID) {
            submit(agentID: agent.id, project: project, instruction: instruction, user: user, channel: channel,
                   threadTS: threadTS, messageTS: messageTS, resume: true, resumeTaskID: prev.id, bot: botKey)
            return
        }

        // "crea el proyecto X …": you asked for it explicitly, so ProjectN creates it and starts the task there.
        if let name = SlackRouter.createProjectName(instruction),
           !store.state.projects.contains(where: { $0.name.folded == name.folded }) {
            switch harness.createProject(name: name, description: nil, by: "<@\(user)> via Slack", allowAgent: agent.id) {
            case .success(let p):
                post(channel, threadTS, "📁 Proyecto *\(p.name)* creado en `\(p.path.abbreviatingWithTilde)` y agregado a ProjectN.", bot: botKey)
                submit(agentID: agent.id, project: p, instruction: instruction, user: user, channel: channel,
                       threadTS: threadTS, messageTS: messageTS, resume: false, bot: botKey)
            case .failure(let e):
                post(channel, threadTS, "❌ No pude crear el proyecto “\(name)”: \(e.description)", bot: botKey)
            }
            return
        }

        let allowed = store.state.projects.filter { agent.mayAccess($0.id) }
        // Not naming a project = keep working on the one this conversation was about with this agent.
        let lastHere = harness.tasks.last { $0.origin.slackChannel == channel && $0.agentID == agent.id }?.projectID
        switch SlackRouter.resolveProject(instruction, allowed: allowed, selectedProjectID: store.focusedProjectID,
                                          conversationProjectID: lastHere) {
        case .project(let p):
            submit(agentID: agent.id, project: p, instruction: instruction, user: user, channel: channel,
                   threadTS: threadTS, messageTS: messageTS, resume: wantsResume, bot: botKey)
        case .ambiguous(let list):
            ask(list, agent: agent, instruction: instruction, user: user, channel: channel, threadTS: threadTS,
                intro: "Encontré varios proyectos que coinciden. ¿Cuál?", resume: wantsResume, bot: botKey)
        case .notFound(let name, let list):
            AuditLog.record("slack.project_not_found", ["name": name, "agent": agent.name])
            if list.isEmpty {
                post(channel, threadTS, "No encuentro el proyecto “\(name)” y \(agent.name) no tiene proyectos autorizados.", bot: botKey)
            } else {
                ask(list, agent: agent, instruction: instruction, user: user, channel: channel, threadTS: threadTS,
                    intro: "No encuentro el proyecto “\(name)”. ¿Te refieres a alguno de estos?", resume: wantsResume, bot: botKey)
            }
        case .unspecified(let list):
            if list.isEmpty {
                post(channel, threadTS, "\(agent.name) no tiene proyectos autorizados. Agrégalos en Settings → Agents → Projects.", bot: botKey)
            } else {
                ask(list, agent: agent, instruction: instruction, user: user, channel: channel, threadTS: threadTS,
                    intro: "¿En qué proyecto debe trabajar \(agent.name)?", resume: wantsResume, bot: botKey)
            }
        }
    }

    private func ask(_ list: [Project], agent: AgentProfile, instruction: String, user: String, channel: String,
                     threadTS: String, intro: String, resume: Bool, bot: String) {
        let shown = Array(list.prefix(15))
        pending[conversationKey(channel: channel, thread: threadTS, ts: threadTS)] =
            PendingClarification(agentID: agent.id, instruction: instruction, user: user, candidates: shown, createdAt: Date(), resume: resume)
        let items = shown.enumerated().map { "\($0.offset + 1). \($0.element.name)" }.joined(separator: "\n")
        post(channel, threadTS, "\(intro)\n\(items)\nResponde \(replyHere) con el número o el nombre.", bot: bot)
        log("Asked which project for \(agent.name)")
    }

    private func submit(agentID: UUID, project: Project, instruction: String, user: String, channel: String,
                        threadTS: String, messageTS: String, resume: Bool, resumeTaskID: UUID? = nil, bot: String) {
        guard let harness else { return }
        if resume && resumeTaskID == nil {
            post(channel, threadTS, "ℹ️ No hay una sesión anterior \(settings.replyInThreads ? "en este hilo" : "en esta conversación") para reanudar; empiezo una sesión nueva.", bot: bot)
        }
        var origin = TaskOrigin(kind: .slack, slackChannel: channel, slackThreadTS: threadTS, slackMessageTS: messageTS, slackUser: user)
        origin.slackBot = bot
        var req = AgentTaskRequest(agentID: agentID, projectID: project.id, instruction: instruction, origin: origin, resumeTaskID: resumeTaskID)
        req.freshSession = SlackRouter.wantsNewSession(instruction)
        let existing = Set(harness.tasks.map(\.id))
        switch harness.submit(req) {
        case .success(let t) where existing.contains(t.id):
            // Went into the session that's already working on this conversation.
            log("Message for \(t.agentName)'s running session")
            post(channel, threadTS, "📨 *\(t.agentName)* ya está trabajando en *\(project.name)*: le pasé tu mensaje y lo tendrá en cuenta.", bot: bot, as: t.agentID)
        case .success(let t):
            log("Queued \(t.agentName) → \(project.name)")
            if t.status == .queued, settings.notifyOnStart {
                post(channel, threadTS, "🕓 En cola: *\(t.agentName)* empezará en *\(project.name)* cuando haya capacidad.", bot: bot)
            }
        case .failure(let e):
            log("Rejected: \(e)")
            post(channel, threadTS, "❌ No pude iniciar la tarea: \(e.description)", bot: bot)
        }
    }

    // MARK: Outgoing

    func botKey(for t: AgentTask) -> String { SlackBot.mainKey }

    /// Messages about a task are signed with its agent's current name and emoji.
    private func identity(_ agentID: UUID?) -> (name: String, emoji: String)? {
        guard let id = agentID, let p = harness?.profile(id) else { return nil }
        return (p.name, p.slackEmoji)
    }

    private func taskEvent(_ t: AgentTask, _ event: AgentHarness.Event) {
        let bot = botKey(for: t)
        // A scheduled task that reports to Slack opens its own message when it starts.
        if t.origin.kind == .schedule, let channel = t.origin.slackChannel, t.origin.slackThreadTS == nil {
            guard case .started = event, bots[bot]?.isConnected == true else { return }
            let text = "🗓 *\(t.agentName)* — tarea programada *\(t.origin.scheduleName ?? "")* en *\(t.projectName)*:\n> \(Self.firstLine(t.instruction))"
            Task {
                // The target may be a member ID: posting to it opens the DM; remember the DM channel it returns.
                if let (ch, ts) = await sendReturningChannel(channel, nil, text, bot: bot, as: t.agentID) {
                    harness?.setSlackThread(t.id, channel: ch, ts: ts)
                }
            }
            return
        }
        guard let channel = t.origin.slackChannel, let thread = t.origin.slackThreadTS else { return }
        let delegated = t.origin.kind == .agent
        switch event {
        case .started:
            guard settings.notifyOnStart, t.origin.automatic != true else { return }
            if delegated {
                post(channel, thread, "↳ *\(t.origin.delegatedBy ?? "Un agente")* delegó a *\(t.agentName)* (\(t.projectName)): \(Self.firstLine(t.instruction))", bot: bot, as: t.agentID)
                return
            }
            let label = ModelCatalog.shared.claude.models.first { $0.id == t.model }?.label ?? t.model
            if t.continuedSession == true {
                post(channel, thread, "▶️ *\(t.agentName)* sigue en *\(t.projectName)* (misma sesión)", bot: bot, as: t.agentID)
                return
            }
            let session = t.resumedFromTaskID == nil ? "sesión nueva" : "sesión reanudada"
            post(channel, thread, "▶️ *\(t.agentName)* trabajando en *\(t.projectName)* — \(session) · \(label)\(t.effort.map { " · effort \($0)" } ?? "") · \(t.permission.label)", bot: bot, as: t.agentID)
        case .approvalNeeded:
            // Posted as a request with Aprobar / Rechazar buttons (requestCreated); ProjectN answers the terminal.
            return
        case .planProposed(let plan):
            guard settings.notifyApprovals else { return }
            postLong(channel, thread, "📝 *\(t.agentName)* propone este plan (espera tu aprobación en ProjectN):\n\n" + SlackRouter.toSlack(plan), bot: bot, as: t.agentID)
        case .finished:
            if delegated {
                if settings.notifyOnStart || (t.status != .completed && settings.notifyErrors) {
                    let icon = t.status == .completed ? "✓" : "✗"
                    post(channel, thread, "↳ \(icon) *\(t.agentName)* — \(t.status.label)\(t.error.map { ": \(Self.firstLine($0))" } ?? "")", bot: bot, as: t.agentID)
                }
                harness?.markDelivered(t.id)
            } else {
                deliver(t)
            }
        case .requestCreated(let r):
            requestCreated(r, task: t, channel: channel, thread: thread, bot: bot)
        case .requestResolved(let r):
            requestResolved(r, channel: channel, thread: thread, bot: bot)
        }
    }

    // MARK: Approvals & questions

    /// Messages showing a request, so they can be updated when it's decided.
    private var requestMessages: [UUID: (channel: String, ts: String, bot: String)] = [:]

    /// Requests waiting on you in this conversation (or this thread, with threads on).
    func userRequests(channel: String, thread: String) -> [AgentRequest] {
        guard let harness else { return [] }
        return harness.pendingUserRequests().filter { r in
            guard let t = harness.task(r.taskID), t.origin.slackChannel == channel else { return false }
            return !settings.replyInThreads || t.origin.slackThreadTS == thread
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

    private func requestCreated(_ r: AgentRequest, task t: AgentTask, channel: String, thread: String, bot: String) {
        switch r.route {
        case .user:
            let text: String
            switch r.kind {
            case .approval:
                text = "🔐 *\(t.agentName)* necesita tu aprobación:\n```\(r.summary)```\n_\(r.reason)_\n(o responde *aprobar* / *rechazar* \(replyHere))"
                Task {
                    if let ts = await send(channel, thread, text, blocks: Self.approvalBlocks(text, requestID: r.id), bot: bot, as: t.agentID) {
                        requestMessages[r.id] = (channel, ts, bot)
                    }
                }
            case .question:
                text = "❓ *\(t.agentName)* pregunta:\n> \(r.summary.replacingOccurrences(of: "\n", with: "\n> "))\nResponde \(replyHere)."
                Task { if let ts = await send(channel, thread, text, bot: bot, as: t.agentID) { requestMessages[r.id] = (channel, ts, bot) } }
            }
            log("Waiting on you: \(t.agentName) — \(r.summary)")
        case .orchestrator:
            guard settings.notifyApprovals else { return }
            post(channel, thread, "🤖 *\(t.agentName)* consulta a *\(t.origin.delegatedBy ?? "su coordinador")*: `\(ApprovalPolicy.clip(r.summary))`", bot: bot, as: t.agentID)
        }
    }

    private func requestResolved(_ r: AgentRequest, channel: String, thread: String, bot: String) {
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
            Task { await update(m.channel, m.ts, text, bot: m.bot) }
        } else if settings.notifyApprovals, r.route != .user || r.decidedBy?.hasPrefix("ProjectN") == true {
            post(channel, thread, "\(outcome) para *\(r.agentName)*: `\(ApprovalPolicy.clip(r.summary))`\(r.answer.map { " — \($0)" } ?? "")", bot: bot, as: harness?.task(r.taskID)?.agentID)
        }
    }

    /// Button clicks (Socket Mode "interactive" envelopes).
    func handleInteraction(_ payload: [String: Any], bot: String = SlackBot.mainKey) {
        guard payload["type"] as? String == "block_actions",
              let action = (payload["actions"] as? [[String: Any]])?.first,
              let id = (action["value"] as? String).flatMap(UUID.init(uuidString:)) else { return }
        let user = (payload["user"] as? [String: Any])?["id"] as? String ?? ""
        guard settings.authorizedUsers.contains(user.uppercased()) else {
            AuditLog.record("slack.unauthorized_action", ["user": user])
            if let ch = (payload["channel"] as? [String: Any])?["id"] as? String {
                let thread = ((payload["message"] as? [String: Any])?["thread_ts"] as? String)
                post(ch, thread, "⛔ <@\(user)> no está autorizado para aprobar acciones de los agentes.", bot: bot)
            }
            return
        }
        let approve = action["action_id"] as? String == "pn_approve"
        if let ch = (payload["channel"] as? [String: Any])?["id"] as? String,
           let ts = (payload["message"] as? [String: Any])?["ts"] as? String, requestMessages[id] == nil {
            requestMessages[id] = (ch, ts, bot)
        }
        if harness?.resolveRequest(id, approve: approve, by: "<@\(user)>") != true {
            log("Button for a request that's no longer pending")
        }
    }

    private func deliver(_ t: AgentTask) {
        let bot = botKey(for: t)
        guard let channel = t.origin.slackChannel, bots[bot]?.isConnected == true else { return }   // retried on reconnect
        let thread = t.origin.slackThreadTS   // nil only for a scheduled run whose start couldn't be posted
        var footer: [String] = []
        if let d = t.duration { footer.append("\(Int(d / 60)) min \(Int(d) % 60) s") }
        if let u = t.usage { footer.append("\(u.outputTokens.formatted()) output tokens (\(u.total.formatted()) incl. cache)") }
        let notes = t.notes.isEmpty ? "" : "\n" + t.notes.map { "ℹ️ \($0)" }.joined(separator: "\n")
        switch t.status {
        case .completed:
            let body = (t.result ?? "").isEmpty ? "_(sin texto en la respuesta)_" : SlackRouter.toSlack(t.result ?? "")
            postLong(channel, thread, body + notes + "\n\n_\(t.agentName) · \(t.projectName)\(footer.isEmpty ? "" : " · " + footer.joined(separator: " · "))_", bot: bot, as: t.agentID)
        case .cancelled, .failed, .timedOut, .interrupted:
            guard settings.notifyErrors else { break }
            let icon = t.status == .interrupted ? "⚠️" : "❌"
            post(channel, thread, "\(icon) *\(t.agentName)* — \(t.status.label): \(t.error ?? "sin detalles")\(notes)"
                 + (t.status == .interrupted ? "\nVuelve a enviar la instrucción para empezar de nuevo." : ""), bot: bot, as: t.agentID)
        default:
            return
        }
        harness?.markDelivered(t.id)
    }

    /// Outcomes produced while Slack was disconnected (or before a restart) are sent once connected.
    func deliverUndelivered() {
        guard let harness else { return }
        for t in harness.tasks where (t.origin.kind == .slack || (t.origin.kind == .schedule && t.origin.slackChannel != nil)) && t.status.isFinished && !t.delivered {
            // Don't flood a conversation with very old outcomes.
            if let f = t.finishedAt, Date().timeIntervalSince(f) > 24 * 3600 { harness.markDelivered(t.id); continue }
            deliver(t)
        }
    }

    private func postLong(_ channel: String, _ thread: String?, _ text: String, bot: String, as agent: UUID? = nil) {
        let parts = SlackRouter.chunks(text)
        Task {
            for p in parts { await send(channel, thread, p, bot: bot, as: agent) }
        }
    }

    private func post(_ channel: String, _ thread: String?, _ text: String, bot: String, as agent: UUID? = nil) {
        // In an agent's channel, everything is said by that agent.
        Task { await send(channel, thread, text, bot: bot, as: agent ?? agentForChannel(channel)?.id) }
    }

    /// Test hooks: replace the network calls. `signedSender` also receives the name a message is signed with.
    var sender: ((String, String?, String) async -> Void)?
    var signedSender: ((String, String?, String) async -> Void)?
    var updater: ((String, String, String) async -> Void)?
    /// Test hook for other Web API calls (channel sync).
    var apiCaller: ((String, [String: Any]) async throws -> [String: Any])?

    @discardableResult
    private func send(_ channel: String, _ thread: String?, _ text: String, blocks: [[String: Any]]? = nil,
                      bot: String, as agent: UUID? = nil) async -> String? {
        await sendReturningChannel(channel, thread, text, blocks: blocks, bot: bot, as: agent)?.ts
    }

    private func sendReturningChannel(_ channel: String, _ thread: String?, _ text: String,
                                      blocks: [[String: Any]]? = nil, bot: String, as agent: UUID? = nil) async -> (channel: String, ts: String)? {
        // Without threads, everything goes straight into the conversation.
        let thread = settings.replyInThreads ? thread : nil
        let who = identity(agent)
        if sender != nil || signedSender != nil {
            await sender?(channel, thread, text)
            await signedSender?(channel, who?.name, text)
            return (channel, "test-\(UUID().uuidString)")
        }
        guard let token = (bots[bot] ?? bots[SlackBot.mainKey])?.botToken else { return nil }
        do {
            let api = SlackAPI(token: token)
            var p: [String: Any] = ["channel": channel, "text": text, "unfurl_links": false, "unfurl_media": false]
            if let thread { p["thread_ts"] = thread }
            if let blocks { p["blocks"] = blocks }
            if let who { p["username"] = who.name; p["icon_emoji"] = who.emoji }   // chat:write.customize
            let r = try await api.call("chat.postMessage", p)
            guard let ts = r["ts"] as? String else { return nil }
            return ((r["channel"] as? String) ?? channel, ts)
        } catch {
            log("Couldn't post to Slack: \(error)")
            AuditLog.record("slack.post_failed", ["channel": channel, "bot": bot, "error": "\(error)"])
            return nil
        }
    }

    private func update(_ channel: String, _ ts: String, _ text: String, bot: String) async {
        if let updater { await updater(channel, ts, text); return }
        guard let token = (bots[bot] ?? bots[SlackBot.mainKey])?.botToken else { return }
        do { try await SlackAPI(token: token).update(channel: channel, ts: ts, text: text, blocks: [["type": "section", "text": ["type": "mrkdwn", "text": text]]]) }
        catch { AuditLog.record("slack.update_failed", ["error": "\(error)"]) }
    }

    // MARK: Agent channels

    /// The agent whose private channel this is.
    func agentForChannel(_ channel: String) -> AgentProfile? {
        harness?.profiles.first { $0.slackChannelID == channel }
    }

    private var channelSyncWork: DispatchWorkItem?

    /// Debounced: agents are saved in bursts (editor, schedules).
    func scheduleChannelSync() {
        channelSyncWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.syncAgentChannels() }
        channelSyncWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    private func api(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        if let apiCaller { return try await apiCaller(method, params) }
        guard let token = bots[SlackBot.mainKey]?.botToken else { throw SlackAPI.APIError(message: "Slack isn't connected") }
        return try await SlackAPI(token: token).call(method, params)
    }

    private var syncing = false

    /// Every enabled agent gets a private channel named after it (created once, renamed when the agent is),
    /// and every authorized user is invited.
    func syncAgentChannels() {
        // Connected implies Slack is enabled.
        guard bots[SlackBot.mainKey]?.isConnected == true, !syncing, let harness else { return }
        syncing = true
        let agents = harness.profiles.filter(\.enabled)
        let users = settings.authorizedUsers
        Task {
            defer { syncing = false }
            for p in agents {
                let wanted = SlackRouter.channelName(for: p.name)
                do {
                    var channelID = p.slackChannelID
                    var name = p.slackChannelName
                    if channelID == nil {
                        (channelID, name) = try await createChannel(wanted)
                        AuditLog.record("slack.channel_created", ["agent": p.name, "channel": name ?? wanted])
                    } else if name != wanted, let id = channelID {
                        let r = try await api("conversations.rename", ["channel": id, "name": wanted])
                        name = ((r["channel"] as? [String: Any])?["name"] as? String) ?? wanted
                        AuditLog.record("slack.channel_renamed", ["agent": p.name, "channel": name ?? wanted])
                    }
                    if let id = channelID, !users.isEmpty {
                        _ = try? await api("conversations.invite", ["channel": id, "users": users.joined(separator: ",")])
                    }
                    if channelID != p.slackChannelID || name != p.slackChannelName, var fresh = harness.profile(p.id) {
                        let isNew = fresh.slackChannelID == nil
                        fresh.slackChannelID = channelID
                        fresh.slackChannelName = name
                        harness.replaceProfileQuietly(fresh)
                        if isNew, let id = channelID {
                            await send(id, nil, "Hola 👋 Soy *\(fresh.name)*\(fresh.role.isEmpty ? "" : " (\(fresh.role))"). Todo lo que escribas aquí me llega directo, sin mencionarme. ¿En qué proyecto trabajamos?",
                                       bot: SlackBot.mainKey, as: fresh.id)
                        }
                    }
                    channelErrors[p.id] = nil
                } catch {
                    channelErrors[p.id] = "\(error)"
                    AuditLog.record("slack.channel_error", ["agent": p.name, "error": "\(error)"])
                }
            }
        }
    }

    /// Creates a private channel; if the name is taken, tries "<name>-agente", then a numbered one.
    private func createChannel(_ base: String) async throws -> (String?, String?) {
        for candidate in [base, "\(base)-agente", "\(base)-agente-\(Int.random(in: 2...99))"] {
            do {
                let r = try await api("conversations.create", ["name": String(candidate.prefix(80)), "is_private": true])
                let ch = r["channel"] as? [String: Any]
                return (ch?["id"] as? String, ch?["name"] as? String)
            } catch let e as SlackAPI.APIError where e.message.contains("name_taken") {
                continue
            }
        }
        throw SlackAPI.APIError(message: "conversations.create: name_taken")
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
    /// Creating each agent's private channel and signing messages with the agent's name and emoji.
    static let agentChannelScopes = ["groups:write", "groups:read", "groups:history", "chat:write.customize"]

    /// Verifies tokens, scopes and Socket Mode of the general app and every agent app, without changing anything.
    func checkConnection() {
        checking = true
        checks = []
        var apps: [(String, String, String)] = [("ProjectN",
                                                  IntegrationSecrets.get(IntegrationSecrets.slackAppToken) ?? "",
                                                  IntegrationSecrets.get(IntegrationSecrets.slackBotToken) ?? "")]
        Task {
            var out: [CheckResult] = []
            for (label, app, bot) in apps {
                let prefix = apps.count > 1 ? "\(label): " : ""
                if bot.hasPrefix("xoxb-") {
                    do {
                        let r = try await SlackAPI(token: bot).scopes()
                        let missing = Self.requiredScopes.filter { !r.scopes.contains($0) }
                        out.append(.init(ok: missing.isEmpty, label: prefix + (missing.isEmpty
                            ? "bot @\(r.user) in \(r.team) — scopes OK"
                            : "missing scopes \(missing.joined(separator: ", ")) — add them under OAuth & Permissions and reinstall")))
                        let forChannels = Self.agentChannelScopes.filter { !r.scopes.contains($0) }
                        out.append(.init(ok: forChannels.isEmpty, label: forChannels.isEmpty
                            ? "Agent channels: scopes OK"
                            : "Agent channels need \(forChannels.joined(separator: ", ")) — add them under OAuth & Permissions and reinstall"))
                    } catch { out.append(.init(ok: false, label: prefix + "bot token: \(error)")) }
                } else {
                    out.append(.init(ok: false, label: prefix + (bot.isEmpty ? "bot token not saved" : "bot token must start with xoxb-")))
                }
                if app.hasPrefix("xapp-") {
                    var req = URLRequest(url: URL(string: "https://slack.com/api/apps.connections.open")!)
                    req.httpMethod = "POST"
                    req.setValue("Bearer \(app)", forHTTPHeaderField: "Authorization")
                    let obj = (try? await URLSession.shared.data(for: req)).flatMap { try? JSONSerialization.jsonObject(with: $0.0) as? [String: Any] } ?? [:]
                    let ok = obj["ok"] as? Bool == true
                    out.append(.init(ok: ok, label: prefix + (ok ? "Socket Mode OK" : "app token / Socket Mode: \(obj["error"] as? String ?? "no response")")))
                } else {
                    out.append(.init(ok: false, label: prefix + (app.isEmpty ? "app token not saved" : "app token must start with xapp-")))
                }
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
        let b = bots[SlackBot.mainKey] ?? SlackBot(key: SlackBot.mainKey, agentID: nil)
        b.botUserID = botUserID
        b.botToken = "test"
        b.status = .connected(team: "Test", bot: "bot")
        bots[b.key] = b
        status = b.status
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
        // Merge what another connector (an earlier instance, a restart) saved meanwhile instead of overwriting it.
        if let saved = AppHome.load([String].self, from: AgentStore.slackSeenFile) {
            for k in saved where !set.contains(k) { order.append(k); set.insert(k) }
        }
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
