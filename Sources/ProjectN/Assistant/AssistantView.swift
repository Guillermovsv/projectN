import AVFoundation
import SwiftUI

/// The Assistant: the orb (click to talk), the conversation, and a field to type instead. Shown in the right panel or,
/// with `floating`, in its own window that stays above everything.
struct AssistantView: View {
    @EnvironmentObject var assistant: AssistantController
    @EnvironmentObject var nav: NavigationModel
    @EnvironmentObject var panel: RightPanelModel
    /// In the floating window (it draws its own title bar).
    var inWindow = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            AssistantOrbButton(orb: assistant.orb, size: inWindow ? 64 : 80, showCaption: true) { assistant.toggleListening() }
                .padding(.top, inWindow ? 0 : 4)
                .padding(.bottom, 18)
            Divider().opacity(0.5)
            conversation
            inputBar
        }
        .background(inWindow ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.appWindow))
        .onAppear { assistant.opened() }
        .onDisappear { assistant.closed() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            if inWindow {
                Text("Assistant").font(.system(size: 12, weight: .semibold))
                    .padding(.leading, 58)   // clear of the close button
            }
            AssistantStatusPill(orb: assistant.orb, ai: assistant.useAI)
            Spacer(minLength: 4)
            iconToggle(assistant.speakReplies ? "speaker.wave.2.fill" : "speaker.slash",
                       on: assistant.speakReplies, help: assistant.speakReplies ? "Replies are spoken — click to mute" : "Replies are muted — click to speak them") {
                assistant.speakReplies.toggle()
                if !assistant.speakReplies { assistant.stopSpeaking() }
            }
            iconToggle(assistant.handsFree ? "infinity.circle.fill" : "infinity.circle",
                       on: assistant.handsFree, help: "Conversation mode: keeps listening after each answer") {
                assistant.handsFree.toggle()
            }
            iconToggle(inWindow ? "sidebar.right" : "macwindow.on.rectangle", on: false,
                       help: inWindow ? "Dock in the side panel" : "Float in its own window (stays on top)") {
                FloatingAssistant.shared.setFloating(!inWindow)
            }
            optionsMenu
        }
        .padding(.horizontal, 10)
        .frame(height: inWindow ? 34 : 36)
    }

    private func iconToggle(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? Color.appAccent : Color.secondary)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(inset: 0)
        .help(help)
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Listen as soon as it opens", isOn: $assistant.autoListen)
            Toggle("Conversation mode (keeps listening)", isOn: $assistant.handsFree)
            Toggle("Speak replies", isOn: $assistant.speakReplies)
            Toggle("Use AI for anything else", isOn: $assistant.useAI)
            Divider()
            Toggle("Floating window", isOn: Binding(get: { assistant.floating },
                                                    set: { FloatingAssistant.shared.setFloating($0) }))
            Divider()
            Button("Clear conversation") { assistant.clear() }
            Button("Assistant Settings…") { nav.openSettings(.assistant, panel: panel) }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 13))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Assistant options")
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if assistant.log.isEmpty { emptyState }
                    ForEach(assistant.log) { e in
                        bubble(e).id(e.id)
                    }
                    AssistantThinkingRow(orb: assistant.orb, waiting: assistant.log.last?.fromUser == true)
                        .id("thinking")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .onChange(of: assistant.log.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: assistant.log.last?.text) { _, _ in
                guard let id = assistant.log.last?.id else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text(Self.spanish ? "Habla cuando quieras: responde cuando haces una pausa. También puedes escribir. (⌥⌘A)"
                              : "Just talk — it answers when you pause. Or type below. (⌥⌘A)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ForEach(Self.suggestions, id: \.self) { s in
                    Button { assistant.handle(s) } label: {
                        Text(s)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.primary.opacity(0.05)))
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.09)))
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    private static let spanish = Locale.preferredLanguages.first?.hasPrefix("es") == true

    private static var suggestions: [String] {
        spanish
            ? ["¿Qué está corriendo?", "Abre 3 Claude en Opus 5.5 low", "Nueva terminal y ejecuta git status", "Diles a todos que corran los tests"]
            : ["What's running?", "Open 3 Claude on Opus 5.5 low", "New terminal and run git status", "Tell all of them to run the tests"]
    }

    private func bubble(_ e: AssistantController.Entry) -> some View {
        HStack(alignment: .bottom, spacing: 7) {
            if e.fromUser {
                Spacer(minLength: 36)
            } else {
                Circle()
                    .fill(LinearGradient(colors: [Color.appAccent, Color.appAccent.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 18, height: 18)
                    .overlay(Image(systemName: "sparkles").font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
            }
            Text(e.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .foregroundStyle(e.fromUser ? Color.white : Color.primary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 13, bottomLeadingRadius: e.fromUser ? 13 : 4,
                                           bottomTrailingRadius: e.fromUser ? 4 : 13, topTrailingRadius: 13)
                        .fill(e.fromUser ? AnyShapeStyle(Color.appAccent) : AnyShapeStyle(Color.primary.opacity(0.07)))
                )
            if !e.fromUser { Spacer(minLength: 36) }
        }
        .frame(maxWidth: .infinity, alignment: e.fromUser ? .trailing : .leading)
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button { assistant.toggleListening() } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.appAccent.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .handCursor()
            .help("Talk (⌥⌘A)")
            TextField(Self.spanish ? "Pídele algo a ProjectN…" : "Ask ProjectN…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...5)
                .focused($fieldFocused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(draft.isEmpty ? Color.secondary.opacity(0.35) : Color.appAccent))
            }
            .buttonStyle(.plain)
            .disabled(draft.isEmpty)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(fieldFocused ? Color.appAccent.opacity(0.6) : Color.primary.opacity(0.1)))
        .padding(10)
    }

    static func voiceLabel(_ v: AVSpeechSynthesisVoice) -> String {
        let id = v.identifier.lowercased()
        let kind = id.contains("siri") ? "Siri, natural"
            : v.quality == .premium ? "Premium" : v.quality == .enhanced ? "Enhanced"
            : id.contains("eloquence") || id.contains("speech.synthesis") ? "robotic" : "basic"
        return "\(v.name) (\(v.language), \(kind))"
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !t.isEmpty else { return }
        assistant.handle(t)
    }
}

/// What the Assistant is doing, as a small coloured pill. Watches only the orb.
private struct AssistantStatusPill: View {
    @ObservedObject var orb: AssistantOrbModel
    let ai: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 11, weight: .medium))
            if ai && orb.phase == .idle {
                Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(.secondary)
                    .help("Anything the built-in commands don't cover goes to the AI")
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private var label: String {
        switch orb.phase {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        }
    }

    private var color: Color {
        switch orb.phase {
        case .idle: return .secondary
        case .listening: return Color(red: 0.2, green: 0.7, blue: 1)
        case .thinking: return Color(red: 0.65, green: 0.45, blue: 1)
        case .speaking: return Color(red: 0.2, green: 0.8, blue: 0.6)
        }
    }
}

