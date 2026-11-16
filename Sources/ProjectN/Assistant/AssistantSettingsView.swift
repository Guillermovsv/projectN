import AVFoundation
import SwiftUI

/// Settings › Assistant.
struct AssistantSettingsView: View {
    @EnvironmentObject var assistant: AssistantController

    var body: some View {
        Form {
            Section("Listening") {
                Toggle("Listen as soon as the Assistant opens", isOn: $assistant.autoListen)
                Toggle("Conversation mode — keep listening after each answer", isOn: $assistant.handsFree)
                LabeledContent("Pause that ends your turn") {
                    HStack {
                        Slider(value: $assistant.silenceSeconds, in: 0.5...2, step: 0.1).frame(width: 200)
                        Text(String(format: "%.1f s", assistant.silenceSeconds)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text("Shorter answers faster; longer gives you time to think mid-sentence. Click the orb (or ⌥⌘A) to stop at any time. Say “gracias” or “eso es todo” to end the conversation. Uses NVoice's languages and microphone.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Voice") {
                Toggle("Speak replies", isOn: $assistant.speakReplies)
                voicePicker("Spanish", lang: .es, selection: $assistant.voiceES)
                voicePicker("English", lang: .en, selection: $assistant.voiceEN)
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: $assistant.speechSpeed, in: 0.8...1.3, step: 0.05).frame(width: 200)
                        Text(String(format: "%.2f×", assistant.speechSpeed)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Get more natural voices…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Refresh list") { assistant.refreshVoices(); assistant.objectWillChange.send() }
                }
                Text("Most natural: Siri voices, then Premium. Download them in System Settings › Accessibility › Spoken Content › System voice › Manage Voices…, then Refresh.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("AI") {
                Toggle("Use AI for anything the built-in commands don't cover", isOn: $assistant.useAI)
                Picker("Provider", selection: $assistant.aiProvider) {
                    ForEach(AIProvider.allCases) { Text($0.label).tag($0) }
                }
                Picker("Model", selection: $assistant.aiModel) {
                    ForEach(assistant.aiProvider.models, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Keep the AI ready while the Assistant is in use (faster)", isOn: $assistant.keepWarm)
                    .disabled(assistant.aiProvider != .claude)
                Text(assistant.aiProvider == .claude
                     ? "Claude Haiku answers fastest. Keeping it ready saves ~3 s per answer; it closes after 5 idle minutes."
                     : "Codex can't stream or stay ready, so answers take noticeably longer. Claude Haiku is recommended.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Enhance requests before sending them to agents", isOn: $assistant.enhanceRequests)
                Toggle("Summarize agent results with AI before reading them", isOn: $assistant.aiSummaries)
            }
        }
        .formStyle(.grouped)
    }

    private func voicePicker(_ title: String, lang: AssistantLang, selection: Binding<String>) -> some View {
        HStack {
            Picker(title, selection: Binding(get: { selection.wrappedValue },
                                             set: { selection.wrappedValue = $0; assistant.preview(lang) })) {
                Text("Most natural installed").tag("")
                ForEach(assistant.availableVoices(lang), id: \.identifier) { v in
                    Text(AssistantView.voiceLabel(v)).tag(v.identifier)
                }
            }
            Button { assistant.preview(lang) } label: { Image(systemName: "play.circle") }
                .buttonStyle(.borderless)
                .help("Preview")
        }
    }
}
