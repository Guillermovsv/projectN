import Foundation
import Testing
@testable import ProjectN

struct GitHubCloneTests {
    @Test func parsesWhatPeoplePaste() {
        let expected = GitHubRepoRef(owner: "SaulRobles243", name: "pavirigido")
        for raw in ["SaulRobles243/pavirigido",
                    "  SaulRobles243/pavirigido  ",
                    "https://github.com/SaulRobles243/pavirigido",
                    "https://github.com/SaulRobles243/pavirigido.git",
                    "github.com/SaulRobles243/pavirigido/pull/67",
                    "https://www.github.com/SaulRobles243/pavirigido/tree/main?tab=readme#top",
                    "git@github.com:SaulRobles243/pavirigido.git",
                    "ssh://git@github.com/SaulRobles243/pavirigido.git"] {
            #expect(GitHubRepoRef(raw) == expected, "\(raw)")
        }
        #expect(GitHubRepoRef("Guillermovsv/projectN")?.slug == "Guillermovsv/projectN")
        #expect(GitHubRepoRef("owner/my.repo_name-2")?.name == "my.repo_name-2")
    }

    @Test func rejectsUnsafeOrIncomplete() {
        for raw in ["", "pavirigido", "owner/", "/repo", "owner/..", "owner/.", "own er/repo",
                    "owner/re po", "-owner/repo", "owner/repo;rm -rf ~", "owner/$(whoami)", "ownér/repo"] {
            #expect(GitHubRepoRef(raw) == nil, "\(raw)")
        }
    }

    @Test func quotesShellArguments() {
        #expect(GitHubClone.quote("/Users/me/Dev Projects/it's") == "'/Users/me/Dev Projects/it'\\''s'")
        let repo = GitHubRepoRef("a/b")!
        #expect(GitHubClone.cloneCommand(repo, destination: "/tmp/x y/b") == "gh repo clone 'a/b' '/tmp/x y/b' -- --quiet")
    }

    @Test func parsesRepoListNewestFirst() {
        let json = """
        [{"nameWithOwner":"me/old","description":"","isPrivate":false,"updatedAt":"2026-01-01T00:00:00Z"},
         {"nameWithOwner":"me/new","description":"Fresh","isPrivate":true,"updatedAt":"2026-11-10T00:00:00Z"},
         {"nameWithOwner":"me/none","description":null,"isPrivate":false,"updatedAt":null}]
        """
        let repos = GitHubClone.parseList(json)
        #expect(repos?.map(\.nameWithOwner) == ["me/new", "me/old", "me/none"])
        #expect(repos?.first?.isPrivate == true)
        #expect(GitHubClone.parseList("not json") == nil)
    }

    @Test func plansCloneAddOrBlock() {
        let repo = GitHubRepoRef("SaulRobles243/pavirigido")!
        let folder = "/Users/me/Developer"
        let dest = "/Users/me/Developer/pavirigido"
        #expect(GitHubClone.plan(repo: repo, folder: folder, existsKind: nil) == .clone(destination: dest))
        #expect(GitHubClone.plan(repo: repo, folder: folder, existsKind: .cloneOf("git@github.com:saulrobles243/PaviRigido.git"))
                == .addExisting(destination: dest))
        #expect(GitHubClone.plan(repo: repo, folder: folder, existsKind: .cloneOf("https://github.com/acme/pavirigido.git"))
                    .isBlocked)
        #expect(GitHubClone.plan(repo: repo, folder: folder, existsKind: .folder).isBlocked)
        #expect(GitHubClone.plan(repo: repo, folder: folder, existsKind: .file).isBlocked)
    }

    @Test func refusesProtectedFolders() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(GitHubClone.checkFolder("\(home)/.ssh") != nil || !FileManager.default.fileExists(atPath: "\(home)/.ssh"))
        #expect(GitHubClone.checkFolder("\(home)/Library") != nil)
        #expect(GitHubClone.checkFolder("/System") != nil)
        #expect(GitHubClone.checkFolder("/definitely/not/here") != nil)
        #expect(GitHubClone.checkFolder(NSTemporaryDirectory()) == nil)
    }
}

private extension GitHubClone.Plan {
    var isBlocked: Bool { if case .blocked = self { return true } else { return false } }
}
