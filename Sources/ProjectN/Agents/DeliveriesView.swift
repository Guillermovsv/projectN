import SwiftUI

/// Agents view → Deliveries: one entry per request that involved several tasks. Who worked and when (times and
/// usage from ProjectN's own task records, not from what agents write), the acceptance criteria, the findings
/// agents passed to each other, the automatic cycle, and what the request left behind.
struct DeliveriesPage: View {
    @EnvironmentObject var agents: AgentHarness
    @EnvironmentObject var nav: NavigationModel
    @Environment(\.sidebarVisible) private var sidebarVisible
    @Environment(\.showSidebar) private var showSidebar
    @AppStorage("deliveryListWidth") private var listWidth: Double = 290

    var body: some View {
        let all = agents.deliveries
        let selected = nav.selectedDeliveryID.flatMap { id in all.first { $0.id == id } } ?? all.first
        VStack(spacing: 0) {
            TopBar(leadingInset: !sidebarVisible) {
                if !sidebarVisible {
                    Button { showSidebar() } label: { Image(systemName: "sidebar.left") }.buttonStyle(ChromeButtonStyle())
                }
                Image(systemName: "shippingbox").font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Deliveries").font(.headline)
                    Text("Requests that agents worked on together").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if all.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "shippingbox").font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text("No deliveries yet").font(.title3)
                    Text("When an agent delegates work, the request shows up here with who worked on it,\nits criteria and findings, and what it left behind.")
                        .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    DeliveryList(items: all, selectedID: selected?.id) { nav.selectedDeliveryID = $0 }
                        .frame(width: listWidth)
                    ColumnResizeHandle(width: $listWidth, range: 220...460, direction: 1)
                    if let d = selected {
                        DeliveryDetail(delivery: d).id(d.id)
                    } else {
                        Spacer()
                    }
                }
            }
        }
        .background(Color.appSurface)
    }
}

// MARK: - List

