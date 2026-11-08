import Foundation
import Testing
@testable import ProjectN

struct ApprovalPolicyTests {
    let project = "/Users/test/Documents/client-site"

    private func ctx(_ p: AgentPermission = .editProject, cli: [String] = [], autonomy: AgentAutonomy = .balanced) -> ApprovalPolicy.Context {
        .init(permission: p, projectPath: project, cliTools: cli, cwd: project, autonomy: autonomy)
    }
    private func decide(_ c: String, _ a: AgentAutonomy, _ p: AgentPermission = .editProject) -> ApprovalTier {
        ApprovalPolicy.decide(tool: "Bash", input: ["command": c], ctx(p, autonomy: a))
    }
    private func bash(_ c: String, _ p: AgentPermission = .editProject, cli: [String] = []) -> ApprovalTier {
        ApprovalPolicy.classify(tool: "Bash", input: ["command": c], ctx(p, cli: cli))
    }
    private func isUser(_ t: ApprovalTier) -> Bool { if case .user = t { return true }; return false }
    private func isGray(_ t: ApprovalTier) -> Bool { if case .orchestrator = t { return true }; return false }
    private func isDeny(_ t: ApprovalTier) -> Bool { if case .deny = t { return true }; return false }

    @Test func heredocBodiesAndRegexScriptsAreNotPaths() {
        let jsx = "cd \"\(project)/frontend\" && cat > components/a.tsx <<'EOF'\nexport const A = () => <Globe />\n// see /api/reports\nEOF\nnpx tsc --noEmit"
        #expect(decide(jsx, .high) == .allow)
        let sed = "sed -i '' '/^import .*lucide-react/ s/\\bGlobe, //; /^import .*lucide-react/ s/, Globe\\b//' app/page.tsx"
        #expect(decide(sed, .high) == .allow)
        // Real paths are still judged, also around a heredoc.
        #expect(isUser(decide("cat > /etc/hosts <<EOF\nx\nEOF", .high)))
        #expect(isUser(decide("cat <<EOF > ~/.ssh/config\nHost x\nEOF", .high)))
        #expect(isUser(decide("cat <<-EOF\n\tx\n\tEOF\nrm -rf build", .high)))
        // A here-string isn't a heredoc: the next line is a command.
        #expect(isUser(decide("grep x <<< \"$v\"\nrm -rf build", .high)))
        #expect(ApprovalPolicy.stripHeredocs("a <<'X'\n/>\nX\nb") == "a <<'X'\nb")
    }

    @MainActor @Test func agentSessionsTurnOffClaudeCodesOwnReadBlock() throws {
        let json = try #require(AgentHarness.hookSettings(helper: "/x/pn-agent", timeoutSeconds: 60))
        let obj = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect((obj["permissions"] as? [String: Any])?["blockReadsOutsideWorkingDirectories"] as? Bool == false)
        #expect(obj["hooks"] != nil)
    }

    @Test func deletingAnythingAlwaysGoesToTheUser() {
        let deletions = [
            "rm README.md", "rm -rf build", "rmdir old", "unlink a", "find . -name '*.log' -delete", "find . -exec rm {} \\;",
            "git rm src/a.swift", "git clean -fd", "git reset --hard HEAD~1", "git checkout -- .", "git restore src",
            "git branch -D feature", "git stash drop", "git push origin --delete feature", "git push -f", "git tag -d v1",
            "npm uninstall react", "pnpm remove lodash", "pip uninstall requests", "brew uninstall wget",
            "docker rm web", "docker system prune -a", "kubectl delete pod x", "rsync -a --delete src/ dst/",
            "terraform destroy", "gh repo delete me/x", "mysql -e 'DROP TABLE users'", "psql -c \"delete from orders\"",
            "ls && rm a.txt", "echo ok; rm -f x", "truncate -s 0 log.txt", "trash file", "mv secret.txt /dev/null",
        ]
        for c in deletions {
            let t = bash(c)
            #expect(isUser(t), "\(c) → \(t)")
        }
        // Even for a CLI tool the agent may use freely.
        #expect(isUser(bash("wp post delete 12", cli: ["wp"])))
        #expect(bash("wp post list", cli: ["wp"]) == .allow)
        // Emptying a file through Write counts as deleting it.
        #expect(isUser(ApprovalPolicy.classify(tool: "Write", input: ["file_path": project + "/a.txt", "content": ""], ctx())))
        // MCP tools that delete.
        #expect(isUser(ApprovalPolicy.classify(tool: "mcp__zernio__posts_delete", input: [:], ctx())))
        #expect(isUser(ApprovalPolicy.classify(tool: "mcp__claude_ai_Gmail__trash_thread", input: [:], ctx())))
    }

