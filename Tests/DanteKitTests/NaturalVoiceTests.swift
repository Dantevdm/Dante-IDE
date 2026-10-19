@testable import DanteKit
import Foundation
import Testing

struct NaturalVoiceTests {
    @Test func speedFollowsTheSliderAroundNormal() {
        #expect(NaturalVoice.speed(forRate: 0.52) == 1)
        #expect(NaturalVoice.speed(forRate: 0.62) > 1.2)
        #expect(NaturalVoice.speed(forRate: 0.4) < 0.8)
        #expect(NaturalVoice.speed(forRate: 5) == 1.35)
    }

    @Test func unknownVoicesFallBackToTheDefault() {
        #expect(NaturalVoice.voice("bf_emma") == "bf_emma")
        #expect(NaturalVoice.voice("com.apple.voice.compact.en-GB.Daniel") == NaturalVoice.defaultVoice)
    }

    @Test func readsTheServersLines() {
        #expect(NaturalVoice.Reply.parse(#"{"ready": true}"#)?.ready == true)
        let reply = NaturalVoice.Reply.parse(#"{"id": 3, "path": "/tmp/3.f32", "rate": 24000, "samples": 100}"#)
        #expect(reply == NaturalVoice.Reply(ready: nil, id: 3, path: "/tmp/3.f32", rate: 24000, samples: 100, error: nil))
        #expect(NaturalVoice.Reply.parse(#"{"id": 4, "error": "no voice"}"#)?.error == "no voice")
        #expect(NaturalVoice.Reply.parse("Traceback (most recent call last):") == nil)
    }

    @Test func requestsAreOneJSONLine() throws {
        let line = NaturalVoice.request(id: 7, text: "Say \"hi\"\nthen stop.", voice: "af_heart", speed: 1.1)
        #expect(line.hasSuffix("\n"))
        #expect(line.dropLast().contains("\n") == false)
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["text"] as? String == "Say \"hi\"\nthen stop.")
        #expect(object["id"] as? Int == 7)
    }

    @Test func readsRawFloatSamples() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: url) }
        let values: [Float] = [0, 0.5, -0.25, 1]
        var data = Data()
        for value in values { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        try data.write(to: url)
        #expect(NaturalVoice.samples(at: url) == values)
        try Data([1, 2, 3]).write(to: url)
        #expect(NaturalVoice.samples(at: url) == nil)
    }

    @Test func installedOnlyWithThePythonAndWholeModelFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let python = NaturalVoice.python(in: folder)
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        #expect(!NaturalVoice.isInstalled(in: folder))
        // Sparse files of the right sizes stand in for the model.
        for download in NaturalVoice.downloads {
            let url = folder.appending(path: download.name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(download.bytes - (download == NaturalVoice.downloads.last ? 1 : 0)))
            try handle.close()
        }
        #expect(!NaturalVoice.isInstalled(in: folder))
        let last = try FileHandle(forWritingTo: folder.appending(path: NaturalVoice.downloads.last!.name))
        try last.truncate(atOffset: UInt64(NaturalVoice.downloads.last!.bytes))
        try last.close()
        #expect(NaturalVoice.isInstalled(in: folder))
    }

    @Test func theScriptIsWrittenOnceAndKeptCurrent() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try NaturalVoice.writeScript(in: folder)
        #expect(try String(contentsOf: NaturalVoice.server(in: folder), encoding: .utf8) == NaturalVoice.script)
        try "old".write(to: NaturalVoice.server(in: folder), atomically: true, encoding: .utf8)
        try NaturalVoice.writeScript(in: folder)
        #expect(try String(contentsOf: NaturalVoice.server(in: folder), encoding: .utf8) == NaturalVoice.script)
    }
}
