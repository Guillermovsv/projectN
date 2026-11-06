import AppKit
import SwiftUI

/// Settings › Voice (NVoice): turns the built-in dictation on/off and hosts NVoice's own settings pages.
struct VoiceSettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case general = "General", ai = "AI", people = "People & Words", history = "History", metrics = "Metrics"
        var id: String { rawValue }
    }

    @EnvironmentObject var store: Store
    @ObservedObject private var voice = NVoiceController.shared
    @State private var section: Section = .general
    @State private var standaloneRunning = NVoiceController.shared.standaloneRunning
    @State private var canPaste = HotkeyMonitor.hasAccessibility(prompt: false)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch section {
                case .general: GeneralSettingsView()
                case .ai: AISettingsView()
                case .people: PeopleView()
                case .history: HistoryView()
                case .metrics: MetricsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(8)
        .onReceive(NotificationCenter.default.publisher(for: .nvoiceShowGeneral)) { _ in section = .general }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            standaloneRunning = voice.standaloneRunning
            canPaste = HotkeyMonitor.hasAccessibility(prompt: false)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "waveform")
                    .font(.title3)
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.appAccent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(isOn: $store.settings.voiceEnabled) {
                        Text("Dictation — hold fn anywhere, talk, release to paste").font(.headline)
                    }
                    .toggleStyle(.switch)
                    statusLine
                }
                Spacer()
            }
            Toggle("Show NVoice icon in the menu bar (person, language, mic, correct last dictation)", isOn: $store.settings.voiceMenuBarIcon)
                .disabled(!store.settings.voiceEnabled)
            if standaloneRunning && voice.state != .blockedByStandalone {
                Label("The NVoice app is open too. ProjectN handles dictation now, so you can quit it.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    @ViewBuilder private var statusLine: some View {
        switch voice.state {
        case .off:
            dot(.secondary, "Off — the fn key does nothing in ProjectN")
        case .running where !canPaste:
            HStack(spacing: 8) {
                dot(.orange, "Hears fn, but can't paste — Accessibility not allowed for ProjectN")
                Button("Grant…") {
                    _ = HotkeyMonitor.hasAccessibility(prompt: true)
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }.controlSize(.small)
            }
        case .running:
            dot(.green, "Listening for fn — works in every app while ProjectN is open")
        case .waitingForPermission:
            HStack(spacing: 8) {
                dot(.orange, "Waiting for Input Monitoring permission")
                Button("Grant…") { voice.openPermissions() }.controlSize(.small)
            }
        case .blockedByStandalone:
            HStack(spacing: 8) {
                dot(.orange, "The NVoice app is running and already owns the fn key")
                Button("Quit NVoice App & Use ProjectN") { voice.quitStandaloneAndTakeOver() }.controlSize(.small)
            }
        }
    }

    private func dot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
