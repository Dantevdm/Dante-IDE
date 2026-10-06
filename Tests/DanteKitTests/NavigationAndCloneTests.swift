import Foundation
import Testing
@testable import DanteKit

@Suite struct NavigationHistoryTests {
    @Test func backAndForwardRetraceTheVisits() {
        var history = NavigationHistory<String>()
        history.moved(from: "home")
        history.moved(from: "docs")
        // Now at "code".
        #expect(history.goBack(from: "code") == "docs")
        #expect(history.goBack(from: "docs") == "home")
        #expect(history.goBack(from: "home") == nil)
        #expect(history.goForward(from: "home") == "docs")
        #expect(history.goForward(from: "docs") == "code")
        #expect(!history.canGoForward)
    }

    @Test func aNewVisitDropsTheForwardTrail() {
        var history = NavigationHistory<String>()
        history.moved(from: "a")
        _ = history.goBack(from: "b")
        #expect(history.canGoForward)
        history.moved(from: "a")
        #expect(!history.canGoForward)
    }

    @Test func keepsAtMostFiftyAndSkipsRepeats() {
        var history = NavigationHistory<Int>()
        for place in 0..<80 { history.moved(from: place); history.moved(from: place) }
        #expect(history.back.count == 50)
        #expect(history.back.first == 30)
    }
}

@Suite struct CloneProgressTests {
    @Test func parsesGitProgressLines() {
        let receiving = Git.CloneProgress.parse("Receiving objects:  45% (450/1000), 1.20 MiB | 2.40 MiB/s")
        #expect(receiving?.phase == "Receiving objects")
        #expect(receiving?.fraction == 0.45)
        #expect(receiving?.detail == "(450/1000), 1.20 MiB | 2.40 MiB/s")
        #expect(receiving?.overall == 0.05 + 0.75 * 0.45)

        let remote = Git.CloneProgress.parse("remote: Counting objects: 100% (12/12), done.")
        #expect(remote?.phase == "Counting objects")
        #expect(remote?.detail == "(12/12)")

        #expect(Git.CloneProgress.parse("Cloning into 'repo'...") == nil)
        #expect(Git.CloneProgress.parse("fatal: repository not found") == nil)
    }

    @Test func spotsCredentialFailures() {
        #expect(Git.needsCredentials("fatal: could not read Password for 'https://user@bitbucket.org': terminal prompts disabled"))
        #expect(Git.needsCredentials("git@github.com: Permission denied (publickey)."))
        #expect(!Git.needsCredentials("fatal: repository 'https://x/y.git/' not found"))
    }

    @Test func clonesALocalRepositoryWithProgress() async throws {
        let folder = try TemporaryFolder()
        let source = folder.url.appending(path: "source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for command in [["git", "init", "-q"], ["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "x"]] {
            #expect(await Shell.run(command, in: source).status == 0)
        }
        let parent = folder.url.appending(path: "clones")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let cloned = try await Git.clone("file://" + source.path, into: parent)
        #expect(FileManager.default.fileExists(atPath: cloned.appending(path: ".git").path))
        #expect(cloned.lastPathComponent == "source")
    }
}

@Suite struct ClarifyingQuestionTests {
    @Test func parsesQuestionsAndAnswers() {
        let input: JSONValue = [
            "questions": [[
                "question": "Which auth method?",
                "header": "Auth",
                "multiSelect": false,
                "options": [["label": "OAuth", "description": "Sign in with a provider"], ["label": "Passwords"]],
            ]],
            "answers": ["Which auth method?": "OAuth"],
        ]
        let questions = ClarifyingQuestion.parse(input)
        #expect(questions.count == 1)
        #expect(questions[0].header == "Auth")
        #expect(questions[0].options.map(\.label) == ["OAuth", "Passwords"])
        #expect(questions[0].options[1].description == "")
        #expect(ClarifyingQuestion.answers(in: input) == ["Which auth method?": "OAuth"])
    }

    @Test func toolSummary() {
        let tool = ToolActivity(id: "1", name: "AskUserQuestion", input: ["questions": [["question": "Q?", "header": "Scope", "options": []]]], status: .awaitingApproval(requestID: "r"))
        #expect(tool.verb == "Asks")
        #expect(tool.target(in: URL(filePath: "/")) == "Scope")
    }
}

@Suite struct DocTitleTests {
    @Test func sameTitlesShowTheirFolder() {
        let library = DocLibrary(paths: ["frontend/README.md", "api/README.md", "tools/setup.md"])
        let elsewhere = library.groups.first { $0.title == "Elsewhere" }!.docs
        let readme = elsewhere.first { $0.path == "api/README.md" }!
        #expect(library.folder(distinguishing: readme) == "api")
        #expect(library.folder(distinguishing: elsewhere.first { $0.path == "tools/setup.md" }!) == nil)
    }
}

@Suite struct PageLayoutTests {
    @Test func blocksThatFitMoveWhole() {
        let slices = PageLayout.slices(heights: [500, 300], usable: 700, gap: 10)
        #expect(slices.map(\.page) == [0, 1])
        #expect(slices[1].y == 0)
    }

    @Test func longBlocksAreSliced() {
        let slices = PageLayout.slices(heights: [100, 1500], usable: 700, gap: 10)
        #expect(slices.map(\.page) == [0, 0, 1, 2])
        #expect(slices.map(\.height).reduce(0, +) == 1600)
        #expect(slices[2].offset == 590)
    }

    @Test func headingsStayWithTheBlockAfterThem() {
        // A heading would fit at the bottom of page one, but its diagram wouldn't.
        let slices = PageLayout.slices(heights: [600, 40, 400], keepsWithNext: [false, true, false], usable: 700, gap: 10)
        #expect(slices.map(\.page) == [0, 1, 1])
        // Without the rule the heading stays behind.
        #expect(PageLayout.slices(heights: [600, 40, 400], usable: 700, gap: 10).map(\.page) == [0, 0, 1])
    }
}
