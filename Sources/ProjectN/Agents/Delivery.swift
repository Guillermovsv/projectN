import Foundation

// MARK: - Deliveries
//
// A delivery is everything agents did for one request: the coordinator's turns, the tasks it delegated, the
// acceptance criteria, the findings agents passed to each other and the worktrees they left behind. ProjectN
// keeps the criteria and findings itself (agents change them through tools), so it knows how far the work is
// and can drive the fix → retest → verify cycle without the coordinator reading files.
//
//   ~/.projectn/agents/deliveries/<conversation id>.json

/// One acceptance criterion: something observable that must hold, and how it is checked.
struct DeliveryCriterion: Codable, Hashable, Identifiable {
    enum Status: String, Codable, CaseIterable { case pending, met, unmet }
    var id: String
    var text: String
    var check: String
    var status: Status = .pending
    var evidence: String?
    var by: String?
    var at: Date?
    /// Earlier wordings, when the criterion was adjusted ("C5: was … — why").
    var amendments: [String]?
}

/// A problem one agent found and another fixes: anchored to a file line, a page element, a document or a criterion.
struct DeliveryFinding: Codable, Hashable, Identifiable {
    enum Status: String, Codable, CaseIterable {
        case open, fixed, closed, reopened
        /// The fixer can't solve it in the work itself (the criterion is wrong, it needs the user's call): the cycle
        /// stops and asks instead of spending rounds on it.
        case needsDecision = "needs_decision"
        /// Waiting for whoever fixes things.
        var needsFix: Bool { self == .open || self == .reopened }
    }
    struct Event: Codable, Hashable {
        var status: Status
        var by: String
        var at: Date
        var note: String?
    }
    var id: String
    var text: String
    var anchor: String
    var severity: String?
    var openedBy: String
    var status: Status = .open
    var commit: String?
    /// Who marked it fixed last: they can't close it themselves.
    var fixedBy: String?
    var history: [Event] = []
}

/// The automatic cycle: findings go to the fixer, fixed ones to the tester, then the verifier checks the criteria.
struct DeliveryCycle: Codable, Hashable {
    enum State: String, Codable { case running, done, stopped }
    enum Step: String, Codable { case fix, retest, verify, ship }
    var fixer: String
    var tester: String?
    var verifier: String
    var projectID: UUID
    /// The coordinator task that started it: steps are delegated in its name and the end is reported to it.
    var coordinatorTaskID: UUID
    var maxRounds = 3
    /// Fix rounds started so far.
    var round = 0
    var state: State = .running
    var stopReason: String?
    /// The verifier ran after the last change (fix / retest).
    var verifiedSinceChange = false
    /// Steps launched so far (fix, retest, verify): a cycle whose agents don't update anything stops instead of looping.
    var steps = 0
    var maxSteps: Int { maxRounds * 3 + 2 }
    var startedAt = Date()
    var endedAt: Date?
}

struct DeliveryRecord: Codable, Hashable, Identifiable {
    var id: UUID
    var criteria: [DeliveryCriterion] = []
    var findings: [DeliveryFinding] = []
    var cycle: DeliveryCycle?
    /// Absolute paths of git worktrees agents created for this request (`git worktree add`).
    var worktrees: [String] = []
    /// Its pull request being taken to merge-ready (DeliveryShip.swift).
    var ship: ShipWatch?
    /// Review lists given to the verifier (names), and decisions taken during the request.
    var reviewsApplied: [String] = []
    var decisions: [String] = []
    var updatedAt = Date()

    var criteriaMet: Int { criteria.filter { $0.status == .met }.count }
    var openFindings: [DeliveryFinding] { findings.filter { $0.status != .closed } }
    var isEmpty: Bool { criteria.isEmpty && findings.isEmpty && cycle == nil && worktrees.isEmpty && ship == nil && decisions.isEmpty }

