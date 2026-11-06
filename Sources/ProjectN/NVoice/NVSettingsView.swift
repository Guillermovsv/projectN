import SwiftUI
import Charts
import AVFoundation

enum SettingsTab: String, CaseIterable, Identifiable {
    case metrics = "Metrics", people = "People & Words", general = "General", ai = "AI", history = "History"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .metrics: return "chart.bar.xaxis"
        case .people: return "person.2"
        case .general: return "gearshape"
        case .ai: return "sparkles"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

// MARK: - Metrics

struct MetricsView: View {
    @ObservedObject var store = MetricsStore.shared
    @ObservedObject var profiles = ProfileStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("\(profiles.active.name)’s dictation").font(.largeTitle.bold())

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    StatTile(title: "Words dictated", value: store.totalWords.formatted(), icon: "text.word.spacing")
                    StatTile(title: "Time speaking", value: fmtDuration(store.totalDuration), icon: "waveform")
                    StatTile(title: "Average speed", value: "\(Int(store.averageWPM.rounded())) wpm", icon: "speedometer")
                    StatTile(title: "Time saved*", value: fmtDuration(store.timeSaved), icon: "hourglass")
                    StatTile(title: "Dictations", value: store.sessions.formatted(), icon: "mic")
                    StatTile(title: "Enhanced prompts", value: store.enhancedCount.formatted(), icon: "sparkles")
                    StatTile(title: "Words today", value: store.wordsToday.formatted(), icon: "sun.max")
                    StatTile(title: "Day streak", value: "\(store.streak) 🔥", icon: "flame")
                    StatTile(title: "Avg words / dictation", value: store.sessions > 0 ? "\(store.totalWords / store.sessions)" : "0", icon: "number")
                    StatTile(title: "Dictionary words", value: profiles.active.dictionary.count.formatted(), icon: "character.book.closed")
                    StatTile(title: "Corrections learned", value: profiles.active.rules.count.formatted(), icon: "brain.head.profile")
                    StatTile(title: "Corrections applied", value: profiles.active.rules.reduce(0) { $0 + $1.uses }.formatted(), icon: "checkmark.seal")
                }

