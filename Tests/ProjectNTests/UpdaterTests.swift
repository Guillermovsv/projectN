import Foundation
import Testing
@testable import ProjectN

struct UpdaterTests {
    @Test func parsesRepoURLs() {
        #expect(UpdateSource(url: "https://github.com/Guillermovsv/projectN.git") == UpdateSource(owner: "Guillermovsv", name: "projectN"))
        #expect(UpdateSource(url: "git@github.com:o/r.git") == UpdateSource(owner: "o", name: "r"))
        #expect(UpdateSource(url: "https://x:tok@github.com/o/r")?.cloneURL == "https://github.com/o/r.git")
        #expect(UpdateSource(url: "https://gitlab.com/o/r") == nil)
    }

    @Test func compareAheadListsNewestFirst() {
        let d: [String: Any] = [
            "status": "ahead",
            "commits": [
                ["sha": "aaa1111", "html_url": "https://github.com/o/r/commit/aaa", "commit": ["message": "First\n\nbody", "author": ["name": "A", "date": "2026-11-13T10:00:00Z"]]],
                ["sha": "bbb2222", "commit": ["message": "Second", "author": ["name": "B", "date": "2026-11-13T11:00:00Z"]]],
            ],
        ]
        let r = UpdateModel.parseCompare(d)
        #expect(r.commits.map(\.title) == ["Second", "First"])
        #expect(r.head == "bbb2222")
        #expect(r.commits.last?.date != nil)
    }

    @Test func compareIdenticalOrBehindHasNothingPending() {
        #expect(UpdateModel.parseCompare(["status": "identical", "commits": []]).commits.isEmpty)
        #expect(UpdateModel.parseCompare(["status": "behind", "commits": []]).commits.isEmpty)
    }

    @Test func splitsMessageAndDropsTrailers() {
        let (title, body) = UpdateModel.splitMessage("Title here\n\nWhat changed.\nMore.\n\nCo-Authored-By: X <x@y>")
        #expect(title == "Title here")
        #expect(body == "What changed.\nMore.")
        #expect(UpdateModel.splitMessage("Only").body == "")
    }

    @Test func summarySentence() {
        func c(_ t: String) -> UpdateModel.Commit { .init(sha: t, title: t, author: "", date: nil, url: nil) }
        #expect(UpdateModel.summary(of: [c("Fix A")]) == "Fix A.")
        #expect(UpdateModel.summary(of: [c("A"), c("B")]) == "A; y B.")
        #expect(UpdateModel.summary(of: [c("A"), c("B"), c("C"), c("D")]) == "A; B; y 2 cambios más.")
    }

    @Test func shellQuoting() {
        #expect(UpdateModel.shellQuote("/a b/it's") == "'/a b/it'\\''s'")
    }
}
