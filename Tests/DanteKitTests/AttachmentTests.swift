import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DanteKit

@Suite struct AttachmentTests {
    /// A solid PNG of the given size.
    private func png(width: Int, height: Int, alpha: Bool) throws -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func textFilesGoAsText() async throws {
        let folder = try TemporaryFolder()
        let url = try folder.write("notes.txt", "line one\nline two")
        let attachment = try await Attachment.load(url)
        #expect(attachment.kind == .text("line one\nline two"))
        #expect(attachment.summary == "2 lines")
        let block = attachment.contentBlock
        #expect(block["type"]?.string == "text")
        #expect(block["text"]?.string?.contains("<attachment name=\"notes.txt\">") == true)
    }

    @Test func smallImagesGoAsTheyAre() async throws {
        let folder = try TemporaryFolder()
        let data = try png(width: 40, height: 30, alpha: true)
        let url = folder.url.appending(path: "shot.png")
        try data.write(to: url)
        let attachment = try await Attachment.load(url)
        #expect(attachment.kind == .image(mediaType: "image/png", base64: data.base64EncodedString()))
        #expect(attachment.note == nil)
        #expect(attachment.contentBlock["source"]?["media_type"]?.string == "image/png")
    }

    @Test func largeImagesAreScaledDown() async throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appending(path: "big.png")
        try png(width: 3000, height: 1500, alpha: false).write(to: url)
        let attachment = try await Attachment.load(url)
        guard case .image(let mediaType, let base64) = attachment.kind, let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("expected an image")
            return
        }
        #expect(mediaType == "image/jpeg")
        #expect(max(image.width, image.height) == Attachment.maxImageSide)
        #expect(attachment.note?.hasPrefix("resized") == true)
    }

    @Test func pdfsGoAsDocuments() async throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appending(path: "spec.pdf")
        try Data("%PDF-1.4\n%%EOF".utf8).write(to: url)
        let attachment = try await Attachment.load(url)
        let block = attachment.contentBlock
        #expect(block["type"]?.string == "document")
        #expect(block["title"]?.string == "spec.pdf")
        #expect(block["source"]?["media_type"]?.string == "application/pdf")
    }

    @Test func binaryFilesArePassedByPath() async throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appending(path: "model.bin")
        try Data([0, 1, 2, 0, 255]).write(to: url)
        let attachment = try await Attachment.load(url)
        #expect(attachment.kind == .reference)
        #expect(attachment.contentBlock["text"]?.string?.contains("path=\"\(url.path)\"") == true)
    }

    @Test func rtfIsConvertedToText() async throws {
        let folder = try TemporaryFolder()
        let url = try folder.write("brief.rtf", #"{\rtf1\ansi Hello {\b brief}.}"#)
        let attachment = try await Attachment.load(url)
        guard case .text(let text) = attachment.kind else {
            Issue.record("expected text, got \(attachment.kind)")
            return
        }
        #expect(text.contains("Hello brief."))
        #expect(attachment.note == "converted to text")
    }

    @Test func messagesWithAttachmentsUseContentBlocks() {
        let attachment = Attachment(url: URL(filePath: "/tmp/a.txt"), kind: .text("hi"))
        let message = ClaudeInput.userMessage("What is this?", attachments: [attachment])
        let content = message["message"]?["content"]?.array
        #expect(content?.count == 2)
        #expect(content?.first?["type"]?.string == "text")
        #expect(content?.last?["text"]?.string == "What is this?")
        #expect(ClaudeInput.userMessage("plain")["message"]?["content"]?.string == "plain")
    }
}

@Suite struct DocFilesTests {
    @Test func filesCountAsDocsOnlyInDocFolders() {
        #expect(DocLibrary.isDoc("docs/spec.pdf"))
        #expect(DocLibrary.isDoc(".dante/specs/flow.png"))
        #expect(DocLibrary.isDoc("Documentation/brief.docx"))
        #expect(!DocLibrary.isDoc("Sources/App/Assets/icon.png"))
        #expect(!DocLibrary.isDoc("logo.png"))
        #expect(DocLibrary.isDoc("NOTES.md"))
        // Documents at the root are docs; documents deep in the code are assets.
        #expect(DocLibrary.isDoc("Architecture Overview.pdf"))
        #expect(DocLibrary.isDoc("docs/roadmap.key"))
        #expect(DocLibrary.Doc(path: "docs/roadmap.key").kind == .slides)
        #expect(DocLibrary.Doc(path: "budget.xlsx").kind == .slides)
        #expect(!DocLibrary.isDoc("frontend/public/terms.pdf"))
    }

    @Test func kindsAndOrder() {
        let library = DocLibrary(paths: ["docs/spec.pdf", "docs/spec.md", "docs/flow.png", "assets/icon.png"])
        let docs = library.groups.first { $0.title == "Docs" }?.docs ?? []
        #expect(docs.map(\.path) == ["docs/spec.md", "docs/flow.png", "docs/spec.pdf"])
        #expect(docs.map(\.kind) == [.markdown, .image, .pdf])
        #expect(docs[2].title == "spec.pdf")
    }

    @Test func importsAreNumberedWhenTaken() {
        #expect(DocLibrary.importPath(for: "brief.pdf", existing: []) == "docs/brief.pdf")
        #expect(DocLibrary.importPath(for: "brief.pdf", existing: ["docs/brief.pdf", "docs/brief 2.pdf"]) == "docs/brief 3.pdf")
    }

    @Test func imagesOnTheirOwnLine() {
        let document = MarkdownDocument("""
        # Flow

        ![The checkout flow](flow.png)

        Text with ![inline](x.png) stays a paragraph.
        """)
        #expect(document.blocks.contains(.image(alt: "The checkout flow", source: "flow.png")))
        #expect(document.blocks.contains(.paragraph("Text with ![inline](x.png) stays a paragraph.")))
    }
}
