import Foundation

/// Slack Web API calls with the bot token (xoxb-…). Tokens are only sent to slack.com.
struct SlackAPI {
    let token: String

    struct APIError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://slack.com/api/\(method)")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: params)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 {
            let wait = Double((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
            try await Task.sleep(for: .seconds(min(wait, 30)))
            return try await call(method, params)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(message: "\(method): HTTP \(code)")
        }
        guard obj["ok"] as? Bool == true else {
            throw APIError(message: "\(method): \(obj["error"] as? String ?? "HTTP \(code)")")
        }
        return obj
    }

    /// Posts a message; returns its ts (needed to update it later).
    @discardableResult
    func post(channel: String, threadTS: String?, text: String, blocks: [[String: Any]]? = nil) async throws -> String? {
        var p: [String: Any] = ["channel": channel, "text": text, "unfurl_links": false, "unfurl_media": false]
        if let threadTS { p["thread_ts"] = threadTS }
        if let blocks { p["blocks"] = blocks }
        return try await call("chat.postMessage", p)["ts"] as? String
    }

    func update(channel: String, ts: String, text: String, blocks: [[String: Any]] = []) async throws {
        _ = try await call("chat.update", ["channel": channel, "ts": ts, "text": text, "blocks": blocks])
    }

    /// The bot token's scopes (Slack returns them in the X-OAuth-Scopes header of any call).
    func scopes() async throws -> (team: String, user: String, scopes: [String]) {
        var req = URLRequest(url: URL(string: "https://slack.com/api/auth.test")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard obj["ok"] as? Bool == true else { throw APIError(message: "auth.test: \(obj["error"] as? String ?? "failed")") }
        let header = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-oauth-scopes") ?? ""
        return (obj["team"] as? String ?? "", obj["user"] as? String ?? "",
                header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }
}

/// Socket Mode: an outbound WebSocket from this Mac to Slack, so no public server or open port is needed.
/// `apps.connections.open` (app-level token xapp-…, scope connections:write) returns a wss URL; every
/// envelope is acknowledged immediately with its envelope_id, then handed to `onEvent`.
@MainActor
final class SlackSocketClient: NSObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    var onState: ((State) -> Void)?
    /// (envelope type, payload, retry attempt)
    var onEnvelope: ((String, [String: Any], Int) -> Void)?

    private var appToken = ""
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var wantConnected = false
    private var attempt = 0
    private var pingTimer: Timer?
    private var generation = 0

    private(set) var state: State = .disconnected {
        didSet { if state != oldValue { onState?(state) } }
    }

    func connect(appToken: String) {
        self.appToken = appToken
        wantConnected = true
        attempt = 0
        open()
    }

    func disconnect() {
        wantConnected = false
        generation += 1
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .disconnected
    }

    private func open() {
        guard wantConnected else { return }
        generation += 1
        let gen = generation
        state = .connecting
        task?.cancel(with: .goingAway, reason: nil)
        let token = appToken
        Task {
            do {
                var req = URLRequest(url: URL(string: "https://slack.com/api/apps.connections.open")!)
                req.httpMethod = "POST"
                req.timeoutInterval = 20
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                let (data, _) = try await URLSession.shared.data(for: req)
                let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                guard obj["ok"] as? Bool == true, let s = obj["url"] as? String, let url = URL(string: s) else {
                    throw SlackAPI.APIError(message: "apps.connections.open: \(obj["error"] as? String ?? "no URL")")
                }
                guard gen == self.generation, self.wantConnected else { return }
                let session = URLSession(configuration: .default)
                let ws = session.webSocketTask(with: url)
                self.session = session
                self.task = ws
                ws.resume()
                self.receive(ws, gen: gen)
                self.startPing(ws, gen: gen)
            } catch {
                guard gen == self.generation else { return }
                let msg = (error as? SlackAPI.APIError)?.message ?? error.localizedDescription
                // invalid_auth / not_allowed_token_type won't fix themselves: don't retry.
                if msg.contains("invalid_auth") || msg.contains("not_allowed_token_type") || msg.contains("not_authed") {
                    self.wantConnected = false
                    self.state = .failed(msg)
                } else {
                    self.state = .failed(msg)
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func receive(_ ws: URLSessionWebSocketTask, gen: Int) {
        ws.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .failure(let e):
                    self.state = .failed("Connection lost: \(e.localizedDescription)")
                    self.scheduleReconnect()
                case .success(let message):
                    var text: String?
                    switch message {
                    case .string(let s): text = s
                    case .data(let d): text = String(data: d, encoding: .utf8)
                    @unknown default: break
                    }
                    if let text { self.handle(text, ws: ws) }
                    self.receive(ws, gen: gen)
                }
            }
        }
    }

    private func handle(_ text: String, ws: URLSessionWebSocketTask) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        let type = obj["type"] as? String ?? ""
        if let envelope = obj["envelope_id"] as? String {
            // Acknowledge first (Slack retries if no ack within 3 s); processing happens afterwards.
            if let ack = try? JSONSerialization.data(withJSONObject: ["envelope_id": envelope]),
               let s = String(data: ack, encoding: .utf8) {
                ws.send(.string(s)) { _ in }
            }
        }
        switch type {
        case "hello":
            attempt = 0
            state = .connected
        case "disconnect":
            // Slack rotates connections periodically; open a fresh one.
            open()
        default:
            let payload = obj["payload"] as? [String: Any] ?? [:]
            onEnvelope?(type, payload, obj["retry_attempt"] as? Int ?? 0)
        }
    }

    private func startPing(_ ws: URLSessionWebSocketTask, gen: Int) {
        pingTimer?.invalidate()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation else { return }
                ws.sendPing { error in
                    guard error != nil else { return }
                    Task { @MainActor [weak self] in
                        guard let self, gen == self.generation else { return }
                        self.state = .failed("Ping failed")
                        self.scheduleReconnect()
                    }
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pingTimer = t
    }

    private func scheduleReconnect() {
        guard wantConnected else { return }
        generation += 1
        let gen = generation
        attempt += 1
        let delay = min(60, pow(2, Double(min(attempt, 6))))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.open()
        }
    }
}
