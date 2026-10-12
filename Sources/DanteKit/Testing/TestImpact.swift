import Foundation

/// The tests worth running for a set of changed files: tests in changed test files, and
/// tests in the test files that go with a changed source file by name (`mailer.go` →
/// `mailer_test.go`, `Parser.swift` → `ParserTests.swift`, `views.py` → `test_views.py`).
public enum TestImpact {
    public static func tests(for changed: [String], in inventory: TestInventory) -> [WrittenTest] {
        let changedSet = Set(changed)
        let testFiles = Set(inventory.testFiles).union(inventory.tests.map(\.file))
        let stems = Set(changed.filter { !testFiles.contains($0) }.map { stem($0) })
        return inventory.tests.filter { test in
            changedSet.contains(test.file) || stems.contains(stem(ofTest: test.file))
        }
    }

    /// The file name without folders, extension or a `.test`/`.spec` part, lowercased.
    static func stem(_ path: String) -> String {
        var name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        for suffix in [".test", ".spec", ".d"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        return name
    }

    /// The source stem a test file is named after.
    static func stem(ofTest path: String) -> String {
        var name = stem(path)
        for suffix in ["_tests", "_test", "tests", "test", "spec", "_spec"] where name.hasSuffix(suffix) && name.count > suffix.count {
            name.removeLast(suffix.count)
            break
        }
        for prefix in ["test_", "tests_"] where name.hasPrefix(prefix) && name.count > prefix.count {
            name.removeFirst(prefix.count)
            break
        }
        return name
    }
}
