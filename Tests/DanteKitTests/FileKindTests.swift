import Foundation
import Testing
@testable import DanteKit

struct FileKindTests {
    @Test func kindsComeFromTheExtension() {
        #expect(FileKind.of(URL(filePath: "/home/me/docs/Overview.PDF")) == .pdf)
        #expect(FileKind.of(URL(filePath: "/home/me/logo.png")) == .image)
        #expect(FileKind.of(URL(filePath: "/home/me/spec.docx")) == .document)
        #expect(FileKind.of(URL(filePath: "/home/me/demo.mov")) == .media)
        #expect(FileKind.of(URL(filePath: "/home/me/budget.xlsx")) == .quickLook)
        #expect(FileKind.of(URL(filePath: "/home/me/data/app.db")) == .binary)
        #expect(FileKind.of(URL(filePath: "/home/me/main.go")) == .text)
        #expect(FileKind.of(URL(filePath: "/home/me/icon.svg")) == .text)
        #expect(FileKind.of(URL(filePath: "/home/me/Makefile")) == .text)
    }

    @Test func nulBytesOrBadUTF8AreBinary() {
        #expect(FileKind.looksBinary(Data([0x7f, 0x45, 0x4c, 0x46, 0x00, 0x01])))
        #expect(FileKind.looksBinary(Data([0xff, 0xfe, 0xfd])))
        #expect(!FileKind.looksBinary(Data("hello\n".utf8)))
    }

    @MainActor
    @Test func aViewerTabNeverWritesOverItsFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "filekind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let pdf = folder.appending(path: "Overview.pdf")
        try Data("%PDF-1.4 not really".utf8).write(to: pdf)
        let document = try EditorDocument(url: pdf)
        #expect(document.kind == .pdf)
        #expect(document.text.isEmpty)
        try document.save()
        #expect(try Data(contentsOf: pdf) == Data("%PDF-1.4 not really".utf8))

        // No telling extension: the bytes decide.
        let blob = folder.appending(path: "payload")
        try Data([0x00, 0x01, 0x02]).write(to: blob)
        #expect(try EditorDocument(url: blob).kind == .binary)

        let text = folder.appending(path: "notes")
        try Data("plain".utf8).write(to: text)
        let notes = try EditorDocument(url: text)
        #expect(notes.kind == .text)
        #expect(notes.text == "plain")
    }
}
