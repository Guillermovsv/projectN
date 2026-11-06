import Foundation
import Combine

struct DictationRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var words: Int
    var characters: Int
    var duration: TimeInterval      // seconds spent speaking
    var enhanced: Bool
    var app: String
    var text: String
    var rawText: String?            // original transcript when enhanced
    var profileID: UUID?            // nil = recorded before profiles existed
    var corrected: Bool?            // user edited this dictation (and NVoice learned from it)
    var localeID: String?           // language picked for this dictation
}

final class MetricsStore: ObservableObject {
    static let shared = MetricsStore()
    static let typingWPM = 40.0     // average typing speed, used for "time saved"

    /// Every record from every profile.
    @Published private(set) var allRecords: [DictationRecord] = []
    private var bag = Set<AnyCancellable>()

    /// Records of the active profile — all stats below are per person.
    var records: [DictationRecord] {
        let ps = ProfileStore.shared
        let active = ps.activeID, legacyOwner = ps.defaultProfileID
        return allRecords.filter { ($0.profileID ?? legacyOwner) == active }
    }

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: url) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            allRecords = (try? dec.decode([DictationRecord].self, from: data)) ?? []
        }
        // Switching person refreshes every view that shows stats.
        ProfileStore.shared.$activeID.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
    }

    func add(_ r: DictationRecord) {
        allRecords.insert(r, at: 0)
        save()
    }

    func update(_ id: UUID, _ change: (inout DictationRecord) -> Void) {
        guard let i = allRecords.firstIndex(where: { $0.id == id }) else { return }
        change(&allRecords[i])
        save()
    }

    /// Clears the active profile's history only.
    func clear() {
        let mine = Set(records.map(\.id))
        allRecords.removeAll { mine.contains($0.id) }
        save()
    }

    func removeRecords(of profileID: UUID) {
        allRecords.removeAll { $0.profileID == profileID }
        save()
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(allRecords) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Aggregates

    var totalWords: Int { records.reduce(0) { $0 + $1.words } }
    var totalDuration: TimeInterval { records.reduce(0) { $0 + $1.duration } }
    var sessions: Int { records.count }
    var enhancedCount: Int { records.filter(\.enhanced).count }
    var averageWPM: Double { totalDuration > 0 ? Double(totalWords) / (totalDuration / 60) : 0 }
    /// Minutes saved vs typing at 40 WPM.
    var timeSaved: TimeInterval { max(0, Double(totalWords) / Self.typingWPM * 60 - totalDuration) }

    var wordsToday: Int {
        let cal = Calendar.current
        return records.filter { cal.isDateInToday($0.date) }.reduce(0) { $0 + $1.words }
    }

    /// Consecutive days (ending today or yesterday) with at least one dictation.
    var streak: Int {
        let cal = Calendar.current
        let days = Set(records.map { cal.startOfDay(for: $0.date) })
        var day = cal.startOfDay(for: Date())
        if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var n = 0
        while days.contains(day) { n += 1; day = cal.date(byAdding: .day, value: -1, to: day)! }
        return n
    }

    struct DayStat: Identifiable { let day: Date; let words: Int; var id: Date { day } }

    func lastDays(_ count: Int) -> [DayStat] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var bucket: [Date: Int] = [:]
        for r in records { bucket[cal.startOfDay(for: r.date), default: 0] += r.words }
        return (0..<count).reversed().map { offset in
            let d = cal.date(byAdding: .day, value: -offset, to: today)!
            return DayStat(day: d, words: bucket[d] ?? 0)
        }
    }

    func topApps(_ n: Int) -> [(app: String, words: Int)] {
        var bucket: [String: Int] = [:]
        for r in records { bucket[r.app, default: 0] += r.words }
        return bucket.sorted { $0.value > $1.value }.prefix(n).map { ($0.key, $0.value) }
    }

    static func wordCount(_ s: String) -> Int {
        var n = 0
        s.enumerateSubstrings(in: s.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in n += 1 }
        return n
    }
}
