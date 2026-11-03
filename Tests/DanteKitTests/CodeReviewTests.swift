import Foundation
import Testing
@testable import DanteKit

struct CodeReviewTests {
    let day = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func linesRoundTripAndBadLinesAreSkipped() {
        let mark = CodeReview.Mark(path: "src/orders/api.go", blob: "abc", by: "Ana", at: day, verdict: .concern, note: "Retries forever")
        let request = CodeReview.Request(paths: ["src/orders"], reviewer: "Sam", by: "Ana", at: day.addingTimeInterval(60))
        let text = [CodeReview.line(mark), "not json", #"{"type":"mark","by":"Sam"}"#, CodeReview.line(request)].joined(separator: "\n")
        let log = CodeReview.parse(text)
        #expect(log.marks == [mark])
        #expect(log.requests == [request])
        #expect(CodeReview.line(mark).contains(#""path":"src/orders/api.go""#))
    }

    @Test func coverageFollowsTheCurrentVersion() {
        let log = CodeReview.Log(marks: [
            .init(path: "a.swift", blob: "1", by: "Ana", at: day),
            .init(path: "a.swift", blob: "1", by: "Sam", at: day),
            .init(path: "b.swift", blob: "old", by: "Ana", at: day),
            .init(path: "c.swift", blob: "3", by: "Ana", at: day),
            .init(path: "d.swift", blob: "4", by: "Sam", at: day, verdict: .concern, note: "Leaks"),
            .init(path: "e.swift", blob: "5", by: "Ana", at: day),
            .init(path: "e.swift", blob: "5", by: "Ana", at: day.addingTimeInterval(5), verdict: .cleared),
            .init(path: "gone.swift", blob: "9", by: "Ana", at: day),
        ])
        let coverage = CodeReview.coverage(blobs: ["a.swift": "1", "b.swift": "2", "c.swift": "3", "d.swift": "4", "e.swift": "5", "f.swift": "6"],
                                           log: log, required: 2)
        let states = Dictionary(uniqueKeysWithValues: coverage.files.map { ($0.path, $0.state) })
        #expect(states == ["a.swift": .reviewed, "b.swift": .changed, "c.swift": .partly, "d.swift": .concern, "e.swift": .notReviewed, "f.swift": .notReviewed])
        #expect(coverage.reviewed == 1)
        #expect(coverage.looked == 3)
        #expect(coverage.people.map(\.name) == ["Ana", "Sam"])
        #expect(coverage.people.first { $0.name == "Sam" }?.concerns == 1)
    }

    @Test func requestsStandUntilTheReviewerReadsThisVersion() {
        let log = CodeReview.Log(
            marks: [.init(path: "api/a.go", blob: "1", by: "sam", at: day.addingTimeInterval(10))],
            requests: [.init(paths: ["api"], reviewer: "Sam", by: "Ana", at: day), .init(paths: [""], reviewer: "Lee", by: "Ana", at: day)])
        let coverage = CodeReview.coverage(blobs: ["api/a.go": "1", "api/b.go": "2", "web/c.ts": "3"], log: log)
        #expect(coverage.askedOf("Sam").map(\.path) == ["api/b.go"])
        #expect(coverage.askedOf("lee").count == 3)
        #expect(coverage.openRequests.count == 2)
        #expect(coverage.folders().map(\.path) == ["api", "web"])
    }

    @Test func policyAndWhatCountsAsCode() {
        let policy = CodeReview.Policy.parse(projectYAML: "review:\n  required: 2\n  include: [config/*.yaml]\n  exclude: [scripts/]\n")
        #expect(policy.required == 2)
        #expect(policy.counts("Sources/App/Main.swift"))
        #expect(policy.counts("config/app.yaml"))
        #expect(!policy.counts("scripts/build.sh"))
        #expect(!policy.counts("README.md"))
        #expect(!policy.counts("web/node_modules/x/index.js"))
        #expect(!policy.counts("web/dist/app.min.js"))
        #expect(policy.counts("Dockerfile"))
        #expect(CodeReview.Policy.parse(projectYAML: "name: shop").required == 1)
    }

    @Test func readsLsFiles() {
        let output = "100644 aaa 0\tsrc/a.swift\u{0}100644 bbb 1\tsrc/conflict.swift\u{0}100755 ccc 0\tdir with space/run.sh\u{0}"
        #expect(CodeReview.blobs(fromLsFiles: output) == ["src/a.swift": "aaa", "dir with space/run.sh": "ccc"])
        #expect(CodeReview.initials("Ana Smith") == "AS")
        #expect(CodeReview.initials("sam") == "S")
    }

    @Test func appendsAndAddsTheMergeAttributeOnce() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "*.png binary".write(to: root.appending(path: ".gitattributes"), atomically: true, encoding: .utf8)
        let mark = CodeReview.Mark(path: "a.go", blob: "1", by: "Ana", at: day)
        try CodeReview.append([CodeReview.line(mark)], in: root)
        try CodeReview.append([CodeReview.line(mark)], in: root)
        #expect(CodeReview.load(in: root).marks.count == 2)
        let attributes = try String(contentsOf: root.appending(path: ".gitattributes"), encoding: .utf8)
        #expect(attributes.hasPrefix("*.png binary\n"))
        #expect(attributes.components(separatedBy: CodeReview.attribute).count == 2)
    }
}
