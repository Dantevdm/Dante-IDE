import DanteKit
import Testing

@Suite struct DocLibraryTests {
    let library = DocLibrary(paths: [
        "README.md", "CLAUDE.md",
        "docs/setup.md", "docs/plans/remote-ssh.md", "docs/plans/walk-and-work.md",
        "docs/images/map.jpg", "docs/images/code.jpg",
        ".dante/specs/checkout.md", ".dante/specs/payments/refunds.md",
        ".dante/jobs/builder.md", ".dante/notes.md",
        "frontend/README.md", "api/README.md",
    ])

    private func group(_ title: String) -> DocLibrary.Group { library.groups.first { $0.title == title }! }

    @Test func groupsSplitIntoFolders() {
        let docs = group("Docs").sections
        #expect(docs.map(\.folder) == ["", "images", "plans"])
        #expect(docs.map(\.title) == ["", "Images", "Plans"])
        #expect(docs[1].images.count == 2)
        #expect(docs[1].others.isEmpty)
        #expect(group("Specs").sections.map(\.folder) == ["", "payments"])
        #expect(group("Plan").sections.map(\.folder) == ["", "jobs"])
        #expect(group("Elsewhere").sections.map(\.folder) == ["api", "frontend"])
        #expect(group("Project").sections.map(\.folder) == [""])
    }

    @Test func sectionIDsAreUniqueAcrossGroups() {
        let ids = library.groups.flatMap(\.sections).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func filterMatchesEveryWordInTitleOrPath() {
        let found = library.filtered("plans walk")
        #expect(found.all.map(\.path) == ["docs/plans/walk-and-work.md"])
        #expect(library.filtered("readme").all.count == 3)
        #expect(library.filtered("  ").all.count == library.all.count)
        #expect(library.filtered("nothing-like-this").isEmpty)
    }

    @Test func libraryPathIsNotADoc() {
        #expect(library.doc(preferring: DocLibrary.libraryPath)?.path == "README.md")
    }

    @Test func excerptSkipsBadgesAndMarkup() {
        let markdown = """
        # Dante

        [![build](https://example.com/badge.svg)](https://example.com)

        A **native** macOS IDE where [Claude](https://claude.com) plans, builds and ships with you, `phase` by phase.
        """
        #expect(DocExcerpt.of(markdown) == "A native macOS IDE where Claude plans, builds and ships with you, phase by phase.")
    }

    @Test func excerptPrefersFrontMatterDescription() {
        let markdown = """
        ---
        name: builder
        description: "Takes a ready task and builds it on its own branch."
        ---

        # Builder

        Some longer explanation that should not be used for the excerpt at all.
        """
        #expect(DocExcerpt.of(markdown) == "Takes a ready task and builds it on its own branch.")
    }

    @Test func excerptIsShortenedAtAWord() {
        let long = String(repeating: "words go here ", count: 30)
        let excerpt = DocExcerpt.of(long)!
        #expect(excerpt.count <= DocExcerpt.length + 1)
        #expect(excerpt.hasSuffix("go…"))
        #expect(DocExcerpt.of("# Only a heading\n\n```\ncode\n```") == nil)
    }
}

@Suite struct SVGPathTests {
    @Test func readsAbsoluteAndRelativeCommands() {
        let commands = SVGPath.parse("M18.7 62.4L37.1 52.1H40V50C1 2 3 4 5 6Zm1-1l2,2")
        #expect(commands == [
            .move(.init(18.7, 62.4)), .line(.init(37.1, 52.1)), .line(.init(40, 52.1)), .line(.init(40, 50)),
            .curve(.init(1, 2), .init(3, 4), to: .init(5, 6)), .close,
            .move(.init(19.7, 61.4)), .line(.init(21.7, 63.4)),
        ])
    }

    @Test func pairsAfterAMoveAreLines() {
        #expect(SVGPath.parse("M0 0 10 0 10 10z") == [.move(.init(0, 0)), .line(.init(10, 0)), .line(.init(10, 10)), .close])
    }
}
