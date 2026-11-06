import Foundation
import Combine

/// "When the transcriber hears X, write Y."
struct CorrectionRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var heard: String
    var replacement: String
    var learned: Bool = false        // true = learned automatically from an edit
    var uses: Int = 0
    var createdAt = Date()
}

/// Everything that is personal to one speaker.
struct Profile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var localeID: String
    /// Optional second language; both are transcribed and the more confident one wins (e.g. en-US + es-MX).
    var secondLocaleID: String? = nil
    var dictionary: [String] = []
    var rules: [CorrectionRule] = []
}

final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published private(set) var profiles: [Profile] = []
    @Published var activeID: UUID { didSet { NVoiceDefaults.store.set(activeID.uuidString, forKey: "activeProfile") } }

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profiles.json")
    }()

    private init() {
        var loaded: [Profile] = []
        if let data = try? Data(contentsOf: url) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            loaded = (try? dec.decode([Profile].self, from: data)) ?? []
        }
        if loaded.isEmpty {
            // First run (or upgrade from the single-user version): carry over the old language setting.
            let locale = NVoiceDefaults.store.string(forKey: "localeID") ?? Locale.current.identifier
            let name = NSFullUserName().split(separator: " ").first.map(String.init) ?? "Me"
            loaded = [Profile(name: name.isEmpty ? "Me" : name, localeID: locale)]
        }
        profiles = loaded
        let saved = NVoiceDefaults.store.string(forKey: "activeProfile").flatMap(UUID.init(uuidString:))
        activeID = loaded.contains(where: { $0.id == saved }) ? saved! : loaded[0].id
        save()
    }

    var active: Profile { profiles.first(where: { $0.id == activeID }) ?? profiles[0] }

    /// Languages to transcribe for the active person (1 or 2).
    var activeLocaleIDs: [String] {
        let p = active
        guard let second = p.secondLocaleID, second != p.localeID else { return [p.localeID] }
        return [p.localeID, second]
    }
    /// The first profile also owns history recorded before profiles existed.
    var defaultProfileID: UUID { profiles[0].id }

    // MARK: Mutations

    func update(_ id: UUID? = nil, _ change: (inout Profile) -> Void) {
        let target = id ?? activeID
        guard let i = profiles.firstIndex(where: { $0.id == target }) else { return }
        change(&profiles[i])
        save()
    }

    @discardableResult
    func addProfile(name: String) -> Profile {
        let p = Profile(name: name, localeID: active.localeID)
        profiles.append(p)
        save()
        return p
    }

    func deleteProfile(_ id: UUID) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
        if activeID == id { activeID = profiles[0].id }
        save()
    }

    func addTerm(_ term: String, to id: UUID? = nil) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        update(id) { p in
            if !p.dictionary.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { p.dictionary.append(t) }
        }
    }

    func addRule(heard: String, replacement: String, learned: Bool, to id: UUID? = nil) {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !r.isEmpty, h != r else { return }
        update(id) { p in
            if let i = p.rules.firstIndex(where: { $0.heard.caseInsensitiveCompare(h) == .orderedSame }) {
                p.rules[i].replacement = r
            } else {
                p.rules.append(CorrectionRule(heard: h, replacement: r, learned: learned))
            }
        }
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        if let data = try? enc.encode(profiles) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Applying personalization

    /// Words/phrases handed to the speech engine as hints.
    var contextualStrings: [String] {
        let p = active
        return Array(Set(p.dictionary + p.rules.map(\.replacement))).sorted()
    }

    /// Applies correction rules, then fixes the capitalization of dictionary terms.
    func personalize(_ text: String) -> String {
        var out = text
        var used: [UUID] = []
        // Longer phrases first so "for v marketing" wins over "marketing".
        for rule in active.rules.sorted(by: { $0.heard.count > $1.heard.count }) {
            let replaced = Self.replaceWholeWords(rule.heard, with: rule.replacement, in: out)
            if replaced != out { used.append(rule.id); out = replaced }
        }
        for term in active.dictionary {
            out = Self.replaceWholeWords(term, with: term, in: out)
        }
        if !used.isEmpty {
            update { p in for i in p.rules.indices where used.contains(p.rules[i].id) { p.rules[i].uses += 1 } }
        }
        return out
    }

    static func replaceWholeWords(_ phrase: String, with replacement: String, in text: String) -> String {
        // Allow any whitespace between the words of the phrase; match case-insensitively.
        let words = phrase.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return text }
        let pattern = "(?<![\\p{L}\\p{N}])" + words.joined(separator: "\\s+") + "(?![\\p{L}\\p{N}]|[./@][\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    // MARK: Learning from an edit

    struct Learned { var rules: [(heard: String, replacement: String)] = []; var terms: [String] = [] }

    /// Compares what NVoice wrote with what the user corrected it to, word by word,
    /// and turns each small substitution into a rule. New proper nouns go to the dictionary.
    @discardableResult
    func learn(original: String, corrected: String, profileID: UUID? = nil) -> Learned {
        var result = Learned()
        let a = Self.tokens(original), b = Self.tokens(corrected)
        guard !a.isEmpty, !b.isEmpty else { return result }

        // LCS over normalized words.
        let na = a.map(Self.norm), nb = b.map(Self.norm)
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = na[i] == nb[j] && a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var i = 0, j = 0
        var delA: [String] = [], insB: [String] = []
        func flush() {
            defer { delA = []; insB = [] }
            guard !delA.isEmpty, !insB.isEmpty, delA.count <= 4, insB.count <= 4 else { return }
            let heard = delA.joined(separator: " "), repl = insB.joined(separator: " ")
            // A one-word, all-lowercase swap ("their" → "there") is usually grammar, not vocabulary —
            // learning it would rewrite that word everywhere.
            if delA.count == 1, insB.count == 1, repl == repl.lowercased(), repl.allSatisfy({ $0.isLetter || "'’-".contains($0) }) { return }
            guard Self.norm(heard) != Self.norm(repl) || heard != repl else { return }
            result.rules.append((heard, repl))
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, na[i] == nb[j], a[i] == b[j] {
                flush(); i += 1; j += 1
            } else if j < b.count, i == a.count || dp[i][j + 1] >= dp[i + 1][j] {
                insB.append(b[j]); j += 1
            } else {
                delA.append(a[i]); i += 1
            }
        }
        flush()

        for r in result.rules {
            addRule(heard: r.heard, replacement: r.replacement, learned: true, to: profileID)
            // Names, brands and acronyms are worth hinting to the recognizer too.
            if r.replacement.rangeOfCharacter(from: .uppercaseLetters) != nil || r.replacement.rangeOfCharacter(from: .decimalDigits) != nil {
                addTerm(r.replacement, to: profileID)
                result.terms.append(r.replacement)
            }
        }
        return result
    }

    /// Words with surrounding punctuation stripped (punctuation fixes aren't vocabulary).
    private static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "#@+&"))) }
            .filter { !$0.isEmpty }
    }

    private static func norm(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
