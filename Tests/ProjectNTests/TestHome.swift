import Foundation
@testable import ProjectN

/// One disposable ProjectN home shared by every suite. AppHome.root is read once per process; scripts/test.sh
/// sets PROJECTN_HOME to a temp folder before anything runs, and AppHome itself refuses ~/.projectn inside a
/// test process — so whichever code touches it first, every suite uses the same throw-away folder.
enum TestHome {
    static let url: URL = {
        _ = helper
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".projectn").standardizedFileURL.path
        if let set = ProcessInfo.processInfo.environment["PROJECTN_HOME"], !set.isEmpty {
            precondition(URL(fileURLWithPath: set).standardizedFileURL.path != real, "Tests must not use the real ~/.projectn")
            return URL(fileURLWithPath: set)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("projectn-tests-\(UUID())")
        setenv("PROJECTN_HOME", url.path, 1)
        return url
    }()

    /// Project folders for agent tests. Outside the ProjectN home, which agents may never use.
    static let projects: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("projectn-test-projects-\(UUID())")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// .build/debug/pn-agent (built by scripts/test.sh).
    static let helper: String = {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/pn-agent").path
        setenv("PROJECTN_AGENT_HELPER", path, 1)
        return path
    }()
}
