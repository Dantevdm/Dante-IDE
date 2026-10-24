import DanteCore
import Foundation
import Testing
@testable import DanteKit

/// Every parser that reads what other programs, agents or files say gets random and mangled
/// input: none may crash (an index out of range, a bad range, a forced unwrap). Seeded, so a
/// failure repeats.
@Suite struct ParserFuzzTests {
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Pieces that parsers split on, so random text reaches their edge cases.
    static let pieces = [
        "\n", "\r\n", " ", "\t", ":", "::", "/", "\\", "\"", "'", "`", "{", "}", "[", "]", "(", ")", "<", ">", "=", "-", "--", "+", "@@",
        "<<<<<<< ours", "=======", ">>>>>>> theirs", "|||||||", "@@ -1,3 +1,4 @@", "diff --git a/x b/x", "--- a/x", "+++ b/x",
        "Test Case '-[A b]' failed", "✘ Test x() recorded an issue at", "--- FAIL: TestX", "FAILED tests/x.py::t", "PASS", "ok  \tpkg\t0.1s",
        "{\"type\":\"assistant\",\"message\":{\"content\":[", "\"tool_use\"", "\"id\":", "Content-Length: ", "\r\n\r\n", "0", "1", "42", "-1",
        "99999999999999999999", "é", "🙂", "\u{0}", "%", "#", "*", "|", "&&", ";", "$(", "${", "?", "&", "~", ".", "..", "graph TD", "A-->B",
        "sequenceDiagram", "erDiagram", "services:", "  web:", "    image: x", "    ports:", "      - \"80:80\"", "KEY=value", "export A=",
        "M ", "?? ", "R  a -> b", "author ", "filename ", "\t", "SF:", "DA:1,0", "end_of_record", "mode: set", "x.go:1.1,2.2 1 0",
        "postgres://u:p@h:5432/db", "mysql://", "sqlite:", "reply to ", " that ", "hey dante", "<svg", "M0 0L1 1Z", "cmd+shift+", "⌘",
    ]

    static func inputs(_ count: Int, seed: UInt64) -> [String] {
        var random = Seeded(state: seed)
        return (0..<count).map { _ in
            let length = Int.random(in: 0...40, using: &random)
            return (0..<length).map { _ in pieces.randomElement(using: &random)! }.joined()
        } + ["", " ", "\n\n\n", String(repeating: "x", count: 10_000), String(repeating: "\n", count: 500)]
    }

    @Test func toolOutputParsersNeverCrash() {
        for text in Self.inputs(400, seed: 1) {
            _ = GitStatus.parse(text)
            _ = GitBranch.parse(text)
            _ = UnifiedDiff.parse(text)
            _ = GitBlame.parse(text)
            _ = MergeConflict.parse(text)
            _ = ContainerState.parse(text)
            _ = DockerContainer.parse(text)
            _ = ListeningPort.parse(text)
            _ = LogLine.parse(text, id: 0, service: "web")
            _ = ComposeProgress.parse(text.components(separatedBy: "\n"))
            _ = MCPServer.parse(text)
            _ = ClaudePlugin.parse(text)
            _ = ClaudeAccount.parse(text)
            _ = CoverageReport.parse(text, files: ["a/x.go", "b.swift"])
            var tests = TestOutputParser()
            for line in text.components(separatedBy: "\n") { tests.consume(line) }
            _ = SavedTestRun.reading(command: "swift test", output: text, failed: true, by: .you)
        }
    }

    @Test func agentReplyParsersNeverCrash() {
        for text in Self.inputs(400, seed: 2) {
            _ = ClaudeEvent(line: text)
            _ = ReplyChoices.parse(text)
            _ = CommitMessage.read(text)
            _ = PullRequestDraft.parse(text)
            _ = BranchReview.parse(text)
            _ = TaskRouting.classify(text, hasAttachments: false, hasInstructions: false)
            _ = JobGuard.forbidden(text)
            _ = ApprovalPolicy.readsOnly(text)
            _ = ApprovalPolicy.rules(for: "Bash", input: ["command": .string(text)])
            _ = TestCommandLine.runsTests(text)
            _ = MailReply.parse(text)
            _ = VoiceCommand.parse(text, projects: ["Dante IDE"])
        }
    }

    @Test func projectFileParsersNeverCrash() {
        for text in Self.inputs(400, seed: 3) {
            _ = MarkdownDocument(text)
            _ = Mermaid.parse(text)
            _ = try? ComposeFile.parse(text)
            _ = EnvFile.parse(text)
            _ = ClaudeRules.parse(projectYAML: text)
            _ = ProjectInfo.parse(projectYAML: text)
            _ = BrowserHosts.parse(text)
            _ = JobType.parse(text, id: "x")
            _ = MotionPiece.parse(text)
            _ = SecurityIgnores.parse(text)
            _ = Dependencies.parse(text, file: "package-lock.json")
            _ = Dependencies.parse(text, file: "go.sum")
            _ = SVGPath.parse(text)
            _ = DatabaseConnection.parse(url: text)
            _ = try? Diagram.decode(Data(text.utf8))
            _ = try? TaskFile.decode(text)
            _ = try? SafeYAML.load(text)
        }
    }

    @Test func yamlWithAListOrMapAsAKeyIsInvalidNotACrash() {
        for yaml in ["[a]: b", "? {x: y}\n: z", "services:\n  ? [web]\n  : {image: x}", "claude:\n  never:\n    {a: 1}: 2"] {
            #expect(throws: SafeYAML.Invalid.self) { try SafeYAML.load(yaml) }
        }
        #expect(ClaudeRules.parse(projectYAML: "claude:\n  [never]: x") == ClaudeRules.parse(projectYAML: ""))
        // Anchors and merge keys still work.
        let merged = try? SafeYAML.load("base: &b {image: x}\nweb:\n  <<: *b\n  ports: [1]") as? [String: Any]
        #expect((merged?["web"] as? [String: Any])?["image"] as? String == "x")
    }

    @Test func languageServerFramesNeverCrash() {
        var random = Seeded(state: 4)
        for text in Self.inputs(300, seed: 5) {
            var decoder = LSPFraming.Decoder()
            let data = Data(text.utf8)
            // Arrives in pieces of any size.
            var index = 0
            while index < data.count {
                let size = Int.random(in: 1...16, using: &random)
                _ = decoder.append(data.subdata(in: index..<min(index + size, data.count)))
                index += size
            }
        }
    }
}
