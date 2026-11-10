import Foundation

/// Auto mode → "Complete": recognises yes/no and multiple-choice prompts drawn by Claude Code / Codex
/// at the bottom of the screen and decides which keys to send.
///
/// Rules (deliberately conservative — anything unrecognised is left for the user):
///   • Numbered menu with a selection cursor (❯ / ›): pick the option marked "Recommended";
///     otherwise the first option starting with "Yes". If neither exists, do nothing.
///   • Multi-select (checkbox) menus are skipped.
///   • Inline prompts ending in (y/n), [y/N], [Y/n], (yes/no): answer "y".
///   • Cursor Agent key-hint menus (`→ Run (once) (y)` … `Skip … (esc or n)`): press "y".
enum AutoResponder {
    struct Decision: Equatable {
        /// Key presses to send, one write each (TUIs parse one key per read more reliably).
        var keys: [String]
        /// Human-readable answer, e.g. "Yes" or "dayjs (Recommended)".
        var label: String
        /// Identifies the prompt independent of where the cursor currently is.
        var fingerprint: String
    }

    static let down = "\u{1b}[B"
    static let up = "\u{1b}[A"
    static let enter = "\r"

    private static let cursorGlyphs: Set<Character> = ["❯", "›", "▸", "▶", "➤"]
    private static let boxChars = CharacterSet(charactersIn: "│┃║|╭╮╰╯─━")

    private struct Option {
        let line: Int
        let number: Int
        let text: String
        let hasCursor: Bool
    }

    private static func window(_ screen: [String]) -> [String]? {
        // Work on the bottom part of the screen, ignoring trailing blank rows.
        var lines = screen.map { $0.trimmingCharacters(in: boxChars.union(.whitespaces)) }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        return Array(lines.suffix(30))
    }

    static func decide(screen: [String]) -> Decision? {
        guard let window = window(screen) else { return nil }
        // The last line is where input goes, so an inline y/n prompt there wins over any menu still drawn above it.
        if let d = inlineYesNoDecision(window) { return d }
        if let d = menuDecision(window) { return d }
        if let d = keyHintDecision(window) { return d }
        return nil
    }

    /// Whether the screen is waiting for the user to answer a prompt (whether or not Auto could answer it).
    /// Returns the question text (best effort) or nil.
    static func pendingPrompt(screen: [String]) -> String? {
        guard let window = window(screen) else { return nil }
        if inlineYesNoDecision(window) != nil { return window.last }
        // Numbered menus first, as in `decide` (Codex's "1. Allow (y) … 4. Cancel (esc)" also looks like key hints).
        guard let menu = findMenu(window) else {
            guard let hint = findKeyHintMenu(window) else { return nil }
            return window[max(0, hint.first - 4)..<hint.first].reversed()
                .first { !$0.isEmpty && $0.rangeOfCharacter(from: .letters) != nil } ?? "Choose an option"
        }
        let first = menu.block.first!.line
        // A real question ("…?") above the options wins: Codex prints the tool's parameters (e.g. "post_id: 798")
        // or the command between its question and the menu. Otherwise the closest non-empty line with letters.
        let above = window[max(0, first - 12)..<first].reversed()
        let question = above.first { $0.hasSuffix("?") && $0.rangeOfCharacter(from: .letters) != nil }
            ?? window[max(0, first - 4)..<first].reversed()
            .first { !$0.isEmpty && $0.rangeOfCharacter(from: .letters) != nil }
        return question ?? "Choose an option"
    }

    /// Plain-text heuristics for "the agent is busy" (Claude: "esc to interrupt", Codex: "Esc to interrupt").
    static func isWorking(screen: [String]) -> Bool {
        screen.suffix(12).contains { $0.range(of: "to interrupt", options: .caseInsensitive) != nil }
    }

    // MARK: Numbered menus

