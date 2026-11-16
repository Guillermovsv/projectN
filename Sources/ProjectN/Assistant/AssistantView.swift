import SwiftUI

/// Right panel › Assistant: the orb (click to talk), the conversation, and a field to type instead.
struct AssistantView: View {
    @EnvironmentObject var assistant: AssistantController
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            AssistantOrbButton(orb: assistant.orb) { assistant.toggleListening() }
                .padding(.top, 22)
                .padding(.bottom, 10)
            conversation
            Divider()
            inputBar
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if assistant.log.isEmpty {
                        Text("Click the orb and talk, or type below.\nTry “open web shop”, “new Claude”, “what's running?” or “Developer, fix the login”.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                    }
                    ForEach(assistant.log) { e in
                        bubble(e).id(e.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: assistant.log.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private func bubble(_ e: AssistantController.Entry) -> some View {
        HStack {
            if e.fromUser { Spacer(minLength: 30) }
            Text(e.text)
                .font(.callout)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(e.fromUser ? Color.appAccent.opacity(0.18) : Color.primary.opacity(0.06)))
            if !e.fromUser { Spacer(minLength: 30) }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            TextField("Ask ProjectN…", text: $draft)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit(send)
            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 18)) }
                .buttonStyle(.plain)
                .foregroundStyle(draft.isEmpty ? Color.secondary : Color.appAccent)
                .disabled(draft.isEmpty)
            optionsMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Speak replies", isOn: $assistant.speakReplies)
            Toggle("Use AI for anything else", isOn: $assistant.useAI)
            Toggle("Enhance requests to agents", isOn: $assistant.enhanceRequests)
            Toggle("AI summaries of agent results", isOn: $assistant.aiSummaries)
            Divider()
            Text("AI: NVoice's provider and model (Settings › Voice)")
            Button("Clear conversation") { assistant.clear() }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Assistant options")
    }

    private func send() {
        let t = draft
        draft = ""
        assistant.handle(t)
    }
}

/// The orb: still and cheap while idle, breathes while thinking, follows your voice while listening and the words
/// while speaking. It only animates (and redraws) when it isn't idle.
struct AssistantOrbButton: View {
    @ObservedObject var orb: AssistantOrbModel
    let action: () -> Void
    @State private var hover = false
    private let size: CGFloat = 112

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: orb.phase == .idle)) { ctx in
                orbBody(time: ctx.date)
            }
            .frame(width: size * 1.6, height: size * 1.6)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .handCursor()
        .help(help)
        .accessibilityLabel(help)
        .overlay(alignment: .bottom) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .offset(y: 10)
        }
    }

    private func orbBody(time: Date) -> some View {
        let t = time.timeIntervalSinceReferenceDate
        let energy = currentEnergy(t: time)
        let scale = 1 + 0.18 * energy + (orb.phase == .idle && hover ? 0.03 : 0)
        let (a, b) = colors
        return ZStack {
            // Glow
            Circle()
                .fill(RadialGradient(colors: [a.opacity(0.55 * (0.35 + energy)), .clear],
                                     center: .center, startRadius: size * 0.2, endRadius: size * 0.8))
                .scaleEffect(1 + 0.35 * energy)
            // Core
            Circle()
                .fill(AngularGradient(colors: [a, b, a], center: .center,
                                      angle: .degrees(orb.phase == .idle ? 0 : (t * spin).truncatingRemainder(dividingBy: 360))))
                .overlay(Circle().fill(RadialGradient(colors: [.white.opacity(0.45), .clear],
                                                      center: UnitPoint(x: 0.35, y: 0.3),
                                                      startRadius: 0, endRadius: size * 0.45)))
                .frame(width: size, height: size)
                .scaleEffect(scale)
                .shadow(color: a.opacity(0.5 * energy), radius: 18)
            if orb.phase == .idle {
                Image(systemName: "mic.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .drawingGroup()
    }

    /// 0…1. Listening/speaking: the last level decaying; thinking: a slow breath.
    private func currentEnergy(t: Date) -> Double {
        switch orb.phase {
        case .idle: return hover ? 0.15 : 0.05
        case .thinking: return 0.25 + 0.2 * sin(t.timeIntervalSinceReferenceDate * 3)
        case .listening, .speaking:
            let age = t.timeIntervalSince(orb.levelAt)
            let decayed = Double(orb.level) * exp(-age * (orb.phase == .speaking ? 4 : 8))
            let floor = orb.phase == .speaking ? 0.2 + 0.08 * sin(t.timeIntervalSinceReferenceDate * 6) : 0.12
            return min(1, max(floor, decayed * 1.4))
        }
    }

    private var spin: Double {
        switch orb.phase {
        case .thinking: return 160
        case .speaking: return 70
        default: return 40
        }
    }

    private var colors: (Color, Color) {
        switch orb.phase {
        case .idle: return (Color.appAccent.opacity(0.75), Color.appAccent.opacity(0.45))
        case .listening: return (Color(red: 0.2, green: 0.75, blue: 1), Color(red: 0.35, green: 0.4, blue: 1))
        case .thinking: return (Color(red: 0.6, green: 0.4, blue: 1), Color(red: 0.95, green: 0.4, blue: 0.8))
        case .speaking: return (Color(red: 0.25, green: 0.9, blue: 0.7), Color(red: 0.2, green: 0.6, blue: 1))
        }
    }

    private var caption: String {
        switch orb.phase {
        case .idle: return "Click to talk"
        case .listening: return "Listening… click when done"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking — click to interrupt"
        }
    }

    private var help: String { orb.phase == .listening ? "Stop listening" : "Talk to the assistant" }
}
