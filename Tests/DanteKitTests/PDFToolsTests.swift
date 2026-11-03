import AppKit
import Foundation
import PDFKit
import Testing
@testable import DanteKit

@MainActor
struct PDFToolsTests {
    /// A PDF with one line of text per page: "Page 1 of the shop report" and so on.
    static func sample(pages: Int) -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for n in 1...pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(string: "Page \(n) of the shop report", attributes: [.font: NSFont.systemFont(ofSize: 14)])
                .draw(at: CGPoint(x: 20, y: 360))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return PDFDocument(data: data as Data)!
    }

    static func numbers(_ document: PDFDocument) -> [Int] {
        (0..<document.pageCount).compactMap { index in
            document.page(at: index)?.string?.split(separator: " ").dropFirst().first.flatMap { Int($0) }
        }
    }

    /// A bookmark per page, "Part 1" and so on.
    static func bookmarked(pages: Int) -> PDFDocument {
        let document = sample(pages: pages)
        let root = PDFOutline()
        for index in 0..<pages {
            let item = PDFOutline()
            item.label = "Part \(index + 1)"
            item.destination = PDFDestination(page: document.page(at: index)!, at: CGPoint(x: 0, y: 400))
            root.insertChild(item, at: index)
        }
        document.outlineRoot = root
        return document
    }

    @Test func bookmarksSurvivePageChangesAndASave() throws {
        let document = Self.bookmarked(pages: 4)
        PDFTools.move(document, pages: [3], to: 0)
        let removed = PDFTools.delete(document, pages: [1])
        PDFTools.restore(removed, into: document)
        PDFTools.rotate(document, pages: [0], by: 90)
        let url = FileManager.default.temporaryDirectory.appending(path: "bookmarks-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try PDFTools.save(document, to: url)
        let saved = try #require(PDFDocument(url: url))
        #expect(PDFTools.info(saved).bookmarks == 4)
        let first = try #require(saved.outlineRoot?.child(at: 3)?.destination?.page)
        #expect(saved.index(for: first) == 0)
    }

    @Test func readsPageRanges() throws {
        #expect(try PDFTools.pages("1-3, 5, 8-", count: 9) == [0, 1, 2, 4, 7, 8])
        #expect(try PDFTools.pages("", count: 3) == [0, 1, 2])
        #expect(try PDFTools.pages("-2,last", count: 4) == [0, 1, 3])
        #expect(try PDFTools.pages("3-1", count: 4) == [2, 1, 0])
        #expect(try PDFTools.pages("2,2,1-2", count: 4) == [1, 0])
        #expect(throws: PDFTools.Failure.self) { try PDFTools.pages("7", count: 4) }
        #expect(throws: PDFTools.Failure.self) { try PDFTools.pages("x", count: 4) }
    }

    @Test func reordersAndSplits() {
        #expect(PDFTools.reordered(count: 5, moving: [3], to: 0) == [3, 0, 1, 2, 4])
        #expect(PDFTools.reordered(count: 5, moving: [0, 1], to: 5) == [2, 3, 4, 0, 1])
        #expect(PDFTools.reordered(count: 5, moving: [1, 3], to: 3) == [0, 2, 1, 3, 4])
        #expect(PDFTools.parts(cuttingAt: [3, 1, 9], count: 5) == [0..<1, 1..<3, 3..<5])
        #expect(PDFTools.splitPoints(every: 2, count: 5) == [0, 2, 4])
        let urls = PDFTools.partURLs(for: URL(fileURLWithPath: "/home/me/report.pdf"), count: 12)
        #expect(urls.first?.lastPathComponent == "report-01.pdf")
        #expect(urls.last?.lastPathComponent == "report-12.pdf")
    }

    @Test func organisesPages() {
        let document = Self.sample(pages: 4)
        #expect(Self.numbers(document) == [1, 2, 3, 4])
        let moved = PDFTools.move(document, pages: [3], to: 0)
        #expect(moved == [0])
        #expect(Self.numbers(document) == [4, 1, 2, 3])
        let removed = PDFTools.delete(document, pages: [1, 3])
        #expect(Self.numbers(document) == [4, 2])
        PDFTools.restore(removed, into: document)
        #expect(Self.numbers(document) == [4, 1, 2, 3])
        PDFTools.rotate(document, pages: [0], by: -90)
        #expect(document.page(at: 0)?.rotation == 270)
        PDFTools.insertBlank(document, at: 1, like: document.page(at: 0))
        #expect(document.pageCount == 5)
    }

    @Test func combinesExtractsAndSplits() {
        let combined = PDFTools.combine([Self.sample(pages: 2), Self.sample(pages: 3)])
        #expect(Self.numbers(combined) == [1, 2, 1, 2, 3])
        #expect(Self.numbers(PDFTools.extract(combined, pages: [4, 0])) == [3, 1])
        let parts = PDFTools.split(combined, cuttingAt: [2])
        #expect(parts.map(\.pageCount) == [2, 3])
        #expect(PDFTools.info(combined).pages == 5)
        #expect(PDFTools.text(combined, pages: [1]).contains("Page 2 of the shop report"))
    }

    @Test func commentsThreadAndSurviveASave() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = Self.sample(pages: 2)
        let page = try #require(document.page(at: 1))
        let passage = try #require(page.selection(for: CGRect(x: 0, y: 340, width: 300, height: 60)))
        let added = PDFTools.comment("Is this the final figure?", by: "Ana", on: page, passage: passage)
        #expect(!added.isEmpty)
        PDFTools.reply("Yes, from the October run", by: "Sam", to: added[0])
        let note = PDFTools.comment("Add a summary page", by: "Sam", on: try #require(document.page(at: 0)))
        PDFTools.reply("Will do", by: "Ana", to: note[0])

        let url = folder.appending(path: "report.pdf")
        try PDFTools.save(document, to: url)
        try PDFTools.save(document, to: url)
        let reopened = try PDFTools.open(url)
        let threads = PDFTools.threads(in: reopened)
        #expect(threads.count == 2)
        let passageThread = try #require(threads.first { $0.page == 1 })
        #expect(passageThread.author == "Ana")
        #expect(passageThread.text == "Is this the final figure?")
        #expect(passageThread.replies.map(\.contents) == ["Yes, from the October run"])
        #expect(passageThread.quote?.contains("shop report") == true)
        #expect(threads.first { $0.page == 0 }?.replies.map(\.contents) == ["Will do"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["report.pdf"])
    }

    @Test func protectsWithAPassword() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "locked.pdf")
        let secret = ["open", "sesame"].joined(separator: "-")
        try PDFTools.save(Self.sample(pages: 1), to: url, password: secret)
        #expect(throws: PDFTools.Failure.locked("locked.pdf")) { try PDFTools.open(url) }
        let opened = try PDFTools.open(url, password: secret)
        #expect(opened.pageCount == 1)
        #expect(PDFTools.info(opened).encrypted)
    }

    @Test func recoveryCopiesAreNewerThanTheFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "a.pdf")
        try PDFTools.save(Self.sample(pages: 1), to: file)
        let recovery = folder.appending(path: "recovery")
        #expect(PDFRecovery.pending(for: file, in: recovery) == nil)
        PDFRecovery.keep(Self.sample(pages: 2), for: file, in: recovery)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: PDFRecovery.url(for: file, in: recovery).path)
        #expect(PDFRecovery.pending(for: file, in: recovery) != nil)
        PDFRecovery.discard(for: file, in: recovery)
        #expect(PDFRecovery.pending(for: file, in: recovery) == nil)
    }
}
