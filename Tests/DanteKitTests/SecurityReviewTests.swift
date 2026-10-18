import Foundation
import Testing
@testable import DanteKit

@Suite struct SecurityReviewTests {
    private let root = URL(filePath: "/home/me/app", directoryHint: .isDirectory)

    private func change(_ path: String, added: [String], file: String? = nil) -> ProposedChange {
        var lines: [DiffLine] = []
        if let file { lines.append(DiffLine(kind: .file, text: file)) }
        lines.append(DiffLine(kind: .context, text: "import os", oldNumber: 1, newNumber: 1))
        for (index, text) in added.enumerated() {
            lines.append(DiffLine(kind: .added, text: text, oldNumber: nil, newNumber: index + 2))
        }
        lines.append(DiffLine(kind: .removed, text: "cursor.execute(\"SELECT 1 FROM t WHERE id = \" + old)", oldNumber: 2, newNumber: nil))
        return ProposedChange(url: root.appending(path: path), displayPath: path, isNewFile: false, lines: lines, applies: true)
    }

    @Test func injectionInAddedLinesBlocksTheEdit() {
        let findings = SecurityReview.findings(in: change("api/users.py", added: [
            "def find(name):",
            "    cursor.execute(\"SELECT * FROM users WHERE name = '\" + name + \"'\")",
        ]), root: root)
        #expect(findings.contains { $0.rule == "py.sql" && $0.line == 3 && $0.file == "api/users.py" })
        #expect(SecurityReview.blocks(findings))
        #expect(SecurityReview.note(for: findings)?.contains("(line 3)") == true)
    }

    @Test func removedLinesAndCleanEditsPass() {
        let findings = SecurityReview.findings(in: change("api/users.py", added: [
            "    cursor.execute(\"SELECT * FROM users WHERE name = %s\", (name,))",
        ]), root: root)
        #expect(findings.isEmpty)
        #expect(!SecurityReview.blocks(findings))
        #expect(SecurityReview.note(for: findings) == nil)
    }

    @Test func wholeFileRulesWaitForTheScan() {
        let findings = SecurityReview.findings(in: change("Dockerfile", added: ["FROM python:3.13", "COPY . /app"]), root: root)
        #expect(!findings.contains { $0.rule == "docker.root" })
    }

    @Test func fileHeadersNameTheFileOfEachLine() {
        let key = "AKIA" + "Q7ZK3M9WX2PLR4TN"
        let findings = SecurityReview.findings(in: change("patch", added: ["aws_key = \"\(key)\""], file: "config/settings.py"), root: root)
        #expect(findings.first?.file == "config/settings.py")
        #expect(findings.first?.severity == .critical)
    }
}

@Suite struct SecurityBriefTests {
    @Test func auditRepliesBecomeFindings() {
        let reply = """
        Here's what I found.

        - [high] api/routes/users.ts:42 — Users can read other users' profiles by id — Check the id belongs to the session user before loading it
        - **[medium]** `db/schema.sql:0` – ID numbers stored in plain text – Encrypt the column with pgcrypto and a key from the secret store
        * [low] web/app.js:7 - Missing CSP header - Add a Content-Security-Policy
        - [urgent] nowhere — not a severity — ignored
        Overall: Access control is the main gap; personal information isn't encrypted at rest.
        """
        let (findings, overall) = SecurityBrief.parseAudit(reply, source: "Codex")
        #expect(findings.count == 3)
        #expect(findings[0].file == "api/routes/users.ts")
        #expect(findings[0].line == 42)
        #expect(findings[0].severity == .high)
        #expect(findings[0].rule == "audit.codex")
        #expect(findings[0].source == "Codex")
        #expect(findings[1].file == "db/schema.sql")
        #expect(findings[1].category == .privacy)
        #expect(findings[2].title == "Missing CSP header")
        #expect(overall?.hasPrefix("Access control") == true)
    }

    @Test func theFixBriefNamesThePartner() {
        let finding = SecurityFinding(rule: "py.sql", category: .code, severity: .high, title: "SQL built from a string",
                                      why: "Injection.", fix: "Use parameters.", file: "app.py", line: 3,
                                      evidence: "cursor.execute(q + name)", reference: "CWE-89", source: "Dante")
        let brief = SecurityBrief.fix([finding], partner: ("Codex", "ask_codex"))
        #expect(brief.contains("[high] SQL built from a string at app.py:3 (CWE-89)"))
        #expect(brief.contains("ask Codex to check your changes with ask_codex"))
        #expect(!SecurityBrief.fix([finding], partner: nil).contains("ask_codex"))
    }

    @Test func theAuditBriefListsWhatTheScannerFound() {
        let finding = SecurityFinding(rule: "py.sql", category: .code, severity: .high, title: "SQL built from a string",
                                      why: "", fix: "", file: "app.py", line: 3, evidence: "", reference: nil, source: "Dante")
        let brief = SecurityBrief.audit(known: [finding], projectName: "shop")
        #expect(brief.contains("POPIA"))
        #expect(brief.contains("- [high] app.py:3 — SQL built from a string"))
    }
}
