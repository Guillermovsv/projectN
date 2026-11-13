import Foundation
import Testing
@testable import ProjectN

struct UsageTests {
    typealias W = UsageModel.Window

    @Test func codexRecordWithoutNumbersHasNoWindows() {
        // Codex writes these alongside the real ones; they must not blank the meter.
        let premium: [String: Any] = ["limit_id": "premium", "primary": NSNull(), "secondary": NSNull()]
        #expect(UsageModel.codexWindows(premium).isEmpty)
    }

    @Test func codexWindowsParseAndCapAtLimit() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let limits: [String: Any] = [
            "primary": ["used_percent": 97.0, "window_minutes": 300, "resets_at": 1_003_600],
            "secondary": ["used_percent": 22.0, "window_minutes": 10080, "resets_at": 1_500_000],
            "rate_limit_reached_type": "primary",
        ]
        let w = UsageModel.codexWindows(limits, now: now)
        #expect(w.map(\.label) == ["5h", "Week"])
        #expect(w[0].percent == 100)
        #expect(w[0].resetsAt == Date(timeIntervalSince1970: 1_003_600))
        #expect(w[1].percent == 22)
        #expect(usagePercentText(130) == "100%")
    }

    @Test func failedReadKeepsLastNumbers() {
        let now = Date()
        let old = UsageModel.ToolUsage(windows: [W(label: "5h", percent: 100, resetsAt: now.addingTimeInterval(3600))], updated: now)
        let kept = UsageModel.merge(old, .failure(.init(message: "HTTP 429")), now: now)
        #expect(kept.windows.first?.percent == 100)
        #expect(kept.error == "HTTP 429")
        // An empty successful read also keeps them.
        let empty = UsageModel.merge(old, .success(.init(error: "No usage data")), now: now)
        #expect(empty.windows.first?.percent == 100)
    }

    @Test func keptWindowDropsToZeroAfterReset() {
        let now = Date()
        let old = UsageModel.ToolUsage(windows: [W(label: "5h", percent: 100, resetsAt: now.addingTimeInterval(-60))], updated: now)
        let kept = UsageModel.merge(old, .failure(.init(message: "offline")), now: now)
        #expect(kept.windows.first?.percent == 0)
    }
}
