import Foundation
import SwiftUI

enum AIProvider: String, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var label: String { self == .claude ? "Claude (subscription via Claude Code)" : "Codex (ChatGPT subscription via Codex CLI)" }
    var binaryName: String { rawValue }
    var models: [String] {
        switch self {
        case .claude: return ["haiku", "sonnet", "opus", "claude-fable-5-1"]
        case .codex: return AIProvider.codexModelsFromCache() ?? ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-luna"]
        }
    }

    /// Codex CLI keeps the list of models available to your ChatGPT plan in ~/.codex/models_cache.json.
    static func codexModelsFromCache() -> [String]? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return nil }
        let slugs = models
            .filter { ($0["visibility"] as? String) == "list" }
            .sorted { ($0["priority"] as? Int ?? 99) < ($1["priority"] as? Int ?? 99) }
            .compactMap { $0["slug"] as? String }
        return slugs.isEmpty ? nil : slugs
    }
}

enum HotkeyMode: String, CaseIterable, Identifiable {
    case hold, toggle
    var id: String { rawValue }
    var label: String { self == .hold ? "Hold fn to talk" : "Tap fn to start / stop" }
}

enum WidgetPosition: String, CaseIterable, Identifiable {
    case bottom, top
    var id: String { rawValue }
    var label: String { self == .bottom ? "Bottom center" : "Top center" }
}

let defaultEnhancePrompt = """
You rewrite dictated speech into a clear, well-structured prompt for an AI assistant.
Keep the speaker's intent, language, facts and constraints. Remove filler words, false starts and repetition.
Organize into short paragraphs or bullet points when it helps. Add missing context only when it is clearly implied.
Return ONLY the improved prompt text — no preamble, no quotes, no explanations.
"""

final class NVoiceSettings: ObservableObject {
    static let shared = NVoiceSettings()
    private let d = NVoiceDefaults.store

    @Published var provider: AIProvider { didSet { d.set(provider.rawValue, forKey: "provider"); if !provider.models.contains(model) { model = provider.models[0] } } }
    @Published var model: String { didSet { d.set(model, forKey: "model") } }
    @Published var customModel: String { didSet { d.set(customModel, forKey: "customModel") } }
    @Published var enhanceEnabled: Bool { didSet { d.set(enhanceEnabled, forKey: "enhanceEnabled") } }
    @Published var enhancePrompt: String { didSet { d.set(enhancePrompt, forKey: "enhancePrompt") } }
    @Published var hotkeyMode: HotkeyMode { didSet { d.set(hotkeyMode.rawValue, forKey: "hotkeyMode") } }
    @Published var playSounds: Bool { didSet { d.set(playSounds, forKey: "playSounds") } }
    @Published var showWidget: Bool { didSet { d.set(showWidget, forKey: "showWidget") } }
    @Published var widgetPosition: WidgetPosition { didSet { d.set(widgetPosition.rawValue, forKey: "widgetPosition") } }
    @Published var restoreClipboard: Bool { didSet { d.set(restoreClipboard, forKey: "restoreClipboard") } }
    /// Turn other audio down while dictating, to this fraction of its volume.
    @Published var duckAudio: Bool { didSet { d.set(duckAudio, forKey: "duckAudio") } }
    @Published var duckLevel: Double { didSet { d.set(duckLevel, forKey: "duckLevel") } }
    /// "auto" (built-in mic when the default is Bluetooth), "system", or a device UID.
    @Published var microphone: String { didSet { d.set(microphone, forKey: "microphone") } }
    @Published var claudePath: String { didSet { d.set(claudePath, forKey: "claudePath") } }
    @Published var codexPath: String { didSet { d.set(codexPath, forKey: "codexPath") } }

    /// The model actually sent to the CLI (custom overrides the picker).
    var effectiveModel: String {
        let c = customModel.trimmingCharacters(in: .whitespaces)
        return c.isEmpty ? model : c
    }

    private init() {
        provider = AIProvider(rawValue: d.string(forKey: "provider") ?? "") ?? .claude
        let p = AIProvider(rawValue: d.string(forKey: "provider") ?? "") ?? .claude
        model = d.string(forKey: "model") ?? p.models[0]
        customModel = d.string(forKey: "customModel") ?? ""
        enhanceEnabled = d.object(forKey: "enhanceEnabled") as? Bool ?? false
        enhancePrompt = d.string(forKey: "enhancePrompt") ?? defaultEnhancePrompt
        hotkeyMode = HotkeyMode(rawValue: d.string(forKey: "hotkeyMode") ?? "") ?? .hold
        playSounds = d.object(forKey: "playSounds") as? Bool ?? true
        showWidget = d.object(forKey: "showWidget") as? Bool ?? true
        widgetPosition = WidgetPosition(rawValue: d.string(forKey: "widgetPosition") ?? "") ?? .bottom
        restoreClipboard = d.object(forKey: "restoreClipboard") as? Bool ?? true
        duckAudio = d.object(forKey: "duckAudio") as? Bool ?? true
        duckLevel = d.object(forKey: "duckLevel") as? Double ?? 0.2
        microphone = d.string(forKey: "microphone") ?? AudioDevices.automatic
        claudePath = d.string(forKey: "claudePath") ?? ""
        codexPath = d.string(forKey: "codexPath") ?? ""
    }
}
