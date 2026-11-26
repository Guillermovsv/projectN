import Foundation

/// Deliveries: criteria and findings kept by ProjectN, the automatic fix → retest → verify cycle, and the
/// worktrees a request leaves behind. See Delivery.swift for the model and its rules.
extension AgentHarness {
    var deliveries: [Delivery] { Delivery.group(tasks, records: deliveryRecords) }

    func delivery(_ id: UUID) -> Delivery? { deliveries.first { $0.id == id } }

    func deliveryRecord(_ id: UUID) -> DeliveryRecord { deliveryRecords[id] ?? DeliveryRecord(id: id) }

    /// Changes a delivery's record and saves it. Throws whatever the rules throw (nothing is saved then).
    @discardableResult
    func mutateDelivery(_ id: UUID, _ body: (inout DeliveryRecord) throws -> Void) rethrows -> DeliveryRecord {
        var r = deliveryRecord(id)
        try body(&r)
        r.updatedAt = Date()
        deliveryRecords[id] = r
        DeliveryStore.save(r)
        return r
    }

    // MARK: Tools

    static let deliveryToolNames: Set<String> = ["criteria_set", "criterion_update", "finding_open", "finding_update", "delivery_status",
                                                 "start_cycle", "review_lists", "ship_pr", "stop_ship", "criterion_amend"]

