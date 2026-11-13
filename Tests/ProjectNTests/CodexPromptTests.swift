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

    // MARK: Judging Codex prompts (no hook): Auto mode answers routine ones itself

    func ctx(auto: Bool = true, autonomy: AgentAutonomy = .balanced, permission: AgentPermission = .editProject) -> ApprovalPolicy.Context {
        ApprovalPolicy.Context(permission: permission, projectPath: "/Users/Shared/demo-project", cwd: "/Users/Shared/demo-project",
                               autonomy: autonomy, autoMode: auto)
    }

    func commandScreen(_ cmd: String...) -> [String] {
        ["  Would you like to run the following command?", "", "  Reason: check the API", ""]
            + cmd.enumerated().map { $0.offset == 0 ? "  $ \($0.element)" : "    \($0.element)" }
            + ["", "› 1. Yes, proceed (y)", "  2. Yes, and don't ask again for this command (p)",
               "  3. No, and tell Codex what to do differently (esc)", ""]
    }

    @Test func readsTheMCPToolOfAPrompt() {
        let ask = CodexPromptPolicy.parse(screen: mcpApproval, question: "Allow the demo MCP server to run tool \"manage-elements\"?")
        #expect(ask == .mcp(server: "demo", tool: "manage-elements"))
    }

    @Test func autoModeAllowsRoutineMCPCalls() {
        for tool in ["mcp-adapter-execute-ability", "manage-elements", "elementor-publish-document", "get-page-structure"] {
            #expect(CodexPromptPolicy.decide(.mcp(server: "site-elementor", tool: tool), ctx()) == .allow, "\(tool)")
        }
        #expect(CodexPromptPolicy.decide(.mcp(server: "zernio", tool: "posts_delete"), ctx()).isDeletion)
    }

    @Test func readsAWrappedCommand() {
        let ask = CodexPromptPolicy.parse(screen: commandScreen("curl -sS http://127.0.0.1:3900/openapi.json |", "python3 -c 'print(1)'"),
                                          question: "Would you like to run the following command?")
        #expect(ask == .command("curl -sS http://127.0.0.1:3900/openapi.json | python3 -c 'print(1)'", collapsed: false))
    }

    @Test func autoModeAllowsRoutineCommandsButNotDeleting() {
        for cmd in ["curl -sS http://127.0.0.1:3900/openapi.json", "python3 /private/tmp/ralero_generate.py all",
                    "ls -lh /private/tmp/ralero-voicestudio-test.wav"] {
            #expect(CodexPromptPolicy.decide(.command(cmd, collapsed: false), ctx()) == .allow, "\(cmd)")
        }
        #expect(CodexPromptPolicy.decide(.command("rm -rf build", collapsed: false), ctx()).isDeletion)
        #expect(CodexPromptPolicy.decide(.command("sudo launchctl load x.plist", collapsed: false), ctx()) != .allow)
        #expect(CodexPromptPolicy.decide(.command("cat ~/.ssh/id_rsa", collapsed: false), ctx()) != .allow)
        // Part of the command hidden on screen: it could hide an rm.
        #expect(CodexPromptPolicy.decide(.command("python3 - <<EOF", collapsed: true), ctx()) != .allow)
    }

    @Test func collapsedCommandIsDetected() {
        var screen = commandScreen("python3 - <<'PY'")
        screen.insert("    [… 28 lines] ⌃a view all", at: 5)
        if case .command(_, let collapsed) = CodexPromptPolicy.parse(screen: screen, question: "Would you like to run the following command?") {
            #expect(collapsed)
        } else { Issue.record("not read as a command") }
    }

    @Test func otherPromptsInAutoMode() {
        #expect(CodexPromptPolicy.decide(.other("Allow Computer Use to use \"VoiceStudio\"?"), ctx()) == .allow)
        #expect(CodexPromptPolicy.decide(.edits(deletes: false), ctx(permission: .askBeforeChanges)) == .allow)
        #expect(CodexPromptPolicy.decide(.edits(deletes: true), ctx()) != .allow)
        #expect(CodexPromptPolicy.decide(.other("Delete the folder audio/ventas?"), ctx()) != .allow)
    }

    @Test func withoutAutoModeOnlyTheAutonomyRulesApply() {
        // Cautious agents still get asked about publishing; balanced ones about deleting/publishing as before.
        #expect(CodexPromptPolicy.decide(.mcp(server: "s", tool: "elementor-publish-document"), ctx(auto: false, autonomy: .cautious)) != .allow)
        #expect(CodexPromptPolicy.decide(.mcp(server: "s", tool: "get-page-structure"), ctx(auto: false)) == .allow)
    }
}