    init(id: UUID) { self.id = id }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        criteria = (try? c.decode([DeliveryCriterion].self, forKey: .criteria)) ?? []
        findings = (try? c.decode([DeliveryFinding].self, forKey: .findings)) ?? []
        cycle = try? c.decode(DeliveryCycle.self, forKey: .cycle)
        worktrees = (try? c.decode([String].self, forKey: .worktrees)) ?? []
        ship = try? c.decode(ShipWatch.self, forKey: .ship)
        reviewsApplied = (try? c.decode([String].self, forKey: .reviewsApplied)) ?? []
        decisions = (try? c.decode([String].self, forKey: .decisions)) ?? []
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date()
    }
}

enum DeliveryError: Error, Equatable, CustomStringConvertible {
    case criteriaLocked
    case invalid(String)
    case unknown(String)
    case notAllowed(String)
    var description: String {
        switch self {
        case .criteriaLocked: return "The criteria are fixed once one has been checked. If one is wrong, say so with ask."
        case .invalid(let s), .unknown(let s), .notAllowed(let s): return s
        }
    }
}

// MARK: - Rules (pure)

extension DeliveryRecord {
    /// Sets the criteria. Allowed while none has been checked yet (the author may still refine them).
    mutating func setCriteria(_ items: [(id: String?, text: String, check: String)], by: String, now: Date = Date()) throws {
        guard !criteria.contains(where: { $0.status != .pending }) else { throw DeliveryError.criteriaLocked }
        let clean = items.map { (id: $0.id?.trimmingCharacters(in: .whitespaces), text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                 check: $0.check.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard !clean.isEmpty, clean.count <= 20 else { throw DeliveryError.invalid("Give 1–20 criteria.") }
        guard clean.allSatisfy({ !$0.text.isEmpty && !$0.check.isEmpty }) else {
            throw DeliveryError.invalid("Every criterion needs `text` (what must hold) and `check` (how it is checked).")
        }
        var used = Set<String>()
        criteria = clean.enumerated().map { i, c in
            var id = (c.id?.isEmpty == false ? c.id! : "C\(i + 1)").uppercased()
            while used.contains(id) { id += "'" }
            used.insert(id)
            return DeliveryCriterion(id: id, text: c.text, check: c.check, by: by, at: now)
        }
        updatedAt = now
    }

    mutating func updateCriterion(_ id: String, status: DeliveryCriterion.Status, evidence: String?, by: String, now: Date = Date()) throws {
        guard let i = criteria.firstIndex(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
            throw DeliveryError.unknown("No criterion \(id). Criteria: \(criteria.map(\.id).joined(separator: ", ")).")
        }
        if let c = cycle, c.fixer.folded == by.folded {
            throw DeliveryError.notAllowed("\(by) fixes this work, so it can't mark criteria. The verifier does.")
        }
        guard status != .pending else { throw DeliveryError.invalid("status must be met or unmet.") }
        let ev = evidence?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !ev.isEmpty else { throw DeliveryError.invalid("Give the `evidence`: the command / test / file that shows it.") }
        criteria[i].status = status
        criteria[i].evidence = ev
        criteria[i].by = by
        criteria[i].at = now
        updatedAt = now
    }

    /// Rewords a criterion when the right solution turned out different from what it says (coordinators only).
    /// It goes back to pending, so the verifier checks it again; the old wording is kept.
    mutating func amendCriterion(_ id: String, text: String?, check: String?, reason: String, by: String, now: Date = Date()) throws {
        guard let i = criteria.firstIndex(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
            throw DeliveryError.unknown("No criterion \(id). Criteria: \(criteria.map(\.id).joined(separator: ", ")).")
        }
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !why.isEmpty else { throw DeliveryError.invalid("Give the `reason`: why the criterion changes.") }
        let t = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let k = check?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !t.isEmpty || !k.isEmpty else { throw DeliveryError.invalid("Give the new `text` and/or `check`.") }
        var c = criteria[i]
        c.amendments = (c.amendments ?? []) + ["Was: \(c.text) (check: \(c.check)) — changed by \(by): \(why)"]
        if !t.isEmpty { c.text = t }
        if !k.isEmpty { c.check = k }
        c.status = .pending
        c.evidence = nil
        c.by = by
        c.at = now
        criteria[i] = c
        // Findings that were only about the old wording are settled by the change.
        for j in findings.indices where findings[j].status == .needsDecision || findings[j].status.needsFix {
            let a = findings[j].anchor.folded
            if a.contains("criterion \(c.id.folded)") || a.contains("criterio \(c.id.folded)") {
                findings[j].status = .closed
                findings[j].history.append(.init(status: .closed, by: by, at: now, note: "Criterion \(c.id) amended: \(why)"))
            }
        }
        cycle?.verifiedSinceChange = false
        updatedAt = now
    }

    /// Opens a finding; returns its id. Ids from a report (B20, N05) are kept; otherwise P1, P2…
    @discardableResult
    mutating func openFinding(id: String?, text: String, anchor: String, severity: String?, by: String, now: Date = Date()) throws -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = anchor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw DeliveryError.invalid("Missing `text`: what fails and what was expected.") }
        guard !a.isEmpty else {
            throw DeliveryError.invalid("Missing `anchor`: file:line, page: selector · viewport · screenshot, document: file · page, or criterion Cn.")
        }
        let given = (id?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0.uppercased() }
        if let given, findings.contains(where: { $0.id == given }) {
            throw DeliveryError.invalid("Finding \(given) already exists: update it with finding_update.")
        }
        let nextP = (findings.compactMap { $0.id.hasPrefix("P") ? Int($0.id.dropFirst()) : nil }.max() ?? 0) + 1
        let fid = given ?? "P\(nextP)"
        var f = DeliveryFinding(id: fid, text: t, anchor: a, severity: severity?.trimmingCharacters(in: .whitespaces), openedBy: by)
        f.history = [.init(status: .open, by: by, at: now, note: nil)]
        findings.append(f)
        if cycle?.state == .running { cycle?.verifiedSinceChange = false }
        updatedAt = now
        return fid
    }

