import Foundation

/// Where a file sits in a project: code that ships, tests (and what only tests use: fixtures,
/// mocks, test data), or docs and examples. Each language marks its tests its own way, mostly by
/// name or folder (Go can only say so in the file name, `_test.go`), so this reads all of them.
public enum CodePlace: String, Codable, Sendable, CaseIterable {
    case shipped, tests, docs

    /// `tests` adds a project's own test paths: folders ("qa/") or globs ("*_it.go").
    public static func of(_ path: String, tests: [String] = []) -> CodePlace {
        if tests.contains(where: { ClaudeRules.path(path, matches: $0) }) { return .tests }
        let folders = path.split(separator: "/").dropLast().map(String.init)
        let name = (path as NSString).lastPathComponent
        if folders.contains(where: isTestFolder) || isTestName(name) { return .tests }
        if folders.contains(where: { docFolders.contains($0.lowercased()) }) || docExtensions.contains((name as NSString).pathExtension.lowercased()) {
            return .docs
        }
        return .shipped
    }

    public var title: String {
        switch self {
        case .shipped: "Shipped code"
        case .tests: "Tests"
        case .docs: "Docs and examples"
        }
    }

    static let testFolders: Set<String> = [
        "test", "tests", "__tests__", "__mocks__", "__fixtures__", "spec", "specs", "testdata", "fixtures", "mocks",
        "e2e", "cypress", "playwright", "testutil", "testutils", "testhelpers", "androidtest", "integrationtest", "testfixtures",
    ]
    static let docFolders: Set<String> = ["docs", "doc", "documentation", "examples", "example", "samples", "sample"]
    static let docExtensions: Set<String> = ["md", "mdx", "markdown", "rst", "adoc"]

    static func isTestFolder(_ folder: String) -> Bool {
        let lower = folder.lowercased()
        if testFolders.contains(lower) { return true }
        // Swift's "DanteKitTests", .NET's "Shop.Api.Tests" and "Shop.UnitTests".
        return (folder.hasSuffix("Tests") && folder.count > 5) || lower.hasSuffix(".tests") || lower.hasSuffix(".test")
    }

    static func isTestName(_ name: String) -> Bool {
        let lower = name.lowercased()
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "go":
            // Tests, and the mocks generated for them.
            return lower.hasSuffix("_test.go") || lower.hasSuffix("_mock.go") || lower.hasPrefix("mock_")
        case "py":
            return lower.hasPrefix("test_") || lower.hasSuffix("_test.py") || lower == "conftest.py"
        case "js", "jsx", "ts", "tsx", "mjs", "cjs", "mts", "cts", "vue", "svelte":
            return [".test.", ".spec.", ".cy.", ".e2e."].contains { lower.contains($0) }
        case "rb":
            return lower.hasSuffix("_spec.rb") || lower.hasSuffix("_test.rb")
        case "exs":
            return lower.hasSuffix("_test.exs")
        case "dart":
            return lower.hasSuffix("_test.dart")
        case "c", "cc", "cpp", "cxx":
            return lower.hasSuffix("_test.\(ext)") || lower.hasSuffix("_unittest.\(ext)")
        case "java", "kt", "kts", "groovy", "scala", "cs", "swift", "php", "m":
            // Class-style names need the capital: "OrderServiceTest", "OrderServiceIT", not "Latest".
            // Spock and Kotest name specs "…Spec"; elsewhere (Swift's "PageSpec") that's often code.
            let jvm = ["java", "kt", "kts", "groovy", "scala"].contains(ext)
            let suffixes = jvm ? ["Tests", "Test", "Spec", "IT"] : ["Tests", "Test"]
            for suffix in suffixes where stem.hasSuffix(suffix) && stem.count > suffix.count {
                let before = stem[stem.index(stem.endIndex, offsetBy: -suffix.count - 1)]
                if suffix != "IT" || before.isLowercase { return true }
            }
            return false
        default:
            return false
        }
    }
}
