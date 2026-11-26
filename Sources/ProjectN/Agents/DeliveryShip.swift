import Foundation

// MARK: - Until merge ("ship")
//
// After the user accepts a delivery, a coordinator can hand its pull request to an agent until it is ready to
// merge: ProjectN reads the PR with `gh` every couple of minutes and, when checks fail, the branch conflicts or
// new review comments arrive, gives the agent a task to fix it (it may push to that PR's branch without asking).
// When everything is green it tells the coordinator. Merging stays with the user.

struct ShipWatch: Codable, Hashable {
    enum State: String, Codable { case watching, fixing, ready, merged, closed, stopped }
    struct Note: Codable, Hashable { var at: Date; var text: String }

    var pr: Int
    var branch = ""
    var url = ""
    var agent: String
    var projectID: UUID
    var coordinatorTaskID: UUID
    var state: State = .watching
    var fixes = 0
    var maxFixes = 5
    var lastCheck: Date?
    var status = "Waiting for the first check"
    /// Review comments already handed to the agent (or present when watching started).
    var seenComments: Int?
    /// Checks have been pending since (to say it's stuck instead of waiting forever).
    var pendingSince: Date?
    var stuckNotified = false
    var readyNotified = false
    var notes: [Note] = []
    var startedAt = Date()
    var endedAt: Date?
    var stopReason: String?

    var isLive: Bool { [.watching, .fixing, .ready].contains(state) }

    mutating func note(_ text: String, at: Date = Date()) {
        notes.append(.init(at: at, text: text))
        if notes.count > 60 { notes.removeFirst(notes.count - 60) }
    }
}

/// What `gh pr view --json …` says about a pull request.
struct PRSnapshot: Equatable {
    var state: String            // OPEN, MERGED, CLOSED
    var mergeable: String        // MERGEABLE, CONFLICTING, UNKNOWN
    var reviewDecision: String   // APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, ""
    var branch: String
    var url: String
    var failing: [String]
    var pending: [String]
    var passed: Int
    var comments: Int

    static let fields = "state,mergeable,reviewDecision,headRefName,url,statusCheckRollup,comments,reviews"

