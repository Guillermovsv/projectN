import Foundation

/// Where agent tasks run: ordinary ProjectN panes (same Launcher / TerminalSession as any Claude or Codex pane)
/// inside one workspace the harness manages, named "Agents". Its spaces obey the 8-pane limit.
extension Store {
    static let agentWorkspaceName = "Agents"

    var agentWorkspace: Workspace? { state.workspaces.first { $0.agentHost } }

    @discardableResult
    func ensureAgentWorkspace() -> Workspace {
        if let w = agentWorkspace { return w }
        var w = Workspace(name: Self.agentWorkspaceName, projectIDs: [])
        w.agentHost = true
        w.spaces = [Space(name: "Agents 1")]
        w.expanded = false
        state.workspaces.append(w)
        return w
    }

    /// A space with room for one more pane. In order: any agent space below the limit; else close the oldest pane
    /// that belongs to one of the harness's *finished* tasks (`recyclable`); else a new space.
    /// Panes the harness didn't create, or whose task is still active, are never closed.
    func agentSpaceWithRoom(recyclable: Set<UUID>) -> (workspaceID: UUID, spaceID: UUID) {
        let w = ensureAgentWorkspace()
        if let s = w.spaces.first(where: { !$0.isFull }) { return (w.id, s.id) }
        let candidates = w.spaces.flatMap { s in s.panes.map { (s, $0) } }
            .filter { _, p in p.agentTaskID.map(recyclable.contains) ?? false }
            .sorted { $0.1.createdAt < $1.1.createdAt }
        if let (s, p) = candidates.first {
            closePane(p.id, in: w.id)
            return (w.id, s.id)
        }
        var n = w.spaces.count + 1
        while w.spaces.contains(where: { $0.name == "Agents \(n)" }) { n += 1 }
        let s = Space(name: "Agents \(n)")
        updateWorkspace(w.id) { $0.spaces.append(s) }
        return (w.id, s.id)
    }

    struct AgentLaunch {
        var taskID: UUID
        var tool: Tool
        var projectID: UUID
        var options: LaunchOptions
        var agentArgs: [String]
        var prompt: String
        var title: String
        /// Explicit resume: continue this conversation instead of starting a new one.
        var resumeSessionID: String?
        /// Explicit resume: the earlier task's pane, reused so its process exits before the resume starts.
        var reusePaneID: UUID?
    }

    /// Creates (or, for an explicit resume, reuses) a pane and starts it with the task's first message.
    /// Doesn't change what you're looking at.
    func launchAgentPane(_ l: AgentLaunch, recyclable: Set<UUID>) -> (workspaceID: UUID, pane: Pane)? {
        guard project(l.projectID) != nil else { return nil }
        let w = ensureAgentWorkspace()

        if let reuse = l.reusePaneID, let (_, old) = pane(reuse, in: w.id), old.tool == l.tool {
            updatePane(reuse, in: w.id) {
                $0.agentTaskID = l.taskID
                $0.agentArgs = l.agentArgs
                $0.launchOptions = l.options
                $0.title = l.title
                $0.lastPrompt = nil
            }
            guard let (_, updated) = pane(reuse, in: w.id) else { return nil }
            initialPrompts[reuse] = l.prompt
            start(updated, in: w.id, resume: true)
            return (w.id, updated)
        }

        let (wid, sid) = agentSpaceWithRoom(recyclable: recyclable)
        var p = Pane(tool: l.tool, projectID: l.projectID)
        p.title = l.title
        p.launchOptions = l.options
        p.agentArgs = l.agentArgs
        p.agentTaskID = l.taskID
        switch l.tool {
        case .claude:
            // Known session id → the harness can read exactly this conversation's transcript.
            p.claudeSessionID = l.resumeSessionID ?? UUID().uuidString.lowercased()
        case .codex:
            p.codexSessionID = l.resumeSessionID
        case .cursor, .terminal:
            return nil   // agent runtimes are Claude Code and Codex
        }
        if l.projectID != Self.coordinationProjectID {
            updateWorkspace(wid) { if !$0.projectIDs.contains(l.projectID) { $0.projectIDs.append(l.projectID) } }
        }
        updateSpace(sid, in: wid) { s in
            s.panes.append(p)
            if s.focusedPaneID == nil { s.focusedPaneID = p.id }
        }
        initialPrompts[p.id] = l.prompt
        // resume: true keeps the pre-assigned Claude session id (a new conversation is created
        // under it when no transcript exists yet) and resumes it when one does.
        start(p, in: wid, resume: true)
        guard let (_, started) = pane(p.id, in: wid) else { return nil }
        return (wid, started)
    }

    /// True while a launch for this pane is queued but its terminal doesn't exist yet.
    func isLaunching(_ paneID: UUID) -> Bool { runtimes[paneID] == nil && hasPendingLaunch(paneID) }
}
