import Foundation

/// Runs agents' scheduled tasks. Checked from the harness tick (every ~30 s), only while ProjectN is open.
extension AgentHarness {
    /// Starts every schedule that's due. Each schedule runs at most once per check, so a backlog of missed runs
    /// (ProjectN closed for days) becomes a single catch-up run — or none if the schedule says so.
    func runDueSchedules(now: Date = Date()) {
        for p in profiles where p.enabled {
            for s in p.schedules where s.enabled {
                guard let due = s.nextRun(after: s.lastRun ?? s.createdAt), due <= now else { continue }
                let missedBy = now.timeIntervalSince(due)
                if missedBy > 15 * 60 && !s.runIfMissed {
                    updateSchedule(agent: p.id, schedule: s.id) { $0.lastRun = now }
                    AuditLog.record("schedule.skipped", ["agent": p.name, "schedule": s.name, "missed_at": ISO8601DateFormatter().string(from: due)])
                    continue
                }
                runSchedule(s, of: p, now: now, reason: missedBy > 15 * 60 ? "catch-up" : "on time")
            }
        }
    }

    /// Runs a schedule now (also the "Run Now" button). Returns the error if the task couldn't start.
    @discardableResult
    func runSchedule(_ s: AgentSchedule, of p: AgentProfile, now: Date = Date(), reason: String = "manual") -> AgentHarnessError? {
        updateSchedule(agent: p.id, schedule: s.id) { $0.lastRun = now }
        guard let projectID = s.projectID else {
            AuditLog.record("schedule.failed", ["agent": p.name, "schedule": s.name, "reason": "no project chosen"])
            return .projectNotFound
        }
        var target = s.slackTarget.trimmingCharacters(in: .whitespaces).uppercased()
        // "AGENT" = the agent's own Slack channel.
        if target == "AGENT" { target = p.slackChannelID ?? "" }
        let origin = TaskOrigin(kind: .schedule, slackChannel: target.isEmpty ? nil : target,
                                scheduleID: s.id, scheduleName: s.name)
        AuditLog.record("schedule.run", ["agent": p.name, "schedule": s.name, "reason": reason])
        if case .failure(let e) = submit(AgentTaskRequest(agentID: p.id, projectID: projectID, instruction: s.instruction, origin: origin)) {
            AuditLog.record("schedule.failed", ["agent": p.name, "schedule": s.name, "reason": e.description])
            return e
        }
        return nil
    }

    /// Changes one schedule without touching the rest of the profile (no "agent.saved" entry).
    func updateSchedule(agent: UUID, schedule: UUID, _ mutate: (inout AgentSchedule) -> Void) {
        guard let i = profiles.firstIndex(where: { $0.id == agent }),
              let j = profiles[i].schedules.firstIndex(where: { $0.id == schedule }) else { return }
        var p = profiles[i]
        mutate(&p.schedules[j])
        replaceProfileQuietly(p)
    }

    /// Next run across all of an agent's schedules (for the UI).
    func nextScheduledRun(of agent: UUID) -> (AgentSchedule, Date)? {
        guard let p = profile(agent), p.enabled else { return nil }
        return p.schedules.filter(\.enabled).compactMap { s in s.upcoming().map { (s, $0) } }.min { $0.1 < $1.1 }
    }

    /// Scheduled tasks reporting to Slack get their thread once the first message is posted.
    func setSlackThread(_ taskID: UUID, channel: String, ts: String) {
        guard let i = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        var t = tasks[i]
        t.origin.slackChannel = channel
        t.origin.slackThreadTS = ts
        replaceTask(t)
    }
}
