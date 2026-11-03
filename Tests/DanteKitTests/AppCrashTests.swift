import Foundation
import Testing
@testable import DanteKit

struct AppCrashTests {
    static let header = #"{"app_name":"Dante","timestamp":"2026-11-03 13:37:17.00 +0200","app_version":"0.1","build_version":"abc1234","bundleID":"dev.dante.ide","bug_type":"309"}"#
    static let body = #"""
    {
      "captureTime" : "2026-11-03 13:37:13.3617 +0200",
      "osVersion" : {"train" : "macOS 27.2", "build" : "26B1"},
      "exception" : {"type" : "EXC_BAD_ACCESS", "signal" : "SIGSEGV"},
      "termination" : {"indicator" : "Segmentation fault: 11"},
      "asi" : {"libswiftCore.dylib" : ["Fatal error: Index out of range"]},
      "faultingThread" : 1,
      "threads" : [
        {"frames" : [{"imageIndex" : 1, "symbol" : "mach_msg"}]},
        {"queue" : "com.apple.main-thread", "frames" : [
          {"imageIndex" : 1, "symbol" : "swift_getObjectType"},
          {"imageIndex" : 0, "symbol" : "SystemDiagram.diagram.getter", "sourceFile" : "/home/me/shop/Map.swift", "sourceLine" : 42},
          {"imageIndex" : 2, "imageOffset" : 255}
        ]}
      ],
      "usedImages" : [{"name" : "Dante"}, {"name" : "libswiftCore.dylib"}, {"name" : "SwiftUI"}]
    }
    """#

    @Test func readsTheCrashedThread() throws {
        let report = try #require(AppCrash.parse(Self.header + "\n" + Self.body, file: URL(fileURLWithPath: "/home/me/a.ips")))
        #expect(report.version == "0.1")
        #expect(report.build == "abc1234")
        #expect(report.os == "macOS 27.2 (26B1)")
        #expect(report.exception == "EXC_BAD_ACCESS SIGSEGV")
        #expect(report.termination == "Segmentation fault: 11")
        #expect(report.message == "Fatal error: Index out of range")
        #expect(report.queue == "com.apple.main-thread")
        #expect(report.frames.map(\.image) == ["libswiftCore.dylib", "Dante", "SwiftUI"])
        #expect(report.frames[2].symbol == "0xff")
        #expect(report.danteFrame?.symbol == "SystemDiagram.diagram.getter")
        #expect(report.headline == "SystemDiagram.diagram.getter")
        #expect(report.frames[1].text.hasSuffix("(Map.swift:42)"))
        #expect(report.summary.contains("Crashed thread, top frames:"))
        #expect(AppCrash.date("2026-11-03 13:37:17.00 +0200") == report.date)
    }

    @Test func refusesWhatIsntAReport() {
        #expect(AppCrash.parse("not json", file: URL(fileURLWithPath: "/home/me/a.ips")) == nil)
        #expect(AppCrash.parse(Self.header, file: URL(fileURLWithPath: "/home/me/a.ips")) == nil)
    }

    @Test func listsOnlyThisAppsReportsNewestFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "Retired"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let older = Self.header.replacingOccurrences(of: "13:37:17", with: "09:00:00")
        try (Self.header + "\n" + Self.body).write(to: folder.appending(path: "Dante-1.ips"), atomically: true, encoding: .utf8)
        try (older + "\n" + Self.body).write(to: folder.appending(path: "Retired/Dante-0.ips"), atomically: true, encoding: .utf8)
        let other = Self.header.replacingOccurrences(of: "dev.dante.ide", with: "dev.dante.stagetest")
        try (other + "\n" + Self.body).write(to: folder.appending(path: "Dante-2.ips"), atomically: true, encoding: .utf8)
        let reports = AppCrash.list(in: folder, bundleID: "dev.dante.ide")
        #expect(reports.map(\.file.lastPathComponent) == ["Dante-1.ips", "Dante-0.ips"])
    }
}