    mutating func updateFinding(_ id: String, status: DeliveryFinding.Status, commit: String?, note: String?, by: String, now: Date = Date()) throws {
        guard let i = findings.firstIndex(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
            throw DeliveryError.unknown("No finding \(id). Open ones: \(openFindings.map(\.id).joined(separator: ", ")).")
        }
        var f = findings[i]
        let n = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case .open:
            throw DeliveryError.invalid("Use fixed, closed or reopened.")
        case .needsDecision:
            guard f.status.needsFix else { throw DeliveryError.invalid("\(f.id) is \(f.status.rawValue): only an open finding can need a decision.") }
            guard !(n ?? "").isEmpty else { throw DeliveryError.invalid("Give a `note`: what has to be decided and your recommendation.") }
            f.fixedBy = by
        case .fixed:
            guard f.status.needsFix else { throw DeliveryError.invalid("\(f.id) is \(f.status.rawValue), not open: nothing to fix.") }
            let c = commit?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !c.isEmpty || !(n ?? "").isEmpty else { throw DeliveryError.invalid("Give the `commit` with the fix (or a `note` if no commit applies).") }
            if !c.isEmpty { f.commit = c }
            f.fixedBy = by
        case .closed, .reopened:
            // Its author may also withdraw a finding nobody has worked on yet (closed straight from open).
            let withdraw = status == .closed && f.status == .open && f.openedBy.folded == by.folded
            guard f.status == .fixed || f.status == .needsDecision || withdraw else {
                throw DeliveryError.invalid("Only a finding marked fixed can be \(status.rawValue) (\(f.id) is \(f.status.rawValue)).")
            }
            if let fixer = f.fixedBy, fixer.folded == by.folded {
                throw DeliveryError.notAllowed(f.status == .needsDecision
                    ? "\(by) asked for a decision on \(f.id), so someone else decides it."
                    : "\(by) fixed \(f.id), so someone else has to check it.")
            }
            guard !(n ?? "").isEmpty else { throw DeliveryError.invalid("Give a `note` with the evidence (what you ran or saw).") }
        }
        f.status = status
        f.history.append(.init(status: status, by: by, at: now, note: n))
        findings[i] = f
        if status == .fixed || status == .reopened { cycle?.verifiedSinceChange = false }
        updatedAt = now
    }

    /// What the automatic cycle does next.
    enum Next: Equatable {
        case fix([String]), retest([String]), verify, done
        case stop(String)
        case wait
    }

    static func nextStep(_ r: DeliveryRecord) -> Next {
        guard let c = r.cycle, c.state == .running else { return .wait }
        let undecided = r.findings.filter { $0.status == .needsDecision }
        if !undecided.isEmpty {
            return .stop("Needs a decision: " + undecided.map { "\($0.id) — \($0.history.last?.note ?? $0.text)" }.joined(separator: "; "))
        }
        let toFix = r.findings.filter { $0.status.needsFix }.map(\.id)
        let fixed = r.findings.filter { $0.status == .fixed }.map(\.id)
        if !toFix.isEmpty {
            if c.round >= c.maxRounds {
                return .stop("\(c.maxRounds) fix rounds used and \(toFix.count) finding(s) still open: \(toFix.joined(separator: ", ")).")
            }
            return .fix(toFix)
        }
        if !fixed.isEmpty {
            return c.tester != nil ? .retest(fixed) : .verify
        }
        if !c.verifiedSinceChange { return .verify }
        if !r.criteria.isEmpty, r.criteria.allSatisfy({ $0.status == .met }) { return .done }
        if r.criteria.isEmpty { return .done }
        let unmet = r.criteria.filter { $0.status != .met }.map(\.id)
        return .stop("The verifier left \(unmet.joined(separator: ", ")) not met without opening findings to fix.")
    }

    /// Plain-text state for agents (delivery_status) and for the coordinator's report.
    func summary() -> [String: Any] {
        var d: [String: Any] = [
            "criteria": criteria.map { c -> [String: Any] in
                var x: [String: Any] = ["id": c.id, "text": c.text, "check": c.check, "status": c.status.rawValue]
                if let e = c.evidence { x["evidence"] = e }
                return x
            },
            "criteria_met": "\(criteriaMet)/\(criteria.count)",
            "findings": findings.map { f -> [String: Any] in
                var x: [String: Any] = ["id": f.id, "text": f.text, "anchor": f.anchor, "status": f.status.rawValue, "opened_by": f.openedBy]
                if let s = f.severity { x["severity"] = s }
                if let c = f.commit { x["commit"] = c }
                if let last = f.history.last?.note { x["last_note"] = last }
                return x
            },
        ]
        if let c = cycle {
            d["cycle"] = ["state": c.state.rawValue, "round": c.round, "max_rounds": c.maxRounds,
                          "fixer": c.fixer, "tester": c.tester ?? "", "verifier": c.verifier, "stop_reason": c.stopReason ?? ""]
        }
        if !worktrees.isEmpty { d["worktrees"] = worktrees }
        if let s = ship { d["until_merge"] = ["pr": s.pr, "state": s.state.rawValue, "status": s.status, "fixes": s.fixes] }
        if !decisions.isEmpty { d["decisions"] = decisions }
        return d
    }

    /// One paragraph for the coordinator when the cycle ends.
    func endReport() -> String {
        let c = cycle
        var lines = ["## Automatic cycle \(c?.state == .done ? "finished" : "stopped")"]
        if let r = c?.stopReason { lines.append("Reason: \(r)") }
        lines.append("Criteria met: \(criteriaMet)/\(criteria.count). Fix rounds: \(c?.round ?? 0)/\(c?.maxRounds ?? 0).")
        let left = openFindings
        lines.append(left.isEmpty ? "All findings are closed (\(findings.count))."
                                  : "Not closed: " + left.map { "\($0.id) (\($0.status.rawValue)) \(PromptComposer.oneLine($0.text, 90))" }.joined(separator: "; "))
        if !worktrees.isEmpty { lines.append("Worktrees left: \(worktrees.joined(separator: ", ")) (the user can clean them up in Deliveries).") }
        if findings.contains(where: { $0.status == .needsDecision }) || criteria.contains(where: { $0.status == .unmet }) {
            lines.append("If a criterion's wording is what's wrong (the solution is right but different), adjust it with criterion_amend (reason required) — ask the user first if it changes what they asked for — then start_cycle again. Close or reopen findings that needed a decision with finding_update.")
        }
        lines.append("Tell the user the outcome in a few lines (criteria, rounds, what's left, the branch) and what they need to do. Pushing / opening the PR is theirs.")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Step instructions

enum CycleInstructions {
    static func text(_ step: DeliveryCycle.Step, ids: [String], record: DeliveryRecord, reviews: [ReviewList] = []) -> String {
        let list = record.findings.filter { ids.contains($0.id) }
            .map { "- \($0.id)\($0.severity.map { " [\($0)]" } ?? ""): \($0.text) — \($0.anchor)\($0.history.last?.note.map { " (last note: \($0))" } ?? "")" }
            .joined(separator: "\n")
        switch step {
        case .fix:
            return """
            Automatic cycle, round \((record.cycle?.round ?? 0)): fix these findings.
            \(list)

            For each one: fix it, run the relevant tests, commit (no push), then call finding_update(id, status: fixed, commit: <hash>).
            If one can't be solved in the work itself (the criterion asks for something that is no longer right, or it needs the
            user's call), don't retry: call finding_update(id, status: needs_decision, note: <what must be decided and what you recommend>).
            Don't mark anything closed and don't change the criteria. delivery_status shows the whole state.
            Answer in the user's language: one line per finding with what you changed.
            """
        case .retest:
            return """
            Automatic cycle: test again these findings marked fixed.
            \(list)

            Reproduce each one as it was found. Then call finding_update(id, status: closed | reopened, note: <what you ran and saw>).
            Don't change code. Open a new finding (finding_open) only for a new problem caused by the fix.
            Answer in the user's language: one line per finding.
            """
        case .verify:
            let crit = record.criteria.map { "- \($0.id): \($0.text) — check: \($0.check)" }.joined(separator: "\n")
            return """
            Automatic cycle: verify the work.
            \(crit.isEmpty ? "(No criteria were set: check the request and open findings for what doesn't hold.)" : crit)

            Run each check and call criterion_update(id, status: met | unmet, evidence: <command / file / screenshot>).
            For every criterion that isn't met, open a finding (finding_open) with an anchor, so it gets fixed.
            Close (or reopen) findings marked fixed that you checked. Don't change code.
            When everything is met, write the delivery summary in your answer, in the user's language.
            """ + ReviewLists.instructionBlock(reviews)
        case .ship:
            return ""
        }
    }
}

// MARK: - Storage

enum DeliveryStore {
    static var dir: URL { AgentStore.dir.appendingPathComponent("deliveries") }
    static func file(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }

    static func loadAll() -> [UUID: DeliveryRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [UUID: DeliveryRecord] = [:]
        for f in files where f.pathExtension == "json" {
            if let r = AppHome.load(DeliveryRecord.self, from: f) { out[r.id] = r }
        }
        return out
    }

    static func save(_ r: DeliveryRecord) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        AppHome.save(r, to: file(r.id))
    }
}

