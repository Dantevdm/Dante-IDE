@testable import DanteKit
import Testing

struct MarkdownHTMLTests {
    @Test func readsAReadmesHTMLHeader() {
        let document = MarkdownDocument("""
            <p align="center"><img src="docs/images/icon.png" width="128" alt="The icon"></p>

            <h1 align="center">Dante</h1>

            <!-- badges -->
            <p align="center">A native IDE &amp; more, with <b>Claude</b>.</p>

            Plain text with <kbd>⌘K</kbd> inline stays a paragraph.
            """)
        #expect(document.blocks == [
            .image(alt: "The icon", source: "docs/images/icon.png", width: 128),
            .heading(level: 1, text: "Dante", anchor: "dante"),
            .paragraph("A native IDE & more, with Claude."),
            .paragraph("Plain text with <kbd>⌘K</kbd> inline stays a paragraph."),
        ])
        #expect(document.title == "Dante")
    }

    @Test func readsAttributesInEitherQuoteStyle() {
        #expect(MarkdownDocument.attribute("src", in: "<img src='a.png' alt=logo>") == "a.png")
        #expect(MarkdownDocument.attribute("alt", in: "<img src='a.png' alt=logo>") == "logo")
        #expect(MarkdownDocument.attribute("width", in: "<img src=a.png>") == nil)
    }
}
