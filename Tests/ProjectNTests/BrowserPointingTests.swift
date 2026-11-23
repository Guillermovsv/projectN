import Foundation
import Testing
@testable import ProjectN

struct BrowserPointingTests {
    private func payload(_ kind: String, id: String = "m1") -> [String: Any] {
        ["id": id, "kind": kind, "url": "http://localhost:3000/", "label": "<h1.hero__title>",
         "selector": "body > header > h1.hero__title", "text": "Bienvenido", "html": "<h1 class=\"hero__title\">Bienvenido</h1>",
         "box": "860×38 px at x 20, y 41 of the page", "contents": ["attributes: href=\"/\""]]
    }

    @Test func markFromPagePayload() throws {
        let m = try #require(BrowserMark.from(payload("element"), number: 3, tabID: UUID()))
        #expect(m.kind == .element)
        #expect(m.chipText == "3 · <h1.hero__title>")
        #expect(m.contents == ["attributes: href=\"/\""])
        #expect(BrowserMark.from(["id": "x", "kind": "bogus"], number: 1, tabID: UUID()) == nil)
    }

    @Test func promptBlockListsMarksInOrder() throws {
        var a = try #require(BrowserMark.from(payload("element", id: "a"), number: 2, tabID: UUID()))
        a.imagePath = "/tmp/point shot.png"
        let b = try #require(BrowserMark.from(payload("area", id: "b"), number: 1, tabID: UUID()))
        let block = BrowserMark.promptBlock([a, b])
        let one = try #require(block.range(of: "[1] Area of the page"))
        let two = try #require(block.range(of: "[2] Element <h1.hero__title> on http://localhost:3000/"))
        #expect(one.lowerBound < two.lowerBound)
        #expect(block.contains("selector: body > header > h1.hero__title"))
        #expect(block.contains("screenshot: '/tmp/point shot.png'"))
        #expect(BrowserMark.promptBlock([]) == "")
    }
}
