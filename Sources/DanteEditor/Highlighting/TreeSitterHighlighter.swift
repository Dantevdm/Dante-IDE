import DanteKit
import Foundation
import Synchronization
import SwiftTreeSitter
import TreeSitterGo
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterPython
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTypeScript

/// Highlighting from a tree-sitter parse and the grammar's own `highlights.scm`.
///
/// Each call parses the whole document; tree-sitter does a few thousand lines in a
/// couple of milliseconds, well inside the editor's debounce.
public struct TreeSitterHighlighter: Highlighter {
    let language: SwiftTreeSitter.Language
    let query: Query

    public func tokens(in text: String) -> [Token] {
        let parser = Parser()
        guard (try? parser.setLanguage(language)) != nil, let tree = parser.parse(text) else { return [] }
        let cursor = query.execute(in: tree)
        // Less specific captures come first, so later tokens override earlier ones.
        return cursor.resolve(with: .init(string: text)).highlights().compactMap { range in
            Self.kind(forCapture: range.name).map { Token(range: range.range, kind: $0) }
        }
    }

    /// Maps capture names, in both the tree-sitter and Neovim conventions, onto Dante's colours.
    static func kind(forCapture name: String) -> TokenKind? {
        let head = name.split(separator: ".").first.map(String.init) ?? name
        switch head {
        case "keyword", "boolean", "conditional", "repeat", "include", "exception", "storageclass", "label":
            return .keyword
        case "string", "character", "escape":
            return .string
        case "comment":
            return .comment
        case "number", "float":
            return .number
        case "type", "constructor", "attribute", "namespace", "module":
            return .type
        case "function", "method":
            return .function
        case "constant":
            return name == "constant.builtin" ? .keyword : nil
        default:
            return nil
        }
    }

    // MARK: Grammars

    private struct Grammar {
        var language: OpaquePointer
        /// Resource bundles holding highlights.scm, in the order their queries apply.
        var bundles: [String]
    }

    private static func grammar(for language: DanteKit.Language) -> Grammar? {
        switch language {
        case .swift: Grammar(language: tree_sitter_swift(), bundles: ["TreeSitterSwift_TreeSitterSwift"])
        case .python: Grammar(language: tree_sitter_python(), bundles: ["TreeSitterPython_TreeSitterPython"])
        case .javascript: Grammar(language: tree_sitter_javascript(), bundles: ["TreeSitterJavaScript_TreeSitterJavaScript"])
        // TypeScript's queries only cover what it adds to JavaScript.
        case .typescript: Grammar(language: tree_sitter_typescript(), bundles: ["TreeSitterJavaScript_TreeSitterJavaScript", "TreeSitterTypeScript_TreeSitterTypeScript"])
        case .go: Grammar(language: tree_sitter_go(), bundles: ["TreeSitterGo_TreeSitterGo"])
        case .rust: Grammar(language: tree_sitter_rust(), bundles: ["TreeSitterRust_TreeSitterRust"])
        case .json: Grammar(language: tree_sitter_json(), bundles: ["TreeSitterJSON_TreeSitterJSON"])
        default: nil
        }
    }

    /// Compiled queries are shared: compiling Swift's takes longer than highlighting a file.
    private static let cache = Mutex<[DanteKit.Language: TreeSitterHighlighter?]>([:])

    /// A highlighter for `language`, or nil when Dante has no grammar for it or can't find its queries.
    public static func make(for language: DanteKit.Language) -> TreeSitterHighlighter? {
        if let cached = cache.withLock({ $0[language] }) { return cached }
        let made = build(language)
        cache.withLock { $0[language] = made }
        return made
    }

    private static func build(_ language: DanteKit.Language) -> TreeSitterHighlighter? {
        guard let grammar = grammar(for: language) else { return nil }
        var source = ""
        for bundle in grammar.bundles {
            guard let url = queryURL(bundle: bundle, file: "highlights.scm"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            source += text + "\n"
        }
        let tsLanguage = SwiftTreeSitter.Language(language: grammar.language)
        guard let query = try? Query(language: tsLanguage, data: Data(source.utf8)) else { return nil }
        return TreeSitterHighlighter(language: tsLanguage, query: query)
    }

    /// SwiftPM puts grammar resources in `<bundle>.bundle` next to the binary, and the app
    /// bundle copies them into Contents/Resources. Under `swift test` the main bundle is
    /// SwiftPM's helper, so the search starts from the image this code was loaded from.
    static func queryURL(bundle: String, file: String) -> URL? {
        var folders = [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        var info = Dl_info()
        if dladdr(#dsohandle, &info) != 0, let path = info.dli_fname {
            var folder = URL(filePath: String(cString: path)).deletingLastPathComponent()
            for _ in 0..<4 {
                folders += [folder, folder.appending(path: "Resources")]
                folder = folder.deletingLastPathComponent()
            }
        }
        for folder in folders {
            for relative in ["queries", "Contents/Resources/queries"] {
                let url = folder.appending(path: "\(bundle).bundle/\(relative)/\(file)")
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }
}