/// Three bouncing dots while an answer is on its way.
private struct AssistantThinkingRow: View {
    @ObservedObject var orb: AssistantOrbModel
    let waiting: Bool

    var body: some View {
        if orb.phase == .thinking && waiting {
            TimelineView(.animation(minimumInterval: 1 / 20)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                HStack(spacing: 4) {
                    ForEach(0..<3) { i in
                        Circle().fill(Color.secondary)
                            .frame(width: 5, height: 5)
                            .opacity(0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.8)))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .padding(.leading, 25)
            }
        }
    }
}

/// The orb: still and cheap while idle, breathes while thinking, follows your voice while listening and the words
/// while speaking. It only animates (and redraws) when it isn't idle.
struct AssistantOrbButton: View {
    @ObservedObject var orb: AssistantOrbModel
    var size: CGFloat = 112
    var showCaption = true
    let action: () -> Void
    @State private var hover = false

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
            if showCaption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .offset(y: 12)
            }
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
                    .font(.system(size: size * 0.23, weight: .medium))
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
        case .listening: return "Listening… click to stop"
        case .thinking: return "Thinking… click to stop"
        case .speaking: return "Speaking… click to stop"
        }
    }

    private var help: String { orb.phase == .idle ? "Talk to the assistant" : "Stop" }
}
