import AppKit
import SwiftUI
import Combine
import Carbon
import CoreAudio

// NVoice, built into ProjectN. This is NVoice's former AppDelegate, turned into a controller that
// ProjectN starts and stops from Settings › Voice. Everything else (transcriber, enhancer, people,
// metrics, overlay) is NVoice's own code, unchanged apart from these names:
//   AppSettings → NVoiceSettings,  UserDefaults.standard → NVoiceDefaults.store

/// NVoice's preferences live in the standalone app's own defaults domain, so settings are shared
/// with NVoice.app (and nothing collides with ProjectN's own keys). Profiles and history are shared
/// too: ~/Library/Application Support/NVoice/.
enum NVoiceDefaults {
    static let suite = "dev.projectn.nvoice"
    static let store: UserDefaults = UserDefaults(suiteName: suite) ?? .standard
}

/// The same lock file the standalone NVoice app uses, so only one of them ever listens to fn
/// (two would both paste every dictation).
enum SingleInstance {
    static let activateNote = Notification.Name("dev.projectn.nvoice.activate")
    private static var fd: Int32 = -1

    static var held: Bool { fd >= 0 }

    static func acquire() -> Bool {
        if fd >= 0 { return true }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("nvoice.lock").path
        let f = open(path, O_CREAT | O_RDWR, 0o644)
        guard f >= 0 else { return true }          // can't lock → don't block the user
        if flock(f, LOCK_EX | LOCK_NB) != 0 {
            close(f)
            return false
        }
        fd = f
        return true
    }

    static func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN); close(fd); fd = -1
    }
}

enum Sound {
    static func play(_ name: String) {
        guard NVoiceSettings.shared.playSounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

final class NVoiceController: NSObject, ObservableObject {
    static let shared = NVoiceController()
    static let standaloneBundleID = "com.4vmarketing.nvoice"

    enum State: Equatable {
        case off
        /// The standalone NVoice app holds the lock.
        case blockedByStandalone
        /// Running, but macOS hasn't granted Input Monitoring yet (fn can't be heard).
        case waitingForPermission
        case running
    }

    @Published private(set) var state: State = .off
    /// Set when macOS refused to register the chosen shortcut.
    @Published private(set) var hotkeyProblem: String?

    /// Opens ProjectN's Settings › Voice (set by ProjectN).
    var onOpenSettings: (() -> Void)?
    /// Passive wake listening must yield synchronously before a dictation shortcut opens the mic.
    var onDictationWillStart: (() -> Void)?

    private let settings = NVoiceSettings.shared
    private let metrics = MetricsStore.shared
    private let profiles = ProfileStore.shared
    private var locales: [Locale] = []
    private var correctionWindow: NSWindow?
    private let hotkey = HotkeyMonitor()
    private let transcriber = Transcriber()
    private var overlay: OverlayController?
    private var statusItem: NSStatusItem?
    private var bag = Set<AnyCancellable>()
    private var permissionTimer: Timer?
    private var lockRetryTimer: Timer?
    private var observersInstalled = false
    private var wantMenuBarIcon = true

    private var recordingStart: Date?
    private var dictationRecording = false
    private var targetApp: NSRunningApplication?
    private var enhanceThisTime = false
    private var busy = false               // transcribing / enhancing
    private var resetWork: DispatchWorkItem?
    private var duckWork: DispatchWorkItem?
    private var wordsItem: NSMenuItem?
    private weak var micMenu: NSMenu?
    private weak var micItem: NSMenuItem?

    private var isOn: Bool { state == .running || state == .waitingForPermission }

    var standaloneRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.standaloneBundleID).isEmpty
    }

    // MARK: Lifecycle (driven by ProjectN settings)

    /// Turn dictation on/off and the menu bar icon on/off. Safe to call repeatedly.
    func apply(enabled: Bool, menuBarIcon: Bool) {
        wantMenuBarIcon = menuBarIcon
        if enabled {
            if state == .off || state == .blockedByStandalone { start() }
            if isOn { menuBarIcon ? setupStatusItem() : removeStatusItem() }
        } else if state != .off {
            stop()
        }
    }

