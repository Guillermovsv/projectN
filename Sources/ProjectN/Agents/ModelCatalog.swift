import Foundation

/// The models (and the efforts each supports) that a runtime can actually use right now.
///
/// - Claude Code: `GET /v1/models` with the login Claude Code keeps in the Keychain (same credential and host
///   as the usage meter: only sent to api.anthropic.com). Each model reports which effort levels it supports.
///   Cached in ~/.projectn/agents/claude-models.json; the built-in catalog is only a fallback when offline.
/// - Codex CLI: Codex's own `models_cache.json` (slug + supported reasoning levels), already used by panes.
@MainActor
final class ModelCatalog: ObservableObject {
    struct Model: Codable, Hashable, Identifiable {
        var id: String
        var label: String
        /// Supported effort levels, low → high. Empty = the model has no effort setting.
        var efforts: [String]
    }

    enum Source: String, Codable { case live, cache, builtIn, codexCache, none }

    struct Listing: Codable {
        var models: [Model]
        var source: Source
        var fetchedAt: Date?
        var error: String?
    }

    static let shared = ModelCatalog()

    @Published private(set) var claude = Listing(models: [], source: .none)
    @Published private(set) var refreshing = false

    private var cacheURL: URL { AgentStore.dir.appendingPathComponent("claude-models.json") }

    init() {
        if let cached = AppHome.load(Listing.self, from: cacheURL), !cached.models.isEmpty {
            claude = Listing(models: cached.models, source: .cache, fetchedAt: cached.fetchedAt)
        } else {
            claude = Self.builtInClaude()
        }
    }

    func listing(for runtime: AgentRuntime, settings: AppSettings) -> Listing {
        switch runtime {
        case .claudeCode: return claude
        case .codexCLI:
            let models = LaunchCatalog.codexModels(settings: settings).map {
                Model(id: $0.slug, label: $0.slug, efforts: $0.efforts)
            }
            return Listing(models: models, source: models.isEmpty ? .none : .codexCache,
                           error: models.isEmpty ? "Codex hasn't cached its model list yet. Open a Codex pane once." : nil)
        }
    }

    func model(_ id: String, runtime: AgentRuntime, settings: AppSettings) -> Model? {
        let id = runtime == .claudeCode ? LaunchCatalog.normalizeClaudeModel(id) : id
        return listing(for: runtime, settings: settings).models.first { $0.id == id }
    }

    /// Replaces the Claude listing (tests, or a list obtained elsewhere).
    func setClaudeListing(_ listing: Listing) { claude = listing }

    /// Refreshes the Claude list from the API (no-op if one is in flight).
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let result = await Self.fetchClaude()
            switch result {
            case .success(let models):
                claude = Listing(models: models, source: .live, fetchedAt: Date())
                AppHome.save(claude, to: cacheURL)
            case .failure(let e):
                claude.error = e.message
            }
            refreshing = false
        }
    }

    private static func builtInClaude() -> Listing {
        let models = LaunchCatalog.claudeModels.map { Model(id: $0.value, label: $0.label, efforts: LaunchCatalog.claudeEfforts) }
        return Listing(models: models, source: .builtIn, error: "Using the built-in list until the live list loads.")
    }

    struct FetchError: Error { let message: String }

    nonisolated static func fetchClaude() async -> Result<[Model], FetchError> {
        guard let token = UsageModel.claudeAccessToken() else {
            return .failure(FetchError(message: "Not signed in to Claude Code"))
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("ProjectN", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { return .failure(FetchError(message: "Model list: HTTP \(code)")) }
            let models = parseClaudeModels(data)
            return models.isEmpty ? .failure(FetchError(message: "Model list was empty")) : .success(models)
        } catch {
            return .failure(FetchError(message: error.localizedDescription))
        }
    }

    /// `{"data":[{"id","display_name","capabilities":{"effort":{"supported":true,"low":{"supported":true},…}}}]}`
    nonisolated static func parseClaudeModels(_ data: Data) -> [Model] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            let effort = (m["capabilities"] as? [String: Any])?["effort"] as? [String: Any]
            var efforts: [String] = []
            if (effort?["supported"] as? Bool) == true {
                efforts = LaunchCatalog.claudeEfforts.filter { ((effort?[$0] as? [String: Any])?["supported"] as? Bool) == true }
            }
            let label = (m["display_name"] as? String) ?? LaunchCatalog.claudeModels.first { $0.value == id }?.label ?? id
            return Model(id: id, label: label, efforts: efforts)
        }
    }
}

/// Outcome of validating a profile's model/effort right before a launch.
struct ModelResolution: Equatable {
    var model: String
    var effort: String?
    var notes: [String] = []
}

extension ModelCatalog {
    /// Validates provider/runtime/model/effort. An unsupported effort is dropped with a note
    /// ("High, when the model supports it"); an unknown model is an error unless the list is only a fallback.
    func resolve(_ profile: AgentProfile, settings: AppSettings) -> Result<ModelResolution, AgentHarnessError> {
        guard profile.runtime.providers.contains(profile.provider) else {
            return .failure(.invalidRuntime("\(profile.runtime.label) can't use provider \(profile.provider.label)."))
        }
        let listing = self.listing(for: profile.runtime, settings: settings)
        let requested = profile.runtime == .claudeCode ? LaunchCatalog.normalizeClaudeModel(profile.model) : profile.model
        guard !requested.isEmpty else { return .failure(.modelUnavailable(model: "(none)", available: listing.models.map(\.id))) }
        var res = ModelResolution(model: requested, effort: profile.effort)
        if profile.provider == .other {
            // A compatible endpoint configured in the CLI itself: its models aren't in the vendor's list.
            res.notes.append("Model \(requested) is served by a custom provider and wasn't verified.")
            return .success(res)
        }
        if let m = listing.models.first(where: { $0.id == requested }) {
            if let e = profile.effort, !m.efforts.contains(e) {
                res.effort = nil
                res.notes.append(m.efforts.isEmpty ? "\(m.label) has no effort setting; using its default."
                                                   : "\(m.label) doesn't support effort “\(e)”; using its default.")
            }
        } else if listing.source == .live || listing.source == .cache || listing.source == .codexCache {
            // An authoritative list exists and doesn't contain it.
            return .failure(.modelUnavailable(model: requested, available: listing.models.map(\.id)))
        } else if profile.provider != .other {
            // Only the built-in fallback is known (offline): let the CLI decide, but say so.
            res.notes.append("Couldn't verify \(requested) against the live model list.")
        }
        return .success(res)
    }
}
