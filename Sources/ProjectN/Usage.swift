import Foundation
import SwiftUI

/// Plan usage for Claude (5-hour + weekly windows) and Codex (primary + secondary windows), refreshed periodically.
///
/// - Claude: the same endpoint Claude Code's `/usage` uses, authenticated with the login Claude Code keeps in the
///   macOS Keychain ("Claude Code-credentials"). The token is only sent to api.anthropic.com.
/// - Codex: read locally from the latest `rate_limits` record Codex writes into ~/.codex/sessions.
/// - Cursor: the dashboard usage the Cursor app shows, authenticated with the login cursor-agent keeps in the
///   Keychain ("cursor-access-token"). The token is only sent to api2.cursor.sh.
@MainActor
final class UsageModel: ObservableObject {
    struct Window: Identifiable, Hashable {
        var id: String { label }
        let label: String        // "5h" / "Week"
        let percent: Double      // 0…100
        let resetsAt: Date?
    }

    struct ToolUsage {
        var windows: [Window] = []
        var updated: Date?
        var error: String?

        var highest: Window? { windows.max { $0.percent < $1.percent } }
    }

    @Published private(set) var claude = ToolUsage()
    @Published private(set) var codex = ToolUsage()
    @Published private(set) var cursor = ToolUsage()
    @Published private(set) var refreshing = false

    private var timer: Timer?
    private weak var store: Store?

    func start(store: Store) {
        guard timer == nil else { return }
        self.store = store
        refresh()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let settings = store?.settings ?? AppSettings()
        Task {
            async let c = Self.fetchClaude()
            async let k = Self.fetchCursor()
            // Task inherits MainActor here. A synchronous log scan inside it still
            // blocks typing and animation, even though readCodex is nonisolated.
            let x = await Task.detached(priority: .utility) {
                Self.readCodex(settings: settings)
            }.value
            let claudeResult = await c
            self.codex = x
            switch claudeResult {
            case .success(let u): self.claude = u
            case .failure(let e):
                // Keep the last good numbers; just note the problem.
                self.claude.error = e.message
                if self.claude.updated == nil { self.claude.updated = nil }
            }
            switch await k {
            case .success(let u): self.cursor = u
            case .failure(let e): self.cursor.error = e.message
            }
            self.refreshing = false
        }
    }

    func usage(for tool: Tool) -> ToolUsage {
        switch tool {
        case .codex: return codex
        case .cursor: return cursor
        default: return claude
        }
    }

    // MARK: Cursor

    nonisolated private static func fetchCursor() async -> Result<ToolUsage, UsageError> {
        guard let token = keychainPassword(service: "cursor-access-token") else {
            return .failure(UsageError(message: "Not signed in to Cursor (cursor-agent login)"))
        }
        var req = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue("ProjectN", forHTTPHeaderField: "User-Agent")
        req.httpBody = Data("{}".utf8)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                return .failure(UsageError(message: code == 401 ? "Login expired — run cursor-agent login" : "HTTP \(code)"))
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(UsageError(message: "Unexpected response"))
            }
            return .success(parseCursorUsage(obj))
        } catch {
            return .failure(UsageError(message: error.localizedDescription))
        }
    }

    /// `planUsage.totalPercentUsed` for the included-usage period (weekly or monthly, from the cycle dates),
    /// plus on-demand spend against its limit when one is set.
    nonisolated static func parseCursorUsage(_ obj: [String: Any]) -> ToolUsage {
        func num(_ v: Any?) -> Double? {
            if let n = v as? NSNumber { return n.doubleValue }
            if let s = v as? String { return Double(s) }
            return nil
        }
        let start = num(obj["billingCycleStart"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        let end = num(obj["billingCycleEnd"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        var label = "Period"
        if let start, let end { label = end.timeIntervalSince(start) <= 8 * 86400 ? "Week" : "Month" }
        var windows: [Window] = []
        let plan = obj["planUsage"] as? [String: Any]
        if let p = num(plan?["totalPercentUsed"]) ?? num(plan?["autoPercentUsed"]) {
            windows.append(Window(label: label, percent: p, resetsAt: end))
        }
        if let s = obj["spendLimitUsage"] as? [String: Any],
           let limit = num(s["individualLimit"]), limit > 0, let remaining = num(s["individualRemaining"]) {
            windows.append(Window(label: "On-demand", percent: max(0, min(100, (limit - remaining) / limit * 100)), resetsAt: end))
        }
        return ToolUsage(windows: windows, updated: Date(), error: windows.isEmpty ? "No usage data" : nil)
    }

    nonisolated private static func keychainPassword(service: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }

    // MARK: Claude

    struct UsageError: Error { let message: String }

    nonisolated private static func fetchClaude() async -> Result<ToolUsage, UsageError> {
        guard let token = claudeAccessToken() else { return .failure(UsageError(message: "Not signed in to Claude Code")) }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("ProjectN", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                return .failure(UsageError(message: code == 401 ? "Login expired — open Claude once to refresh it" : "HTTP \(code)"))
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(UsageError(message: "Unexpected response"))
            }
            var windows: [Window] = []
            for (key, label) in [("five_hour", "5h"), ("seven_day", "Week")] {
                guard let w = obj[key] as? [String: Any], let u = (w["utilization"] as? NSNumber)?.doubleValue else { continue }
                windows.append(Window(label: label, percent: u, resetsAt: parseISO(w["resets_at"] as? String)))
            }
            return .success(ToolUsage(windows: windows, updated: Date(), error: windows.isEmpty ? "No usage data" : nil))
        } catch {
            return .failure(UsageError(message: error.localizedDescription))
        }
    }

    /// Claude Code's OAuth access token from the Keychain (also used by ModelCatalog). Never logged.
    nonisolated static func claudeAccessToken() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        return token
    }

    nonisolated private static func parseISO(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: Codex

    nonisolated private static func readCodex(settings: AppSettings) -> ToolUsage {
        let root = SessionDiscovery.codexHome(settings).appendingPathComponent("sessions")
        guard let file = newestRollout(in: root) else { return ToolUsage(error: "No Codex sessions yet") }
        guard let limits = lastRateLimits(in: file) else { return ToolUsage(error: "No rate-limit data yet") }
        var windows: [Window] = []
        for key in ["primary", "secondary"] {
            guard let w = limits[key] as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
            let minutes = (w["window_minutes"] as? NSNumber)?.intValue ?? 0
            let resets = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            // A snapshot from before the window reset no longer applies.
            let pct = (resets.map { $0 < Date() } ?? false) ? 0 : used
            let label = minutes == 300 ? "5h" : (minutes == 10080 ? "Week" : (minutes >= 1440 ? "\(minutes / 1440)d" : "\(minutes / 60)h"))
            windows.append(Window(label: label, percent: pct, resetsAt: resets))
        }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return ToolUsage(windows: windows, updated: modified, error: windows.isEmpty ? "No rate-limit data yet" : nil)
    }

    nonisolated private static func newestRollout(in root: URL) -> URL? {
        let fm = FileManager.default
        let cal = Calendar.current
        var best: (URL, Date)?
        for back in 0..<8 {
            guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if best == nil || m > best!.1 { best = (f, m) }
            }
            if best != nil && back >= 1 { break }
        }
        return best?.0
    }

    nonisolated private static func lastRateLimits(in url: URL) -> [String: Any]? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let chunk: UInt64 = 512 * 1024
        try? h.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else { continue }
            if let found = find("rate_limits", in: obj) { return found }
        }
        return nil
    }

    nonisolated private static func find(_ key: String, in obj: Any) -> [String: Any]? {
        if let d = obj as? [String: Any] {
            if let v = d[key] as? [String: Any] { return v }
            for v in d.values { if let f = find(key, in: v) { return f } }
        } else if let a = obj as? [Any] {
            for v in a { if let f = find(key, in: v) { return f } }
        }
        return nil
    }
}