    private func start() {
        guard SingleInstance.acquire() else {
            Diagnostics.log("ProjectN: the NVoice app is running — not starting built-in dictation")
            state = .blockedByStandalone
            retryWhenStandaloneExits()
            return
        }
        lockRetryTimer?.invalidate(); lockRetryTimer = nil
        Diagnostics.log("ProjectN: starting built-in NVoice")
        AudioDucker.restoreAfterCrash()
        if overlay == nil {
            let o = OverlayController()
            o.onClick = { [weak self] in self?.settings.enhanceEnabled.toggle() }
            overlay = o
        }
        overlay?.model.enhance = settings.enhanceEnabled
        overlay?.setVisible(settings.showWidget)

        if wantMenuBarIcon { setupStatusItem() }
        bindSettings()
        installObserversOnce()
        wireHotkey()
        applyHotkey(settings.hotkey)
        if !transcriber.isRecording {
            transcriber.onLevel = { [weak self] in self?.overlay?.model.push(level: $0) }
        }
        transcriber.inputDeviceProvider = {
            AudioDevices.resolve(NVoiceDefaults.store.string(forKey: "microphone") ?? AudioDevices.automatic)
        }
        transcriber.prewarm()

        Task {
            _ = await Transcriber.requestPermissions()
            for id in profiles.activeLocaleIDs { try? await transcriber.ensureModel(localeID: id) }
            locales = await Transcriber.supportedLocales()
            await MainActor.run { self.rebuildMenu(enhance: self.settings.enhanceEnabled) }
        }
        startHotkeyOrWaitForPermission()
    }

