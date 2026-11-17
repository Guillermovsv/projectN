import AppKit
import Foundation

/// How names sound, so a name that dictation spelled wrong still matches: "Bible Boys" → Vibevoice,
/// "Catherine" → Katherine, "aseo cap" → SEO Core App. Tuned for Spanish and English said by the same person.
enum SoundsLike {
    /// A spelling-independent key for normalized text (lowercase, no accents); spaces are ignored. b/v, c/k/q,
    /// s/z/soft c, i/y, ch/sh, silent h and doubled letters come out the same.
    static func key(_ normalized: String) -> String {
        var t = normalized.replacingOccurrences(of: " ", with: "")
        // Uppercase letters are placeholders: the input is lowercase, so they can't collide with it.
        let rules: [(String, String)] = [
            ("ph", "f"), ("sh", "C"), ("ch", "C"), ("th", "t"), ("ll", "y"),
            ("qu(?=[ei])", "k"), ("gu(?=[ei])", "G"), ("ck", "k"),
            ("c(?=[eiy])", "s"), ("c", "k"), ("q", "k"), ("g(?=[eiy])", "j"),
            ("x", "ks"), ("z", "s"), ("v", "b"), ("w", "u"), ("y", "i"), ("h", ""),
        ]
        for (pattern, with) in rules { t = t.replacingOccurrences(of: pattern, with: with, options: .regularExpression) }
        return t.replacingOccurrences(of: #"(.)\1+"#, with: "$1", options: .regularExpression)
    }

    /// 0…1: how alike two normalized phrases sound as a whole.
    static func similarity(_ a: String, _ b: String) -> Double {
        let ka = key(a), kb = key(b)
        guard !ka.isEmpty, !kb.isEmpty else { return 0 }
        if ka == kb { return 1 }
        // Short words sound alike too easily ("ap", "cap"): only identical ones count.
        guard min(ka.count, kb.count) >= 4 else { return 0 }
        let sound = 1 - Double(AssistantCommands.editDistance(ka, kb)) / Double(max(ka.count, kb.count))
        // Vowels are what speech gets wrong most ("bible boys" / "vibevoice"): the consonants alone, a bit discounted.
        let sa = ka.filter { !"aeiou".contains($0) }, sb = kb.filter { !"aeiou".contains($0) }
        guard sa.count >= 4, sb.count >= 4 else { return sound }
        let skeleton = 1 - Double(AssistantCommands.editDistance(sa, sb)) / Double(max(sa.count, sb.count))
        return max(sound, 0.9 * skeleton)
    }

    /// 0…1: how well `said` sounds like a part of `name` ("boys" in Vibevoice). For suggestions, never on its own.
    static func partial(_ said: String, of name: String) -> Double {
        let ks = Array(key(said)), kn = Array(key(name))
        guard ks.count >= 4, kn.count >= ks.count + 2 else { return 0 }
        var best = 0.0
        for len in (ks.count - 1)...(ks.count + 1) where len <= kn.count {
            for i in 0...(kn.count - len) {
                let d = AssistantCommands.editDistance(String(ks), String(kn[i..<(i + len)]))
                best = max(best, 1 - Double(d) / Double(max(ks.count, len)))
            }
        }
        return best
    }
}

/// Ways a name is said that its spelling doesn't show: "projectN" → "project N", "Vibevoice" → "Vibe Voice",
/// "HR-System" → "HR System". Given to speech recognition as hints and to the AI so it maps what it hears.
@MainActor
enum SpokenNames {
    /// `isWord`: a dictionary check (the system spell checker when nil).
    static func forms(_ name: String, isWord: ((String) -> Bool)? = nil) -> [String] {
        let system = isWord == nil
        if system, let cached = cache[name] { return cached }
        let isWord = isWord ?? { dictionaryWord($0) }
        var t = name.replacingOccurrences(of: #"[-_./]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<=\p{Ll})(?=\p{Lu})"#, with: " ", options: .regularExpression)      // projectN
        t = t.replacingOccurrences(of: #"(?<=\p{Lu})(?=\p{Lu}\p{Ll})"#, with: " ", options: .regularExpression) // NVoice
        t = t.replacingOccurrences(of: #"(?<=\p{N})(?=\p{L})|(?<=\p{L})(?=\p{N})"#, with: " ", options: .regularExpression)
        let words = t.split(separator: " ").map { w -> String in
            let s = String(w)
            return split(s, isWord: isWord).map { "\($0.0) \($0.1)" } ?? s
        }
        let spoken = words.joined(separator: " ")
        let out = spoken.folded == name.folded ? [] : [spoken]
        if system { cache[name] = out }
        return out
    }

    /// A long word made of two dictionary words, capitalized as given: "Vibevoice" → ("Vibe", "voice").
    private static func split(_ word: String, isWord: (String) -> Bool) -> (String, String)? {
        let w = Array(word)
        guard w.count >= 7, word.allSatisfy(\.isLetter), !isWord(word.lowercased()) else { return nil }
        // From the middle out: "vibe|voice" before "vib|evoice".
        let mid = w.count / 2
        let cuts = (3...(w.count - 3)).sorted { abs($0 - mid) < abs($1 - mid) }
        for i in cuts {
            let a = String(w[..<i]), b = String(w[i...])
            if isWord(a.lowercased()), isWord(b.lowercased()) { return (a, b) }
        }
        return nil
    }

    private static var cache: [String: [String]] = [:]

    /// English or Spanish word, per the system spell checker (off if it accepts anything).
    static func dictionaryWord(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        func known(_ w: String) -> Bool {
            ["en", "es"].contains { lang in
                checker.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false,
                                      inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
            }
        }
        if checkerTrusted == nil { checkerTrusted = !known("qzxvbnkw") }
        return checkerTrusted == true && known(word)
    }

    private static var checkerTrusted: Bool?
}

/// Names you confirmed after the Assistant asked “¿Quisiste decir…?”: next time what you said goes straight there.
/// Only the Assistant uses them (never dictation). Kept in `assistant-names.json` in the ProjectN home.
@MainActor
final class AssistantAliases {
    struct Alias: Codable, Equatable {
        /// What was heard, normalized ("bible boys").
        var heard: String
        /// The project, workspace or space it meant.
        var id: UUID
        var name: String
    }

    static let shared = AssistantAliases()
    static let limit = 200

    private(set) var all: [Alias]
    private let url: URL

    init(url: URL = AppHome.root.appendingPathComponent("assistant-names.json")) {
        self.url = url
        all = AppHome.load([Alias].self, from: url) ?? []
    }

    func learn(heard: String, id: UUID, name: String) {
        let h = AssistantCommands.normalize(heard)
        // What the name already sounds like needs no alias.
        guard !h.isEmpty, AssistantCommands.normalize(name) != h else { return }
        all.removeAll { $0.heard == h }
        all.append(Alias(heard: h, id: id, name: name))
        if all.count > Self.limit { all.removeFirst(all.count - Self.limit) }
        AppHome.save(all, to: url)
    }
}
