import Foundation
import Network

/// Loopback endpoint (127.0.0.1, random port) that `pn-agent` talks to. One JSON line per request; the reply may
/// come much later (an approval waiting for the orchestrator or for you). Every request must carry the secret token
/// of a running task — the token lives only in that task's process environment and in memory here.
@MainActor
final class AgentBridge {
    typealias Reply = ([String: Any]) -> Void
    /// (request, reply). Called on the main actor.
    var handler: (([String: Any], @escaping Reply) -> Void)?

    private var listener: NWListener?
    private(set) var port: UInt16?
    private let queue = DispatchQueue(label: "dev.projectn.agent-bridge")

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        params.acceptLocalOnly = true
        guard let l = try? NWListener(using: params) else {
            AuditLog.record("bridge.error", ["error": "couldn't create listener"])
            return
        }
        l.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.accept(conn) }
        }
        l.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready: self.port = self.listener?.port?.rawValue
                case .failed(let e): AuditLog.record("bridge.error", ["error": "\(e)"]); self.port = nil
                default: break
                }
            }
        }
        listener = l
        l.start(queue: queue)
    }

    /// Waits (briefly) until the port is known; launches need it for the environment.
    func waitUntilReady(timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while port == nil, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private nonisolated func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            var buf = buffer
            if let data { buf.append(data) }
            if let nl = buf.firstIndex(of: 0x0A) {
                let line = buf[..<nl]
                let obj = (try? JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
                Task { @MainActor in
                    guard let self, let handler = self.handler else { Self.send(conn, ["error": "not ready"]); return }
                    var replied = false
                    handler(obj) { response in
                        guard !replied else { return }
                        replied = true
                        Self.send(conn, response)
                    }
                }
                return
            }
            if done || error != nil || buf.count > (4 << 20) { conn.cancel(); return }
            self?.receive(conn, buffer: buf)
        }
    }

    private nonisolated static func send(_ conn: NWConnection, _ obj: [String: Any]) {
        var data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        data.append(0x0A)
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Path of the helper: next to the app binary (inside ProjectN.app), or PROJECTN_AGENT_HELPER.
    static var helperPath: String? {
        if let p = ProcessInfo.processInfo.environment["PROJECTN_AGENT_HELPER"], FileManager.default.isExecutableFile(atPath: p) { return p }
        let candidates = [Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("pn-agent"),
                          URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("pn-agent")]
        return candidates.compactMap { $0?.path }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