    static func parse(_ json: String) -> PRSnapshot? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let state = o["state"] as? String else { return nil }
        var failing: [String] = [], pending: [String] = [], passed = 0
        for c in o["statusCheckRollup"] as? [[String: Any]] ?? [] {
            let name = (c["name"] as? String) ?? (c["context"] as? String) ?? "check"
            if let s = c["state"] as? String {   // commit status
                switch s.uppercased() {
                case "SUCCESS": passed += 1
                case "FAILURE", "ERROR": failing.append(name)
                default: pending.append(name)
                }
                continue
            }
            let status = (c["status"] as? String ?? "").uppercased()
            let conclusion = (c["conclusion"] as? String ?? "").uppercased()
            if status != "COMPLETED" { pending.append(name); continue }
            switch conclusion {
            case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": failing.append(name)
            default: passed += 1   // SUCCESS, NEUTRAL, SKIPPED
            }
        }
        let comments = (o["comments"] as? [Any])?.count ?? 0
        let reviews = (o["reviews"] as? [[String: Any]] ?? []).filter {
            !(($0["body"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || ($0["state"] as? String) == "CHANGES_REQUESTED"
        }.count
        return PRSnapshot(state: state.uppercased(), mergeable: (o["mergeable"] as? String ?? "UNKNOWN").uppercased(),
                          reviewDecision: (o["reviewDecision"] as? String ?? "").uppercased(),
                          branch: o["headRefName"] as? String ?? "", url: o["url"] as? String ?? "",
                          failing: failing, pending: pending, passed: passed, comments: comments + reviews)
    }
}

enum ShipAction: Equatable {
    case merged, closed
    case fix([String])
    case wait(String)
    case ready(String)
    case stop(String)
}

extension ShipWatch {
    /// What to do about this snapshot (pure).
    func evaluate(_ s: PRSnapshot) -> ShipAction {
        if s.state == "MERGED" { return .merged }
        if s.state == "CLOSED" { return .closed }
        var reasons: [String] = []
        if !s.failing.isEmpty { reasons.append("Failing checks: \(s.failing.joined(separator: ", "))") }
        if s.mergeable == "CONFLICTING" { reasons.append("The branch conflicts with the base branch") }
        let seen = seenComments ?? s.comments
        if s.comments > seen { reasons.append("\(s.comments - seen) new review comment(s)" + (s.reviewDecision == "CHANGES_REQUESTED" ? " (changes requested)" : "")) }
        if !reasons.isEmpty {
            if fixes >= maxFixes { return .stop("\(maxFixes) fix tasks ran and the PR still needs work: \(reasons.joined(separator: "; ")).") }
            return .fix(reasons)
        }
        if !s.pending.isEmpty { return .wait("Checks running: \(s.pending.joined(separator: ", "))") }
        if s.mergeable == "UNKNOWN" { return .wait("GitHub is still computing whether it can merge") }
        let checks = s.passed > 0 ? "\(s.passed) check(s) green" : "no checks"
        switch s.reviewDecision {
        case "REVIEW_REQUIRED": return .ready("\(checks), no conflicts — waiting for a reviewer's approval")
        case "CHANGES_REQUESTED": return .ready("\(checks), no conflicts — a reviewer asked for changes earlier; nothing new to address")
        default: return .ready("\(checks), no conflicts\(s.reviewDecision == "APPROVED" ? ", approved" : "") — ready to merge")
        }
    }

    func fixInstruction(_ reasons: [String]) -> String {
        """
        Until merge: pull request #\(pr) (\(url.isEmpty ? "branch \(branch)" : url)) needs work.
        \(reasons.map { "- \($0)" }.joined(separator: "\n"))

        Work on its branch `\(branch)` (use the worktree you already have for it, or `git worktree add .worktrees/pr\(pr) \(branch)`).
        See what failed with `gh pr checks \(pr)` and `gh run view <run-id> --log-failed`; read comments with `gh pr view \(pr) --comments`.
        Fix it, run the tests, commit, then push with exactly `git push origin HEAD:\(branch)` (allowed for this PR; never force-push, never push elsewhere).
        Answer review comments only by fixing the code; if a comment needs a decision, use ask.
        Answer in the user's language: one line per problem with what you did.
        """
    }

    func report() -> String {
        var lines = ["## Until merge: PR #\(pr) — \(state.rawValue)"]
        if let r = stopReason { lines.append("Reason: \(r)") }
        lines.append("Status: \(status). Fix tasks: \(fixes).")
        switch state {
        case .ready: lines.append("Tell the user it's ready and that the merge is theirs (\(url)). ProjectN keeps watching in case something changes.")
        case .merged: lines.append("Tell the user it was merged.")
        default: lines.append("Tell the user what happened and what they need to do.")
        }
        return lines.joined(separator: "\n")
    }

    /// `git push` refspecs this watch allows the agent to push without asking.
    static func pushAllowed(args: [String], branches: [String]) -> Bool {
        guard !branches.isEmpty else { return false }
        let banned = ["--force", "-f", "--force-with-lease", "--delete", "-d", "--mirror", "--all", "--tags", "--prune"]
        guard !args.contains(where: { a in banned.contains(where: { a == $0 || a.hasPrefix($0 + "=") }) || a.hasPrefix("+") }) else { return false }
        let plain = args.filter { !$0.hasPrefix("-") }
        guard plain.count == 2, plain[0] == "origin" else { return false }
        var dst = plain[1].components(separatedBy: ":").last ?? plain[1]
        if dst.hasPrefix("refs/heads/") { dst = String(dst.dropFirst("refs/heads/".count)) }
        return branches.contains(dst)
    }

    static func prNumber(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let n = Int(t.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) { return n }
        if let r = t.range(of: #"/pull/(\d+)"#, options: .regularExpression) {
            return Int(t[r].dropFirst("/pull/".count))
        }
        return nil
    }
}

// MARK: - Harness

extension AgentHarness {
    /// Branches the agent of this task may push to without asking (a PR it's taking to merge).
    func pushableBranches(for t: AgentTask) -> [String] {
        guard let s = deliveryRecords[Delivery.key(t)]?.ship, s.isLive, !s.branch.isEmpty,
              s.agent.folded.trimmingCharacters(in: .whitespaces) == t.agentName.folded.trimmingCharacters(in: .whitespaces) else { return [] }
        return [s.branch]
    }

    func startShip(_ a: [String: Any], task t: AgentTask, profile: AgentProfile) throws -> String {
        guard let pr = (a["pr"] as? String).flatMap(ShipWatch.prNumber) ?? (a["pr"] as? Int) else {
            throw DeliveryError.invalid("Give `pr`: the pull request number or URL.")
        }
        let name = (a["agent"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard let agent = availableAgents().first(where: { $0.name.folded.trimmingCharacters(in: .whitespaces) == name.folded }) else {
            throw DeliveryError.unknown("No enabled agent named “\(name)”. Call list_agents.")
        }
        guard agent.permission.canWrite else { throw DeliveryError.invalid("\(agent.name) is read-only: it can't fix the PR.") }
        var projectID = t.projectID
        if let pname = a["project"] as? String, !pname.isEmpty {
            guard let p = namedProject(pname, for: profile) else { throw DeliveryError.unknown("No project named “\(pname)” that you can access.") }
            projectID = p.id
        } else if projectID == Store.coordinationProjectID {
            throw DeliveryError.invalid("Pass `project`: the project of the pull request.")
        }
        guard agent.mayAccess(projectID) else { throw DeliveryError.notAllowed("\(agent.name) can't work in that project.") }
        let id = Delivery.key(t)
        if let s = deliveryRecords[id]?.ship, s.isLive { throw DeliveryError.invalid("PR #\(s.pr) is already being taken to merge for this request.") }
        mutateDelivery(id) {
            var w = ShipWatch(pr: pr, agent: agent.name, projectID: projectID, coordinatorTaskID: t.id)
            w.maxFixes = min(10, max(1, (a["max_fixes"] as? Int) ?? 5))
            w.note("Started by \(t.agentName): \(agent.name) takes PR #\(pr) to merge-ready")
            $0.ship = w
        }
        AuditLog.record("ship.started", ["delivery": id.uuidString, "pr": String(pr), "agent": agent.name])
        checkShip(id, force: true)
        return Self.json(["watching": "PR #\(pr)", "agent": agent.name,
                          "next": "End your turn. ProjectN checks the PR every 2 minutes, gives \(agent.name) a task when checks fail, it conflicts or reviewers comment, and tells you when it's ready to merge."])
    }

    func stopShip(_ id: UUID, reason: String) {
        guard let s = deliveryRecords[id]?.ship, s.isLive else { return }
        endShip(id, .stopped, reason: reason)
    }

    /// Called from the harness tick: checks live watches that are due.
    func shipTick(now: Date = Date()) {
        for (id, r) in deliveryRecords {
            guard let s = r.ship, s.isLive, s.state != .fixing else { continue }
            if let last = s.lastCheck, now.timeIntervalSince(last) < shipInterval { continue }
            checkShip(id)
        }
    }

    func checkShip(_ id: UUID, force: Bool = false) {
        guard let s = deliveryRecords[id]?.ship, s.isLive, let store, let project = store.project(s.projectID) else { return }
        if shipChecking.contains(id) { return }
        shipChecking.insert(id)
        mutateDelivery(id) { $0.ship?.lastCheck = Date() }
        let shell = store.settings.shell.isEmpty ? "/bin/zsh" : store.settings.shell
        let env = AccountsModel.environment(settings: store.settings)
        let command = "cd \(Shell.quote(project.path)) && gh pr view \(s.pr) --json \(PRSnapshot.fields)"
        let fetch = shipFetcher
        Task.detached {
            let out = fetch?(command) ?? AccountsModel.run(shell: shell, command, env: env)
            await MainActor.run { self.applyShipCheck(id, output: out.out, code: out.code) }
        }
    }

    func applyShipCheck(_ id: UUID, output: String, code: Int32, now: Date = Date()) {
        shipChecking.remove(id)
        guard var s = deliveryRecords[id]?.ship, s.isLive else { return }
        guard code == 0, let snap = PRSnapshot.parse(output.components(separatedBy: "\n").first { $0.hasPrefix("{") } ?? output) else {
            let msg = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? ""
            mutateDelivery(id) { $0.ship?.status = "Couldn't read the PR with gh: \(PromptComposer.oneLine(msg, 160))" }
            return
        }
        if s.branch.isEmpty { s.branch = snap.branch; s.url = snap.url }
        if s.seenComments == nil { s.seenComments = snap.comments }
        mutateDelivery(id) { $0.ship = s }
        switch s.evaluate(snap) {
        case .merged: endShip(id, .merged, reason: nil)
        case .closed: endShip(id, .closed, reason: "The PR was closed without merging.")
        case .stop(let why): endShip(id, .stopped, reason: why)
        case .wait(let status):
            let since = s.pendingSince ?? now
            mutateDelivery(id) {
                $0.ship?.status = status
                $0.ship?.pendingSince = since
                if $0.ship?.state == .ready { $0.ship?.state = .watching }
            }
            if now.timeIntervalSince(since) > shipStuckAfter, !s.stuckNotified {
                mutateDelivery(id) { $0.ship?.stuckNotified = true; $0.ship?.note("Stuck: \(status) for \(Int(shipStuckAfter / 60)) min") }
                reportShip(id, extra: "Stuck: \(status) for more than \(Int(shipStuckAfter / 60)) minutes. Tell the user.")
            }
        case .ready(let status):
            let first = !s.readyNotified
            mutateDelivery(id) {
                $0.ship?.status = status
                $0.ship?.state = .ready
                $0.ship?.pendingSince = nil
                $0.ship?.readyNotified = true
                if first { $0.ship?.note("Ready: \(status)") }
            }
            if first { reportShip(id, extra: nil) }
        case .fix(let reasons):
            guard let agent = availableAgents().first(where: { $0.name.folded == s.agent.folded }),
                  let coordinator = task(s.coordinatorTaskID) else {
                endShip(id, .stopped, reason: "\(s.agent) or the coordinator task isn't available any more."); return
            }
            var origin = coordinator.origin
            origin.kind = .agent
            origin.parentTaskID = coordinator.id
            origin.delegatedBy = "ProjectN (until merge)"
            origin.automatic = nil
            origin.conversationID = id
            switch submit(AgentTaskRequest(agentID: agent.id, projectID: s.projectID, instruction: s.fixInstruction(reasons), origin: origin)) {
            case .success(let child):
                update(child.id) { $0.cycleStep = .ship }
                mutateDelivery(id) {
                    $0.ship?.state = .fixing
                    $0.ship?.fixes += 1
                    $0.ship?.seenComments = snap.comments
                    $0.ship?.readyNotified = false
                    $0.ship?.pendingSince = nil
                    $0.ship?.stuckNotified = false
                    $0.ship?.status = "\(agent.name) is fixing: " + reasons.joined(separator: "; ")
                    let n = $0.ship?.fixes ?? 0
                    $0.ship?.note("Fix \(n) → \(agent.name): " + reasons.joined(separator: "; "))
                }
                AuditLog.record("ship.fix", ["delivery": id.uuidString, "pr": String(s.pr), "agent": agent.name, "why": reasons.joined(separator: "; ")])
            case .failure(let e):
                endShip(id, .stopped, reason: "Couldn't start \(agent.name)'s fix: \(e.description)")
            }
        }
    }

    /// A fix task ended: back to watching (check again right away), or stop if it didn't complete.
    func shipStepFinished(_ done: AgentTask) {
        guard done.cycleStep == .ship else { return }
        let id = Delivery.key(done)
        guard let s = deliveryRecords[id]?.ship, s.state == .fixing else { return }
        guard done.status == .completed else {
            endShip(id, .stopped, reason: "\(done.agentName)'s fix ended as \(done.status.label.lowercased())" + (done.error.map { ": \($0)" } ?? "."))
            return
        }
        mutateDelivery(id) { $0.ship?.state = .watching; $0.ship?.note("\(done.agentName) finished its fix") }
        // CI needs a moment to see the push.
        let delay = min(45, shipInterval)
        mutateDelivery(id) { $0.ship?.lastCheck = Date().addingTimeInterval(-shipInterval + delay) }
    }

    private func endShip(_ id: UUID, _ state: ShipWatch.State, reason: String?) {
        mutateDelivery(id) {
            $0.ship?.state = state
            $0.ship?.stopReason = reason
            $0.ship?.endedAt = Date()
            $0.ship?.note(state == .merged ? "Merged" : state == .closed ? "Closed" : "Stopped: \(reason ?? "")")
        }
        AuditLog.record("ship.\(state.rawValue)", ["delivery": id.uuidString, "reason": reason ?? ""])
        reportShip(id, extra: nil)
    }

    private func reportShip(_ id: UUID, extra: String?) {
        guard let s = deliveryRecords[id]?.ship, let coordinator = task(s.coordinatorTaskID) else { return }
        let message = s.report() + (extra.map { "\n" + $0 } ?? "")
        if coordinator.status.isActive {
            queueForSession(coordinator.id, message)
        } else if profile(coordinator.agentID)?.enabled == true {
            var origin = coordinator.origin
            origin.automatic = true
            origin.conversationID = id
            submit(AgentTaskRequest(agentID: coordinator.agentID, projectID: coordinator.projectID, instruction: message, origin: origin))
        }
    }
}