// MARK: - Grouping tasks into deliveries

struct Delivery: Identifiable, Hashable {
    /// The conversation id (or the legacy grouping key turned into one).
    var id: UUID
    var tasks: [AgentTask]
    var record: DeliveryRecord?

    /// The user's request: the first task that wasn't an automatic follow-up.
    var request: AgentTask? { tasks.first { $0.origin.automatic != true && $0.origin.parentTaskID == nil } ?? tasks.first }
    var start: Date { tasks.compactMap { $0.startedAt ?? $0.createdAt }.min() ?? Date() }
    var end: Date? { tasks.allSatisfy { $0.status.isFinished } ? tasks.compactMap(\.finishedAt).max() : nil }
    var isActive: Bool { tasks.contains { !$0.status.isFinished } || record?.cycle?.state == .running }
    var agents: [String] {
        var seen: [String] = []
        for t in tasks where !seen.contains(t.agentName) { seen.append(t.agentName) }
        return seen
    }
    var usage: TokenUsage {
        var u = TokenUsage()
        for t in tasks {
            guard let x = t.usage else { continue }
            u.inputTokens += x.inputTokens; u.outputTokens += x.outputTokens
            u.cacheReadTokens += x.cacheReadTokens; u.cacheWriteTokens += x.cacheWriteTokens
        }
        return u
    }

