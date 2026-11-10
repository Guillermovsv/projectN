import Testing
@testable import ProjectN

/// Codex asks about MCP tool calls with Allow / Allow for this session / Always allow / Cancel — no "Yes".
/// Approving such a prompt from Slack used to fail ("prompt.answer_failed") and re-post it every few seconds.
@Suite struct CodexPromptTests {
    /// Captured from Codex 0.167 (pyte render of the real TUI): each option carries a description column.
    let mcpApproval = [
        "› Call the demo MCP tool manage-elements with post_id 798 right now. Do nothing else.",
        "• Calling demo.manage-elements",
        "    + Show details",
        "  Field 1/1",
        "  Allow the demo MCP server to run tool \"manage-elements\"?",
        "  post_id: 798",
        "  › 1. Allow                   Run the tool and continue",
        "    2. Allow for this session  Run the tool and remember this choice for this session",
        "    3. Always allow            Run the tool and remember this choice for future tool calls",
        "    4. Cancel                  Cancel this tool call",
        "  enter to submit | esc to cancel",
        "",
    ]

    @Test func approvingPicksTheOneTimeAllow() {
        let d = AutoResponder.decide(screen: mcpApproval)
        #expect(d?.keys == ["\r"] && d?.label == "Allow")
        #expect(d.map { AutoResponder.approves($0.label) } == true)
    }

    @Test func reportsTheQuestionNotAParameter() {
        #expect(AutoResponder.pendingPrompt(screen: mcpApproval)?.hasPrefix("Allow the demo MCP server to run tool") == true)
    }

    @Test func neverWidensPermissions() {
        #expect(!AutoResponder.approves("Allow for this session (a)"))
        #expect(!AutoResponder.approves("Always allow (p)"))
        #expect(!AutoResponder.approves("Cancel (esc)"))
        // Cursor at "Allow for this session": a one-time Allow above is chosen, never the current one.
        var moved = mcpApproval
        moved[6] = "    1. Allow                   Run the tool and continue"
        moved[7] = "  › 2. Allow for this session  Run the tool and remember this choice for this session"
        #expect(AutoResponder.decide(screen: moved)?.keys == [AutoResponder.up, "\r"])
    }

    @Test func earlierLabelsStillApprove() {
        #expect(AutoResponder.approves("y"))
        #expect(AutoResponder.approves("Yes"))
        #expect(AutoResponder.approves("Yes, proceed (y)"))
        #expect(AutoResponder.approves("Run (once)"))
    }
}