    @Test func publishingAndOutsideTheProjectGoToTheUser() {
        for c in ["git push", "git push origin main", "npm publish", "vercel --prod", "firebase deploy", "gh pr merge 3",
                  "gh release create v1", "docker push img", "ssh host ls", "scp a host:/b", "curl -X POST https://x.dev/api",
                  "curl -d a=1 https://x", "sudo ls", "chmod -R 777 .", "cat ~/.ssh/id_rsa", "cp a.txt /etc/hosts",
                  "echo hi > ~/notes.txt", "cat ~/.claude.json", "grep token ~/.aws/config"] {
            #expect(isUser(bash(c)), "\(c) → \(bash(c))")
        }
        #expect(isUser(ApprovalPolicy.classify(tool: "Read", input: ["file_path": "/Users/test/.aws/credentials"], ctx())))
        // Reading another folder: fine unless the agent is cautious.
        #expect(bash("ls ../other-client") == .allow)
        #expect(isUser(ApprovalPolicy.classify(tool: "Bash", input: ["command": "ls ../other-client"], ctx(autonomy: .cautious))))
        #expect(ApprovalPolicy.classify(tool: "Read", input: ["file_path": "/Users/test/Documents/other/README.md"], ctx()) == .allow)
        #expect(isUser(ApprovalPolicy.classify(tool: "Edit", input: ["file_path": "/Users/test/other/x.swift"], ctx())))
        #expect(isUser(ApprovalPolicy.classify(tool: "mcp__zernio__posts_publish_now", input: [:], ctx())))
        #expect(isUser(ApprovalPolicy.classify(tool: "mcp__zernio__posts_create", input: [:], ctx())))
        #expect(isUser(ApprovalPolicy.classify(tool: "mcp__seo-core__confirm_deploy", input: [:], ctx())))
    }

    @Test func routineWorkIsAutomatic() {
        for c in ["ls -la", "cat README.md", "git status", "git log --oneline -5", "git diff", "rg TODO", "grep -rn fixme src",
                  "npm test", "npm run build", "swift build", "./scripts/test.sh", "make", "mkdir -p out", "git add . && git commit -m wip",
                  "npm install", "ls > /dev/null 2>&1", "echo hi > notes.txt", "sed -i '' s/a/b/ file.txt", "find . -name '*.swift'"] {
            #expect(bash(c) == .allow, "\(c) → \(bash(c))")
        }
        for t in ["Read", "Glob", "Grep", "TodoWrite", "mcp__projectn__delegate_task"] {
            #expect(ApprovalPolicy.classify(tool: t, input: ["file_path": project + "/a"], ctx()) == .allow)
        }
        #expect(ApprovalPolicy.classify(tool: "Edit", input: ["file_path": project + "/src/a.swift"], ctx()) == .allow)
        #expect(ApprovalPolicy.classify(tool: "mcp__zernio__posts_list", input: [:], ctx()) == .allow)
        #expect(ApprovalPolicy.classify(tool: "mcp__seo-core__get_onpage_grade", input: [:], ctx()) == .allow)
    }

    @Test func grayAreaAndReadOnlyAgents() {
        for c in ["curl https://example.com", "some-unknown-tool --x", "echo $(some-unknown-tool)"] {
            #expect(isGray(bash(c)), "\(c) → \(bash(c))")
        }
        // What runs inside $(…) / `…` is judged like the rest of the command.
        #expect(bash("echo $(whoami)") == .allow)
        #expect(bash("ls \"$(npm prefix -g)/bin\"") == .allow)
        #expect(isUser(bash("echo $(rm -rf build)")))
        #expect(isUser(bash("x=`git push`")))
        #expect(isGray(ApprovalPolicy.classify(tool: "WebFetch", input: ["url": "https://x.dev"], ctx())))
        #expect(isGray(ApprovalPolicy.classify(tool: "mcp__airedinamica-elementor__elementor-manage-elements", input: [:], ctx())))
        // Read-only agents: reading is fine, changing is refused outright (not even asked).
        #expect(bash("git status", .readOnly) == .allow)
        #expect(isDeny(bash("npm install", .readOnly)))
        #expect(isDeny(bash("echo x > notes.txt", .readOnly)))
        #expect(isDeny(ApprovalPolicy.classify(tool: "Edit", input: ["file_path": project + "/a"], ctx(.readOnly))))
        // …but deleting still asks the user rather than being silently refused? No: a read-only agent's delete is user-tier
        // (the user may allow it explicitly).
        #expect(isUser(bash("rm a", .readOnly)))
        // "Ask before any change": edits go to the user.
        #expect(isUser(ApprovalPolicy.classify(tool: "Edit", input: ["file_path": project + "/a"], ctx(.askBeforeChanges))))
        // Most restrictive part wins.
        #expect(isUser(bash("npm test && git push")))
        #expect(isDeny(bash("rm a; npm install", .readOnly)))
    }