private struct DeliveryList: View {
    let items: [Delivery]
    let selectedID: UUID?
    let onSelect: (UUID) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(items) { d in row(d) }
            }
            .padding(8)
        }
        .background(Color.appSidebar.opacity(0.5))
    }

    private func row(_ d: Delivery) -> some View {
        let selected = d.id == selectedID
        return HStack(alignment: .top, spacing: 8) {
            DeliveryStateDot(delivery: d).padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(DeliveryText.title(d)).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(d.start.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                    Text("· \(d.agents.count) agents").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let r = d.record, !r.criteria.isEmpty {
                        Text("\(r.criteriaMet)/\(r.criteria.count)").font(.caption2.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill((r.criteriaMet == r.criteria.count ? Color.green : Color.orange).opacity(0.2)))
                    }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.primary.opacity(0.1) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { onSelect(d.id) }
    }
}

private struct DeliveryStateDot: View {
    let delivery: Delivery
    var body: some View {
        let (color, symbol) = DeliveryText.state(delivery)
        Image(systemName: symbol).font(.caption).foregroundStyle(color).frame(width: 14)
    }
}

@MainActor
enum DeliveryText {
    static func title(_ d: Delivery) -> String {
        let raw = d.request?.instruction ?? "Request"
        // Coordinators get "(Proyecto indicado: …)" appended: not part of what the user said.
        let cut = raw.components(separatedBy: "\n\n(Proyecto indicado:").first ?? raw
        return AgentHarness.oneLine(cut, max: 110)
    }

    static func state(_ d: Delivery) -> (Color, String) {
        if d.isActive { return (.green, "circle.fill") }
        if d.record?.cycle?.state == .stopped { return (.orange, "exclamationmark.circle.fill") }
        if let r = d.record, !r.criteria.isEmpty, r.criteriaMet < r.criteria.count { return (.orange, "circle.lefthalf.filled") }
        if d.tasks.contains(where: { $0.status != .completed }) { return (.red, "xmark.circle.fill") }
        return (.secondary, "checkmark.circle.fill")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2f M", Double(n) / 1_000_000) }
        if n >= 10_000 { return String(format: "%.0f k", Double(n) / 1000) }
        return n.formatted()
    }

    static func clock(_ d: Date) -> String { d.formatted(.dateTime.hour().minute().second()) }
}

// MARK: - Detail

private struct DeliveryDetail: View {
    @EnvironmentObject var agents: AgentHarness
    @EnvironmentObject var nav: NavigationModel
    let delivery: Delivery
    @State private var confirmCleanup = false
    @State private var cleanupLog: [String] = []
    @State private var cleaning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                timeline
                if let r = delivery.record, !r.criteria.isEmpty { criteria(r) }
                if let r = delivery.record, !r.findings.isEmpty { findings(r) }
                if let c = delivery.record?.cycle { cycle(c) }
                leftBehind
            }
            .padding(18)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        let d = delivery
        let total = (d.end ?? Date()).timeIntervalSince(d.start)
        let u = d.usage
        return VStack(alignment: .leading, spacing: 8) {
            Text(DeliveryText.title(d)).font(.title3.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 8) {
                pill(d.request?.origin.label ?? "ProjectN", "bubble.left")
                pill("\(d.start.formatted(date: .abbreviated, time: .omitted)) · \(DeliveryText.clock(d.start))", "clock")
                pill(DeliveryText.duration(total) + (d.end == nil ? " · in progress" : ""), "timer")
                pill("\(d.tasks.count) tasks · \(d.agents.count) agents", "person.2")
                if u.total > 0 { pill("\(DeliveryText.tokens(u.outputTokens)) out · \(DeliveryText.tokens(u.cacheReadTokens)) cache", "gauge") }
            }
        }
    }

    private func pill(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.caption).labelStyle(.titleAndIcon)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }

    // MARK: Who worked

    private var timeline: some View {
        let d = delivery
        let start = d.start
        let span = max(1, (d.end ?? Date()).timeIntervalSince(start))
        return section("Who worked", note: "Times and usage recorded by ProjectN") {
            VStack(spacing: 0) {
                ForEach(d.tasks) { t in
                    let s = t.startedAt ?? t.createdAt
                    let e = t.finishedAt ?? Date()
                    HStack(spacing: 10) {
                        if let p = agents.profile(t.agentID) { AgentAvatar(profile: p, size: 22) }
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(t.agentName).font(.callout.weight(.medium))
                                if let step = t.cycleStep { tag("cycle · \(step.rawValue)", .blue) }
                                if t.origin.automatic == true, t.origin.parentTaskID == nil { tag("follow-up", .secondary) }
                                if t.status != .completed { tag(t.status.label, t.status.isFinished ? .red : .green) }
                            }
                            Text(AgentHarness.oneLine(t.instruction, max: 90)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                        GeometryReader { g in
                            let x = g.size.width * s.timeIntervalSince(start) / span
                            let w = max(3, g.size.width * e.timeIntervalSince(s) / span)
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.07))
                                Capsule().fill(barColor(t)).frame(width: min(w, g.size.width - x)).offset(x: x)
                            }
                        }
                        .frame(width: 160, height: 8)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(DeliveryText.clock(s)).font(.caption.monospacedDigit())
                            Text(DeliveryText.duration(e.timeIntervalSince(s))).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .frame(width: 74, alignment: .trailing)
                        Text(t.usage.map { DeliveryText.tokens($0.outputTokens) } ?? "—")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                            .help("Output tokens")
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture { open(t) }
                    .help("Open this task in its agent's page")
                    Divider()
                }
            }
        }
    }

    private func barColor(_ t: AgentTask) -> Color {
        if t.cycleStep == .fix { return .orange }
        if t.cycleStep != nil { return .green }
        return agents.profile(t.agentID)?.canDelegate == true ? .secondary : .appAccent
    }

    private func open(_ t: AgentTask) {
        nav.showDeliveries = false
        nav.selectedAgentID = t.agentID
        nav.selectedTaskByAgent[t.agentID] = t.id
    }

    // MARK: Criteria & findings

    private func criteria(_ r: DeliveryRecord) -> some View {
        section("Criteria", note: "\(r.criteriaMet) of \(r.criteria.count) met") {
            VStack(spacing: 0) {
                ForEach(r.criteria) { c in
                    HStack(alignment: .top, spacing: 10) {
                        Text(c.id).font(.caption.monospaced().weight(.semibold)).foregroundStyle(Color.appAccent).frame(width: 34, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.text).font(.callout).textSelection(.enabled)
                            Text("Check: \(c.check)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if let e = c.evidence { Text("Evidence: \(e)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        Spacer(minLength: 8)
                        statusTag(c.status.rawValue, c.status == .met ? .green : c.status == .unmet ? .red : .secondary)
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
            }
        }
    }

    private func findings(_ r: DeliveryRecord) -> some View {
        section("Findings", note: "\(r.openFindings.count) not closed of \(r.findings.count)") {
            VStack(spacing: 0) {
                ForEach(r.findings) { f in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.id).font(.caption.monospaced().weight(.semibold))
                            if let s = f.severity { Text(s).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                        }
                        .frame(width: 34, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.text).font(.callout).textSelection(.enabled)
                            Text(f.anchor).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(history(f)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        statusTag(f.status.rawValue, color(f.status))
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
            }
        }
    }

    private func history(_ f: DeliveryFinding) -> String {
        f.history.map { "\($0.status.rawValue) by \($0.by) \(DeliveryText.clock($0.at))" }.joined(separator: " → ")
            + (f.commit.map { " · \($0)" } ?? "")
    }

    private func color(_ s: DeliveryFinding.Status) -> Color {
        switch s { case .open, .reopened: return .red; case .fixed: return .orange; case .closed: return .green }
    }

    // MARK: Cycle

    private func cycle(_ c: DeliveryCycle) -> some View {
        section("Automatic cycle", note: c.state == .running ? "Running" : c.state == .done ? "Finished" : "Stopped") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    tag("fix: \(c.fixer)", .orange)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    tag("retest: \(c.tester ?? c.verifier)", .blue)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    tag("verify: \(c.verifier)", .green)
                    Spacer()
                    Text("Round \(c.round) of \(c.maxRounds) · \(c.steps) steps").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let why = c.stopReason { Text(why).font(.callout).foregroundStyle(.orange) }
            }
        }
    }

    // MARK: Left behind

    @ViewBuilder private var leftBehind: some View {
        let paths = delivery.record?.worktrees ?? []
        if !paths.isEmpty || !cleanupLog.isEmpty {
            section("Left behind", note: "Worktrees agents created for this request") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(paths, id: \.self) { p in
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(p).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if !paths.isEmpty {
                        Button(cleaning ? "Cleaning up…" : "Clean Up Worktrees…") { confirmCleanup = true }
                            .disabled(cleaning || delivery.isActive)
                            .help(delivery.isActive ? "Wait until the agents finish" : "Removes them with git worktree remove --force")
                    }
                    ForEach(cleanupLog, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .confirmationDialog("Remove \(paths.count) worktree(s)?", isPresented: $confirmCleanup) {
                Button("Remove", role: .destructive) {
                    cleaning = true
                    Task {
                        cleanupLog = await agents.cleanUpWorktrees(delivery.id)
                        cleaning = false
                    }
                }
            } message: {
                Text("Uncommitted changes in them are lost. Branches and commits stay in the repository.")
            }
        }
    }

    // MARK: Pieces

    private func section<C: View>(_ title: String, note: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
    }

    private func statusTag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().strokeBorder(color.opacity(0.5)))
    }
}
