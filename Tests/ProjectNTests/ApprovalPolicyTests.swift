import Foundation
import Testing
@testable import ProjectN

struct ApprovalPolicyTests {
    let project = "/Users/test/Documents/client-site"

    private func ctx(_ p: AgentPermission = .editProject, cli: [String] = []) -> ApprovalPolicy.Context {
        .init(permission: p, projectPath: project, cliTools: cli, cwd: project)
    }
    private func bash(_ c: String, _ p: AgentPermission = .editProject, cli: [String] = []) -> ApprovalTier {
        ApprovalPolicy.classify(tool: "Bash", input: ["command": c], ctx(p, cli: cli))
    }
    private func isUser(_ t: ApprovalTier) -> Bool { if case .user = t { return true }; return false }
    private func isGray(_ t: ApprovalTier) -> Bool { if case .orchestrator = t { return true }; return false }
    private func isDeny(_ t: ApprovalTier) -> Bool { if case .deny = t { return true }; return false }

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
                  "ls ../other-client", "echo hi > ~/notes.txt"] {
            #expect(isUser(bash(c)), "\(c) → \(bash(c))")
        }
        #expect(isUser(ApprovalPolicy.classify(tool: "Read", input: ["file_path": "/Users/test/.aws/credentials"], ctx())))
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
        for c in ["curl https://example.com", "some-unknown-tool --x", "echo $(whoami)"] {
            #expect(isGray(bash(c)), "\(c) → \(bash(c))")
        }
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
}
