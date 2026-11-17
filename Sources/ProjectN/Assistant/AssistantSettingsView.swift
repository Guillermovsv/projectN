import AVFoundation
import SwiftUI

/// Settings › Assistant.
struct AssistantSettingsView: View {
    @EnvironmentObject var assistant: AssistantController

    var body: some View {
        Form {
            Section("Listening") {
                Toggle("Wake with “Hey N”", isOn: $assistant.wakeWordEnabled)
                if assistant.wakeWordEnabled {
                    Text(assistant.wakeWordStatus).font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Your “Hey N”") {
                        HStack {
                            Text("\(assistant.wakeSampleCount) of \(AssistantController.wakeSamplesNeeded) recordings")
                                .monospacedDigit().foregroundStyle(.secondary)
                            Button(assistant.recordingWakeSample ? "Listening…" : "Record") { assistant.recordWakeSample() }
                                .disabled(assistant.recordingWakeSample)
                            if assistant.wakeSampleCount > 0 {
                                Button("Clear") { assistant.clearWakeSamples() }.disabled(assistant.recordingWakeSample)
                            }
                        }
                    }
                    if !assistant.wakeSampleMessage.isEmpty {
                        Text(assistant.wakeSampleMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Sensitivity", selection: $assistant.wakeSensitivity) {
                        Text("Low").tag(WakeWordDetector.Sensitivity.low)
                        Text("Normal").tag(WakeWordDetector.Sensitivity.normal)
                        Text("High").tag(WakeWordDetector.Sensitivity.high)
                    }
                }
                Text("Say “Hey N”, then your request, even when the Assistant is closed. Record yourself saying “Hey N” at least 3 times, the way you normally would. The microphone stays open while ProjectN is open, but it only compares sound with your recordings — nothing is transcribed. When something sounds like “Hey N”, a few seconds are transcribed on this Mac to confirm it; otherwise they're dropped. Nothing is sent anywhere or saved except your recordings. If it wakes when it shouldn't, lower the sensitivity; if it misses you, raise it or add recordings. Pauses during dictation and spoken replies.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Listen as soon as the Assistant opens", isOn: $assistant.autoListen)
                Toggle("Conversation mode — keep listening after each answer", isOn: $assistant.handsFree)
                Toggle("Interrupt by talking — talk over an answer and it stops to listen", isOn: $assistant.bargeIn)
                LabeledContent("Pause that ends your turn") {
                    HStack {
                        Slider(value: $assistant.silenceSeconds, in: 0.5...2, step: 0.1).frame(width: 200)
                        Text(String(format: "%.1f s", assistant.silenceSeconds)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text("Shorter answers faster; longer gives you time to think mid-sentence. It also waits a little longer when you trail off (“…y”, “…and”) and less after a finished sentence. While you talk, what it hears appears as you speak; click the orb to send it right away. The microphone stays on for the whole conversation, even while it answers: talk over it and it lowers its voice at once, then stops and listens once it's sure it's you (or say “stop”, “espera”). It knows what it is saying, so its own voice from the speakers doesn't count; headphones make it even more reliable. If you go on talking right after it thought you'd finished, it waits for the rest. Say “gracias” or “eso es todo”, click the orb, or stay quiet to end the conversation; the microphone then turns off. Pressing your dictation key (fn) always takes the microphone. Uses NVoice's languages, microphone, dictionary and corrections.")
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
                Text("Most natural: Siri voices, then Premium. Download them in System Settings › Accessibility › Spoken Content › System voice › Manage Voices…, then Refresh. Compact voices sound robotic.")
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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker(title, selection: Binding(get: { selection.wrappedValue },
                                                 set: { selection.wrappedValue = $0; assistant.preview(lang) })) {
                    Text("Most natural installed" + (assistant.availableVoices(lang).first.map { " — \(AssistantController.displayName($0))" } ?? ""))
                        .tag("")
                    ForEach(assistant.availableVoices(lang), id: \.identifier) { v in
                        Text(AssistantView.voiceLabel(v)).tag(v.identifier)
                    }
                }
                Button { assistant.preview(lang) } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.borderless)
                    .help("Preview")
            }
            if assistant.onlyBasicVoices(lang) {
                Text("Only basic \(title) voices are installed, so it will sound robotic. Download a Siri or Premium \(title) voice (button below), then Refresh.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
