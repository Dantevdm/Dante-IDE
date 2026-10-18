import DanteKit
import Testing

@Suite struct ApprovalsTests {
    let pipeline: JSONValue = ["command": #"git -C "/home/me/shop" log --format=%s | uniq -c | sort -rn 2>/dev/null"#]

    @Test func levelsDecideEditsAndCommands() {
        let edit: JSONValue = ["file_path": "/home/me/shop/a.swift"]
        #expect(!ApprovalPolicy.approves("Edit", input: edit, level: .ask, allow: [], hasRuleNote: false))
        #expect(ApprovalPolicy.approves("Edit", input: edit, level: .edits, allow: [], hasRuleNote: false))
        #expect(!ApprovalPolicy.approves("Bash", input: pipeline, level: .edits, allow: [], hasRuleNote: false))
        #expect(ApprovalPolicy.approves("Bash", input: pipeline, level: .everything, allow: [], hasRuleNote: false))
        // Flagged edits and questions always wait.
        #expect(!ApprovalPolicy.approves("Edit", input: edit, level: .everything, allow: [], hasRuleNote: true))
        #expect(!ApprovalPolicy.approves("AskUserQuestion", input: [:], level: .everything, allow: ["AskUserQuestion"], hasRuleNote: false))
    }

    @Test func alwaysAllowRulesCoverEveryPartOfAPipeline() {
        let rules = ApprovalPolicy.rules(for: "Bash", input: pipeline)
        #expect(rules == [#"Bash(git -C "/home/me/shop" log:*)"#, "Bash(uniq:*)", "Bash(sort:*)"])
        #expect(ApprovalPolicy.allowed("Bash", input: pipeline, by: rules))
        #expect(!ApprovalPolicy.allowed("Bash", input: pipeline, by: Array(rules.prefix(2))))
        let other: JSONValue = ["command": #"git -C "/home/me/shop" log -1 && sort a.txt"#]
        #expect(ApprovalPolicy.allowed("Bash", input: other, by: rules))
        #expect(!ApprovalPolicy.allowed("Bash", input: ["command": #"git -C "/home/me/shop" push"#], by: rules))
    }

    @Test func rulesNeverVouchForSubstitutionOrWrites() {
        let rules = ["Bash(echo:*)", "Bash(cat:*)"]
        #expect(!ApprovalPolicy.allowed("Bash", input: ["command": "echo $(rm -rf x)"], by: rules))
        #expect(!ApprovalPolicy.allowed("Bash", input: ["command": "echo hi > ~/.zshrc"], by: rules))
        #expect(!ApprovalPolicy.allowed("Bash", input: ["command": "cat a & rm b"], by: rules))
        #expect(ApprovalPolicy.allowed("Bash", input: ["command": "cat a 2>&1"], by: rules))
        #expect(ApprovalPolicy.allowed("Bash", input: ["command": "echo 'a | b'"], by: rules))
        #expect(ApprovalPolicy.rules(for: "Bash", input: ["command": "echo `id`"]).isEmpty)
    }

    @Test func otherToolsGetTheirOwnRules() {
        #expect(ApprovalPolicy.rules(for: "MultiEdit", input: [:]) == ["Edit"])
        #expect(ApprovalPolicy.rules(for: "WebFetch", input: ["url": "https://docs.swift.org/x"]) == ["WebFetch(domain:docs.swift.org)"])
        #expect(ApprovalPolicy.allowed("WebFetch", input: ["url": "https://api.docs.swift.org/x"], by: ["WebFetch(domain:docs.swift.org)"]))
        #expect(ApprovalPolicy.rules(for: "mcp__github__create_issue", input: [:]) == ["mcp__github__create_issue"])
        #expect(ApprovalPolicy.rules(for: "AskUserQuestion", input: [:]).isEmpty)
    }

    @Test func addingRulesKeepsTheRestOfTheSettings() {
        let existing = #"{"permissions":{"allow":["Bash(make:*)"],"deny":["Read(.env)"]},"model":"sonnet"}"#
        let updated = ApprovalPolicy.settings(adding: ["Bash(make:*)", "Bash(uniq:*)"], to: existing)
        let permissions = ClaudePermissions.parse([updated])
        #expect(permissions.allow == ["Bash(make:*)", "Bash(uniq:*)"])
        #expect(permissions.deny == ["Read(.env)"])
        #expect(updated.contains(#""model" : "sonnet""#))
        #expect(ClaudePermissions.parse([ApprovalPolicy.settings(adding: ["Edit"], to: nil)]).allow == ["Edit"])
    }
}