    /// Which delivery a task belongs to. New tasks carry their conversation id; older ones are grouped by their
    /// Slack thread (every follow-up and delegated task of a Slack request shares it), else by their root task.
    static func key(_ t: AgentTask) -> UUID {
        if let c = t.origin.conversationID { return c }
        return threadKey(t.origin) ?? t.rootTaskID ?? t.id
    }

    /// The delivery of a Slack thread.
    static func threadKey(_ o: TaskOrigin) -> UUID? {
        guard let ch = o.slackChannel, let ts = o.slackThreadTS ?? o.slackMessageTS else { return nil }
        return UUID.stable("slack:\(ch):\(ts)")
    }

    /// Requests that involved more than one task (a coordinator delegating, or an automatic cycle), newest first.
    static func group(_ tasks: [AgentTask], records: [UUID: DeliveryRecord]) -> [Delivery] {
        var byKey: [UUID: [AgentTask]] = [:]
        var order: [UUID] = []
        for t in tasks {
            let k = key(t)
            if byKey[k] == nil { order.append(k) }
            byKey[k, default: []].append(t)
        }
        return order.compactMap { k -> Delivery? in
            let ts = (byKey[k] ?? []).sorted { ($0.startedAt ?? $0.createdAt) < ($1.startedAt ?? $1.createdAt) }
            let rec = records[k]
            guard ts.contains(where: { $0.origin.parentTaskID != nil }) || !(rec?.isEmpty ?? true) else { return nil }
            return Delivery(id: k, tasks: ts, record: rec)
        }
        .sorted { $0.start > $1.start }
    }
}

