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

    @Test func shellQuoting() {
        #expect(UpdateModel.shellQuote("/a b/it's") == "'/a b/it'\\''s'")
    }
}
