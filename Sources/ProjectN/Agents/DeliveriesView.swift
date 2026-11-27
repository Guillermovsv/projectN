import AppKit
import SwiftUI

/// Agents view → Deliveries: one entry per request agents worked on together. In the middle, who worked and when
/// (times and usage from ProjectN's own task records), the criteria, the findings and the cycle, compact and
/// expandable; on the right, **For you**: what needs your decision or approval, a box to answer the coordinator,
/// what to clean up and what it cost.
struct DeliveriesPage: View {
    @EnvironmentObject var agents: AgentHarness
    @EnvironmentObject var nav: NavigationModel
    @Environment(\.sidebarVisible) private var sidebarVisible
    @Environment(\.showSidebar) private var showSidebar
    @AppStorage("deliveryListWidth") private var listWidth: Double = 290
    @AppStorage("deliveryFilterAll") private var showAll = false
    @State private var showRules = false

    var body: some View {
        let all = agents.deliveries
        let relevant = all.filter(Self.isRelevant)
        let items = showAll || relevant.isEmpty ? all : relevant
        let selected = nav.selectedDeliveryID.flatMap { id in all.first { $0.id == id } } ?? items.first
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
                Button { showRules = true } label: { Label("Reviews & Decisions", systemImage: "checklist") }
                    .help("Review lists and decisions of each project")
                Picker("", selection: $showAll) {
                    Text("Recent & tracked").tag(false)
                    Text("All (\(all.count))").tag(true)
                }
                .pickerStyle(.segmented).fixedSize()
                .help("Recent & tracked: in progress, from the last 2 days, or with criteria / findings / a PR")
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
                    DeliveryList(items: items, selectedID: selected?.id) { nav.selectedDeliveryID = $0 }
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
        .sheet(isPresented: $showRules) {
            ProjectRulesSheet(projectID: selected.flatMap { agents.projectID(of: $0) })
        }
    }

    static func isRelevant(_ d: Delivery) -> Bool {
        d.isActive || d.record?.ship?.isLive == true || !(d.record?.isEmpty ?? true)
            || Date().timeIntervalSince(d.start) < 2 * 86400
    }
}

// MARK: - List

private struct DeliveryList: View {
    @EnvironmentObject var agents: AgentHarness
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
        let waiting = agents.pendingForUser(d).count + (d.record?.findings.filter { $0.status == .needsDecision }.count ?? 0)
        return HStack(alignment: .top, spacing: 8) {
            DeliveryStateDot(delivery: d).padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(DeliveryText.title(d)).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(d.start.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                    Text("· \(d.agents.count) agents").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if waiting > 0 { CountBadge(count: waiting) }
                    if let r = d.record, !r.criteria.isEmpty { CriteriaBadge(record: r) }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.primary.opacity(0.1) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { onSelect(d.id) }
    }
}

private struct CriteriaBadge: View {
    let record: DeliveryRecord
    var body: some View {
        let ok = record.criteriaMet == record.criteria.count
        Text("\(record.criteriaMet)/\(record.criteria.count)").font(.caption2.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(ok ? Color.green : Color.orange)
            .background(Capsule().fill((ok ? Color.green : Color.orange).opacity(0.18)))
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
        if d.isActive || d.record?.ship?.isLive == true { return (.green, "circle.fill") }
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
    @AppStorage("deliveryForYouWidth") private var sideWidth: Double = 310
    let delivery: Delivery
    @State private var expanded: Set<String> = []
    @State private var allTasks = false
    @State private var autoDecisions: [AutoDecision] = []
    @State private var showActions = false

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    // What's happening now first: the cycle and the PR, then who worked, then the detail.
                    if let c = delivery.record?.cycle { cycle(c) }
                    if let w = delivery.record?.ship { ship(w) }
                    timeline
                    if let r = delivery.record, !r.criteria.isEmpty { criteria(r) }
                    if let r = delivery.record, !r.findings.isEmpty { findings(r) }
                    if !autoDecisions.isEmpty { autoModeDecisions }
                    if let r = delivery.record, !r.reviewsApplied.isEmpty || !r.decisions.isEmpty { reviewsAndDecisions(r) }
                }
                .padding(18)
                .frame(maxWidth: 900, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .safeAreaInset(edge: .bottom) { filesBar }
            ColumnResizeHandle(width: $sideWidth, range: 260...440, direction: -1)
            ForYouPanel(delivery: delivery).frame(width: sideWidth)
        }
        // Reloaded when a task changes state, and every few seconds while agents are still working.
        .task(id: delivery.tasks.map { "\($0.id)\($0.status.rawValue)" }.joined()) {
            repeat {
                let auto = Set(agents.profiles.filter(\.autoMode).map(\.id))
                let found = await AutoDecision.load(tasks: delivery.tasks, autoModeAgents: auto)
                if Task.isCancelled { return }
                autoDecisions = found
                try? await Task.sleep(for: .seconds(5))
            } while !Task.isCancelled && delivery.isActive
        }
    }