// MARK: - Views

func usageColor(_ percent: Double) -> Color {
    percent >= 90 ? .red : (percent >= 70 ? .orange : .primary)
}

/// Compact meter for the top bar: the active pane's agent (Claude or Codex), showing whichever window
/// (5h or weekly) is highest. Switches when you focus a pane of the other type.
struct UsageMeters: View {
    @EnvironmentObject var usage: UsageModel
    let tool: Tool
    @State private var showDetails = false

    var body: some View {
        Button { showDetails.toggle() } label: {
            meter(tool, usage.usage(for: tool))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
                .contentShape(Rectangle())
                .animation(.easeInOut(duration: 0.2), value: tool)
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 7, inset: 0)
        .help("\(tool.label) plan usage — the higher of the 5-hour and weekly windows. Click for details.")
        .popover(isPresented: $showDetails, arrowEdge: .bottom) { UsageDetails(tool: tool).environmentObject(usage) }
    }

    @ViewBuilder
    private func meter(_ tool: Tool, _ u: UsageModel.ToolUsage) -> some View {
        HStack(spacing: 6) {
            Image(systemName: tool.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(toolColor(tool))
            Text(tool.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            if let w = u.highest {
                UsageBar(percent: w.percent)
                    .frame(width: 56, height: 5)
                Text("\(Int(w.percent.rounded()))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(usageColor(w.percent))
                Text(["Week": "wk", "Month": "mo", "On-demand": "extra"][w.label] ?? w.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("—").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .opacity(u.error != nil && u.highest != nil ? 0.6 : 1)
    }
}

struct UsageBar: View {
    let percent: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15))
                Capsule()
                    .fill(usageColor(percent))
                    .frame(width: max(2, geo.size.width * min(1, percent / 100)))
            }
        }
    }
}

struct UsageDetails: View {
    @EnvironmentObject var usage: UsageModel
    var tool: Tool = .claude

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Plan usage").font(.headline)
                Spacer()
                Button { usage.refresh() } label: {
                    if usage.refreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.hover)
                .help("Refresh now")
            }
            section(tool, usage.usage(for: tool))
            // The other agents you use, for comparison (only those with data).
            ForEach(Tool.allCases.filter { $0.hasUsageMeter && $0 != tool && !usage.usage(for: $0).windows.isEmpty }) { other in
                Divider()
                section(other, usage.usage(for: other))
            }
            Text("Refreshes every minute. White < 70%, orange ≥ 70%, red ≥ 90%.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 300)
    }

    private func section(_ tool: Tool, _ u: UsageModel.ToolUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(tool.label, systemImage: tool.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(toolColor(tool))
            ForEach(u.windows) { w in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(["5h": "5-hour window", "Week": "Weekly", "Month": "Monthly", "On-demand": "On-demand spend"][w.label] ?? w.label).font(.callout)
                        Spacer()
                        Text("\(Int(w.percent.rounded()))%").font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(usageColor(w.percent))
                    }
                    UsageBar(percent: w.percent).frame(height: 6)
                    if let r = w.resetsAt {
                        Text("Resets \(r.formatted(.relative(presentation: .named))) · \(r.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if let e = u.error {
                Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            } else if let d = u.updated {
                Text("Updated \(d.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
