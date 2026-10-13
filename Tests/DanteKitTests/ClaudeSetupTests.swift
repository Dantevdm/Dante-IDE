import Foundation
import Testing
@testable import DanteKit

struct ClaudeSetupTests {
    @Test func readsSkillFrontMatter() {
        let text = "---\nname: add-endpoint\ndescription: \"Add an HTTP endpoint the house way\"\n---\n# Steps\n"
        let meta = ClaudeSkills.frontMatter(text)
        #expect(meta.name == "add-endpoint" && meta.description == "Add an HTTP endpoint the house way")
        #expect(ClaudeSkills.frontMatter("# No front matter").name == nil)
        #expect(ClaudeSkills.folderName("Add an API endpoint!") == "add-an-api-endpoint")
    }

    @Test func suggestsSkillsFromWhatTheProjectHas() {
        let files = ["backend/internal/api/handlers.go", "backend/internal/api/handlers_test.go", "frontend/views/orders.js",
                     "docker-compose.yml", "backend/migrations/001_init.sql", ".dante/tasks.yaml"]
        let ids = ClaudeSkills.suggestions(files: files, stack: ["Go"], hasDante: true, existing: []).map(\.id)
        #expect(ids == ["dante-tasks", "add-endpoint", "new-screen", "db-change", "local-env", "write-tests", "review-changes"])

        let existing = [ClaudeSkill(name: "add-endpoint", description: "", scope: .project, file: URL(filePath: "/home/me/app/.claude/skills/add-endpoint/SKILL.md"))]
        let left = ClaudeSkills.suggestions(files: files, stack: ["Go"], hasDante: false, existing: existing)
        #expect(!left.map(\.id).contains("add-endpoint") && !left.map(\.id).contains("dante-tasks"))
        #expect(left.first?.prompt.contains(".claude/skills/new-screen/SKILL.md") == true)
    }

    @Test func reviewsEveryFortnight() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(ClaudeSkills.reviewDue(lastReview: nil, now: now))
        #expect(!ClaudeSkills.reviewDue(lastReview: now.addingTimeInterval(-3 * 86_400), now: now))
        #expect(ClaudeSkills.reviewDue(lastReview: now.addingTimeInterval(-15 * 86_400), now: now))
    }

    @Test func readsConnectorsAndPermissions() {
        let output = """
        Checking MCP server health...

        github: npx -y @modelcontextprotocol/server-github - ✓ Connected
        notes: https://example.com/mcp (HTTP) - ✗ Failed to connect
        """
        let servers = MCPServer.parse(output)
        #expect(servers.map(\.name) == ["github", "notes"])
        #expect(servers[0].connected && servers[0].source == "npx -y @modelcontextprotocol/server-github")
        #expect(!servers[1].connected && servers[1].status == "Failed to connect")

        let permissions = ClaudePermissions.parse([#"{"permissions": {"allow": ["Bash(go test:*)"], "deny": ["Read(./data/**)"]}}"#, "{}"])
        #expect(permissions.allow == ["Bash(go test:*)"] && permissions.deny == ["Read(./data/**)"] && permissions.ask.isEmpty)
    }

    @Test func toolVersions() {
        #expect(Tool.version(from: "psql (PostgreSQL) 16.4") == "16.4")
        #expect(Tool.version(from: "go version go1.23.2 darwin/arm64") == "1.23.2")
        #expect(Tool.version(from: "nothing here") == nil)
        let ids = Tool.relevant(stack: ["Go"]).map(\.id)
        #expect(ids.contains("gopls") && !ids.contains("rust-analyzer") && ids.contains("psql"))
    }
}

struct TurnCheckpointTests {
    @Test func undoPutsBackTheFirstVersionAndRemovesCreatedFiles() {
        var disk: [String: String] = ["/home/me/app/a.go": "one"]
        var checkpoint = TurnCheckpoint()
        checkpoint.record("/home/me/app/a.go") { disk[$0] }
        disk["/home/me/app/a.go"] = "two"
        checkpoint.record("/home/me/app/a.go") { disk[$0] }   // a second edit keeps the first original
        checkpoint.record("/home/me/app/new.go") { disk[$0] }
        disk["/home/me/app/new.go"] = "created"
        let restored = checkpoint.undo { path, text in disk[path] = text }
        #expect(restored == ["/home/me/app/a.go", "/home/me/app/new.go"])
        #expect(disk == ["/home/me/app/a.go": "one"])
        #expect(checkpoint.undone && checkpoint.undo { _, _ in }.isEmpty)
    }
}

struct ComposerTokenTests {
    @Test func findsTheMentionOrCommandBeingTyped() {
        #expect(ComposerToken.current(in: "look at @mail")?.query == "mail")
        #expect(ComposerToken.current(in: "look at @mail")?.kind == .mention)
        #expect(ComposerToken.current(in: "write to me@example.com") == nil)
        #expect(ComposerToken.current(in: "@a.go then") == nil)
        #expect(ComposerToken.current(in: "/comp")?.kind == .command)
        #expect(ComposerToken.current(in: "/compact now") == nil)
        let token = ComposerToken.current(in: "fix @hand")!
        #expect(token.replacing(in: "fix @hand", with: "@api/handlers.go") == "fix @api/handlers.go ")
    }

    @Test func readsMentionedProjectFiles() {
        let files: Set<String> = ["api/handlers.go", "README.md"]
        #expect(ComposerToken.mentions(in: "compare @api/handlers.go, @README.md and @nope.txt (@README.md)", files: files) == ["api/handlers.go", "README.md"])
    }

    @Test func commandsMatchByPrefixFirst() {
        let skill = ClaudeSkill(name: "db-change", description: "Schema changes", scope: .project, file: URL(filePath: "/home/me/p/.claude/skills/db-change/SKILL.md"))
        #expect(ComposerCommand.matching("c", skills: [skill]).map(\.name) == ["compact", "context", "db-change"])
        #expect(ComposerCommand.matching("", skills: [skill]).count == ComposerCommand.builtIn.count + 1)
    }
}

struct ClaudePluginTests {
    @Test func readsInstalledAndAvailablePlugins() {
        let json = """
        {"installed":[{"id":"commit-tools@claude-plugins-official","version":"1.2.0","enabled":false,"description":"Commit helpers"}],
         "available":[{"name":"pr-review","marketplaceName":"claude-plugins-official","description":"Reviews pull requests"}]}
        """
        let plugins = ClaudePlugin.parse(json)
        #expect(plugins.installed == [ClaudePlugin(name: "commit-tools", marketplace: "claude-plugins-official", description: "Commit helpers", version: "1.2.0", enabled: false)])
        #expect(plugins.available.map(\.id) == ["pr-review@claude-plugins-official"])
        #expect(ClaudePlugin.parse("[]").installed.isEmpty)
    }
}
