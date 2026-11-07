import Foundation

/// One disposable ProjectN home shared by every suite. AppHome.root is read once per process, so
/// PROJECTN_HOME must be set before *any* test touches it — otherwise tests would write to ~/.projectn.
enum TestHome {
    static let url: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("projectn-tests-\(UUID())")
        setenv("PROJECTN_HOME", url.path, 1)
        // Agent sessions run the real helper (approval hook + ProjectN MCP server).
        setenv("PROJECTN_AGENT_HELPER", helper, 1)
        return url
    }()

    /// .build/debug/pn-agent (built by scripts/test.sh).
    static let helper: String = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/debug/pn-agent").path

    /// Project folders for agent tests. Outside the ProjectN home, which agents may never use.
    static let projects: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("projectn-test-projects-\(UUID())")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}
