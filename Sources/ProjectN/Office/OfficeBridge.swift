import Foundation

/// What a character in the Office is doing.
enum OfficeStatus: Equatable {
    case working
    case needsInput
    case idle
    /// No process: asleep to save memory, or exited.
    case offline

    var label: String {
        switch self {
        case .working: return "Working"
        case .needsInput: return "Needs you"
        case .idle: return "Idle"
        case .offline: return "Asleep"
        }
    }
}

/// One pane shown as a character.
struct OfficeAgent: Equatable, Identifiable {
    let id: UUID
    let workspaceID: UUID
    var name: String
    var project: String
    var status: OfficeStatus
    /// Idle for a long time: it goes to bed instead of playing.
    var resting = false

    /// How long without activity before an idle agent stops playing and goes to sleep.
    static let sleepAfter: TimeInterval = 10 * 60

    var leisure: OfficeLeisure? {
        switch status {
        case .working, .needsInput: return nil
        case .idle: return resting ? .sleep : .play
        case .offline: return .sleep
        }
    }

    var statusLabel: String {
        if status == .idle { return resting ? "Sleeping" : "Playing" }
        return status.label
    }
}

/// Time off, as the interface calls it.
enum OfficeLeisure: String {
    case play, sleep
}

/// A character's look and desk, kept per pane so it comes back the same after a relaunch.
struct OfficeSeat: Codable, Equatable {
    var palette: Int?
    var repeatIndex: Int?
    var seatId: String?
}

/// What the Office remembers between launches.
struct OfficeSaved: Codable, Equatable {
    /// The edited office layout as the interface sent it (JSON), nil while it's the default one.
    var layout: String?
    var seats: [String: OfficeSeat] = [:]
}

/// Translates ProjectN's panes into the messages the Pixel Agents interface expects from its host
/// (`core/asyncapi.yaml` upstream). Pure: it only remembers what was already sent, so each call returns the changes.
struct OfficeBridge {
    typealias Message = [String: Any]

    /// The interface identifies agents by number; a pane keeps its number for as long as the app runs.
    private(set) var numbers: [UUID: Int] = [:]
    private var nextNumber = 1
    private var sent: [UUID: OfficeAgent] = [:]

    func paneID(for number: Int) -> UUID? {
        numbers.first { $0.value == number }?.key
    }

    /// Messages for a (re)loaded interface, to send after the assets: the agents, the layout, then their state.
    mutating func snapshot(_ agents: [OfficeAgent], saved: OfficeSaved, defaultLayout: Any) -> [Message] {
        sent = [:]
        var meta: [String: Message] = [:]
        var directories: [String: String] = [:]
        var ids: [Int] = []
        for agent in agents {
            let n = number(agent.id)
            ids.append(n)
            meta[String(n)] = seatFields(saved.seats[agent.id.uuidString])
            directories[String(n)] = agent.project
        }
        let layout = saved.layout.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? defaultLayout
        var out: [Message] = [
            ["type": "settingsLoaded", "soundEnabled": false, "alwaysShowLabels": true, "extensionVersion": "", "lastSeenVersion": ""],
            ["type": "existingAgents", "agents": ids, "agentMeta": meta, "directoryNames": directories],
            ["type": "layoutLoaded", "layout": layout],
        ]
        for agent in agents {
            out.append(nameMessage(agent))
            out += statusMessages(agent, from: nil)
            out.append(leisureMessage(agent))
            sent[agent.id] = agent
        }
        return out
    }

    /// Messages for what changed since the last call.
    mutating func update(_ agents: [OfficeAgent], saved: OfficeSaved) -> [Message] {
        var out: [Message] = []
        let current = Set(agents.map(\.id))
        for id in sent.keys.filter({ !current.contains($0) }).sorted(by: { number($0) < number($1) }) {
            out.append(["type": "agentClosed", "id": number(id)])
            sent[id] = nil
        }
        for agent in agents {
            let n = number(agent.id)
            guard let old = sent[agent.id] else {
                var created: Message = ["type": "agentCreated", "id": n, "directoryName": agent.project]
                created.merge(seatFields(saved.seats[agent.id.uuidString])) { a, _ in a }
                out.append(created)
                out.append(nameMessage(agent))
                out += statusMessages(agent, from: nil)
                out.append(leisureMessage(agent))
                sent[agent.id] = agent
                continue
            }
            if old.name != agent.name { out.append(nameMessage(agent)) }
            if old.status != agent.status { out += statusMessages(agent, from: old.status) }
            if old.leisure != agent.leisure { out.append(leisureMessage(agent)) }
            sent[agent.id] = agent
        }
        return out
    }

    /// The interface's `saveAgentSeats` payload, keyed back to panes.
    func seats(from payload: [String: Any]) -> [String: OfficeSeat] {
        var out: [String: OfficeSeat] = [:]
        for (key, value) in payload {
            guard let n = Int(key), let id = paneID(for: n), let v = value as? [String: Any] else { continue }
            out[id.uuidString] = OfficeSeat(palette: v["palette"] as? Int, repeatIndex: v["repeat"] as? Int,
                                            seatId: v["seatId"] as? String)
        }
        return out
    }

    private mutating func number(_ id: UUID) -> Int {
        if let n = numbers[id] { return n }
        let n = nextNumber
        nextNumber += 1
        numbers[id] = n
        return n
    }

    private func seatFields(_ seat: OfficeSeat?) -> Message {
        var out: Message = [:]
        if let p = seat?.palette { out["palette"] = p }
        if let r = seat?.repeatIndex { out["repeat"] = r }
        if let s = seat?.seatId { out["seatId"] = s }
        return out
    }

    private mutating func nameMessage(_ agent: OfficeAgent) -> Message {
        ["type": "agentTeamInfo", "id": number(agent.id), "agentName": agent.name]
    }

    /// ProjectN's own message (see scripts/office/pixel-agents.patch); sent after the status.
    private mutating func leisureMessage(_ agent: OfficeAgent) -> Message {
        ["type": "agentLeisure", "id": number(agent.id), "mode": agent.leisure?.rawValue ?? NSNull()]
    }

    private mutating func statusMessages(_ agent: OfficeAgent, from old: OfficeStatus?) -> [Message] {
        let n = number(agent.id)
        // The tool name picks the animation (typing); its status is the label over the character.
        func tool(_ status: String) -> Message {
            ["type": "agentToolStart", "id": n, "toolId": "pn", "toolName": "Edit", "status": status]
        }
        let clear: [Message] = old == nil ? [] : [
            ["type": "agentToolPermissionClear", "id": n],
            ["type": "agentToolsClear", "id": n],
        ]
        switch agent.status {
        case .working:
            return clear + [["type": "agentStatus", "id": n, "status": "active"], tool("Working")]
        case .needsInput:
            return clear + [["type": "agentStatus", "id": n, "status": "active"], tool("Needs you"),
                            ["type": "agentToolPermission", "id": n]]
        case .idle:
            // "waiting" shows the checkmark: only for a turn that just finished.
            return clear + [["type": "agentStatus", "id": n, "status": old == .working ? "waiting" : "idle"]]
        case .offline:
            return clear + [["type": "agentStatus", "id": n, "status": "idle"]]
        }
    }
}
