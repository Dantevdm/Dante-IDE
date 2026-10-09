import Foundation

/// A source file and the functions and types in it that no test mentions by name.
/// A heuristic, not coverage: a name in a test doesn't mean every path through it runs,
/// but a name in no test almost always means nothing tests it directly.
public struct UntestedFile: Equatable, Sendable, Identifiable {
    public var path: String
    public var lines: Int
    /// Functions and types declared in the file.
    public var declared: [String]
    /// The declared names that appear in no test file.
    public var untested: [String]
    /// A test file sits beside it by convention (foo_test.go, FooTests.swift, test_foo.py).
    public var hasTestFile: Bool
    public var id: String { path }

    public init(path: String, lines: Int, declared: [String], untested: [String], hasTestFile: Bool) {
        self.path = path
        self.lines = lines
        self.declared = declared
        self.untested = untested
        self.hasTestFile = hasTestFile
    }

    /// Views and screens, which unit tests rarely reach; they rank below logic.
    public var isInterface: Bool { TestGaps.isInterface(path) }

    public var testedFraction: Double {
        declared.isEmpty ? 1 : Double(declared.count - untested.count) / Double(declared.count)
    }
}

public struct TestGaps: Equatable, Sendable {
    public var files: [UntestedFile]
    /// Source files read, functions and types found in them.
    public var sourceFiles: Int
    public var declarations: Int

    public init(files: [UntestedFile], sourceFiles: Int, declarations: Int) {
        self.files = files
        self.sourceFiles = sourceFiles
        self.declarations = declarations
    }

    public var untestedCount: Int { files.reduce(0) { $0 + $1.untested.count } }

    static let codeLanguages: Set<Language> = [.swift, .typescript, .javascript, .python, .go, .rust, .ruby, .java, .kotlin]
    /// Names too generic to count as a test mentioning them.
    static let ignoredNames: Set<String> = ["main", "init", "setUp", "tearDown", "String", "Error", "Config", "constructor", "render", "run", "handler", "New", "new"]

    public static func load(root: URL, files: [String], inventory: TestInventory, sizeLimit: Int = 256 * 1024) -> TestGaps {
        var testText = ""
        for file in inventory.testFiles {
            testText += (try? String(contentsOf: root.appending(path: file), encoding: .utf8)) ?? ""
            testText += "\n"
        }
        var sources: [(path: String, text: String)] = []
        var seenContent: Set<Int> = []
        // Build output last, so its copies of source files are the ones skipped.
        let ordered = files.sorted { (isBuildCopy($0) ? 1 : 0, $0) < (isBuildCopy($1) ? 1 : 0, $1) }
        for file in ordered where isSource(file) && !inventory.testFiles.contains(file) {
            let url = root.appending(path: file)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= sizeLimit,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // A build step's copy of another file (public/ from frontend/) counts once.
            guard seenContent.insert(text.hashValue).inserted else { continue }
            sources.append((file, text))
        }
        return find(sources: sources, testText: testText, testFiles: inventory.testFiles)
    }

    /// Pure: which declarations in `sources` the test code never names.
    public static func find(sources: [(path: String, text: String)], testText: String, testFiles: [String]) -> TestGaps {
        let mentioned = identifiers(in: testText)
        var files: [UntestedFile] = []
        var declarations = 0
        for source in sources {
            let language = Language(url: URL(filePath: source.path))
            let names = DeclarationScanner.symbols(in: source.text, language: language, url: URL(filePath: source.path))
                .filter { $0.kind == .function || $0.kind == .type }
                .map { $0.name.trimmingCharacters(in: CharacterSet(charactersIn: "`")) }
                .filter { $0.count > 2 && !ignoredNames.contains($0) && !$0.hasPrefix("_") }
            var unique: [String] = []
            for name in names where !unique.contains(name) { unique.append(name) }
            guard !unique.isEmpty else { continue }
            declarations += unique.count
            let untested = unique.filter { !mentioned.contains($0) }
            let lineCount = source.text.components(separatedBy: "\n").count - (source.text.hasSuffix("\n") ? 1 : 0)
            files.append(UntestedFile(path: source.path, lines: lineCount,
                                      declared: unique, untested: untested, hasTestFile: hasConventionalTest(source.path, testFiles: testFiles)))
        }
        // Logic before interface, then the most untested, then the bigger file.
        files.sort { a, b in
            if a.isInterface != b.isInterface { return !a.isInterface }
            return (a.untested.count, a.lines) > (b.untested.count, b.lines)
        }
        return TestGaps(files: files, sourceFiles: sources.count, declarations: declarations)
    }

