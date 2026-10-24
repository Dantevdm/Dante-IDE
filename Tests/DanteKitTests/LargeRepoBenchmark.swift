import DanteKit
import Foundation
import Testing

/// Times the whole-project passes on a generated 50,000-file repository. Slow to set up,
/// so it only runs with `DANTE_BENCH=1 swift test --filter LargeRepoBenchmark`.
struct LargeRepoBenchmark {
    static let enabled = ProcessInfo.processInfo.environment["DANTE_BENCH"] == "1"

    @Test(.enabled(if: enabled), .timeLimit(.minutes(10)))
    func fiftyThousandFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "dante-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let generate = ContinuousClock().measure { try! Self.generate(in: root, files: 50_000) }

        var timings: [(String, Duration)] = [("generate", generate)]
        func time<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
            let start = ContinuousClock.now
            let value = try work()
            timings.append((name, ContinuousClock.now - start))
            return value
        }

        let files = time("FileIndex.scan") { FileIndex.scan(root) }
        #expect(files.count == FileIndex.limit)
        _ = time("FuzzyMatch.rank") { FuzzyMatch.rank("ordhandler", in: files) }

        var start = ContinuousClock.now
        let literal = await ProjectSearch.run(.init(text: "ErrNotFound"), root: root, paths: files)
        timings.append(("search, literal", ContinuousClock.now - start))
        #expect(literal.matchCount > 0)
        start = ContinuousClock.now
        let none = await ProjectSearch.run(.init(text: "zz_never_\\d+", isRegex: true), root: root, paths: files)
        timings.append(("search, regex, no hits", ContinuousClock.now - start))
        #expect(none.matchCount == 0)

        let testPaths = time("  test files: pick") { files.filter(TestInventory.isTestFile) }
        let texts = time("  test files: read") { testPaths.map { try! String(contentsOf: root.appending(path: $0), encoding: .utf8) } }
        _ = time("  test files: parse") { zip(testPaths, texts).map { TestInventory.tests(in: $1, path: $0) } }
        let inventory = time("TestInventory.load") { TestInventory.load(root: root, files: files) }
        #expect(inventory.tests.count > 10_000)
        let sourcePaths = files.filter { !TestInventory.isTestFile($0) }
        let sources = time("  sources: read") { sourcePaths.map { ($0, try! String(contentsOf: root.appending(path: $0), encoding: .utf8)) } }
        _ = time("  sources: declarations") { TestGaps.find(sources: sources, testText: "", testFiles: testPaths) }
        _ = time("TestGaps.load") { TestGaps.load(root: root, files: files, inventory: inventory) }
        _ = time("TestImpact") { TestImpact.tests(for: ["svc/s0007/pkg3/handler12.go"], in: inventory) }

        let read: @Sendable (String) -> String? = { try? String(contentsOf: root.appending(path: $0), encoding: .utf8) }
        let modules = time("Map: modules") { ArchitectureGraph.goModules(files: files, read: read) ?? ArchitectureGraph.folders(files) }
        let system = time("Map: system") { SystemMap.build(files: files, read: read, modules: modules) }
        #expect(!system.lanes.isEmpty)
        _ = time("Security scan") { SecurityScanner.scan(files: files, read: read) }

        let report = timings.map { "\($0.0): \($0.1.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))" }
        print("Large repo (\(files.count) files)\n  " + report.joined(separator: "\n  "))
    }

    /// Go services and a TypeScript app, one test file for every four sources.
    static func generate(in root: URL, files: Int) throws {
        let manager = FileManager.default
        var written = 0
        var service = 0
        while written < files {
            for package in 0..<10 where written < files {
                let folder = root.appending(path: service.isMultiple(of: 3) ? "web/src/feature\(service)/part\(package)" : String(format: "svc/s%04d/pkg%d", service, package))
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                let typescript = service.isMultiple(of: 3)
                for file in 0..<20 where written < files {
                    let isTest = file % 5 == 4
                    let name: String
                    let text: String
                    if typescript {
                        name = isTest ? "handler\(file - 1).test.ts" : "handler\(file).ts"
                        text = isTest
                            ? "import { handle\(file - 1) } from './handler\(file - 1)'\n\ndescribe('handler', () => {\n  it('handles orders', () => {\n    expect(handle\(file - 1)({ id: 1 })).toBeDefined()\n  })\n  test('rejects bad input', () => {})\n})\n"
                            : "export class Order\(file) { id = 0 }\n\nexport function handle\(file)(order: { id: number }) {\n  if (!order) throw new Error('ErrNotFound')\n  return order.id * \(file)\n}\n"
                    } else {
                        name = isTest ? "handler\(file - 1)_test.go" : "handler\(file).go"
                        text = isTest
                            ? "package pkg\(package)\n\nimport \"testing\"\n\nfunc TestHandle\(file - 1)(t *testing.T) {\n\tif Handle\(file - 1)(1) == 0 {\n\t\tt.Fatal(\"zero\")\n\t}\n}\n\nfunc TestHandle\(file - 1)Errors(t *testing.T) {}\n"
                            : "package pkg\(package)\n\nimport \"errors\"\n\nvar ErrNotFound = errors.New(\"not found\")\n\ntype Order\(file) struct{ ID int }\n\nfunc Handle\(file)(id int) int {\n\tif id < 0 {\n\t\treturn 0\n\t}\n\treturn id * \(file)\n}\n"
                    }
                    try text.write(to: folder.appending(path: name), atomically: false, encoding: .utf8)
                    written += 1
                }
            }
            service += 1
        }
    }
}