    /// The lock frees when the standalone app quits or crashes: take over without needing a settings change.
    private func retryWhenStandaloneExits() {
        guard lockRetryTimer == nil else { return }
        lockRetryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] t in
            guard let self, self.state == .blockedByStandalone else {
                t.invalidate(); self?.lockRetryTimer = nil
                return
            }
            guard SingleInstance.acquire() else { return }
            t.invalidate(); self.lockRetryTimer = nil
            self.apply(enabled: true, menuBarIcon: self.wantMenuBarIcon)
        }
    }

    private func stop() {
        Diagnostics.log("ProjectN: stopping built-in NVoice")
        lockRetryTimer?.invalidate(); lockRetryTimer = nil
        permissionTimer?.invalidate(); permissionTimer = nil
        if dictationRecording { transcriber.cancel() }
        dictationRecording = false
        restoreOtherAudio()
        hotkey.stop()
        bag.removeAll()
        resetWork?.cancel()
        overlay?.model.phase = .idle
        overlay?.setVisible(false)
        removeStatusItem()
        correctionWindow?.close()
        SingleInstance.release()
        state = .off
    }

    /// Quit the standalone NVoice app, then take over.
    func quitStandaloneAndTakeOver() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.standaloneBundleID).forEach { $0.terminate() }
        var tries = 0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            tries += 1
            if SingleInstance.acquire() {
                t.invalidate()
                SingleInstance.release()
                self.state = .off
                self.apply(enabled: true, menuBarIcon: self.wantMenuBarIcon)
            } else if tries == 6 {
                // A frozen app never answers a polite quit.
                Diagnostics.log("NVoice app did not quit — force quitting it")
                NSRunningApplication.runningApplications(withBundleIdentifier: Self.standaloneBundleID).forEach { $0.forceTerminate() }
            } else if tries > 12 {
                t.invalidate()
            }
        }
    }

    /// Call when ProjectN quits.
    func shutdown() {
        AudioDucker.restore()
    }

    // MARK: Setup

    private func installObserversOnce() {
        guard !observersInstalled else { return }
        observersInstalled = true
        // A launch of the standalone app while we hold the lock: it exits and asks us to show ourselves.
        DistributedNotificationCenter.default().addObserver(forName: SingleInstance.activateNote, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isOn else { return }
            Diagnostics.log("NVoice app launch blocked — ProjectN is handling dictation")
            self.openSettings()
        }
        // Rebuild the (pre-warmed) audio engine whenever the audio setup may have changed under it.
        let rebuild: (String) -> Void = { [weak self] why in
            DispatchQueue.main.async {
                guard let self, self.isOn else { return }
                self.transcriber.invalidateEngine(reason: why)
            }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in rebuild("woke from sleep") }
        ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { _ in rebuild("session active") }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in rebuild("screen unlocked") }
        // Mics plugged in / out, AirPods connecting, default input changed.
        for sel in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in
                rebuild(sel == kAudioHardwarePropertyDefaultInputDevice ? "default mic changed" : "audio devices changed")
            }
        }
    }

    private func bindSettings() {
        bag.removeAll()
        settings.$microphone.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.transcriber.invalidateEngine(reason: "microphone setting changed") }
        }.store(in: &bag)
        settings.$hotkey.dropFirst().removeDuplicates().sink { [weak self] h in
            DispatchQueue.main.async {
                guard let self, self.isOn else { return }
                self.applyHotkey(h)
                self.rebuildMenu(enhance: self.settings.enhanceEnabled)
            }
        }.store(in: &bag)
        settings.$hotkeyMode.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildMenu(enhance: self?.settings.enhanceEnabled ?? false) }
        }.store(in: &bag)
        settings.$enhanceEnabled.sink { [weak self] v in self?.overlay?.model.enhance = v; self?.rebuildMenu(enhance: v) }.store(in: &bag)
        settings.$showWidget.dropFirst().sink { [weak self] v in self?.overlay?.setVisible(v) }.store(in: &bag)
        settings.$widgetPosition.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.overlay?.reposition() } }.store(in: &bag)
        // Switching person or language: download that language's model if needed, refresh the menu.
        profiles.$profiles.map { _ in ProfileStore.shared.activeLocaleIDs }
            .merge(with: profiles.$activeID.map { _ in ProfileStore.shared.activeLocaleIDs })
            .dropFirst().removeDuplicates()
            .sink { [weak self] ids in
                guard let self else { return }
                Task { for id in ids { try? await self.transcriber.ensureModel(localeID: id) } }
            }.store(in: &bag)
        profiles.$profiles.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildMenu(enhance: self?.settings.enhanceEnabled ?? false) }
        }.store(in: &bag)
        profiles.$activeID.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildMenu(enhance: self?.settings.enhanceEnabled ?? false) }
        }.store(in: &bag)
        transcriber.onStatus = { [weak self] msg in self?.statusItem?.button?.toolTip = "NVoice — \(msg)" }
    }

    private func startHotkeyOrWaitForPermission() {
        // Ask for both: Input Monitoring (hear fn) and Accessibility (paste with ⌘V).
        if !HotkeyMonitor.hasInputMonitoring() { HotkeyMonitor.requestInputMonitoring() }
        _ = HotkeyMonitor.hasAccessibility(prompt: true)
        if hotkey.start() { Diagnostics.log("event tap started"); state = .running; return }
        Diagnostics.log("event tap could not start yet — waiting for permission")
        state = .waitingForPermission
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            guard let self, self.state == .waitingForPermission else { return t.invalidate() }
            if self.hotkey.start() {
                t.invalidate()
                Diagnostics.log("event tap started after permission was granted")
                self.state = .running
                self.rebuildMenu(enhance: self.settings.enhanceEnabled)
            }
        }
    }

    private func applyHotkey(_ h: DictationHotkey) {
        if dictationRecording { cancelDictation() }
        let registered = hotkey.configure(h)
        hotkeyProblem = registered ? nil : "macOS wouldn't register \(h.displayName). Try another shortcut."
        overlay?.model.hotkeyLabel = h.displayName
        Diagnostics.log("dictation shortcut: \(h.displayName)\(registered ? "" : " (could not register)")")
    }

    /// While Settings records a new shortcut, the current one is switched off.
    func setCapturingHotkey(_ capturing: Bool) {
        if capturing && dictationRecording { cancelDictation() }
        hotkey.setSuspended(capturing)
    }

    private func wireHotkey() {
        hotkey.onHotkeyDown = { [weak self] in
            guard let self else { return }
            Diagnostics.log("hotkey down")
            switch self.settings.hotkeyMode {
            case .hold: self.startDictation()
            case .toggle: self.dictationRecording ? self.finishDictation() : self.startDictation()
            }
        }
        hotkey.onHotkeyUp = { [weak self] in
            guard let self, self.settings.hotkeyMode == .hold else { return }
            self.finishDictation()
        }
        hotkey.onHotkeyChord = { [weak self] in
            // fn + another key (fn+arrows, fn+F-keys…) is a shortcut, not a dictation.
            guard let self, self.dictationRecording,
                  Date().timeIntervalSince(self.recordingStart ?? .distantPast) < 1.0 || self.settings.hotkeyMode == .hold else { return }
            self.cancelDictation("another key pressed with the shortcut")
        }
        hotkey.onEscape = { [weak self] in
            guard let self, self.dictationRecording else { return }
            self.cancelDictation("Esc")
        }
    }

    // MARK: Assistant (shares the warm mic engine: no second audio engine)

    private var assistantPrepared = false
    private var assistantProfile: Profile?
    private var assistantVocabulary: [String] = []
    private var assistantModelLocales: [String] = []
    private var assistantTranscriptHandler: ((String, String) -> Void)?
    private var assistantTranscriptToken: UUID?

    var assistantRecordingAvailable: Bool { !transcriber.isRecording && !busy && !standaloneRunning }

    /// Where the Assistant's mic levels go: (level, seconds since that audio was captured).
    func assistantSetLevelHandler(_ onLevel: @escaping (Float, TimeInterval) -> Void) {
        transcriber.onLevel = nil
        transcriber.onLevelAge = onLevel
    }

    /// Where live text of the running Assistant transcript goes: (language, text).
    func assistantSetTranscriptHandler(_ onTranscript: @escaping (String, String) -> Void) {
        assistantTranscriptHandler = onTranscript
    }

    /// The Assistant opened: build the mic engine now (in the background) so its first recording starts at once,
    /// even when dictation is off.
    func assistantPrewarm() {
        useChosenMic()
        transcriber.prewarm()
    }

    private func useChosenMic() {
        transcriber.inputDeviceProvider = {
            AudioDevices.resolve(NVoiceDefaults.store.string(forKey: "microphone") ?? AudioDevices.automatic)
        }
    }

    /// Opens the mic for an Assistant conversation without transcribing yet. It stays open across turns (listening,
    /// thinking and speaking); each turn is transcribed with `assistantBeginTranscript` / `assistantFinishTranscript`.
    /// Levels (~50 per second, main thread) go to `onLevel` instead of the dictation overlay.
    @MainActor
    func assistantOpenMic(shouldStart: () -> Bool = { true }, onLevel: @escaping (Float, TimeInterval) -> Void) async throws {
        try await assistantPrepare()
        // Claims ownership atomically with starting capture (there is no await below).
        guard shouldStart() else { throw CancellationError() }
        assistantSetLevelHandler(onLevel)
        do {
            try transcriber.start(localeIDs: profiles.activeLocaleIDs, transcribe: false, keepPreroll: true)
        } catch {
            restoreOverlayLevels()
            throw error
        }
    }

    /// Opens the mic for “Hey N” without transcribing: audio (16 kHz mono, on a background queue) only goes to
    /// `onAudio`. Call `assistantBeginTranscript` to start transcribing on the same recording.
    @MainActor
    func assistantStartWakeListening(onAudio: @escaping ([Float]) -> Void, shouldStart: () -> Bool = { true },
                                     onLevel: @escaping (Float) -> Void) async throws {
        try await assistantPrepare()   // speech models ready now, so confirming a match starts at once
        guard shouldStart() else { throw CancellationError() }
        transcriber.onLevelAge = nil
        transcriber.onLevel = onLevel
        do {
            try transcriber.start(localeIDs: profiles.activeLocaleIDs, transcribe: false, onAudio16k: onAudio)
        } catch {
            restoreOverlayLevels()
            throw error
        }
    }

    /// Starts transcribing on the open mic, including the last `preroll` seconds already heard (at most ~2).
    /// `vocabulary`: names the Assistant expects to hear (projects, spaces, panes, agents, tools), as speech hints.
    @MainActor
    func assistantBeginTranscript(vocabulary: [String], preroll: Double = Transcriber.prerollSeconds,
                                  onTranscript: @escaping (String, String) -> Void) {
        let (hints, report) = assistantTranscript(vocabulary: vocabulary, onTranscript: onTranscript)
        transcriber.beginTranscription(localeIDs: profiles.activeLocaleIDs, contextualStrings: hints,
                                       prerollSeconds: preroll, onTranscript: report)
    }

    /// Drops that transcript; the mic stays open.
    @MainActor
    func assistantEndTranscript() {
        assistantClearTranscript()
        transcriber.endTranscription()
    }

    /// Ends the running transcript and returns what was said (and in which language), with personal corrections
    /// applied. The mic stays open.
    @MainActor
    func assistantFinishTranscript(cleanTranscript: (String) -> String = { $0 }) async throws -> (text: String, localeID: String) {
        let profile = assistantProfile
        let vocabulary = assistantVocabulary
        assistantClearTranscript()
        let r = try await transcriber.finishTranscription()
        // Discard wake-listening background and speaker echo before applying/counting personal corrections.
        return (profiles.personalize(cleanTranscript(r.text), profile: profile, vocabulary: vocabulary), r.localeID)
    }

    /// The Assistant adopted the “Hey N” recording: the sound matcher isn't needed anymore.
    @MainActor
    func assistantStopWakeMatcher() {
        transcriber.stopAudioMonitor()
    }

    @MainActor
    var assistantTranscribing: Bool { transcriber.isTranscribing }

    private func assistantPrepare() async throws {
        guard !transcriber.isRecording, !busy else { throw TranscriberError.micUnavailable("dictation is in use") }
        if !assistantPrepared {
            // Dictation may be off: permissions, mic choice and speech models aren't set up yet.
            guard await Transcriber.requestPermissions() else { throw TranscriberError.micDenied }
            useChosenMic()
            assistantPrepared = true
        }
        let localeIDs = profiles.activeLocaleIDs
        if assistantModelLocales != localeIDs {
            for id in localeIDs { try await transcriber.ensureModel(localeID: id) }
            assistantModelLocales = localeIDs
        }
        // Permissions/model downloads suspend: a dictation may have started while we waited.
        guard !transcriber.isRecording, !busy else { throw TranscriberError.micUnavailable("dictation is in use") }
    }

    /// Speech hints and the transcript callback for one Assistant recording.
    private func assistantTranscript(vocabulary: [String], onTranscript: ((String, String) -> Void)?)
        -> (hints: [String], report: ((String, String) -> Void)?) {
        // Keep the speaker and full vocabulary for corrections even when Apple's 100 hints are exhausted.
        assistantProfile = profiles.active
        assistantVocabulary = vocabulary
        let token = UUID()
        assistantTranscriptToken = token
        assistantTranscriptHandler = onTranscript
        let report: ((String, String) -> Void)? = onTranscript == nil ? nil : { [weak self] locale, text in
            guard let self, self.assistantTranscriptToken == token else { return }
            self.assistantTranscriptHandler?(locale, text)
        }
        return (ProfileStore.recognitionHints(personal: profiles.contextualStrings, vocabulary: vocabulary), report)
    }

    private func assistantClearTranscript() {
        assistantProfile = nil
        assistantVocabulary = []
        assistantTranscriptToken = nil
        assistantTranscriptHandler = nil
    }

    /// Closes the Assistant's mic (dropping any transcript in progress).
    @MainActor
    func assistantCancel() {
        assistantClearTranscript()
        transcriber.cancel()
        restoreOverlayLevels()
    }

    private func restoreOverlayLevels() {
        transcriber.onLevelAge = nil
        transcriber.onLevel = { [weak self] in self?.overlay?.model.push(level: $0) }
    }

    // MARK: Dictation flow

    private func startDictation() {
        guard isOn, !busy, let overlay else { return }
        onDictationWillStart?()
        guard !transcriber.isRecording else { return }
        resetWork?.cancel()
        targetApp = NSWorkspace.shared.frontmostApplication
        enhanceThisTime = settings.enhanceEnabled || hotkey.shiftHeld
        do {
            try transcriber.start(localeIDs: profiles.activeLocaleIDs,
                                  contextualStrings: ProfileStore.recognitionHints(personal: profiles.contextualStrings))
        } catch {
            show(error: error.localizedDescription)
            return
        }
        dictationRecording = true
        recordingStart = Date()
        overlay.model.resetLevels()
        overlay.model.enhance = enhanceThisTime
        setPhase(.recording)
        Sound.play("Tink")
        duckOtherAudio()
    }

    /// Lower whatever is playing while fn is held — a beat after the start sound, so that one stays audible.
    private func duckOtherAudio() {
        duckWork?.cancel()
        guard settings.duckAudio else { return }
        let level = Float(settings.duckLevel)
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.dictationRecording else { return }
            AudioDucker.duck(to: level)
        }
        duckWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
    }

    private func restoreOtherAudio() {
        duckWork?.cancel(); duckWork = nil
        AudioDucker.restore()
    }

    private func cancelDictation(_ reason: String = "cancelled") {
        guard dictationRecording else { return }
        dictationRecording = false
        Diagnostics.log(String(format: "dictation cancelled (%@) after %.1f s", reason,
                               Date().timeIntervalSince(recordingStart ?? Date())))
        restoreOtherAudio()
        transcriber.cancel()
        Sound.play("Funk")
        setPhase(.idle)
    }

    private func finishDictation() {
        guard dictationRecording, transcriber.isRecording else { return }
        dictationRecording = false
        restoreOtherAudio()
        if hotkey.shiftHeld { enhanceThisTime = true }
        // Very short taps are accidental.
        if Date().timeIntervalSince(recordingStart ?? Date()) < 0.3 {
            transcriber.cancel(); setPhase(.idle); return
        }
        Sound.play("Pop")
        busy = true
        setPhase(.transcribing)
        let enhance = enhanceThisTime
        let app = targetApp
        let profileID = profiles.activeID
        let released = Date()
        Diagnostics.log(String(format: "hotkey up — recorded %.1f s, target %@",
                               released.timeIntervalSince(recordingStart ?? released), app?.localizedName ?? "?"))

        Task { @MainActor in
            defer { self.busy = false }
            do {
                let (heard, duration, usedLocale) = try await transcriber.stop()
                guard !heard.isEmpty else { show(error: "No speech detected"); return }
                // Personal corrections + dictionary capitalization, before any AI.
                let raw = profiles.personalize(heard)

                var final = raw
                if enhance {
                    setPhase(.enhancing)
                    do { final = try await Enhancer.enhance(raw, settings: settings, terms: profiles.active.dictionary) }
                    catch { show(error: error.localizedDescription); /* fall back to the raw transcript */ }
                }

                // Without Accessibility, macOS silently drops the ⌘V we post — so never lose the text:
                // leave it on the clipboard and say so.
                let canPaste = HotkeyMonitor.hasAccessibility(prompt: false)
                if canPaste {
                    let inFront = await TextInserter.bringToFront(app)
                    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                    Diagnostics.log(String(format: "pasting %d chars into %@ (target %@%@) — %.1f s after release",
                                           final.count, front, app?.localizedName ?? "?",
                                           inFront ? "" : ", NOT frontmost", Date().timeIntervalSince(released)))
                    TextInserter.insert(final, restoreClipboard: settings.restoreClipboard)
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(final, forType: .string)
                    Diagnostics.log("Accessibility not granted — copied to clipboard instead of pasting")
                    _ = HotkeyMonitor.hasAccessibility(prompt: true)
                    show(error: "Allow Accessibility to paste · copied, press ⌘V")
                }

                metrics.add(DictationRecord(
                    date: Date(), words: MetricsStore.wordCount(raw), characters: final.count,
                    duration: duration, enhanced: enhance && final != raw,
                    app: app?.localizedName ?? "Unknown", text: final, rawText: enhance ? raw : nil,
                    profileID: profileID, localeID: usedLocale))

                if case .error = overlay?.model.phase { return }
                setPhase(.done)
                scheduleIdle(after: 0.8)
            } catch {
                show(error: error.localizedDescription)
            }
        }
    }

    private func setPhase(_ p: DictationPhase) {
        guard let overlay else { return }
        overlay.model.phase = p
        if p == .idle { overlay.model.enhance = settings.enhanceEnabled }
        if settings.showWidget || p != .idle { overlay.setVisible(true) }
        if p == .idle && !settings.showWidget { overlay.setVisible(false) }
        updateStatusIcon(p)
    }

    private func show(error: String) {
        Diagnostics.log("error: \(error)")
        Sound.play("Basso")
        setPhase(.error(error))
        scheduleIdle(after: 3.5)
    }

    private func scheduleIdle(after s: TimeInterval) {
        resetWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.dictationRecording, !self.busy else { return }
            self.setPhase(.idle)
        }
        resetWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(overlay?.model.phase ?? .idle)
        rebuildMenu(enhance: settings.enhanceEnabled)
    }

    private func removeStatusItem() {
        guard let s = statusItem else { return }
        NSStatusBar.system.removeStatusItem(s)
        statusItem = nil
    }

    private func updateStatusIcon(_ p: DictationPhase) {
        let name: String
        switch p {
        case .recording: name = "waveform.circle.fill"
        case .transcribing, .enhancing: name = "ellipsis.circle"
        case .error: name = "exclamationmark.circle"
        default: name = "waveform"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "NVoice")
    }

    private func rebuildMenu(enhance: Bool) {
        guard let statusItem else { return }
        let menu = NSMenu()
        let status: String
        if !hotkey.isRunning { status = "⚠︎ Grant Input Monitoring + Accessibility…" }
        else if !HotkeyMonitor.hasAccessibility(prompt: false) { status = "⚠︎ Grant Accessibility to paste…" }
        else { status = "\(settings.hotkeyMode == .hold ? "Hold" : "Tap") \(settings.hotkey.displayName) to dictate" }
        let ready = hotkey.isRunning && HotkeyMonitor.hasAccessibility(prompt: false)
        let header = NSMenuItem(title: status, action: ready ? nil : #selector(openPermissions), keyEquivalent: "")
        header.target = self
        menu.addItem(header)
        let words = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        wordsItem = words
        updateWordsItem()
        menu.addItem(words)
        menu.addItem(.separator())
        let e = NSMenuItem(title: "Enhance prompt (\(settings.provider == .claude ? "Claude" : "Codex") · \(settings.effectiveModel))",
                           action: #selector(toggleEnhance), keyEquivalent: "e")
        e.state = enhance ? .on : .off
        e.target = self
        menu.addItem(e)
        menu.addItem(.separator())
        let fix = NSMenuItem(title: "Correct last dictation…", action: #selector(correctLast), keyEquivalent: "l")
        fix.target = self
        fix.isEnabled = !metrics.records.isEmpty
        menu.addItem(fix)
        let copyLast = NSMenuItem(title: "Copy last dictation", action: #selector(copyLastDictation), keyEquivalent: "c")
        copyLast.target = self
        copyLast.isEnabled = !metrics.records.isEmpty
        menu.addItem(copyLast)
        menu.addItem(.separator())

        // Person
        let active = profiles.active
        let personItem = NSMenuItem(title: "Person: \(active.name)", action: nil, keyEquivalent: "")
        let personMenu = NSMenu()
        for p in profiles.profiles {
            let it = NSMenuItem(title: p.name, action: #selector(selectProfile(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = p.id
            it.state = p.id == active.id ? .on : .off
            personMenu.addItem(it)
        }
        personMenu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage people…", action: #selector(openSettings), keyEquivalent: "")
        manage.target = self
        personMenu.addItem(manage)
        personItem.submenu = personMenu
        menu.addItem(personItem)

        // Language (Apple on-device)
        let langItem = NSMenuItem(title: "Language: \(Self.languageName(active.localeID))", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for l in locales.sorted(by: { Self.languageName($0.identifier) < Self.languageName($1.identifier) }) {
            let it = NSMenuItem(title: Self.languageName(l.identifier), action: #selector(selectLanguage(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = l.identifier
            it.state = l.identifier == active.localeID ? .on : .off
            langMenu.addItem(it)
        }
        if locales.isEmpty { langMenu.addItem(NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")) }
        langItem.submenu = langMenu
        menu.addItem(langItem)

        let second = active.secondLocaleID
        let secondItem = NSMenuItem(title: "Also detect: \(second.map { Self.languageName($0) } ?? "None")", action: nil, keyEquivalent: "")
        let secondMenu = NSMenu()
        let none = NSMenuItem(title: "None (one language)", action: #selector(selectSecondLanguage(_:)), keyEquivalent: "")
        none.target = self
        none.state = second == nil ? .on : .off
        secondMenu.addItem(none)
        secondMenu.addItem(.separator())
        for l in locales.sorted(by: { Self.languageName($0.identifier) < Self.languageName($1.identifier) }) where l.identifier != active.localeID {
            let it = NSMenuItem(title: Self.languageName(l.identifier), action: #selector(selectSecondLanguage(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = l.identifier
            it.state = l.identifier == second ? .on : .off
            secondMenu.addItem(it)
        }
        secondItem.submenu = secondMenu
        menu.addItem(secondItem)

        // Microphone — filled each time it opens, so newly connected mics show up.
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let micMenu = NSMenu()
        micMenu.delegate = self
        micItem.submenu = micMenu
        self.micMenu = micMenu
        self.micItem = micItem
        updateMicTitle()
        menu.addItem(micItem)
        menu.addItem(.separator())

        let s = NSMenuItem(title: "Voice Settings & Metrics…", action: #selector(openSettings), keyEquivalent: ",")
        s.target = self
        menu.addItem(s)
        menu.delegate = self
        statusItem.menu = menu
    }

    private func updateWordsItem() {
        wordsItem?.title = "\(metrics.wordsToday) words today · \(metrics.totalWords) total"
    }

    static func languageName(_ id: String) -> String {
        Locale.current.localizedString(forIdentifier: id) ?? id
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        profiles.activeID = id
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        profiles.update { $0.localeID = id }
        rebuildMenu(enhance: settings.enhanceEnabled)
    }

    @objc private func selectSecondLanguage(_ sender: NSMenuItem) {
        let id = sender.representedObject as? String
        profiles.update { $0.secondLocaleID = id }
        rebuildMenu(enhance: settings.enhanceEnabled)
    }

    private func micLabel(_ choice: String) -> String {
        switch choice {
        case AudioDevices.automatic:
            let used = AudioDevices.resolve(choice) ?? AudioDevices.defaultInput()
            return "Automatic" + (used.map { " (\($0.name))" } ?? "")
        case AudioDevices.systemDefault:
            return "System default" + (AudioDevices.defaultInput().map { " (\($0.name))" } ?? "")
        default:
            return AudioDevices.inputDevices().first { $0.uid == choice }?.name ?? "Unavailable mic → Automatic"
        }
    }

    private func updateMicTitle() { micItem?.title = "Microphone: \(micLabel(settings.microphone))" }

    private func fillMicMenu(_ m: NSMenu) {
        m.removeAllItems()
        let current = settings.microphone
        func add(_ title: String, _ value: String) {
            let it = NSMenuItem(title: title, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = value
            it.state = value == current ? .on : .off
            m.addItem(it)
        }
        add(micLabel(AudioDevices.automatic) + " — avoids Bluetooth mics", AudioDevices.automatic)
        add(micLabel(AudioDevices.systemDefault), AudioDevices.systemDefault)
        m.addItem(.separator())
        for d in AudioDevices.inputDevices() { add(d.name + (d.isBluetooth ? "  (Bluetooth — cuts your audio)" : ""), d.uid) }
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String else { return }
        settings.microphone = v
        updateMicTitle()
    }

    /// Recovery when a paste didn't land: the transcript is always in the history.
    @objc func copyLastDictation() {
        guard let record = metrics.records.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.text, forType: .string)
    }

    @objc func correctLast() {
        guard let record = metrics.records.first else { return }
        correctionWindow?.close()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Correct last dictation"
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: CorrectionView(record: record) { [weak w] in w?.close() })
        w.center()
        w.level = .floating
        correctionWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleEnhance() { settings.enhanceEnabled.toggle() }

    @objc func openPermissions() {
        openSettings()
        NotificationCenter.default.post(name: .nvoiceShowGeneral, object: nil)
        if !hotkey.isRunning {
            HotkeyMonitor.requestInputMonitoring()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        } else {
            _ = HotkeyMonitor.hasAccessibility(prompt: true)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    /// Shows ProjectN's main window on Settings › Voice.
    @objc func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) && $0 !== correctionWindow }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        }
        onOpenSettings?()
    }
}

extension NVoiceController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { if menu === micMenu { fillMicMenu(menu) } }
    func menuWillOpen(_ menu: NSMenu) { updateWordsItem(); updateMicTitle() }
}
