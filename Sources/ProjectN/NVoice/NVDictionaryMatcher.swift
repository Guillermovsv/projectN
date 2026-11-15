import AppKit

/// Makes dictionary words come out right even when the speech engine ignores the hint.
///
/// Apple's recognizer treats the personal dictionary as a soft bias, so a term often arrives
/// split, respelled or spelled out ("4B marketing", "for v marketing", "code x", "S E O").
/// This pass finds spans of the transcript that *sound like* a dictionary term and writes the term.
///
/// It stays conservative so it never rewrites ordinary speech:
/// - any span (1…n words) whose sound-key equals the term's is replaced ("4B marketing" → "4vmarketing");
/// - a single near-miss word is replaced only when it is not itself a real word ("Saltiyo" → "Saltillo",
///   but "invoice" never becomes "Nvoice" — add a correction for that);
/// - short terms (≤ 4 letters, like "SEO") only match their exact letters, so "CEO" stays "CEO".
enum DictionaryMatcher {
    /// Is this a correctly spelled everyday word? Injectable for tests.
    static var isRealWord: (String) -> Bool = { word in
        let checker = NSSpellChecker.shared
        for lang in ["en", "es"] {
            let r = checker.checkSpelling(of: word, startingAt: 0, language: lang, wrap: false,
                                          inSpellDocumentWithTag: 0, wordCount: nil)
            if r.location == NSNotFound { return true }
        }
        return false
    }

    private struct Token { let range: NSRange; let text: String }
    private struct Match { let range: NSRange; let term: String; let exact: Bool }

    static func apply(terms: [String], to text: String) -> String {
        let terms = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !rawKey($0).isEmpty }
        guard !terms.isEmpty, !text.isEmpty else { return text }
        let ns = text as NSString
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return text }
        var realWordCache: [String: Bool] = [:]
        func real(_ w: String) -> Bool {
            if let v = realWordCache[w] { return v }
            let v = isRealWord(w); realWordCache[w] = v; return v
        }

        var matches: [Match] = []
        for term in terms {
            let termWords = term.split(whereSeparator: \.isWhitespace).count
            let tRaw = rawKey(term), tSound = soundKey(term)
            let short = tRaw.count <= 4
            for i in tokens.indices {
                var spanTexts: [String] = []
                for j in i..<min(tokens.count, i + termWords + 4) {
                    if j > i, !joinable(ns.substring(with: gap(tokens[j - 1], tokens[j]))) { break }
                    spanTexts.append(tokens[j].text)
                    let range = NSRange(location: tokens[i].range.location,
                                        length: NSMaxRange(tokens[j].range) - tokens[i].range.location)
                    if partOfAddress(ns, range) { continue }
                    let sRaw = rawKey(spanTexts.joined(separator: " "))
                    let exact: Bool
                    if sRaw == tRaw {
                        exact = true
                    } else if short {
                        continue
                    } else if soundKey(spanTexts.joined(separator: " ")) == tSound {
                        exact = true
                    } else if spanTexts.count == 1, termWords == 1, tRaw.count >= 6,
                              levenshtein(soundKey(spanTexts[0]), tSound) <= (tSound.count >= 10 ? 2 : 1),
                              !real(spanTexts[0]) {
                        exact = false
                    } else {
                        continue
                    }
                    matches.append(Match(range: range, term: term, exact: exact))
                }
            }
        }
        // Exact sound matches beat near-misses; longer spans beat shorter ones; no overlaps.
        matches.sort { a, b in a.exact != b.exact ? a.exact : a.range.length > b.range.length }
        var accepted: [Match] = []
        for m in matches where !accepted.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) {
            accepted.append(m)
        }
        var out = text as NSString
        for m in accepted.sorted(by: { $0.range.location > $1.range.location }) {
            out = out.replacingCharacters(in: m.range, with: m.term) as NSString
        }
        return out as String
    }

    // MARK: Keys

    /// Letters and digits only, lowercased, accents folded: "S.E.O" → "seo", "Node.js" → "nodejs".
    static func rawKey(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    private static let numberWords: [String: String] = [
        "zero": "0", "cero": "0", "one": "1", "uno": "1", "two": "2", "dos": "2",
        "three": "3", "tres": "3", "four": "4", "for": "4", "cuatro": "4", "five": "5", "cinco": "5",
        "six": "6", "seis": "6", "seven": "7", "siete": "7", "eight": "8", "ocho": "8", "nine": "9", "nueve": "9",
    ]

    /// A rough English/Spanish sound key: b/v, c/k/qu, c/s/z, ll/y/i, silent h, doubled letters,
    /// and spoken numbers ("for v marketing" ≈ "4vmarketing").
    static func soundKey(_ s: String) -> String {
        let words = s.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map { w -> String in
            let k = rawKey(String(w)); return numberWords[k] ?? k
        }
        var k = words.joined()
        let swaps: [(String, String)] = [
            ("ch", "9"), ("sh", "9"), ("ph", "f"), ("ll", "y"), ("qu", "k"), ("ck", "k"),
            ("ce", "se"), ("ci", "si"), ("cy", "si"), ("c", "k"), ("x", "ks"), ("z", "s"),
            ("v", "b"), ("y", "i"), ("h", ""),
        ]
        for (a, b) in swaps { k = k.replacingOccurrences(of: a, with: b) }
        var out = ""
        for ch in k where out.last != ch { out.append(ch) }
        return out
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = prev
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    // MARK: Tokens

    private static let wordRE = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:['’][\\p{L}]+)?")
    private static let joinRE = try! NSRegularExpression(pattern: "^(?:\\s+|\\s*-\\s*|\\.\\s+|\\.)$")

    private static func tokenize(_ text: String) -> [Token] {
        let ns = text as NSString
        return wordRE.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { Token(range: $0.range, text: ns.substring(with: $0.range)) }
    }

    private static func gap(_ a: Token, _ b: Token) -> NSRange {
        NSRange(location: NSMaxRange(a.range), length: b.range.location - NSMaxRange(a.range))
    }

    /// Words may be split by spaces, a hyphen, or a period ("4-V", "S.E.O", "Four B. Marketing").
    private static func joinable(_ gap: String) -> Bool {
        joinRE.firstMatch(in: gap, range: NSRange(location: 0, length: (gap as NSString).length)) != nil
    }

    /// Never touch part of a URL, email or file name ("seo.com", "me@codex").
    private static func partOfAddress(_ ns: NSString, _ r: NSRange) -> Bool {
        func isAlnum(_ i: Int) -> Bool {
            guard i >= 0, i < ns.length, let u = UnicodeScalar(ns.character(at: i)) else { return false }
            return CharacterSet.alphanumerics.contains(u)
        }
        func isJoiner(_ i: Int) -> Bool {
            guard i >= 0, i < ns.length else { return false }
            let c = ns.character(at: i)
            return c == 46 || c == 47 || c == 64          // . / @
        }
        let end = NSMaxRange(r)
        return (isJoiner(r.location - 1) && isAlnum(r.location - 2)) || (isJoiner(end) && isAlnum(end + 1))
    }
}