extension UUID {
    /// A UUID derived from a string (same string → same id), for grouping keys.
    static func stable(_ s: String) -> UUID {
        var h1: UInt64 = 0xcbf29ce484222325, h2: UInt64 = 0x84222325cbf29ce4
        for b in s.utf8 {
            h1 = (h1 ^ UInt64(b)) &* 0x100000001b3
            h2 = (h2 ^ UInt64(b)) &* 0x1000193 &+ 7
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i] = UInt8((h1 >> (8 * UInt64(i))) & 0xff); bytes[8 + i] = UInt8((h2 >> (8 * UInt64(i))) & 0xff) }
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: - Worktrees and own processes (parsed from allowed commands)

enum CommandFacts {
    /// Paths created by `git [-C dir] worktree add [options] <path> [<commit>]` in a command, resolved against `cwd`.
    static func worktreesAdded(_ command: String, cwd: String) -> [String] {
        var out: [String] = []
        var dir = cwd
        for segment in ApprovalPolicy.segments(ApprovalPolicy.stripHeredocs(command)) {
            var tokens = Shell.split(segment)
            if tokens.first == "cd", tokens.count >= 2 { dir = resolve(tokens[1], dir); continue }
            guard tokens.first == "git" else { continue }
            tokens.removeFirst()
            var base = dir
            while let t = tokens.first, t.hasPrefix("-") {
                tokens.removeFirst()
                if t == "-C", let d = tokens.first { base = resolve(d, base); tokens.removeFirst() }
            }
            guard tokens.count >= 2, tokens[0] == "worktree", tokens[1] == "add" else { continue }
            var rest = Array(tokens.dropFirst(2))
            while let t = rest.first, t.hasPrefix("-") {
                rest.removeFirst()
                if ["-b", "-B", "--reason"].contains(t), !rest.isEmpty { rest.removeFirst() }
            }
            if let p = rest.first { out.append(resolve(p, base)) }
        }
        return out
    }

    /// The command started in the background (`run_in_background`, or a trailing `&`), for pkill later.
    static func backgroundCommand(_ command: String, runInBackground: Bool) -> String? {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if runInBackground { return c }
        if c.hasSuffix("&"), !c.hasSuffix("&&") { return String(c.dropLast()).trimmingCharacters(in: .whitespaces) }
        return nil
    }

    static func resolve(_ p: String, _ base: String) -> String {
        let e = (p as NSString).expandingTildeInPath
        let abs = e.hasPrefix("/") ? e : (base as NSString).appendingPathComponent(e)
        return (abs as NSString).standardizingPath
    }
}
