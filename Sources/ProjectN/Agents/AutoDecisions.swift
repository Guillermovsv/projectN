import Foundation

/// What agents (Claude Code and Codex alike) decided or did on their own in Auto mode, rebuilt from ProjectN's
/// audit log and the tasks' final answers, so earlier requests show it too.
struct AutoDecision: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A choice the agent made itself (`record_decision`, or an assumption stated in its answer).
        case decision
        /// A question it wanted to ask; Auto mode told it to decide.
        case question
        /// Something that would have asked for approval and Auto mode let through.
        case action
    }
    var id: String
    var taskID: UUID
    var at: Date
    var agent: String
    var runtime: AgentRuntime
    var kind: Kind
    var text: String
    var why: String?
}

extension AgentRuntime {
    var shortLabel: String { self == .codexCLI ? "Codex" : "Claude" }
}

extension AutoDecision.Kind {
    var label: String {
        switch self {
        case .decision: return "decided on its own"
        case .question: return "didn't ask: decided it itself"
        case .action: return "approved automatically"
        }
    }
}

extension AutoDecision {
    private static let events = ["\"decision.auto\"", "\"question.skipped\"", "\"prompt.auto_approved\"", "\"tool.auto_approved\""]

    /// `autoModeAgents`: agents with Auto mode on, whose answers are read for stated assumptions.
    static func collect(audit: String, tasks: [AgentTask], autoModeAgents: Set<UUID>) -> [AutoDecision] {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let iso = ISO8601DateFormatter()
        var out: [AutoDecision] = []
        var recorded = Set<UUID>()
        for (n, line) in audit.split(separator: "\n").enumerated() {
            guard events.contains(where: { line.contains($0) }),
                  let e = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
                  let tid = e["task"].flatMap(UUID.init(uuidString:)), let t = byID[tid] else { continue }
            let kind: Kind, text: String?
            var why: String?
            switch e["event"] {
            case "decision.auto":
                kind = .decision; text = e["decision"]; why = e["why"]; recorded.insert(tid)
            case "question.skipped":
                kind = .question; text = e["question"]
            case "prompt.auto_approved":
                // Also logged for High / Balanced autonomy; ProjectN's own tools are plumbing, not decisions.
                guard e["why"] == "Auto mode", e["call"]?.hasPrefix("projectn ·") != true else { continue }
                kind = .action; text = e["call"]
            case "tool.auto_approved":
                kind = .action; text = e["call"]
            default: continue
            }
            guard let text, !text.isEmpty else { continue }
            out.append(AutoDecision(id: "a\(n)", taskID: tid, at: e["at"].flatMap(iso.date(from:)) ?? t.createdAt, agent: t.agentName,
                                    runtime: t.runtime, kind: kind, text: text, why: why?.isEmpty == false ? why : nil))
        }
        for t in tasks where autoModeAgents.contains(t.agentID) && !recorded.contains(t.id) {
            for (i, text) in assumptions(in: t.result ?? "").enumerated() {
                out.append(AutoDecision(id: "r\(t.id.uuidString)-\(i)", taskID: t.id, at: t.finishedAt ?? t.createdAt,
                                        agent: t.agentName, runtime: t.runtime, kind: .decision, text: text, why: nil))
            }
        }
        return out.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    }

    /// Lines of an answer that declare themselves a decision or assumption ("- **Supuesto:** …"). Only labelled
    /// lines: any sentence merely mentioning a decision would be noise.
    static func assumptions(in answer: String) -> [String] {
        let label = #/^(supuestos?|asunci[oó]n(es)?|decisi[oó]n(es)?( tomadas?)?|assumptions?|decisions?( taken| made)?)\s*:\s*\S|^(asum[ií]|decid[ií]|i assumed|i decided)\s+(que|that)\s/#.ignoresCase()
        return answer.split(separator: "\n").compactMap { raw in
            let line = raw.replacingOccurrences(of: "**", with: "")
                .replacing(#/^\s*([-*•>#]+|\d+[.)])\s*/#, with: "")
                .trimmingCharacters(in: .whitespaces)
            return line.firstMatch(of: label) == nil ? nil : line
        }
    }

    /// Reads the audit log off the main thread.
    static func load(tasks: [AgentTask], autoModeAgents: Set<UUID>) async -> [AutoDecision] {
        let url = AgentStore.auditFile
        return await Task.detached(priority: .userInitiated) {
            collect(audit: (try? String(contentsOf: url, encoding: .utf8)) ?? "", tasks: tasks, autoModeAgents: autoModeAgents)
        }.value
    }
}