    @Test func segmentsRespectQuotesAndRedirections() {
        #expect(ApprovalPolicy.segments("echo 'a; b' && ls 2>&1 | wc -l") == ["echo 'a; b'", "ls 2>&1", "wc -l"])
    }

    @Test func autoModeOnlyAsksForDeletesAdminAndSecrets() {
        var c = ctx(.askBeforeChanges, autonomy: .cautious)
        c.autoMode = true
        let bash = { (cmd: String) in ApprovalPolicy.decide(tool: "Bash", input: ["command": cmd], c) }
        for cmd in ["git push", "curl -X POST https://x.dev/api", "ssh host ls", "some-unknown-tool --x", "ls ../other-client"] {
            #expect(bash(cmd) == .allow, "\(cmd)")
        }
        #expect(ApprovalPolicy.decide(tool: "Edit", input: ["file_path": project + "/a.swift"], c) == .allow)
        #expect(ApprovalPolicy.decide(tool: "mcp__zernio__posts_publish_now", input: [:], c) == .allow)
        for cmd in ["rm -rf build", "git push -f", "sudo ls", "chmod -R 777 .", "cat ~/.ssh/id_rsa", "cp a.txt /etc/hosts"] {
            #expect(isUser(bash(cmd)), "\(cmd) → \(bash(cmd))")
        }
        #expect(isUser(ApprovalPolicy.decide(tool: "mcp__zernio__posts_delete", input: [:], c)))
        // Auto mode never widens access.
        var ro = ctx(.readOnly); ro.autoMode = true
        #expect(isDeny(ApprovalPolicy.decide(tool: "Bash", input: ["command": "npm install"], ro)))
    }

    @Test func autonomyLevelsDecideHowMuchAsks() {
        // Gray area: on its own unless cautious.
        #expect(decide("curl https://example.com", .balanced) == .allow)
        #expect(decide("some-unknown-tool --x", .high) == .allow)
        #expect(isGray(decide("some-unknown-tool --x", .cautious)))
        // Publishing / sending: asks at balanced, runs at high.
        for c in ["git push", "curl -X POST https://x.dev/api", "ssh host ls", "vercel --prod"] {
            #expect(isUser(decide(c, .balanced)), "\(c)")
            #expect(decide(c, .high) == .allow, "\(c)")
        }
        // Always asks: deleting, admin, system state, secrets — even at high.
        for c in ["rm -rf build", "git push -f", "sudo ls", "chmod -R 777 .", "cat ~/.ssh/id_rsa", "cp a.txt /etc/hosts"] {
            #expect(isUser(decide(c, .high)), "\(c) → \(decide(c, .high))")
        }
        // Read-only agents stay read-only whatever the autonomy.
        #expect(isDeny(decide("npm install", .high, .readOnly)))
        // MCP tools: publishing asks at balanced, gray ones don't.
        let mcp = { (t: String, a: AgentAutonomy) in ApprovalPolicy.decide(tool: t, input: [:], self.ctx(autonomy: a)) }
        #expect(mcp("mcp__airedinamica-elementor__elementor-manage-elements", .balanced) == .allow)
        #expect(isUser(mcp("mcp__zernio__posts_publish_now", .balanced)))
        #expect(mcp("mcp__zernio__posts_publish_now", .high) == .allow)
        #expect(isUser(mcp("mcp__zernio__posts_delete", .high)))
    }

    @Test func secretsAreRedacted() {
        let cmd = #"curl -H "Authorization: Basic Z3VpbGwuYWxleC5zYW5jaGV6QGdtYWlsLmNvbTpUcGsxY2RY" https://x.dev"#
        #expect(!Redactor.redact(cmd).contains("Z3VpbGwu"))
        let b64 = #"python3 -c "import base64;print(base64.b64decode('Z3VpbGwuYWxleC5zYW5jaGV6QGdtYWlsLmNvbTpUcGsxY2RYYXEzQW9EVXhBcXhiTEVCVk0='))""#
        #expect(!Redactor.redact(b64).contains("Z3VpbGwu"))
        #expect(!Redactor.redact("export API_KEY=abc123secret").contains("abc123secret"))
        #expect(!Redactor.redact("https://user:hunter2@example.com/x").contains("hunter2"))
        #expect(!ApprovalPolicy.clip("token=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456").contains("ghp_ABCDEF"))
        // Ordinary text, paths, UUIDs and model names survive.
        for keep in ["/private/tmp/claude-501/-Users-memo-Documents-Florina/091f94a5-7193-4d75-98f4-958182b8ab48/scratchpad",
                     "npm view @seo-core-app-ai/mcp version", "claude-sonnet-5-5", "antiquewhite-newt-221898.hostingersite.com",
                     "git log --oneline -5"] {
            #expect(Redactor.redact(keep) == keep, "\(keep)")
        }
    }
}