    // MARK: Auto mode decisions

    private var autoModeDecisions: some View {
        let decided = autoDecisions.filter { $0.kind != .action }
        let actions = autoDecisions.filter { $0.kind == .action }
        return section("Auto mode decisions", note: "\(decided.count) decided · \(actions.count) actions approved automatically") {
            VStack(spacing: 0) {
                ForEach(decided) { autoRow($0) }
                if !actions.isEmpty {
                    Button { showActions.toggle() } label: {
                        Label("\(showActions ? "Hide" : "Show") \(actions.count) actions approved automatically",
                              systemImage: showActions ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.link).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    if showActions { ForEach(actions) { autoRow($0) } }
                }
            }
        }
    }

    private func autoRow(_ d: AutoDecision) -> some View {
        let key = "d:" + d.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                tag(d.runtime.shortLabel, d.runtime == .codexCLI ? .blue : .orange).frame(width: 52, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.text).font(d.kind == .action ? .caption.monospaced() : .callout)
                        .lineLimit(expanded.contains(key) ? nil : 2)
                    if let why = d.why {
                        Text("Why: \(why)").font(.caption).foregroundStyle(.secondary).lineLimit(expanded.contains(key) ? nil : 1)
                    }
                    Text("\(d.agent.trimmingCharacters(in: .whitespaces)) · \(d.kind.label)").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(DeliveryText.clock(d.at)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { toggle(key) }
            Divider()
        }
    }

    // MARK: Files

    @ViewBuilder private var filesBar: some View {
        if let path = agents.projectPath(of: delivery), let dir = DeliveryInsights.evidenceFolder(delivery, projectPath: path) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text("Files: .agentes/\(dir.lastPathComponent)/ · \(DeliveryInsights.fileCount(dir)) files")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open Folder") { NSWorkspace.shared.open(dir) }.controlSize(.small)
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    // MARK: Header

    private var header: some View {
        let d = delivery
        let total = (d.end ?? Date()).timeIntervalSince(d.start)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(DeliveryText.title(d)).font(.title3.weight(.semibold)).textSelection(.enabled).lineLimit(3)
                if let r = d.record, !r.criteria.isEmpty { CriteriaBadge(record: r) }
            }
            HStack(spacing: 8) {
                pill(d.request?.origin.kind == .slack ? "Slack" : "ProjectN", "bubble.left")
                pill("\(d.start.formatted(date: .abbreviated, time: .omitted)) · \(DeliveryText.clock(d.start))", "clock")
                pill(DeliveryText.duration(total) + (d.end == nil ? " · in progress" : ""), "timer")
                pill("\(d.tasks.count) tasks · \(d.agents.count) agents", "person.2")
                if let c = d.record?.cycle { pill("Cycle: \(c.state.rawValue) · round \(c.round)/\(c.maxRounds)", "arrow.triangle.2.circlepath") }
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
        let shown = allTasks || d.tasks.count <= 8 ? d.tasks : Array(d.tasks.suffix(8))
        return section("Who worked", note: "Times recorded by ProjectN") {
            VStack(spacing: 0) {
                if shown.count < d.tasks.count {
                    Button("Show the \(d.tasks.count - shown.count) earlier tasks") { allTasks = true }
                        .buttonStyle(.link).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 4)
                }
                ForEach(shown) { t in
                    let s = t.startedAt ?? t.createdAt
                    let e = t.finishedAt ?? Date()
                    HStack(spacing: 10) {
                        if let p = agents.profile(t.agentID) { AgentAvatar(profile: p, size: 20) }
                        HStack(spacing: 6) {
                            Text(t.agentName.trimmingCharacters(in: .whitespaces)).font(.callout.weight(.medium)).lineLimit(1)
                            Text("· " + stepLabel(t)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if t.status != .completed { tag(t.status.label, t.status.isFinished ? .red : .green) }
                        }
                        .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                        GeometryReader { g in
                            let x = g.size.width * s.timeIntervalSince(start) / span
                            let w = max(3, g.size.width * e.timeIntervalSince(s) / span)
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.07))
                                Capsule().fill(barColor(t)).frame(width: min(w, g.size.width - x)).offset(x: x)
                            }
                        }
                        .frame(width: 140, height: 7)
                        Text("\(DeliveryText.clock(s)) · \(DeliveryText.duration(e.timeIntervalSince(s)))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 128, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    .padding(.leading, CGFloat(DeliveryInsights.depth(t, in: d)) * 22)
                    .contentShape(Rectangle())
                    .onTapGesture { open(t) }
                    .help(AgentHarness.oneLine(t.instruction, max: 300) + "\n\nClick to open this task in its agent's page.")
                    Divider()
                }
            }
        }
    }

    /// What the task was, in a few words.
    private func stepLabel(_ t: AgentTask) -> String {
        switch t.cycleStep {
        case .fix: return "fixes (cycle)"
        case .retest: return "retests (cycle)"
        case .verify: return "verifies (cycle)"
        case .ship: return "fixes the PR (until merge)"
        case nil: break
        }
        if t.origin.parentTaskID == nil {
            return t.origin.automatic == true ? "follow-up" : "gets the request"
        }
        return AgentHarness.oneLine(t.instruction.replacingOccurrences(of: "\n", with: " "), max: 60)
    }

    private func barColor(_ t: AgentTask) -> Color {
        switch t.cycleStep {
        case .fix, .ship: return .orange
        case .retest: return .blue
        case .verify: return .green
        case nil: return agents.profile(t.agentID)?.canDelegate == true ? .secondary : .appAccent
        }
    }

    private func open(_ t: AgentTask) {
        nav.showDeliveries = false
        nav.selectedAgentID = t.agentID
        nav.selectedTaskByAgent[t.agentID] = t.id
    }

    // MARK: Criteria & findings (one line each; click for the detail)

    private func criteria(_ r: DeliveryRecord) -> some View {
        section("Criteria", note: "\(r.criteriaMet) of \(r.criteria.count) met · click one for its check and evidence") {
            VStack(spacing: 0) {
                ForEach(r.criteria) { c in
                    let key = "c:" + c.id
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(c.id).font(.caption.monospaced().weight(.semibold)).foregroundStyle(Color.appAccent).frame(width: 30, alignment: .leading)
                            Text(c.text).font(.callout).lineLimit(expanded.contains(key) ? nil : 1)
                            Spacer(minLength: 8)
                            if c.amendments?.isEmpty == false { tag("amended", .purple) }
                            statusTag(label(c, r), c.status == .met ? .green : c.status == .unmet ? .red : .secondary)
                        }
                        if expanded.contains(key) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Check: \(c.check)")
                                if let e = c.evidence { Text("Evidence: \(e)") }
                                ForEach(c.amendments ?? [], id: \.self) { Text($0).italic() }
                            }
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.leading, 40)
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(key) }
                    Divider()
                }
            }
        }
    }

    /// "met", or "not met · P10" with the findings that keep it from being met.
    private func label(_ c: DeliveryCriterion, _ r: DeliveryRecord) -> String {
        switch c.status {
        case .met: return "met"
        case .pending: return "pending"
        case .unmet:
            let ids = r.findings.filter { f in
                f.status != .closed && ["criterion \(c.id)", "criterio \(c.id)"].contains { f.anchor.folded.contains($0.folded) }
            }.map(\.id)
            return ids.isEmpty ? "not met" : "not met · " + ids.joined(separator: " ")
        }
    }

    private func findings(_ r: DeliveryRecord) -> some View {
        let order: [DeliveryFinding.Status] = [.needsDecision, .reopened, .open, .fixed, .closed]
        let sorted = r.findings.sorted { (order.firstIndex(of: $0.status) ?? 9, $0.id) < (order.firstIndex(of: $1.status) ?? 9, $1.id) }
        return section("Findings", note: "\(r.openFindings.count) not closed of \(r.findings.count)") {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("ID").frame(width: 34, alignment: .leading)
                    Text("SEV.").frame(width: 30, alignment: .leading)
                    Text("WHAT FAILS").frame(maxWidth: .infinity, alignment: .leading)
                    Text("ANCHOR").frame(width: 180, alignment: .leading)
                    Text("STATUS").frame(width: 120, alignment: .trailing)
                }
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 4)
                Divider()
                ForEach(sorted) { f in
                    let key = "f:" + f.id
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(f.id).font(.caption.monospaced().weight(.semibold)).frame(width: 34, alignment: .leading)
                            Text(f.severity ?? "—").font(.caption.monospaced()).foregroundStyle(sevColor(f.severity)).frame(width: 30, alignment: .leading)
                            Text(f.text).font(.callout).lineLimit(expanded.contains(key) ? nil : 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(f.anchor).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(expanded.contains(key) ? nil : 1).truncationMode(.middle).frame(width: 180, alignment: .leading)
                            statusTag(findingLabel(f), color(f.status)).frame(width: 120, alignment: .trailing)
                        }
                        if expanded.contains(key) {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(f.history.enumerated()), id: \.offset) { _, h in
                                    Text("\(DeliveryText.clock(h.at))  \(h.status.rawValue) — \(h.by.trimmingCharacters(in: .whitespaces))\(h.note.map { ": \($0)" } ?? "")")
                                }
                                if let c = f.commit { Text("Commit \(c)") }
                            }
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.leading, 84)
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(key) }
                    Divider()
                }
            }
        }
    }

    /// What is happening to a finding right now: "fixing · round 2", "retesting", "queued", "to retest"…
    private func findingLabel(_ f: DeliveryFinding) -> String {
        let running = delivery.tasks.last { $0.cycleStep != nil && !$0.status.isFinished }
        let inStep = running.map { DeliveryInsights.findingIDs(inStep: $0.instruction).contains(f.id) } ?? false
        let cycleOn = delivery.record?.cycle?.state == .running
        switch f.status {
        case .open, .reopened:
            if inStep, running?.cycleStep == .fix { return "fixing · round \(delivery.record?.cycle?.round ?? 1)" }
            if cycleOn { return f.status == .reopened ? "reopened · queued" : "queued" }
            return f.status.rawValue
        case .fixed:
            if inStep, running?.cycleStep == .retest { return "retesting" }
            return cycleOn ? "fixed · to retest" : "fixed"
        case .closed: return "closed"
        case .needsDecision: return "needs decision"
        }
    }

    private func sevColor(_ s: String?) -> Color {
        switch s?.uppercased() { case "P0", "P1": return .red; case "P2": return .orange; default: return .secondary }
    }

    private func color(_ s: DeliveryFinding.Status) -> Color {
        switch s { case .open, .reopened: return .red; case .fixed: return .orange; case .closed: return .green; case .needsDecision: return .purple }
    }

    private func toggle(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }

    // MARK: Cycle

    private func cycle(_ c: DeliveryCycle) -> some View {
        let running = delivery.tasks.last { $0.cycleStep != nil && $0.cycleStep != .ship && !$0.status.isFinished }?.cycleStep
        return section("Automatic cycle", note: "Round \(c.round) of \(c.maxRounds) · \(c.steps) steps") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    chip("✅ \(c.verifier) opens", on: false)
                    arrow
                    chip("🛠 \(c.fixer) fixes", on: running == .fix)
                    arrow
                    chip("🧪 \((c.tester ?? c.verifier).trimmingCharacters(in: .whitespaces)) retests", on: running == .retest)
                    arrow
                    chip("✅ \(c.verifier) verifies", on: running == .verify)
                    Spacer()
                    statusTag(c.state.rawValue, c.state == .done ? .green : c.state == .running ? .blue : .orange)
                }
                if let why = c.stopReason { Text(why).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                let r = delivery.record
                let closed = r?.findings.filter { $0.status == .closed }.count ?? 0
                Text([DeliveryInsights.branch(r).map { "Branch \($0)" }, "no push", "round \(c.round) of \(c.maxRounds)",
                      "\(closed)/\(r?.findings.count ?? 0) findings closed"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var arrow: some View { Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary) }

    private func chip(_ text: String, on: Bool) -> some View {
        Text(text).font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(on ? 0.12 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Color.appAccent : .clear, lineWidth: 1.5))
    }

    // MARK: Until merge

    private func ship(_ w: ShipWatch) -> some View {
        let color: Color = switch w.state {
        case .ready, .merged: .green
        case .fixing, .watching: .blue
        case .closed, .stopped: .orange
        }
        return section("Until merge", note: "PR #\(w.pr) · \(w.agent)") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    statusTag(w.state.rawValue, color)
                    Text(w.status).font(.callout).textSelection(.enabled)
                    Spacer()
                    if !w.url.isEmpty, let u = URL(string: w.url) { Link("Open PR", destination: u).font(.caption) }
                    if w.isLive {
                        Button("Stop") { agents.stopShip(delivery.id, reason: "Stopped by you in ProjectN") }.controlSize(.small)
                    }
                }
                Text("Fix tasks: \(w.fixes) of \(w.maxFixes)" + (w.lastCheck.map { " · last checked \(DeliveryText.clock($0))" } ?? "")
                     + (w.branch.isEmpty ? "" : " · branch \(w.branch)"))
                    .font(.caption).foregroundStyle(.secondary)
                if let why = w.stopReason { Text(why).font(.callout).foregroundStyle(.orange) }
                ForEach(Array(w.notes.suffix(8).enumerated()), id: \.offset) { _, n in
                    Text("\(DeliveryText.clock(n.at))  \(n.text)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Reviews & decisions

    private func reviewsAndDecisions(_ r: DeliveryRecord) -> some View {
        section("Review lists & decisions", note: "Decisions are saved in the project notes") {
            VStack(alignment: .leading, spacing: 6) {
                if !r.reviewsApplied.isEmpty {
                    HStack(spacing: 6) {
                        Text("Given to the verifier:").font(.caption).foregroundStyle(.secondary)
                        ForEach(r.reviewsApplied, id: \.self) { tag($0, .purple) }
                    }
                }
                ForEach(r.decisions, id: \.self) { Text($0).font(.callout).textSelection(.enabled) }
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
        Text(text).font(.caption.weight(.medium)).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().strokeBorder(color.opacity(0.5)))
    }
}

// MARK: - For you

/// The right column: what this request needs from you, a box to answer its coordinator, clean-up and usage.
private struct ForYouPanel: View {
    @EnvironmentObject var agents: AgentHarness
    let delivery: Delivery
    @State private var reply = ""
    @State private var sent: String?
    @State private var confirmCleanup = false
    @State private var cleanupLog: [String] = []
    @State private var cleaning = false
    @State private var pendingCommand: String?
    @State private var commandOutput: String?

    var body: some View {
        let r = delivery.record
        let pending = agents.pendingForUser(delivery)
        let undecided = r?.findings.filter { $0.status == .needsDecision } ?? []
        let unmet = r?.criteria.filter { $0.status == .unmet } ?? []
        VStack(alignment: .leading, spacing: 0) {
            Text("For you").font(.headline).padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if pending.isEmpty && undecided.isEmpty && unmet.isEmpty && r?.cycle?.state != .stopped && r?.ship?.state != .ready {
                        card {
                            Label(delivery.isActive ? "Agents are working. Nothing needs you right now." : "Nothing is waiting on you.",
                                  systemImage: delivery.isActive ? "hourglass" : "checkmark.circle")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(pending) { q in
                        card {
                            Text(q.kind == .approval ? "Approve?" : "Question").font(.callout.weight(.semibold))
                            Text("\(q.agentName.trimmingCharacters(in: .whitespaces)): \(q.summary)").font(.caption).textSelection(.enabled).lineLimit(6)
                            if q.kind == .approval {
                                HStack {
                                    Button("Approve") { agents.resolveRequest(q.id, approve: true, by: "You (ProjectN)") }.buttonStyle(.borderedProminent)
                                    Button("Deny") { agents.resolveRequest(q.id, approve: false, by: "You (ProjectN)") }
                                }.controlSize(.small)
                            } else {
                                Button("Answer below") { reply = "" }.controlSize(.small).disabled(true)
                                    .help("Answer it in its agent's page or in Slack")
                            }
                        }
                    }
                    if let c = r?.cycle, c.state == .stopped {
                        card {
                            Text("The cycle stopped").font(.callout.weight(.semibold))
                            Text(c.stopReason ?? "").font(.caption).textSelection(.enabled)
                        }
                    }
                    if !undecided.isEmpty || !unmet.isEmpty {
                        card {
                            Text("To decide").font(.callout.weight(.semibold))
                            ForEach(undecided) { f in
                                Text("\(f.id): \(f.history.last?.note ?? f.text)").font(.caption).textSelection(.enabled)
                            }
                            ForEach(unmet) { c in
                                Text("\(c.id) not met: \(c.text)").font(.caption).lineLimit(3).textSelection(.enabled)
                            }
                            suggestions(undecided: undecided, unmet: unmet)
                        }
                    }
                    questionsCard
                    commandsCard
                    if let w = r?.ship, w.state == .ready {
                        card {
                            Text("PR #\(w.pr) is ready to merge").font(.callout.weight(.semibold))
                            Text(w.status).font(.caption)
                            if !w.url.isEmpty, let u = URL(string: w.url) { Link("Open the PR to merge it", destination: u).font(.caption) }
                        }
                    }
                    answerBox
                    cycleLog
                    cleanup
                    usage
                }
                .padding(12)
            }
        }
        .background(Color.appSidebar.opacity(0.35))
    }

    // MARK: Answer the coordinator

    @ViewBuilder private var answerBox: some View {
        if let c = agents.coordinatorTask(of: delivery) {
            card {
                Text("Tell \(c.agentName.trimmingCharacters(in: .whitespaces))").font(.callout.weight(.semibold))
                TextEditor(text: $reply)
                    .font(.callout).frame(minHeight: 60, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(4).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                HStack {
                    if let s = sent { Text(s).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Send") {
                        sent = agents.replyToCoordinator(delivery, text: reply) ? "Sent." : "Couldn't send it."
                        if sent == "Sent." { reply = "" }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                Text(delivery.request?.origin.kind == .slack ? "Its answer also goes to the Slack thread." : "It continues the same conversation.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// One-click starting points for the most common answers (editable before sending).
    @ViewBuilder private func suggestions(undecided: [DeliveryFinding], unmet: [DeliveryCriterion]) -> some View {
        let ids = (undecided.map(\.id) + unmet.map(\.id)).joined(separator: ", ")
        VStack(alignment: .leading, spacing: 4) {
            suggestion("Adjust the criterion and rerun",
                       "Ajusta el criterio (\(ids)) con criterion_amend según lo que recomendó el agente, y vuelve a correr start_cycle.")
            suggestion("Keep it and fix the code",
                       "No cambies el criterio: reabre \(ids) con finding_update (reopened) y vuelve a correr start_cycle.")
        }
    }

    private func suggestion(_ title: String, _ text: String) -> some View {
        Button(title) { send(text) }
            .controlSize(.small)
            .help(text)
    }

    private func send(_ text: String) {
        sent = agents.replyToCoordinator(delivery, text: text) ? "Sent: \(AgentHarness.oneLine(text, max: 60))" : "Couldn't send it."
    }

    // MARK: The coordinator's questions and commands

    /// The coordinator's latest answer, when nothing has happened since (its questions are still open).
    private var lastWord: String? {
        guard let c = agents.coordinatorTask(of: delivery), c.status.isFinished, c.id == delivery.tasks.last?.id else { return nil }
        return c.result
    }

    @ViewBuilder private var questionsCard: some View {
        if let text = lastWord {
            ForEach(Array(DeliveryInsights.questions(in: text).enumerated()), id: \.offset) { _, q in
                card {
                    Text(q.text.isEmpty ? "Decide" : q.text).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    ForEach(q.options, id: \.key) { o in
                        Button {
                            send((q.number.isEmpty ? "" : "\(q.number): ") + "\(o.key)) \(o.text)")
                        } label: {
                            Text("\(o.key)) \(o.text)").frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder private var commandsCard: some View {
        if let text = lastWord, let dir = agents.projectPath(of: delivery) {
            let cmds = DeliveryInsights.commands(in: text)
            if !cmds.isEmpty {
                card {
                    Text("Suggested command").font(.callout.weight(.semibold))
                    ForEach(cmds, id: \.self) { c in
                        Text(c).font(.caption.monospaced()).textSelection(.enabled)
                        HStack {
                            Button("Run…") { pendingCommand = c }.controlSize(.small)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(c, forType: .string)
                            }.controlSize(.small)
                        }
                    }
                    if let out = commandOutput { Text(out).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(8).textSelection(.enabled) }
                }
                .confirmationDialog("Run this command in \((dir as NSString).lastPathComponent)?", isPresented: Binding(
                    get: { pendingCommand != nil }, set: { if !$0 { pendingCommand = nil } })) {
                    Button("Run") {
                        guard let c = pendingCommand else { return }
                        pendingCommand = nil
                        commandOutput = "Running…"
                        Task {
                            let r = await agents.runSuggested(c, in: dir)
                            commandOutput = (r.ok ? "✓ " : "✗ ") + (r.output.isEmpty ? "(no output)" : String(r.output.suffix(600)))
                        }
                    }
                } message: {
                    Text(pendingCommand ?? "")
                }
            }
        }
    }

    // MARK: What ProjectN did by itself

    @ViewBuilder private var cycleLog: some View {
        let steps = delivery.tasks.filter { $0.cycleStep != nil }
        if !steps.isEmpty {
            card {
                Text("What ProjectN did by itself").font(.callout.weight(.semibold))
                ForEach(Array(steps.enumerated()), id: \.offset) { i, t in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text((t.startedAt ?? t.createdAt).formatted(.dateTime.hour().minute()))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        Circle().fill(dot(t)).frame(width: 7, height: 7)
                        Text(logLine(t, index: i, all: steps)).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let c = delivery.record?.cycle, c.state != .running {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text((c.endedAt ?? Date()).formatted(.dateTime.hour().minute()))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        Circle().fill(c.state == .done ? Color.green : .orange).frame(width: 7, height: 7)
                        Text(c.state == .done ? "Finished: every criterion met" : "Stopped and told the coordinator")
                            .font(.caption.weight(.medium))
                    }
                }
            }
        }
    }

    private func dot(_ t: AgentTask) -> Color {
        switch t.cycleStep { case .fix, .ship: return .orange; case .retest: return .blue; default: return .green }
    }

    private func logLine(_ t: AgentTask, index: Int, all: [AgentTask]) -> String {
        let who = t.agentName.trimmingCharacters(in: .whitespaces)
        let ids = DeliveryInsights.findingIDs(inStep: t.instruction)
        let list = ids.isEmpty ? "" : " " + ids.joined(separator: ", ")
        let state = t.status.isFinished ? (t.status == .completed ? "" : " (\(t.status.label.lowercased()))") : " — working"
        switch t.cycleStep {
        case .fix:
            let round = all[...index].filter { $0.cycleStep == .fix }.count
            return "Round \(round): sent\(list) to \(who)\(state)"
        case .retest: return "Sent\(list) to \(who) to retest\(state)"
        case .verify: return "\(who) checked the criteria\(state)"
        case .ship: return "\(who) fixes the PR\(state)"
        case nil: return who
        }
    }

    // MARK: Clean-up & usage

    @ViewBuilder private var cleanup: some View {
        let paths = delivery.record?.worktrees ?? []
        if !paths.isEmpty || !cleanupLog.isEmpty {
            card {
                Text("Clean up what it left").font(.callout.weight(.semibold))
                ForEach(paths, id: \.self) { p in
                    Text((p as NSString).lastPathComponent).font(.caption.monospaced()).help(p)
                }
                if !paths.isEmpty {
                    Button(cleaning ? "Cleaning up…" : "Remove \(paths.count) worktree(s)…") { confirmCleanup = true }
                        .controlSize(.small)
                        .disabled(cleaning || delivery.isActive)
                        .help(delivery.isActive ? "Wait until the agents finish" : "git worktree remove --force; branches and commits stay")
                }
                ForEach(cleanupLog, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
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

    private var usage: some View {
        var rows: [(String, Int, Int)] = []
        for t in delivery.tasks {
            let name = t.agentName.trimmingCharacters(in: .whitespaces)
            let u = t.usage ?? TokenUsage()
            if let i = rows.firstIndex(where: { $0.0 == name }) {
                rows[i].1 += u.outputTokens; rows[i].2 += u.cacheReadTokens
            } else {
                rows.append((name, u.outputTokens, u.cacheReadTokens))
            }
        }
        return card {
            Text("Usage").font(.callout.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("Agent"); Text("Output").gridColumnAlignment(.trailing); Text("Cache").gridColumnAlignment(.trailing)
                }
                .font(.caption2).foregroundStyle(.secondary)
                ForEach(rows, id: \.0) { r in
                    GridRow {
                        Text(r.0).lineLimit(1)
                        Text(DeliveryText.tokens(r.1)).monospacedDigit()
                        Text(DeliveryText.tokens(r.2)).monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.appSurface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}
