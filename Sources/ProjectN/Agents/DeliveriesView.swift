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
                    if let r = delivery.record, !r.reviewsApplied.isEmpty || !r.decisions.isEmpty { reviewsAndDecisions(r) }
                }
                .padding(18)
                .frame(maxWidth: 900, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            ColumnResizeHandle(width: $sideWidth, range: 260...440, direction: -1)
            ForYouPanel(delivery: delivery).frame(width: sideWidth)
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
                            statusTag(label(c.status), c.status == .met ? .green : c.status == .unmet ? .red : .secondary)
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

    private func label(_ s: DeliveryCriterion.Status) -> String {
        switch s { case .met: return "met"; case .unmet: return "not met"; case .pending: return "pending" }
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
                    Text("STATUS").frame(width: 104, alignment: .trailing)
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
                            statusTag(f.status == .needsDecision ? "needs decision" : f.status.rawValue, color(f.status)).frame(width: 104, alignment: .trailing)
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
                    if let w = r?.ship, w.state == .ready {
                        card {
                            Text("PR #\(w.pr) is ready to merge").font(.callout.weight(.semibold))
                            Text(w.status).font(.caption)
                            if !w.url.isEmpty, let u = URL(string: w.url) { Link("Open the PR to merge it", destination: u).font(.caption) }
                        }
                    }
                    answerBox
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
        Button { reply = text } label: {
            Label(title, systemImage: "text.bubble").font(.caption)
        }
        .buttonStyle(.link)
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
