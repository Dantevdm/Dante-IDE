import Foundation

/// A named thing in code, for Go to Symbol: from a language server, or from
/// `DeclarationScanner` when there isn't one.
public struct CodeSymbol: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case type, function, method, property, variable, constant, enumCase, module, heading, other

        /// LSP's SymbolKind numbers.
        init(lsp: Int?) {
            switch lsp {
            case 2, 3, 4: self = .module
            case 5, 10, 11, 23, 26: self = .type
            case 6, 9: self = .method
            case 7, 8: self = .property
            case 12: self = .function
            case 13: self = .variable
            case 14: self = .constant
            case 22: self = .enumCase
            default: self = .other
            }
        }
    }

    public var name: String
    public var kind: Kind
    /// The type or scope it's in, when known.
    public var container: String?
    public var url: URL
    /// Where the name is (UTF-16, zero-based, like LSP).
    public var range: LSPRange

    public init(name: String, kind: Kind, container: String? = nil, url: URL, range: LSPRange) {
        self.name = name
        self.kind = kind
        self.container = container
        self.url = url
        self.range = range
    }

    public var id: String { "\(url.path):\(range.start.line):\(range.start.character):\(name)" }

    /// A `textDocument/documentSymbol` or `workspace/symbol` result: DocumentSymbols (nested,
    /// flattened here with their parent as container) or SymbolInformation (with a location).
    static func list(_ json: JSONValue, in url: URL?) -> [CodeSymbol] {
        var result: [CodeSymbol] = []
        func walk(_ items: [JSONValue], container: String?) {
            for item in items {
                guard let name = item["name"]?.string else { continue }
                let kind = Kind(lsp: item["kind"]?.int)
                if let range = LSPRange(item["selectionRange"]) ?? LSPRange(item["range"]), let url {
                    result.append(CodeSymbol(name: name, kind: kind, container: container, url: url, range: range))
                    walk(item["children"]?.array ?? [], container: name)
                } else if let location = item["location"], let uri = location["uri"]?.string,
                          let target = URL(string: uri), target.isFileURL {
                    // workspace/symbol may leave out the range (WorkspaceSymbol); the file still opens.
                    let range = LSPRange(location["range"]) ?? LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0))
                    result.append(CodeSymbol(name: name, kind: kind, container: item["containerName"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                                             url: target, range: range))
                }
            }
        }
        walk(json.array ?? [], container: nil)
        return result
    }
}

