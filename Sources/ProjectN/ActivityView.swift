import SwiftUI

/// All Claude/Codex panes across workspaces. Panes waiting on the user are highlighted in yellow.
struct ActivityView: View {
    @EnvironmentObject var store: Store

    private enum Group: Int, CaseIterable {
        case needsInput, working, idle, stopped
        var title: String {
            switch self {
            case .needsInput: return "Needs your input"
            case .working: return "Working"
            case .idle: return "Idle"
            case .stopped: return "Not running"
            }
        }
    }

    private func group(_ e: Store.AgentEntry) -> Group {
        guard let rt = e.runtime else { return .stopped }
        switch rt.activity {
        case .needsInput: return .needsInput
        case .working: return .working
        case .idle: return .idle
        case .exited: return .stopped
        }
    }

    var body: some View {
        let agents = store.agents
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summary(agents)
                if agents.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "sparkle").font(.largeTitle).foregroundStyle(.tertiary)
                        Text("No Claude or Codex panes yet").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
                ForEach(Group.allCases, id: \.self) { g in
                    let items = agents.filter { group($0) == g }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(g.title.uppercased()) · \(items.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(g == .needsInput ? Color.yellow : .secondary)
                            ForEach(items) { e in
                                AgentRow(entry: e)
                                    .onTapGesture { store.reveal(pane: e.pane.id, in: e.workspace.id) }
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private func summary(_ agents: [Store.AgentEntry]) -> some View {
        let counts = Dictionary(grouping: agents, by: group).mapValues(\.count)
        return HStack(spacing: 8) {
            stat("Input", counts[.needsInput] ?? 0, .yellow)
            stat("Working", counts[.working] ?? 0, .green)
            stat("Idle", counts[.idle] ?? 0, .secondary)
        }
    }

    private func stat(_ label: String, _ n: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(n)").font(.title2.bold().monospacedDigit()).foregroundStyle(n > 0 ? color : .secondary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

private struct AgentRow: View {
    @EnvironmentObject var store: Store
    let entry: Store.AgentEntry
    @State private var hover = false

    var body: some View {
        if let rt = entry.runtime {
            ObservedAgentRow(entry: entry, runtime: rt, hover: hover)
                .onHover { hover = $0 }
        } else {
            content(status: "Not started", color: .gray, question: nil, highlight: false)
                .onHover { hover = $0 }
        }
    }

    fileprivate func content(status: String, color: Color, question: String?, highlight: Bool) -> some View {
        AgentRowContent(entry: entry, title: store.paneTitle(entry.pane), status: status, color: color,
                        question: question, highlight: highlight, hover: hover)
    }
}

private struct ObservedAgentRow: View {
    @EnvironmentObject var store: Store
    let entry: Store.AgentEntry
    @ObservedObject var runtime: TerminalSession
    let hover: Bool

    var body: some View {
        let (status, color, question, highlight): (String, Color, String?, Bool) = {
            switch runtime.activity {
            case .needsInput(let q): return ("Needs input", .yellow, q, true)
            case .working: return ("Working", .green, nil, false)
            case .idle: return ("Idle", .secondary, nil, false)
            case .exited: return ("Exited", .gray, nil, false)
            }
        }()
        AgentRowContent(entry: entry, title: store.paneTitle(entry.pane), status: status, color: color,
                        question: question, highlight: highlight, hover: hover, auto: entry.pane.isAutoComplete)
    }
}

private struct AgentRowContent: View {
    let entry: Store.AgentEntry
    let title: String
    let status: String
    let color: Color
    let question: String?
    let highlight: Bool
    let hover: Bool
    var auto: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: entry.pane.tool.symbol).foregroundStyle(toolColor(entry.pane.tool))
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                if auto {
                    Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.yellow).help("Auto · Complete")
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    if status == "Working" { ProgressView().controlSize(.mini) }
                    Text(status)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(highlight ? Color.black : color)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(highlight ? Color.yellow : color.opacity(0.15)))
            }
            Text("\(entry.workspace.name) › \(entry.space.name)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let question {
                Text(question)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.yellow.opacity(0.12)))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(highlight ? Color.yellow.opacity(hover ? 0.22 : 0.15) : Color.primary.opacity(hover ? 0.08 : 0.04))
        )
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(highlight ? Color.yellow.opacity(0.8) : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .handCursor()
        .help("Click to jump to this pane")
    }
}
