import Foundation
import Testing
@testable import DanteKit

struct CompanionPagesTests {
    static let files = ["README.md", "docs/guide.md", "docs/images/map.png", "docs/spec.pdf", "docs/diagrams/flow.dante-diagram.json",
                        "docs/motion/intro/motion.yaml", "src/main.go", ".env", ".github/workflows/ci.yml", "assets/logo.png", ".git/config"]

    @Test func listsWhatAPhoneCanShowWithHowItWorksFirst() {
        let library = CompanionPages.library(project: "p", files: Self.files, hasSystem: true, hasInfrastructure: false)
        #expect(library.sections.first?.title == "How it works")
        #expect(library.sections.first?.entries.map(\.path) == [CompanionPage.Special.system])
        let paths = Set(library.entries.map(\.path))
        #expect(paths.isSuperset(of: ["README.md", "docs/guide.md", "docs/spec.pdf", "docs/diagrams/flow.dante-diagram.json"]))
        #expect(!paths.contains("docs/motion/intro/motion.yaml") && !paths.contains("src/main.go"))
        #expect(library.entries.first { $0.path == "docs/spec.pdf" }?.kind == .pdf)
    }

    @Test func aDeviceMayOnlyAskForDocsAndPictures() {
        let files = Set(Self.files)
        #expect(CompanionPages.page(for: "README.md", files: files) == .markdown)
        #expect(CompanionPages.page(for: "assets/logo.png", files: files) == .image)
        #expect(CompanionPages.page(for: "docs/diagrams/flow.dante-diagram.json", files: files) == .diagram)
        #expect(CompanionPages.page(for: CompanionPage.Special.infrastructure, files: files) == .diagram)
        for refused in ["src/main.go", ".env", ".github/workflows/ci.yml", ".git/config", "docs/missing.md", "../outside.md"] {
            #expect(CompanionPages.page(for: refused, files: files) == nil, "\(refused)")
        }
    }

    @Test func markdownBecomesBlocksWithFigures() {
        let markdown = """
        # Orders

        How an order flows:

        ```mermaid
        sequenceDiagram
          Web->>API: POST /orders
        ```

        ![The map](../images/map.png)

        ![Badge](https://example.com/badge.svg)

        - [x] Done
        1. First

        ```swift
        let a = 1
        ```
        """
        let (blocks, mermaid) = CompanionPages.blocks(markdown, path: "docs/guide/orders.md")
        #expect(mermaid.count == 1 && mermaid[0].hasPrefix("sequenceDiagram"))
        #expect(blocks.first == .heading(level: 1, text: "Orders"))
        #expect(blocks.contains(.figure(.init(index: 0, caption: "Sequence diagram"))))
        #expect(blocks.contains(.figure(.init(path: "docs/images/map.png", caption: "The map"))))
        #expect(blocks.contains(.paragraph("*Badge*")))
        #expect(blocks.contains(.item(text: "Done", depth: 0, marker: "☑")))
        #expect(blocks.contains(.item(text: "First", depth: 0, marker: "1.")))
        #expect(blocks.contains(.code("let a = 1", language: "swift")))
    }

    @Test func picturePathsStayInTheProject() {
        #expect(CompanionPages.resolve("./a.png", from: "docs/x.md") == "docs/a.png")
        #expect(CompanionPages.resolve("/docs/a.png", from: "docs/x.md") == "docs/a.png")
        #expect(CompanionPages.resolve("../../a.png", from: "docs/x.md") == nil)
        #expect(CompanionPages.resolve("my%20shot.png?raw=1", from: "README.md") == "my shot.png")
        #expect(CompanionPages.resolve("data:image/png;base64,AA", from: "README.md") == nil)
    }

    @Test func theHashFollowsTheFileAndTheSize() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("README.md", "# A")
        let phone = CompanionPageRequest(path: "README.md", width: 390, scale: 3, dark: false)
        let first = CompanionPages.hash(of: phone, file: file)
        #expect(first == CompanionPages.hash(of: phone, file: file))
        var pad = phone
        pad.width = 820
        #expect(CompanionPages.hash(of: pad, file: file) != first)
        var dark = phone
        dark.dark = true
        #expect(CompanionPages.hash(of: dark, file: file) != first)
        try Data("# A longer one".utf8).write(to: file)
        #expect(CompanionPages.hash(of: phone, file: file) != first)
        #expect(phone.pixelWidth == 1170 && CompanionPageRequest(path: "x", width: 2000, scale: 2, dark: false).pixelWidth == 2732)
    }
}
