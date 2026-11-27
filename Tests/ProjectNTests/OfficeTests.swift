import Foundation
import Testing
@testable import ProjectN

struct OfficeTests {
    private func agent(_ id: UUID, _ status: OfficeStatus, name: String = "Ada") -> OfficeAgent {
        OfficeAgent(id: id, workspaceID: UUID(), name: name, project: "app", status: status)
    }

    private func types(_ messages: [OfficeBridge.Message]) -> [String] { messages.compactMap { $0["type"] as? String } }

    @Test func snapshotSendsAgentsBeforeLayoutAndStateAfter() {
        var bridge = OfficeBridge()
        let id = UUID()
        let saved = OfficeSaved(seats: [id.uuidString: OfficeSeat(palette: 3, seatId: "chair")])
        let out = bridge.snapshot([agent(id, .working)], saved: saved, defaultLayout: ["version": 1])
        #expect(types(out) == ["settingsLoaded", "existingAgents", "layoutLoaded", "agentTeamInfo",
                                    "agentStatus", "agentToolStart", "agentLeisure"])
        let meta = out[1]["agentMeta"] as? [String: [String: Any]]
        #expect(meta?["1"]?["palette"] as? Int == 3)
        #expect(meta?["1"]?["seatId"] as? String == "chair")
        #expect(bridge.paneID(for: 1) == id)
    }

    @Test func updateOnlySendsChanges() {
        var bridge = OfficeBridge()
        let a = UUID(), b = UUID()
        _ = bridge.snapshot([agent(a, .working)], saved: OfficeSaved(), defaultLayout: [:])
        #expect(bridge.update([agent(a, .working)], saved: OfficeSaved()).isEmpty)

        let finished = bridge.update([agent(a, .idle)], saved: OfficeSaved())
        #expect(types(finished) == ["agentToolPermissionClear", "agentToolsClear", "agentStatus", "agentLeisure"])
        #expect(finished.last?["mode"] as? String == "play")
        #expect(finished[2]["status"] as? String == "waiting")

        let swapped = bridge.update([agent(b, .needsInput)], saved: OfficeSaved())
        #expect(types(swapped) == ["agentClosed", "agentCreated", "agentTeamInfo", "agentStatus",
                                        "agentToolStart", "agentToolPermission", "agentLeisure"])
        #expect(swapped[1]["id"] as? Int == 2)
    }

    @Test func busyAgentsOfOneProjectShareAMeetingRoom() {
        var bridge = OfficeBridge()
        func make(_ project: String, _ status: OfficeStatus = .working) -> OfficeAgent {
            OfficeAgent(id: UUID(), workspaceID: UUID(), name: "n", project: project, status: status)
        }
        var app = [make("app"), make("app")]
        let web = [make("web"), make("web", .needsInput), make("web")]
        let docs = [make("docs"), make("docs")]
        let solo = make("solo")
        let out = bridge.snapshot(app + [solo] + web + docs, saved: OfficeSaved(), defaultLayout: [:])
        // The two biggest teams (ties: first listed) get the two rooms.
        #expect(bridge.rooms == ["web": "Meeting 1", "app": "Meeting 2"])
        #expect(out.filter { $0["type"] as? String == "agentRoom" }.count == 5)

        // One of the pair finishes: it leaves, the other keeps the room.
        app[1].status = .idle
        let left = bridge.update(app + [solo] + web + docs, saved: OfficeSaved())
        #expect(left.filter { $0["type"] as? String == "agentRoom" }.count == 1)
        #expect(bridge.rooms["app"] == "Meeting 2")

        // The whole project stops: the room goes to the next team.
        app[0].status = .idle
        _ = bridge.update(app + [solo] + web + docs, saved: OfficeSaved())
        #expect(bridge.rooms == ["web": "Meeting 1", "docs": "Meeting 2"])
    }

    @Test func idleAgentsPlayThenSleep() {
        var bridge = OfficeBridge()
        let id = UUID()
        var idle = agent(id, .idle)
        _ = bridge.snapshot([idle], saved: OfficeSaved(), defaultLayout: [:])
        idle.resting = true
        let out = bridge.update([idle], saved: OfficeSaved())
        #expect(types(out) == ["agentLeisure"])
        #expect(out.first?["mode"] as? String == "sleep")
        #expect(agent(id, .offline).leisure == .sleep)
        #expect(agent(id, .working).leisure == nil)
    }

    @Test func seatsAreKeyedByPane() {
        var bridge = OfficeBridge()
        let id = UUID()
        _ = bridge.snapshot([agent(id, .idle)], saved: OfficeSaved(), defaultLayout: [:])
        let seats = bridge.seats(from: ["1": ["palette": 2, "seatId": "s1"], "99": ["palette": 1]])
        #expect(seats == [id.uuidString: OfficeSeat(palette: 2, seatId: "s1")])
    }

    @Test func bundleIsCompleteAndStaysInside() throws {
        let root = try #require(OfficeBundle.root)
        let assets = try Data(contentsOf: root.appendingPathComponent("office-assets.json"))
        let json = try #require(JSONSerialization.jsonObject(with: assets) as? [String: Any])
        #expect(json["defaultLayout"] != nil)
        #expect(OfficeBundle.file(for: "/index.html", root: root) != nil)
        #expect(OfficeBundle.file(for: "/../../Package.swift", root: root) == nil)
    }
}