    private static func parseOption(_ raw: String, line: Int) -> Option? {
        var s = Substring(raw)
        var hasCursor = false
        if let f = s.first, cursorGlyphs.contains(f) || f == ">" {
            hasCursor = true
            s = s.dropFirst().drop { $0 == " " }
        }
        // number
        let digits = s.prefix { $0.isNumber }
        guard (1...2).contains(digits.count), let n = Int(digits) else { return nil }
        s = s.dropFirst(digits.count)
        guard let sep = s.first, sep == "." || sep == ")" else { return nil }
        s = s.dropFirst()
        guard s.first == " " else { return nil }
        var text = s.trimmingCharacters(in: .whitespaces)
        // Codex draws a description column on the option's own row ("Allow          Run the tool and continue"):
        // the label is what comes before the gap.
        if let gap = text.range(of: "\\s{3,}", options: .regularExpression) { text = String(text[..<gap.lowerBound]) }
        guard !text.isEmpty else { return nil }
        return Option(line: line, number: n, text: text, hasCursor: hasCursor)
    }

    private struct Menu {
        let block: [Option]
        let current: Option
    }

    /// The latest interactive numbered menu near the bottom of the screen (exactly one highlighted option).
    private static func findMenu(_ window: [String]) -> Menu? {
        let options = window.enumerated().compactMap { parseOption($0.element, line: $0.offset) }
        // The latest block that starts at "1." and counts up.
        guard let startIdx = options.lastIndex(where: { $0.number == 1 }) else { return nil }
        var block = [options[startIdx]]
        for o in options[(startIdx + 1)...] {
            if o.number == block.last!.number + 1 && o.line - block.last!.line <= 4 { block.append(o) } else { break }
        }
        guard block.count >= 2 else { return nil }
        let cursors = block.filter(\.hasCursor)
        guard cursors.count == 1, let current = cursors.first else { return nil }
        guard window.count - 1 - block.last!.line <= 8 else { return nil }
        return Menu(block: block, current: current)
    }

    private static func menuDecision(_ window: [String]) -> Decision? {
        guard let menu = findMenu(window) else { return nil }
        let block = menu.block
        let current = menu.current

        // Skip multi-select checkbox menus.
        let checkboxMarks = ["[ ]", "[x]", "[X]", "[✓]", "[✔]", "☐", "☑", "☒", "◯", "◉"]
        if block.contains(where: { o in checkboxMarks.contains { o.text.hasPrefix($0) } }) { return nil }

        let target: Option
        if let rec = block.first(where: { $0.text.range(of: "recommended", options: .caseInsensitive) != nil }) {
            target = rec
        } else if let yes = block.first(where: { isYes($0.text) }) {
            target = yes
        } else {
            return nil
        }

        let delta = target.number - current.number
        var keys = Array(repeating: delta > 0 ? down : up, count: abs(delta))
        keys.append(enter)

        // Fingerprint: up to 3 non-option lines above the block + all option texts.
        let firstLine = block.first!.line
        let context = window[max(0, firstLine - 3)..<firstLine].joined(separator: "\n")
        let fp = context + "\n" + block.map { "\($0.number). \($0.text)" }.joined(separator: "\n")

        return Decision(keys: keys, label: cleanLabel(target.text), fingerprint: fp)
    }