                GroupBox("Words per day — last 14 days") {
                    Chart(store.lastDays(14)) { d in
                        BarMark(x: .value("Day", d.day, unit: .day), y: .value("Words", d.words))
                            .foregroundStyle(LinearGradient(colors: [.cyan, .blue, .purple], startPoint: .bottom, endPoint: .top))
                            .cornerRadius(4)
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
                    .frame(height: 180)
                    .padding(.top, 6)
                }

                if !store.topApps(5).isEmpty {
                    GroupBox("Top apps") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(store.topApps(5), id: \.app) { item in
                                HStack {
                                    Text(item.app)
                                    Spacer()
                                    Text("\(item.words) words").foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }.padding(.vertical, 4)
                    }
                }

                Text("* Compared with typing at \(Int(MetricsStore.typingWPM)) words per minute.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }
}

struct StatTile: View {
    let title: String, value: String, icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

func fmtDuration(_ t: TimeInterval) -> String {
    let s = Int(t.rounded())
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \((s % 3600) / 60)m"
}

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject var s = NVoiceSettings.shared
    @State private var axTrusted = HotkeyMonitor.hasAccessibility(prompt: false)
    @State private var inputOK = HotkeyMonitor.hasInputMonitoring()
    @State private var diag = ""
    @State private var micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

    var body: some View {
        Form {
            Section("Hotkey") {
                Picker("fn key", selection: $s.hotkeyMode) {
                    ForEach(HotkeyMode.allCases) { Text($0.label).tag($0) }
                }
                Text("Language, dictionary and corrections are per person — see People & Words.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Hold ⇧ Shift together with fn to enhance a single dictation. Press Esc to cancel.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Tip: set System Settings › Keyboard › “Press 🌐 key to” → Do Nothing, so macOS doesn’t open the emoji picker.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Dictation") {
                Picker("Microphone", selection: $s.microphone) {
                    Text("Automatic — avoid Bluetooth mics (recommended)").tag(AudioDevices.automatic)
                    Text("System default").tag(AudioDevices.systemDefault)
                    Divider()
                    ForEach(AudioDevices.inputDevices()) { Text($0.name).tag($0.uid) }
                }
                Text("Using AirPods or other Bluetooth headphones as the mic switches them to call mode, which cuts and degrades what you're listening to. Automatic records with the Mac's mic instead.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Enhance prompt with AI", isOn: $s.enhanceEnabled)
                Toggle("Restore clipboard after pasting", isOn: $s.restoreClipboard)
            }
            Section("Widget & sound") {
                Toggle("Show floating widget", isOn: $s.showWidget)
                Picker("Position", selection: $s.widgetPosition) {
                    ForEach(WidgetPosition.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Play sounds", isOn: $s.playSounds)
                Toggle("Lower other audio while holding fn", isOn: $s.duckAudio)
                if s.duckAudio {
                    HStack {
                        Text("Volume while dictating")
                        Slider(value: $s.duckLevel, in: 0...0.6, step: 0.05)
                        Text("\(Int(s.duckLevel * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
            }
            Section("Permissions") {
                PermissionRow(name: "Input Monitoring (hear the fn key)", ok: inputOK) {
                    HotkeyMonitor.requestInputMonitoring()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                }
                PermissionRow(name: "Accessibility (paste into apps)", ok: axTrusted) {
                    _ = HotkeyMonitor.hasAccessibility(prompt: true)
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                PermissionRow(name: "Microphone", ok: micOK) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
                Button("Refresh") { refresh() }
                Text("If a switch is ON in System Settings but shows ✗ here, macOS is holding an outdated entry: select ProjectN in that list, remove it with “–”, then click Grant… again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                Text(diag).font(.caption.monospaced()).textSelection(.enabled)
                Button("Copy diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diag, forType: .string)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private func refresh() {
        axTrusted = HotkeyMonitor.hasAccessibility(prompt: false)
        inputOK = HotkeyMonitor.hasInputMonitoring()
        diag = Diagnostics.summary(tapRunning: HotkeyMonitor.tapRunning) + "\n\nRecent log:\n" + Diagnostics.tail(10)
        micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}

struct PermissionRow: View {
    let name: String, ok: Bool, fix: () -> Void
    var body: some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(ok ? .green : .red)
            Text(name)
            Spacer()
            if !ok { Button("Grant…", action: fix) }
        }
    }
}

// MARK: - AI

struct AISettingsView: View {
    @ObservedObject var s = NVoiceSettings.shared
    @State private var testInput = "um so basically I want you to like write me a quick email to the team saying the launch moves to friday I guess"
    @State private var testOutput = ""
    @State private var testing = false
    @State private var cliPath = ""

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Use", selection: $s.provider) {
                    ForEach(AIProvider.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Picker("Model", selection: $s.model) {
                    ForEach(s.provider.models, id: \.self) { Text($0).tag($0) }
                }
                TextField("Custom model (optional)", text: $s.customModel, prompt: Text("overrides the picker, e.g. claude-sonnet-5-5"))
                LabeledContent("CLI") {
                    Text(cliPath.isEmpty ? "not found" : cliPath).foregroundStyle(cliPath.isEmpty ? .red : .secondary)
                        .textSelection(.enabled).font(.caption.monospaced())
                }
                if s.provider == .claude {
                    TextField("claude path override", text: $s.claudePath, prompt: Text("auto-detect"))
                    Text("Uses your Claude Pro/Max login from Claude Code (`claude login`). No API key needed.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("codex path override", text: $s.codexPath, prompt: Text("auto-detect"))
                    Text("Uses your ChatGPT plan via Codex CLI (`codex login`). Models are read from ~/.codex/models_cache.json.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Enhance prompt") {
                Toggle("Enhance every dictation", isOn: $s.enhanceEnabled)
                TextEditor(text: $s.enhancePrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                Button("Reset to default") { s.enhancePrompt = defaultEnhancePrompt }
            }
            Section("Test") {
                TextField("Sample dictation", text: $testInput, axis: .vertical).lineLimit(2...4)
                HStack {
                    Button(testing ? "Running…" : "Run test") { runTest() }.disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                }
                if !testOutput.isEmpty {
                    Text(testOutput).textSelection(.enabled).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshPath)
        .onChange(of: s.provider) { _, _ in refreshPath() }
        .onChange(of: s.claudePath) { _, _ in refreshPath() }
        .onChange(of: s.codexPath) { _, _ in refreshPath() }
    }

    private func refreshPath() {
        let p = s.provider, o = p == .claude ? s.claudePath : s.codexPath
        DispatchQueue.global().async {
            let path = Enhancer.locate(p, override: o) ?? ""
            DispatchQueue.main.async { cliPath = path }
        }
    }

    private func runTest() {
        testing = true; testOutput = ""
        let start = Date()
        Task {
            do {
                let out = try await Enhancer.enhance(testInput, settings: s)
                testOutput = out + String(format: "\n\n— %.1fs with %@", Date().timeIntervalSince(start), s.effectiveModel)
            } catch {
                testOutput = "⚠️ " + error.localizedDescription
            }
            testing = false
        }
    }
}

// MARK: - History

struct HistoryView: View {
    @ObservedObject var store = MetricsStore.shared
    @ObservedObject var profiles = ProfileStore.shared
    @State private var confirmClear = false
    @State private var editing: DictationRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(profiles.active.name)’s history").font(.largeTitle.bold())
                Spacer()
                Button("Clear…", role: .destructive) { confirmClear = true }.disabled(store.records.isEmpty)
            }
            .padding([.horizontal, .top], 24).padding(.bottom, 8)

            if store.records.isEmpty {
                ContentUnavailableView("No dictations yet", systemImage: "mic", description: Text("Hold fn and start talking."))
            } else {
                List(store.records) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(r.date.formatted(date: .abbreviated, time: .shortened))
                            Text("· \(r.app) · \(r.words) words · \(fmtDuration(r.duration))")
                            if let l = r.localeID, !l.isEmpty { Text("· \(Locale(identifier: l).language.languageCode?.identifier.uppercased() ?? l)") }
                            if r.enhanced { Image(systemName: "sparkles").foregroundStyle(.purple) }
                            if r.corrected == true { Image(systemName: "brain.head.profile").foregroundStyle(.green).help("Corrected — NVoice learned from it") }
                            Spacer()
                            Button { editing = r } label: { Label("Fix", systemImage: "pencil") }.buttonStyle(.borderless)
                                .help("Correct this dictation so NVoice learns")
                            Button { copy(r.text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        Text(r.text).textSelection(.enabled).lineLimit(6)
                        if let raw = r.rawText, r.enhanced {
                            DisclosureGroup("Original transcript") { Text(raw).textSelection(.enabled).foregroundStyle(.secondary) }
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .sheet(item: $editing) { r in CorrectionView(record: r) { editing = nil } }
        .confirmationDialog("Delete \(profiles.active.name)’s dictation history and metrics?", isPresented: $confirmClear) {
            Button("Delete all", role: .destructive) { store.clear() }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
