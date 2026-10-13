import DanteKit
import Testing

struct MergeConflictTests {
    let text = """
        package shop

        <<<<<<< HEAD
        const limit = 10
        =======
        const limit = 25
        >>>>>>> feature
        func total() {}
        <<<<<<< HEAD
        // ours
        ||||||| base
        // base
        =======
        // theirs
        >>>>>>> feature
        end

        """

    @Test func parsesHunksWithLabelsLinesAndBases() throws {
        let conflict = try #require(MergeConflict.parse(text))
        #expect(conflict.hunks.count == 2)
        let first = conflict.hunks[0]
        #expect(first.line == 3 && first.ours == "const limit = 10\n" && first.theirs == "const limit = 25\n")
        #expect(first.oursLabel == "HEAD" && first.theirsLabel == "feature" && first.base == nil)
        #expect(conflict.hunks[1].base == "// base\n" && conflict.hunks[1].line == 9)
        #expect(MergeConflict.parse("no conflicts\n") == nil)
    }

    @Test func resolvingKeepsUnchosenHunksExactly() throws {
        let conflict = try #require(MergeConflict.parse(text))
        #expect(conflict.resolved([:]) == text)
        let resolved = conflict.resolved([0: .theirs, 1: .both])
        #expect(resolved == "package shop\n\nconst limit = 25\nfunc total() {}\n// ours\n// theirs\nend\n")
        #expect(!MergeConflict.hasMarkers(resolved))
        let partly = conflict.resolved([0: .custom("const limit = 20")])
        #expect(partly.contains("const limit = 20\nfunc total"))
        #expect(partly.contains("||||||| base\n// base\n"))
        #expect(MergeConflict.hasMarkers(partly))
    }

    @Test func choicesForEachSide() throws {
        let hunk = try #require(MergeConflict.parse(text)?.hunks[1])
        #expect(MergeConflict.text(for: .theirsThenOurs, in: hunk) == "// theirs\n// ours\n")
        #expect(MergeConflict.text(for: .base, in: hunk) == "// base\n")
        #expect(MergeConflict.text(for: .custom(""), in: hunk) == "")
    }

    @Test func basesComeFromADiff3Version() throws {
        let plain = try #require(MergeConflict.parse("<<<<<<< HEAD\na\n=======\nb\n>>>>>>> x\n"))
        let diff3 = try #require(MergeConflict.parse("<<<<<<< ours\na\n||||||| base\no\n=======\nb\n>>>>>>> theirs\n"))
        let filled = plain.fillingBases(from: diff3)
        #expect(filled.hunks[0].base == "o\n")
        // Filled-in bases don't add a section to the markers written back.
        #expect(filled.resolved([:]) == "<<<<<<< HEAD\na\n=======\nb\n>>>>>>> x\n")
    }

    @Test func anUnfinishedConflictIsLeftAsText() {
        #expect(MergeConflict.parse("<<<<<<< HEAD\na\n=======\nb\n") == nil)
        // Lines that only look like markers are text.
        #expect(MergeConflict.parse("<<<<<<<<< not\n========= no\n") == nil)
    }

    @Test func detectsTheOperationInProgress() {
        func detect(_ files: [String: String]) -> MergeOperation? { MergeOperation.detect { files[$0] } }
        let merge = detect(["MERGE_HEAD": "abc\n", "MERGE_MSG": "Merge branch 'feature/cart' into main\n\n# Conflicts:\n"])
        #expect(merge?.kind == .merge && merge?.subject == "feature/cart" && merge?.title == "Merging feature/cart")
        #expect(merge?.sides.theirs == "feature/cart")
        let rebase = detect(["rebase-merge/head-name": "refs/heads/checkout\n", "rebase-merge/msgnum": "2\n", "rebase-merge/end": "5\n"])
        #expect(rebase?.title == "Rebasing checkout · commit 2 of 5" && rebase?.sides.ours == "Upstream")
        #expect(rebase?.continueArguments == ["rebase", "--continue"])
        #expect(detect(["CHERRY_PICK_HEAD": "0123456789abcdef\n"])?.title == "Cherry-picking 01234567")
        #expect(detect(["CHERRY_PICK_HEAD": "x"])?.abortArguments == ["cherry-pick", "--abort"])
        #expect(detect([:]) == nil)
    }
}