    private static func isYes(_ text: String) -> Bool {
        let t = text.lowercased()
        if t == "yes" || t.hasPrefix("yes ") || t.hasPrefix("yes,") || t.hasPrefix("yes.") || t.hasPrefix("yes!")
            || t.hasPrefix("yes (") || t.hasPrefix("yes -") || t.hasPrefix("yes —") { return true }
        // Codex asks about MCP tool calls with "Allow / Allow for this session / Always allow / Cancel": the plain
        // one-time "Allow" (or "Approve") is the yes. Choices that widen permissions beyond this call never are.
        let core = t.replacingOccurrences(of: "\\s*\\([^()]*\\)\\s*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let widening = ["session", "always", "remember", "future", "don't ask", "do not ask", "all "]
        guard !widening.contains(where: { core.contains($0) }) else { return false }
        return core == "allow" || core == "approve" || core == "allow once" || core == "approve once"
            || core.hasPrefix("allow this request") || core.hasPrefix("approve this request")
    }

    /// Whether an answer label from `decide` agrees to the request (used when the user approved it elsewhere).
    /// Inline prompts answer "y"; Cursor's key-hint menus answer "Run (once)".
    static func approves(_ label: String) -> Bool {
        let t = label.lowercased().trimmingCharacters(in: .whitespaces)
        return t == "y" || isYes(label) || t == "run" || t == "run (once)" || t == "run once"
    }

    private static func cleanLabel(_ s: String) -> String {
        s.count > 60 ? String(s.prefix(57)) + "…" : s
    }

    // MARK: Inline y/n

    private static let ynPatterns = ["(y/n)", "[y/n]", "(y/N)", "[y/N]", "(Y/n)", "[Y/n]", "(yes/no)", "[yes/no]", "(Y/N)", "[Y/N]"]

    private static func inlineYesNoDecision(_ window: [String]) -> Decision? {
        guard let last = window.last else { return nil }
        var t = last.trimmingCharacters(in: .whitespaces)
        // allow a trailing "?" or ":" after the pattern
        while let c = t.last, c == ":" || c == "?" || c == " " { t.removeLast() }
        guard ynPatterns.contains(where: { t.hasSuffix($0) }) else { return nil }
        return Decision(keys: ["y", enter], label: "y", fingerprint: "yn:" + last)
    }

    // MARK: Key-hint menus (Cursor Agent)

    /// Cursor Agent draws approvals as an unnumbered list whose options end in the key that picks them:
    ///
    ///     Run this command?
    ///     Not in allowlist: wc
    ///     → Run (once) (y)
    ///       Add Shell(wc) to allowlist? (tab)
    ///       Run Everything (shift+tab)
    ///       Skip & tell the agent what to do instead (esc or n)
    ///
    /// Auto presses "y" (approve this once — it never widens the allowlist or switches to Run Everything).
    private struct KeyHintMenu {
        let first: Int      // first option line
        let yes: Int        // the "(y)" option line
        let last: Int       // last option line
    }

    /// The keys in a trailing "(…)" hint, e.g. "Skip … (esc or n)" → ["esc", "n"].
    private static func hintKeys(_ line: String) -> [String]? {
        guard let r = line.range(of: "\\(([^()]+)\\)\\s*$", options: .regularExpression) else { return nil }
        let inner = line[r].trimmingCharacters(in: .whitespaces).dropFirst().dropLast()
        let keys = inner.lowercased().components(separatedBy: CharacterSet(charactersIn: ",/"))
            .flatMap { $0.components(separatedBy: " or ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !keys.isEmpty, keys.allSatisfy({ $0.count <= 12 && !$0.contains(" ") }) else { return nil }
        return keys
    }

    private static func stripCursor(_ line: String) -> String {
        var s = Substring(line)
        if let f = s.first, cursorGlyphs.contains(f) || f == ">" || f == "→" { s = s.dropFirst() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func findKeyHintMenu(_ window: [String]) -> KeyHintMenu? {
        // The latest option answered by "y", close to the bottom of the screen.
        guard let yes = window.lastIndex(where: { hintKeys($0) == ["y"] }),
              window.count - 1 - yes <= 8 else { return nil }
        // Contiguous run of key-hinted lines around it.
        var first = yes, last = yes
        while first > 0, hintKeys(window[first - 1]) != nil { first -= 1 }
        while last + 1 < window.count, hintKeys(window[last + 1]) != nil { last += 1 }
        // Only a real menu: it must also offer a way to decline ("n" / "esc").
        let hasNo = (first...last).contains { i in
            hintKeys(window[i]).map { $0.contains("n") || $0.contains("esc") } ?? false
        }
        guard hasNo, last > first else { return nil }
        return KeyHintMenu(first: first, yes: yes, last: last)
    }

    private static func keyHintDecision(_ window: [String]) -> Decision? {
        guard let menu = findKeyHintMenu(window) else { return nil }
        // Fingerprint ignores where the selection arrow is.
        let fp = window[max(0, menu.first - 3)...menu.last].map(stripCursor).joined(separator: "\n")
        let label = stripCursor(window[menu.yes])
            .replacingOccurrences(of: "\\s*\\(y\\)\\s*$", with: "", options: .regularExpression)
        return Decision(keys: ["y"], label: cleanLabel(label.isEmpty ? "Yes" : label), fingerprint: "keys:" + fp)
    }
}
