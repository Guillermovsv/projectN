import Testing
@testable import ProjectN

/// Answering an agent's question from the pane's chat box instead of clicking into the terminal: "2", "yes", "no"
/// move to that option and press Return; text that isn't an answer stays a normal message.
struct ChatBoxAnswerTests {
    let down = AutoResponder.down, up = AutoResponder.up, enter = AutoResponder.enter

    /// Claude Code's numbered permission menu.
    let claudeMenu = [
        " Bash command",
        "   rm -rf build",
        " Do you want to proceed?",
        " ❯ 1. Yes",
        "   2. Yes, and don't ask again for rm commands in /Users/me/app",
        "   3. No, and tell Claude what to do differently (esc)",
        "",
    ]

    @Test func numbersPickThatOption() {
        #expect(AutoResponder.replyKeys("1", screen: claudeMenu) == [enter])
        #expect(AutoResponder.replyKeys("2", screen: claudeMenu) == [down, enter])
        #expect(AutoResponder.replyKeys(" 3 ", screen: claudeMenu) == [down, down, enter])
        #expect(AutoResponder.replyKeys("4", screen: claudeMenu) == nil)
        var moved = claudeMenu
        moved[3] = "   1. Yes"
        moved[5] = " ❯ 3. No, and tell Claude what to do differently (esc)"
        #expect(AutoResponder.replyKeys("1", screen: moved) == [up, up, enter])
    }

    @Test func yesAndNoInEitherLanguagePickTheMatchingOption() {
        #expect(AutoResponder.replyKeys("yes", screen: claudeMenu) == [enter])          // the plain Yes, not "Yes, and…"
        #expect(AutoResponder.replyKeys("Sí.", screen: claudeMenu) == [enter])
        #expect(AutoResponder.replyKeys("no", screen: claudeMenu) == [down, down, enter])
        #expect(AutoResponder.replyKeys("Yes, and don't ask again", screen: claudeMenu) == [down, enter])
    }

    @Test func otherTextIsAMessageNotAnAnswer() {
        #expect(AutoResponder.replyKeys("use the trash instead of rm", screen: claudeMenu) == nil)
        // Nothing waiting: never keys.
        #expect(AutoResponder.replyKeys("1", screen: ["╭──╮", "│ > │", "╰──╯", "  ? for shortcuts"]) == nil)
        #expect(AutoResponder.replyKeys("yes", screen: ["working on it…", "esc to interrupt"]) == nil)
    }

    @Test func codexAllowAndCancel() {
        let codex = [
            "  Allow the demo MCP server to run tool \"manage-elements\"?",
            "  › 1. Allow                   Run the tool and continue",
            "    2. Allow for this session  Run the tool and remember this choice for this session",
            "    3. Always allow            Run the tool and remember this choice for future tool calls",
            "    4. Cancel                  Cancel this tool call",
            "  enter to submit | esc to cancel",
        ]
        #expect(AutoResponder.replyKeys("yes", screen: codex) == [enter])                 // one-time Allow
        #expect(AutoResponder.replyKeys("allow", screen: codex) == [enter])
        #expect(AutoResponder.replyKeys("no", screen: codex) == [down, down, down, enter])
        #expect(AutoResponder.replyKeys("always allow", screen: codex) == [down, down, enter])
    }

    @Test func unnumberedClaudeDialog() {
        let trust = [
            " Quick safety check: Is this a project you created or one you trust?",
            "",
            " ❯ No, exit",
            "   Yes, I trust this folder",
            "",
            " Enter to confirm · Esc to cancel",
        ]
        #expect(AutoResponder.replyKeys("2", screen: trust) == [down, enter])
        #expect(AutoResponder.replyKeys("si", screen: trust) == [down, enter])
        #expect(AutoResponder.replyKeys("no", screen: trust) == [enter])
    }

    @Test func cursorKeyMenuAndInlineYesNo() {
        let cursor = [
            "Run this command?",
            "Not in allowlist: wc",
            " → Run (once) (y)",
            "   Add Shell(wc) to allowlist? (tab)",
            "   Run Everything (shift+tab)",
            "   Skip & tell the agent what to do instead (esc or n)",
            "",
        ]
        #expect(AutoResponder.replyKeys("y", screen: cursor) == ["y"])
        #expect(AutoResponder.replyKeys("sí", screen: cursor) == ["y"])
        #expect(AutoResponder.replyKeys("no", screen: cursor) == ["n"])
        #expect(AutoResponder.replyKeys("esc", screen: cursor) == ["\u{1b}"])
        #expect(AutoResponder.replyKeys("x", screen: cursor) == nil)

        let inline = ["Overwrite package.json? (y/N)"]
        #expect(AutoResponder.replyKeys("y", screen: inline) == ["y", enter])
        #expect(AutoResponder.replyKeys("No", screen: inline) == ["n", enter])
        #expect(AutoResponder.replyKeys("maybe later", screen: inline) == nil)
    }
}