    static func isSource(_ path: String) -> Bool {
        let lower = path.lowercased()
        let skipped = ["node_modules/", "vendor/", "dist/", "build/", ".build/", "target/", "generated", ".min.", "migrations/", "__pycache__/", ".d.ts"]
        guard !skipped.contains(where: { lower.contains($0) }) else { return false }
        let name = (lower as NSString).lastPathComponent
        if ["package.swift", "setup.py", "conftest.py", "vite.config.ts", "vite.config.js", "jest.config.js", "eslint.config.js"].contains(name) { return false }
        return codeLanguages.contains(Language(url: URL(filePath: path))) && !TestInventory.isTestFile(path)
    }

    static func isBuildCopy(_ path: String) -> Bool {
        let lower = path.lowercased()
        return ["public/", "static/", "www/", "assets/"].contains { lower.contains($0) }
    }

    static func isInterface(_ path: String) -> Bool {
        let lower = path.lowercased()
        let parts = lower.split(separator: "/").map(String.init)
        if parts.contains(where: { ["views", "components", "ui", "screens", "pages", "widgets", "design"].contains($0) }) { return true }
        let name = (path as NSString).deletingPathExtension.split(separator: "/").last.map(String.init) ?? ""
        return name.hasSuffix("View") || name.hasSuffix("Screen") || name.hasSuffix("Page") || lower.hasSuffix(".jsx") || lower.hasSuffix(".tsx")
    }

    static func identifiers(in text: String) -> Set<String> {
        var found: Set<String> = []
        var current = ""
        for character in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(character) || character == "_" {
                current.unicodeScalars.append(character)
            } else if !current.isEmpty {
                found.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { found.insert(current) }
        return found
    }

    static func hasConventionalTest(_ path: String, testFiles: [String]) -> Bool {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let folder = (path as NSString).deletingLastPathComponent
        let candidates = [
            "\(folder.isEmpty ? "" : folder + "/")\(name)_test.go",
            "\(name)Tests.swift", "\(name)Test.swift", "test_\(name).py", "\(name)_test.py",
            "\(name).test.ts", "\(name).test.js", "\(name).spec.ts", "\(name).spec.js", "\(name).test.tsx", "\(name)_spec.rb",
        ]
        return testFiles.contains { file in
            candidates.contains { $0.contains("/") ? file == $0 : (file as NSString).lastPathComponent == $0 }
        }
    }

    /// For Claude: the gaps found, so it starts from facts rather than a guess.
    public func prompt(limit: Int = 8) -> String {
        var lines = ["Dante read the project and found code that no test mentions by name. Here are the files with the most of it:"]
        for file in files.filter({ !$0.untested.isEmpty }).prefix(limit) {
            let names = file.untested.prefix(12).joined(separator: ", ")
            lines.append("- \(file.path) (\(file.lines) lines): \(names)\(file.untested.count > 12 ? ", and \(file.untested.count - 12) more" : "")")
        }
        lines.append("\nRead these files and pick the five gaps that matter most: code that handles money, data, security, external services or tricky logic. For each, say what could break and what test would catch it. Don't write tests yet.")
        return lines.joined(separator: "\n")
    }
}
