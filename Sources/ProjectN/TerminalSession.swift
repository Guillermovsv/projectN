import AppKit
import SwiftTerm
import os

/// Only SwiftTerm's nonisolated, lock-protected copying APIs are exposed across
/// queues. AppKit view mutation remains on MainActor.
private struct TerminalScreenReader: @unchecked Sendable {
    let view: LocalProcessTerminalView

    func tail(_ count: Int) -> [String] {
        let rows = view.terminalDimensions.rows
        return rows > 0 ? view.visibleRowsText(max(0, rows - count)..<rows) : []
    }
}

/// A live terminal (pty + view). Kept alive by the Store while you move in and out of workspaces.
@MainActor
final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    enum Status: Equatable {
        case running
        case exited(Int32?)
    }

    let id: UUID
    let view: LocalProcessTerminalView
    @Published private(set) var status: Status = .running
    @Published private(set) var currentDirectory: String?

    /// Set from SwiftTerm's I/O thread whenever new output arrives; lets screen scans skip idle panes.
    private let outputDirty = OSAllocatedUnfairLock(initialState: true)
    /// Last time the process wrote anything (I/O thread); idle-sleep reads it.
    private let lastOutputLock = OSAllocatedUnfairLock(initialState: Date())
    var lastOutputAt: Date { lastOutputLock.withLock { $0 } }
    private var cachedScreen: [String]?
    /// Latest output time the cached screen is known to include (taken when its read was dispatched).
    private var cachedScreenOutputAt = Date.distantPast
    private var screenReadInFlight = false
    private let screenQueue = DispatchQueue(label: "dev.projectn.screen", qos: .utility)
    private var terminated = false
    /// Only the bottom of the screen matters to the prompt/working heuristics.
    private static let scanRows = 30

    /// SwiftTerm's copied-text API is thread-safe, but can wait behind a large output
    /// batch. Never take that lock on the UI thread. Allow only one read per pane.
    private func screenTail(requireCurrent: Bool = false) -> [String]? {
        if !screenReadInFlight {
            let dirty = outputDirty.withLock { d -> Bool in let v = d; d = false; return v }
            if dirty {
                screenReadInFlight = true
                let outputAt = lastOutputAt
                let reader = TerminalScreenReader(view: view)
                let scanRows = Self.scanRows
                screenQueue.async { [weak self] in
                    let screen = reader.tail(scanRows)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.cachedScreen = screen
                        self.cachedScreenOutputAt = outputAt
                        self.screenReadInFlight = false
                        self.considerAutoAnswer(screen)
                    }
                }
            }
        }
        // Auto mode must never act on a previous frame while a newer one is pending.
        if requireCurrent && screenReadInFlight { return nil }
        return cachedScreen
    }
    let commandLine: String
    var onExit: ((Int32?) -> Void)?

    // MARK: Activity (for the Activity dashboard / yellow highlights)
    enum Activity: Equatable {
        case working
        case idle
        case needsInput(String)
        case exited
    }
    @Published private(set) var activity: Activity = .idle

    var needsInput: Bool { if case .needsInput = activity { return true }; return false }

    /// Re-reads the screen; publishes only when the state changes. Returns true on change.
    @discardableResult
    func refreshActivity() -> Bool {
        let new: Activity
        if !isRunning {
            new = .exited
        } else {
            guard let screen = screenTail() else { return false }
            if let q = AutoResponder.pendingPrompt(screen: screen) {
                new = .needsInput(q)
            } else if AutoResponder.isWorking(screen: screen) {
                new = .working
            } else {
                new = .idle
            }
        }
        guard new != activity else { return false }
        activity = new
        return true
    }

    // MARK: Auto mode → Complete
    @Published private(set) var autoComplete = false
    @Published private(set) var autoAnswerCount = 0
    /// Last auto answer, shown briefly in the session header.
    @Published private(set) var lastAutoAnswer: (label: String, at: Date)?
    private var autoTimer: Timer?
    private var pendingFingerprint: String?
    private var pendingSince = Date.distantPast
    private var answeredFingerprint: String?
    /// When the last key of the previous answer went out.
    private var answeredAt = Date.distantPast

    /// Whether the prompt on screen is the one already answered. Consecutive prompts often look identical (two
    /// edits to the same file, the same command twice, Codex's repeated "Allow" for one tool), and the frame
    /// between them is usually too short for a scan to see. So a matching prompt counts as new once the screen
    /// shows output the agent drew after receiving the answer (it always redraws when it takes one).
    private func isAlreadyAnswered(_ fingerprint: String) -> Bool {
        guard fingerprint == answeredFingerprint else { return false }
        let redrawn = cachedScreenOutputAt > answeredAt.addingTimeInterval(0.2)
            && Date().timeIntervalSince(answeredAt) >= 1.0
        if redrawn { answeredFingerprint = nil }
        return !redrawn
    }

    private func recordAnswer(_ d: AutoResponder.Decision) {
        answeredFingerprint = d.fingerprint
        answeredAt = Date().addingTimeInterval(0.06 * Double(max(0, d.keys.count - 1)))
        lastAutoAnswer = (d.label, Date())
        sendKeys(d.keys)
    }

    let startedAt = Date()
    static var background: NSColor { AppTheme.current.termBackground }

    init(id: UUID, plan: Launcher.Plan, fontSize: Double, restoredText: String? = nil, waitFor: [pid_t] = []) {
        self.id = id
        self.commandLine = plan.commandLine
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500),
                                        font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                                        options: TerminalOptions())
        super.init()
        view.autoresizingMask = [.width, .height]
        applyTheme(AppTheme.current)
        view.optionAsMetaKey = true
        view.processDelegate = self
        view.setProcessOutputHandler { [outputDirty, lastOutputLock] in
            outputDirty.withLock { $0 = true }
            lastOutputLock.withLock { $0 = Date() }
        }
        if let restoredText, !restoredText.isEmpty {
            // Previous output, dimmed, followed by a separator; the new shell starts below it.
            let body = restoredText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
            view.feed(text: "\u{1b}[2m" + body + "\u{1b}[0m\r\n\u{1b}[2m──── restored · \(Self.stamp()) ────\u{1b}[0m\r\n")
        }
        let launch = { [weak self] in
            guard let self, !self.terminated else { return }
            let view = self.view
            view.startProcess(executable: plan.executable,
                              args: plan.args,
                              environment: plan.environment,
                              execName: nil,
                              currentDirectory: plan.directory)
        }
        // On a restart, wait for the previous agent to exit first: it holds its conversation's
        // writer lock, and a resume started while it's alive asks to "close the other window".
        Self.whenGone(waitFor, deadline: Date().addingTimeInterval(4), then: launch)
    }

    /// Runs `then` once every process group in `groups` has exited (or the deadline passes).
    private static func whenGone(_ groups: [pid_t], deadline: Date, then: @escaping () -> Void) {
        let alive = groups.filter { kill(-$0, 0) == 0 }
        if alive.isEmpty || Date() >= deadline { then(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { whenGone(alive, deadline: deadline, then: then) }
    }

    var isRunning: Bool { status == .running }

    /// A command (not the idle shell) holds the terminal's foreground: a build, a server, a script…
    var isRunningCommand: Bool {
        guard isRunning, !terminated, let process = view.process, process.shellPid > 0 else { return false }
        let fg = tcgetpgrp(process.childfd)
        return fg > 0 && fg != process.shellPid
    }

    /// AI CLIs we recognize when they're started by hand inside a plain terminal pane.
    static let aiCLINames: Set<String> = ["claude", "codex", "cursor-agent", "gemini"]

    /// The AI CLI (claude, codex, cursor-agent, gemini) holding this terminal's foreground, if any.
    /// Looks at argv, not just the process name, because npm-installed CLIs run as `node …/gemini`.
    var foregroundAICLI: String? {
        guard isRunning, !terminated, let process = view.process, process.shellPid > 0 else { return nil }
        let fg = tcgetpgrp(process.childfd)
        guard fg > 0, fg != process.shellPid else { return nil }
        for arg in Self.arguments(of: fg).prefix(3) {
            let name = (arg as NSString).lastPathComponent
            if Self.aiCLINames.contains(name) { return name }
        }
        return nil
    }

    /// argv of a process (via KERN_PROCARGS2); empty if it can't be read.
    private static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let argc = buf.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }      // executable path
        while i < size, buf[i] == 0 { i += 1 }      // padding
        var args: [String] = []
        while i < size, args.count < argc {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// Plain text of the normal screen buffer (scrollback + screen), trimmed to the last `maxLines`.
    func scrollbackText(maxLines: Int = 3000, kind: Terminal.BufferKind = .normal) -> String {
        let data = view.getBufferAsData(kind: kind, encoding: .utf8)
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        var lines = text.components(separatedBy: "\n").map { line -> String in
            var l = line
            while let c = l.last, c == " " || c == "\0" { l.removeLast() }
            return l
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f.string(from: Date())
    }

    func setAutoComplete(_ on: Bool) {
        guard on != autoComplete else { return }
        autoComplete = on
        autoTimer?.invalidate()
        autoTimer = nil
        pendingFingerprint = nil
        answeredFingerprint = nil
        if on {
            let t = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.autoScan() }
            }
            RunLoop.main.add(t, forMode: .common)
            autoTimer = t
        }
    }

    /// Reads the bottom of the screen; answers a prompt once it has been stable for two scans.
    private func autoScan() {
        guard autoComplete, isRunning else { return }
        guard let screen = screenTail(requireCurrent: true) else { return }
        considerAutoAnswer(screen)
    }

    /// Also runs when a background read completes. Continuous title/spinner output
    /// must not prevent a stable prompt from receiving its second observation.
    private func considerAutoAnswer(_ screen: [String]) {
        guard autoComplete, isRunning, !terminated, !screen.isEmpty else { return }
        guard let decision = AutoResponder.decide(screen: screen) else {
            pendingFingerprint = nil
            answeredFingerprint = nil
            return
        }
        let now = Date()
        // Already answered this prompt: never answer it twice (it may just be left over in the scrollback).
        if isAlreadyAnswered(decision.fingerprint) { return }
        // Require the same prompt on two consecutive scans so we never act on a half-drawn frame.
        if decision.fingerprint != pendingFingerprint {
            pendingFingerprint = decision.fingerprint
            pendingSince = now
            return
        }
        guard now.timeIntervalSince(pendingSince) >= 0.3 else { return }

        pendingFingerprint = nil
        autoAnswerCount += 1
        recordAnswer(decision)
    }

    /// Agent panes: answers the CLI's own permission prompt with "Yes", but only when that prompt shows one of
    /// `approved` (tool calls ProjectN's policy, an orchestrator or the user already approved). Claude Code still
    /// asks for some commands (e.g. with `$(…)`) after a hook allowed them. Returns the answer given.
    func confirmApprovedPrompt(_ approved: [String]) -> String? {
        guard isRunning, !terminated, let screen = screenTail(requireCurrent: true),
              AutoResponder.pendingPrompt(screen: screen) != nil,
              let d = AutoResponder.decide(screen: screen), !isAlreadyAnswered(d.fingerprint),
              AutoResponder.approves(d.label) else { return nil }
        let squash = { (s: String) in String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !"│┃║╭╮╰╯─━".unicodeScalars.contains($0) }.map(Character.init)) }
        let text = squash(screen.joined())
        guard approved.contains(where: { a in let n = squash(a); return n.count >= 2 && text.contains(String(n.prefix(50))) }) else { return nil }
        autoAnswerCount += 1
        recordAnswer(d)
        return d.label
    }

    /// Answers the prompt on screen for the user (approved / denied from Slack or ProjectN): "Yes" when the
    /// prompt's default choice is a yes, Escape to refuse. Returns false if there's no prompt to answer.
    @discardableResult
    func answerPendingPrompt(approve: Bool) -> Bool {
        guard isRunning, !terminated, let screen = screenTail(), AutoResponder.pendingPrompt(screen: screen) != nil else { return false }
        if approve {
            guard let d = AutoResponder.decide(screen: screen), AutoResponder.approves(d.label) else { return false }
            recordAnswer(d)
        } else {
            lastAutoAnswer = ("No", Date())
            sendKeys(["\u{1b}"])
        }
        return true
    }

    /// Sends key presses one at a time with a short gap; TUIs (Ink, ratatui) handle that more reliably than one burst.
    private func sendKeys(_ keys: [String]) {
        for (i, k) in keys.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(i)) { [weak self] in
                guard let self, self.isRunning else { return }
                self.view.send(txt: k)
            }
        }
    }

    /// Ends the whole job, not just the wrapper shell. The wrapper is `zsh -i`, which ignores SIGTERM,
    /// and it runs the agent in its own process group — so signalling only the shell left Claude/Codex
    /// running invisibly (still holding its session). Hang up both groups like closing a terminal
    /// window does, SIGKILL whatever is left after 3s, and return the groups so a restart can wait.
    @discardableResult
    func terminate() -> [pid_t] {
        terminated = true
        setAutoComplete(false)
        guard isRunning, let process = view.process else { return [] }
        var groups: [pid_t] = []
        let shell = process.shellPid
        if shell > 0 { groups.append(shell) }                 // the shell leads its own session/group
        let fg = tcgetpgrp(process.childfd)                    // the agent's job group
        if fg > 0, !groups.contains(fg) { groups.append(fg) }
        for g in groups { kill(-g, SIGHUP); kill(-g, SIGCONT) }
        view.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for g in groups where kill(-g, 0) == 0 { kill(-g, SIGKILL) }
        }
        return groups
    }

    func send(_ text: String) {
        view.send(txt: text)
    }

    /// Types slash commands (e.g. "/model claude-opus-5-5") into the running agent, one after another.
    func runSlashCommands(_ commands: [String]) {
        for (i, cmd) in commands.enumerated() {
            // Give Claude time to finish the previous command (e.g. /model saves settings) before typing the next.
            let t = 2.2 * Double(i)
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self, self.isRunning else { return }
                self.view.send(txt: cmd)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.isRunning else { return }
                    self.view.send(txt: "\r")
                }
            }
        }
    }

    /// Types a message into the agent's input box (bracketed paste, so newlines don't submit early) and presses Return.
    func submit(_ text: String) {
        view.pasteText(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isRunning else { return }
            self.view.send(txt: "\r")
        }
    }

    /// Panes running Claude/Codex: Shift+Return inserts a new line instead of submitting.
    var shiftReturnInsertsNewline = false

    func focus() {
        DispatchQueue.main.async { [view] in
            view.window?.makeFirstResponder(view)
        }
    }

    func applyTheme(_ t: AppTheme) {
        view.installColors(t.terminalPalette)
        view.nativeBackgroundColor = t.termBackground
        view.nativeForegroundColor = t.termForeground
        view.caretColor = t.cursor
        view.needsDisplay = true
    }

    func setFontSize(_ size: Double) {
        view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Unused: publishing it redrew the pane on every title update (Claude updates it while working).
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        Task { @MainActor in self.currentDirectory = directory }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.status = .exited(exitCode)
            self.autoTimer?.invalidate()
            self.autoTimer = nil
            self.onExit?(exitCode)
        }
    }
}