/// Finds declarations with patterns, for files no language server covers: good enough to
/// jump around a file, not a parser.
public enum DeclarationScanner {
    public static func symbols(in text: String, language: Language, url: URL) -> [CodeSymbol] {
        guard let patterns = patterns[language] else { return [] }
        var result: [CodeSymbol] = []
        let lines = text.components(separatedBy: "\n")
        var inFence = false
        for (number, line) in lines.enumerated() {
            if language == .markdown, line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            let ns = line as NSString
            for (regex, kind) in patterns {
                guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges > 1 else { continue }
                let nameRange = match.range(at: 1)
                guard nameRange.location != NSNotFound else { continue }
                let name = ns.substring(with: nameRange).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                let start = LSPPosition(line: number, character: nameRange.location)
                let end = LSPPosition(line: number, character: NSMaxRange(nameRange))
                result.append(CodeSymbol(name: name, kind: kind, url: url, range: LSPRange(start: start, end: end)))
                break
            }
        }
        return result
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    private static let identifier = "([A-Za-z_$][A-Za-z0-9_$]*)"

    nonisolated(unsafe) static let patterns: [Language: [(NSRegularExpression, CodeSymbol.Kind)]] = {
        let id = identifier
        let swift: [(NSRegularExpression, CodeSymbol.Kind)] = [
            (regex(#"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|open|final|static|nonisolated|override|indirect)\s+)*(?:class|struct|enum|protocol|actor|extension|typealias)\s+"# + id), .type),
            (regex(#"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|open|final|static|class|nonisolated|override|mutating)\s+)*func\s+([^\s(<]+)"#), .function),
        ]
        let js: [(NSRegularExpression, CodeSymbol.Kind)] = [
            (regex(#"^\s*(?:export\s+)?(?:default\s+)?(?:abstract\s+)?(?:class|interface|enum|type)\s+"# + id), .type),
            (regex(#"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\*?\s+"# + id), .function),
            (regex(#"^\s*(?:export\s+)?(?:const|let|var)\s+"# + id + #"\s*=\s*(?:async\s*)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>"#), .function),
        ]
        return [
            .swift: swift,
            .typescript: js,
            .javascript: js,
            .python: [(regex(#"^\s*class\s+"# + id), .type), (regex(#"^\s*(?:async\s+)?def\s+"# + id), .function)],
            .go: [(regex(#"^type\s+"# + id), .type), (regex(#"^func\s+(?:\([^)]*\)\s*)?"# + id), .function)],
            .rust: [(regex(#"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:struct|enum|trait|type|mod)\s+"# + id), .type),
                    (regex(#"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?fn\s+"# + id), .function)],
            .ruby: [(regex(#"^\s*(?:class|module)\s+([A-Z][\w:]*)"#), .type), (regex(#"^\s*def\s+(?:self\.)?([\w?!=]+)"#), .function)],
            .java: [(regex(#"^\s*(?:(?:public|private|protected|abstract|final|static)\s+)*(?:class|interface|enum|record)\s+"# + id), .type)],
            .kotlin: [(regex(#"^\s*(?:(?:public|private|internal|data|sealed|abstract|open|enum)\s+)*(?:class|interface|object)\s+"# + id), .type),
                      (regex(#"^\s*(?:(?:public|private|internal|override|suspend)\s+)*fun\s+(?:<[^>]*>\s*)?(?:\w+\.)?"# + id), .function)],
            .shell: [(regex(#"^\s*(?:function\s+)?([A-Za-z_][\w-]*)\s*\(\)\s*\{"#), .function)],
            .sql: [(regex(#"(?i)^\s*create\s+(?:or\s+replace\s+)?(?:temp(?:orary)?\s+)?(?:table|view|function|procedure|index|type)\s+(?:if\s+not\s+exists\s+)?([\w."]+)"#), .type)],
            .markdown: [(regex(#"^#{1,6}\s+(.+?)\s*#*\s*$"#), .heading)],
        ]
    }()
}

/// Ranks symbols for a query: name matches first, then container ones.
public enum SymbolSearch {
    public static func rank(_ query: String, in symbols: [CodeSymbol], limit: Int = 60) -> [CodeSymbol] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(symbols.prefix(limit)) }
        let names = symbols.map(\.name)
        var seen = Set<String>()
        var ranked: [CodeSymbol] = []
        for result in FuzzyMatch.rank(trimmed, in: names, limit: limit * 3) {
            for symbol in symbols where symbol.name == result.path && !seen.contains(symbol.id) {
                seen.insert(symbol.id)
                ranked.append(symbol)
            }
            if ranked.count >= limit { break }
        }
        return Array(ranked.prefix(limit))
    }
}

extension DeclarationScanner {
    /// Declarations in every source file of a project, for Go to Symbol when no server
    /// can search. Skips big files and stops after `fileLimit` files. Run it off the main thread.
    public static func project(root: URL, files: [String], fileLimit: Int = 4000, sizeLimit: Int = 512 * 1024) -> [CodeSymbol] {
        var result: [CodeSymbol] = []
        var scanned = 0
        for path in files {
            let url = root.appending(path: path)
            let language = Language(url: url)
            guard patterns[language] != nil, language != .markdown, language != .sql else { continue }
            guard scanned < fileLimit else { break }
            scanned += 1
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= sizeLimit,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            result += symbols(in: text, language: language, url: url)
        }
        return result
    }
}