    func callDeliveryTool(_ name: String, _ a: [String: Any], task t: AgentTask, profile: AgentProfile,
                          reply: @escaping (String, Bool) -> Void) {
        let id = Delivery.key(t)
        let who = t.agentName
        func str(_ k: String) -> String? { (a[k] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
        do {
            switch name {
            case "delivery_status":
                reply(Self.json(deliveryRecord(id).summary()), false)

            case "criteria_set":
                let raw = a["criteria"] as? [[String: Any]] ?? []
                let items = raw.map { (id: $0["id"] as? String, text: $0["text"] as? String ?? "", check: $0["check"] as? String ?? "") }
                let r = try mutateDelivery(id) { try $0.setCriteria(items, by: who) }
                AuditLog.record("delivery.criteria", ["delivery": id.uuidString, "agent": who, "count": String(r.criteria.count)])
                reply(Self.json(["saved": r.criteria.map { "\($0.id): \($0.text)" },
                                 "next": "These are the acceptance criteria of this request. Another agent will check them; don't mark them yourself if you do the work."]), false)

            case "criterion_update":
                guard let cid = str("id"), let s = str("status").flatMap(DeliveryCriterion.Status.init(rawValue:)) else {
                    reply("Give `id` and `status` (met | unmet).", true); return
                }
                let r = try mutateDelivery(id) { try $0.updateCriterion(cid, status: s, evidence: str("evidence"), by: who) }
                AuditLog.record("delivery.criterion", ["delivery": id.uuidString, "agent": who, "criterion": cid, "status": s.rawValue])
                var out: [String: Any] = ["criteria_met": "\(r.criteriaMet)/\(r.criteria.count)"]
                if s == .unmet { out["next"] = "Open a finding (finding_open) with an anchor so it gets fixed." }
                reply(Self.json(out), false)

            case "finding_open":
                var fid = ""
                try mutateDelivery(id) {
                    fid = try $0.openFinding(id: str("id"), text: str("text") ?? "", anchor: str("anchor") ?? "",
                                             severity: str("severity"), by: who)
                }
                AuditLog.record("delivery.finding", ["delivery": id.uuidString, "agent": who, "finding": fid, "status": "open"])
                reply(Self.json(["id": fid, "status": "open"]), false)

            case "criterion_amend":
                guard depthAllowsDelegation(t, profile) else {
                    reply("Only the coordinator can change a criterion. Use finding_update(id, needs_decision, note) to ask for it.", true); return
                }
                guard let cid = str("id") else { reply("Give the criterion `id`.", true); return }
                let r = try mutateDelivery(id) { try $0.amendCriterion(cid, text: str("text"), check: str("check"), reason: str("reason") ?? "", by: who) }
                AuditLog.record("delivery.criterion_amended", ["delivery": id.uuidString, "agent": who, "criterion": cid, "reason": str("reason") ?? ""])
                reply(Self.json(["amended": cid, "criteria_met": "\(r.criteriaMet)/\(r.criteria.count)",
                                 "next": "It's pending again: start_cycle (or ask the verifier) to check it."]), false)

            case "finding_update":
                guard let fid = str("id"), let s = str("status").flatMap(DeliveryFinding.Status.init(rawValue:)) else {
                    reply("Give `id` and `status` (fixed | needs_decision | closed | reopened).", true); return
                }
                let r = try mutateDelivery(id) { try $0.updateFinding(fid, status: s, commit: str("commit"), note: str("note"), by: who) }
                AuditLog.record("delivery.finding", ["delivery": id.uuidString, "agent": who, "finding": fid, "status": s.rawValue])
                reply(Self.json(["id": fid, "status": s.rawValue, "still_open": r.openFindings.map(\.id)]), false)

            case "start_cycle":
                guard depthAllowsDelegation(t, profile) else { reply("\(profile.name) can't delegate, so it can't start a cycle.", true); return }
                reply(try startCycle(a, task: t, profile: profile), false)

            case "review_lists":
                let paths = (a["paths"] as? [String])?.filter { !$0.isEmpty }
                let lists = reviewLists(delivery: id, projectID: t.projectID, paths: paths)
                let where_ = store?.project(t.projectID).map { ReviewLists.folder(for: $0.path).path } ?? ""
                reply(Self.json(["lists": lists.map { ["name": $0.name, "when": $0.patterns, "checklist": $0.text] },
                                 "note": lists.isEmpty ? "No review list matches these files (lists live in \(where_))." : "Apply every point; open a finding for each one that fails."]), false)

            case "ship_pr":
                guard depthAllowsDelegation(t, profile) else { reply("\(profile.name) can't delegate, so it can't hand a PR to an agent.", true); return }
                reply(try startShip(a, task: t, profile: profile), false)

            case "stop_ship":
                guard let s = deliveryRecords[id]?.ship, s.isLive else { reply("No PR is being taken to merge for this request.", true); return }
                stopShip(id, reason: str("reason") ?? "Stopped by \(who)")
                reply("Stopped watching PR #\(s.pr).", false)

            default:
                reply("Unknown tool \(name).", true)
            }
        } catch let e as DeliveryError {
            reply(e.description, true)
        } catch {
            reply("\(error)", true)
        }
    }

    // MARK: Cycle

    private func startCycle(_ a: [String: Any], task t: AgentTask, profile: AgentProfile) throws -> String {
        func agent(_ key: String, required: Bool) throws -> AgentProfile? {
            let n = (a[key] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if n.isEmpty {
                if required { throw DeliveryError.invalid("Missing `\(key)` (agent name from list_agents).") }
                return nil
            }
            // Names are compared without surrounding spaces ("QA " typed in the editor is "QA").
            guard let p = availableAgents().first(where: { $0.name.folded.trimmingCharacters(in: .whitespaces) == n.folded }) else {
                throw DeliveryError.unknown("No enabled agent named “\(n)”. Call list_agents.")
            }
            return p
        }
        guard let fixer = try agent("fixer", required: true), let verifier = try agent("verifier", required: true) else {
            throw DeliveryError.invalid("Give `fixer` and `verifier`.")
        }
        let tester = try agent("tester", required: false)
        guard fixer.id != verifier.id, tester?.id != fixer.id else {
            throw DeliveryError.invalid("The fixer can't test or verify its own work: pick other agents for tester / verifier.")
        }
        guard fixer.permission.canWrite else { throw DeliveryError.invalid("\(fixer.name) is read-only: it can't fix anything.") }
        var projectID = t.projectID
        if let pname = a["project"] as? String, !pname.isEmpty {
            guard let p = namedProject(pname, for: profile) else { throw DeliveryError.unknown("No project named “\(pname)” that you can access.") }
            projectID = p.id
        } else if projectID == Store.coordinationProjectID {
            throw DeliveryError.invalid("Pass `project`: the project the cycle works in.")
        }
        for p in [fixer, verifier] + (tester.map { [$0] } ?? []) where !p.mayAccess(projectID) {
            throw DeliveryError.notAllowed("\(p.name) can't work in that project.")
        }
        let id = Delivery.key(t)
        if let c = deliveryRecords[id]?.cycle, c.state == .running {
            throw DeliveryError.invalid("A cycle is already running for this request (round \(c.round)/\(c.maxRounds)).")
        }
        let rounds = min(5, max(1, (a["max_rounds"] as? Int) ?? Int((a["max_rounds"] as? Double) ?? 3)))
        let r = mutateDelivery(id) {
            $0.cycle = DeliveryCycle(fixer: fixer.name, tester: tester?.name, verifier: verifier.name, projectID: projectID,
                                     coordinatorTaskID: t.id, maxRounds: rounds)
        }
        AuditLog.record("cycle.started", ["delivery": id.uuidString, "fixer": fixer.name, "tester": tester?.name ?? "",
                                          "verifier": verifier.name, "rounds": String(rounds)])
        advanceCycle(id)
        let step = tasks.last { Delivery.key($0) == id && $0.cycleStep != nil && !$0.status.isFinished }
        return Self.json(["cycle": "started", "max_rounds": rounds, "open_findings": r.findings.filter { $0.status.needsFix }.map(\.id),
                          "first_step": step.map { "\($0.cycleStep!.rawValue) → \($0.agentName)" } ?? "none",
                          "next": "End your turn now. ProjectN runs fix → retest → verify by itself and sends you one message when the cycle ends."])
    }

    /// A task ended: if it was a step of a running cycle, record what it means and launch the next step.
    func advanceCycle(after done: AgentTask) {
        guard let step = done.cycleStep, step != .ship else { return }
        let id = Delivery.key(done)
        guard let c = deliveryRecords[id]?.cycle, c.state == .running else { return }
        guard done.status == .completed else {
            endCycle(id, .stopped, reason: "\(done.agentName)'s \(done.cycleStep!.rawValue) step ended as \(done.status.label.lowercased())"
                     + (done.error.map { ": \($0)" } ?? "."))
            return
        }
        if done.cycleStep == .verify { mutateDelivery(id) { $0.cycle?.verifiedSinceChange = true } }
        advanceCycle(id)
    }

    func advanceCycle(_ id: UUID) {
        guard let r = deliveryRecords[id], let c = r.cycle, c.state == .running else { return }
        // One step at a time.
        if tasks.contains(where: { Delivery.key($0) == id && $0.cycleStep != nil && !$0.status.isFinished }) { return }
        if c.steps >= c.maxSteps {
            endCycle(id, .stopped, reason: "\(c.steps) steps ran without finishing (agents didn't update the findings / criteria).")
            return
        }
        switch DeliveryRecord.nextStep(r) {
        case .wait: return
        case .fix(let ids):
            mutateDelivery(id) { $0.cycle?.round += 1; $0.cycle?.verifiedSinceChange = false }
            launchCycleStep(.fix, agent: c.fixer, ids: ids, delivery: id)
        case .retest(let ids):
            launchCycleStep(.retest, agent: c.tester ?? c.verifier, ids: ids, delivery: id)
        case .verify:
            launchCycleStep(.verify, agent: c.verifier, ids: [], delivery: id)
        case .done:
            endCycle(id, .done, reason: nil)
        case .stop(let why):
            endCycle(id, .stopped, reason: why)
        }
    }

    private func launchCycleStep(_ step: DeliveryCycle.Step, agent name: String, ids: [String], delivery id: UUID) {
        let r = deliveryRecord(id)
        guard let c = r.cycle, let coordinator = task(c.coordinatorTaskID) else {
            endCycle(id, .stopped, reason: "The coordinator task is gone."); return
        }
        guard let agent = availableAgents().first(where: { $0.name.folded == name.folded }) else {
            endCycle(id, .stopped, reason: "\(name) isn't available (turned off or renamed)."); return
        }
        var origin = coordinator.origin
        origin.kind = .agent
        origin.parentTaskID = coordinator.id
        origin.delegatedBy = "ProjectN (automatic cycle)"
        origin.automatic = nil
        origin.conversationID = id
        var reviews: [ReviewList] = []
        if step == .verify {
            reviews = reviewLists(delivery: id, projectID: c.projectID)
            if !reviews.isEmpty { mutateDelivery(id) { r in for n in reviews.map(\.name) where !r.reviewsApplied.contains(n) { r.reviewsApplied.append(n) } } }
        }
        let text = CycleInstructions.text(step, ids: ids, record: r, reviews: reviews)
        switch submit(AgentTaskRequest(agentID: agent.id, projectID: c.projectID, instruction: text, origin: origin)) {
        case .success(let child):
            update(child.id) { $0.cycleStep = step }
            mutateDelivery(id) { $0.cycle?.steps += 1 }
            AuditLog.record("cycle.step", ["delivery": id.uuidString, "step": step.rawValue, "agent": agent.name,
                                           "round": String(c.round), "findings": ids.joined(separator: ",")])
        case .failure(let e):
            endCycle(id, .stopped, reason: "Couldn't start \(agent.name)'s \(step.rawValue) step: \(e.description)")
        }
    }

    private func endCycle(_ id: UUID, _ state: DeliveryCycle.State, reason: String?) {
        let r = mutateDelivery(id) {
            $0.cycle?.state = state
            $0.cycle?.stopReason = reason
            $0.cycle?.endedAt = Date()
        }
        AuditLog.record("cycle.\(state.rawValue)", ["delivery": id.uuidString, "reason": reason ?? "",
                                                    "criteria": "\(r.criteriaMet)/\(r.criteria.count)", "round": String(r.cycle?.round ?? 0)])
        guard let c = r.cycle, let coordinator = task(c.coordinatorTaskID) else { return }
        let message = r.endReport()
        if coordinator.status.isActive {
            queueForSession(coordinator.id, message)
        } else if profile(coordinator.agentID)?.enabled == true {
            var origin = coordinator.origin
            origin.automatic = true
            origin.conversationID = id
            submit(AgentTaskRequest(agentID: coordinator.agentID, projectID: coordinator.projectID, instruction: message, origin: origin))
        }
    }

    // MARK: Facts from allowed commands

    /// Worktrees and background commands in a command the hook let through.
    func noteCommandFacts(_ command: String, runInBackground: Bool, cwd: String, task t: AgentTask) {
        let added = CommandFacts.worktreesAdded(command, cwd: cwd)
        if !added.isEmpty {
            let id = Delivery.key(t)
            mutateDelivery(id) { r in for p in added where !r.worktrees.contains(p) { r.worktrees.append(p) } }
            AuditLog.record("delivery.worktree", ["delivery": id.uuidString, "agent": t.agentName, "paths": added.joined(separator: ", ")])
        }
        if let bg = CommandFacts.backgroundCommand(command, runInBackground: runInBackground) {
            backgroundCommands[t.id, default: []].append(bg)
        }
    }

    // MARK: Clean-up (from the Deliveries view, after you confirm)

    /// Removes the delivery's worktrees with `git worktree remove --force`. Returns one line per worktree.
    func cleanUpWorktrees(_ id: UUID) async -> [String] {
        let r = deliveryRecord(id)
        var lines: [String] = []
        var removed: [String] = []
        for path in r.worktrees {
            guard FileManager.default.fileExists(atPath: path) else { removed.append(path); lines.append("Already gone: \(path)"); continue }
            // Run from the main checkout (found through the worktree's shared .git), never from inside the worktree.
            let (found, common) = await Self.runGit(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: path)
            let main = found ? (common as NSString).deletingLastPathComponent : (path as NSString).deletingLastPathComponent
            let (ok, out) = await Self.runGit(["worktree", "remove", "--force", path], in: main)
            if ok { removed.append(path); lines.append("Removed: \(path)") } else { lines.append("Couldn't remove \(path): \(out)") }
        }
        mutateDelivery(id) { $0.worktrees.removeAll { removed.contains($0) } }
        AuditLog.record("delivery.cleanup", ["delivery": id.uuidString, "removed": removed.joined(separator: ", ")])
        return lines
    }

    nonisolated static func runGit(_ args: [String], in dir: String) async -> (Bool, String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir] + args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.terminationHandler = { proc in
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                cont.resume(returning: (proc.terminationStatus == 0, out.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            do { try p.run() } catch { cont.resume(returning: (false, error.localizedDescription)) }
        }
    }
}

// MARK: - From the Deliveries view

extension AgentHarness {
    /// The coordinator of a request: its latest task by an agent that delegates.
    func coordinatorTask(of d: Delivery) -> AgentTask? {
        d.tasks.last { profile($0.agentID)?.canDelegate == true }
    }

    /// Your message to the request's coordinator, written in ProjectN: into its live session, else as a new turn
    /// of the same conversation (a Slack request answers in its thread).
    @discardableResult
    func replyToCoordinator(_ d: Delivery, text: String) -> Bool {
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty, let c = coordinatorTask(of: d) else { return false }
        AuditLog.record("delivery.reply", ["delivery": d.id.uuidString, "agent": c.agentName, "text": ApprovalPolicy.clip(msg)])
        if c.status.isActive { deliverMessage(msg, to: c.id); return true }
        var origin = c.origin
        origin.automatic = nil
        origin.conversationID = d.id
        if case .success = submit(AgentTaskRequest(agentID: c.agentID, projectID: c.projectID,
                                                   instruction: msg + "\n\n(Written by the user in ProjectN → Deliveries.)", origin: origin)) {
            return true
        }
        return false
    }

    /// Approvals and questions of this request waiting on you.
    func pendingForUser(_ d: Delivery) -> [AgentRequest] {
        let ids = Set(d.tasks.map(\.id))
        return pendingUserRequests().filter { ids.contains($0.taskID) }
    }
}
