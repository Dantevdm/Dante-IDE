import Foundation

/// One suggestion from `textDocument/completion`.
public struct LSPCompletionItem: Hashable, Sendable, Identifiable {
    /// The LSP CompletionItemKind numbers Dante shows an icon for.
    public enum Kind: Int, Sendable {
        case text = 1, method, function, constructor, field, variable, `class`, interface, module, property
        case unit, value, `enum`, keyword, snippet, color, file, reference, folder, enumMember
        case constant, `struct`, event, `operator`, typeParameter
    }

    public var label: String
    public var kind: Kind?
    public var detail: String?
    public var documentation: String?
    /// What goes into the text; may be a snippet (`foo(${1:x})`) when `isSnippet`.
    public var insertText: String
    public var isSnippet: Bool
    /// The text the item replaces, when the server says; otherwise the word before the caret.
    public var replaceRange: LSPRange?
    public var sortText: String
    public var filterText: String
    public var id: String { "\(label)\u{1F}\(detail ?? "")\u{1F}\(sortText)" }

    public init(label: String, kind: Kind? = nil, detail: String? = nil, documentation: String? = nil, insertText: String? = nil,
                isSnippet: Bool = false, replaceRange: LSPRange? = nil, sortText: String? = nil, filterText: String? = nil) {
        self.label = label
        self.kind = kind
        self.detail = detail
        self.documentation = documentation
        self.insertText = insertText ?? label
        self.isSnippet = isSnippet
        self.replaceRange = replaceRange
        self.sortText = sortText ?? label
        self.filterText = filterText ?? label
    }

    /// Reads a completion result: a CompletionList or a bare array of items.
    public static func list(_ json: JSONValue) -> (items: [LSPCompletionItem], isIncomplete: Bool) {
        let items = json["items"]?.array ?? json.array ?? []
        let incomplete = json["isIncomplete"]?.bool ?? false
        let defaultRange = LSPRange(json["itemDefaults"]?["editRange"]) ?? LSPRange(json["itemDefaults"]?["editRange"]?["insert"])
        return (items.compactMap { item(from: $0, defaultRange: defaultRange) }, incomplete)
    }

    static func item(from json: JSONValue, defaultRange: LSPRange?) -> LSPCompletionItem? {
        guard let label = json["label"]?.string else { return nil }
        let edit = json["textEdit"]
        let range = LSPRange(edit?["range"]) ?? LSPRange(edit?["insert"]) ?? defaultRange
        let documentation = json["documentation"]?.string ?? json["documentation"]?["value"]?.string
        let detail = json["detail"]?.string ?? json["labelDetails"]?["detail"]?.string
        return LSPCompletionItem(
            label: label,
            kind: json["kind"]?.int.flatMap(Kind.init(rawValue:)),
            detail: detail?.trimmingCharacters(in: .whitespaces),
            documentation: documentation,
            insertText: edit?["newText"]?.string ?? json["insertText"]?.string,
            isSnippet: json["insertTextFormat"]?.int == 2,
            replaceRange: range,
            sortText: json["sortText"]?.string,
            filterText: json["filterText"]?.string
        )
    }
}

/// Snippet syntax (`$1`, `${1:name}`, `$0`) turned into plain text, with the first
/// placeholder's range so the editor can select it.
public enum Snippet {
    public static func expand(_ snippet: String) -> (text: String, selection: NSRange?) {
        var output = ""
        var first: (index: Int, range: NSRange)?
        var scalars = Array(snippet)[...]
        func note(_ index: Int, start: Int, text: String) {
            let range = NSRange(location: start, length: (text as NSString).length)
            // $0 is the final caret; prefer a numbered placeholder.
            let order = index == 0 ? Int.max : index
            if first == nil || order < first!.index { first = (order, range) }
        }
        while let character = scalars.popFirst() {
            if character == "\\", let next = scalars.first, "$}\\".contains(next) {
                output.append(scalars.removeFirst())
                continue
            }
            guard character == "$" else { output.append(character); continue }
            if let next = scalars.first, next.isNumber {
                var digits = ""
                while let digit = scalars.first, digit.isNumber { digits.append(scalars.removeFirst()) }
                note(Int(digits) ?? 0, start: (output as NSString).length, text: "")
            } else if scalars.first == "{" {
                scalars.removeFirst()
                var digits = ""
                while let digit = scalars.first, digit.isNumber { digits.append(scalars.removeFirst()) }
                var body = ""
                if scalars.first == ":" {
                    scalars.removeFirst()
                    var depth = 0
                    while let next = scalars.first {
                        if next == "}" && depth == 0 { break }
                        if next == "{" { depth += 1 }
                        if next == "}" { depth -= 1 }
                        body.append(scalars.removeFirst())
                    }
                } else if scalars.first == "|" {
                    // A choice: ${1|one,two|} — take the first option.
                    scalars.removeFirst()
                    var choice = ""
                    while let next = scalars.first, next != "|" { choice.append(scalars.removeFirst()) }
                    if scalars.first == "|" { scalars.removeFirst() }
                    body = choice.components(separatedBy: ",").first ?? ""
                }
                if scalars.first == "}" { scalars.removeFirst() }
                let plain = expand(body).text
                note(Int(digits) ?? 0, start: (output as NSString).length, text: plain)
                output += plain
            } else {
                output.append(character)
            }
        }
        return (output, first?.range)
    }
}

/// A replacement in one document.
public struct LSPTextEdit: Hashable, Sendable {
    public var range: LSPRange
    public var newText: String

    public init(range: LSPRange, newText: String) {
        self.range = range
        self.newText = newText
    }

    init?(_ json: JSONValue) {
        guard let range = LSPRange(json["range"]), let newText = json["newText"]?.string else { return nil }
        self.init(range: range, newText: newText)
    }

    static func list(_ json: JSONValue) -> [LSPTextEdit] {
        (json.array ?? []).compactMap(LSPTextEdit.init)
    }

    /// Applies edits that were all computed against `text`, last first so earlier
    /// positions stay valid. Servers sometimes repeat an edit (sourcekit-lsp does for
    /// renames in open files), so duplicates and edits overlapping one already made are skipped.
    public static func apply(_ edits: [LSPTextEdit], to text: String) -> String {
        let source = text as NSString
        let index = LineIndex(source)
        let ranges = Array(Set(edits)).map { (index.range(of: $0.range), $0.newText) }
            .sorted { $0.0.location == $1.0.location ? $0.0.length > $1.0.length : $0.0.location > $1.0.location }
        let result = NSMutableString(string: text)
        var limit = source.length
        for (range, newText) in ranges where NSMaxRange(range) <= limit {
            result.replaceCharacters(in: range, with: newText)
            limit = range.location
        }
        return result as String
    }
}

/// Edits across files, as `textDocument/rename` returns them.
public struct LSPWorkspaceEdit: Equatable, Sendable {
    public var changes: [URL: [LSPTextEdit]]

    public init(changes: [URL: [LSPTextEdit]]) {
        self.changes = changes
    }

    /// Reads either form: `changes` keyed by URI, or `documentChanges` (file
    /// create/rename/delete operations in it are skipped).
    public init(_ json: JSONValue) {
        var changes: [URL: [LSPTextEdit]] = [:]
        if case .object(let byURI)? = json["changes"] {
            for (uri, edits) in byURI {
                guard let url = URL(string: uri), url.isFileURL else { continue }
                changes[url.standardizedFileURL, default: []] += LSPTextEdit.list(edits)
            }
        }
        for change in json["documentChanges"]?.array ?? [] {
            guard let uri = change["textDocument"]?["uri"]?.string, let url = URL(string: uri), url.isFileURL else { continue }
            changes[url.standardizedFileURL, default: []] += LSPTextEdit.list(change["edits"] ?? .null)
        }
        self.changes = changes.filter { !$0.value.isEmpty }
    }

    public var editCount: Int { changes.values.reduce(0) { $0 + $1.count } }

    /// Adds a rename edit for each reference in a file the server's rename left out, where
    /// that file's text (from `text`) really holds the old name. sourcekit-lsp reports index
    /// references as empty ranges at the start of the name, so those are widened to it.
    public mutating func include(_ references: [LSPLocation], renaming name: String, to newName: String, text: (URL) -> String?) {
        let length = (name as NSString).length
        let covered = Set(changes.keys)
        var sources: [URL: (text: NSString, lines: LineIndex)] = [:]
        for location in references {
            let url = location.url.standardizedFileURL
            guard !covered.contains(url), location.range.start.line == location.range.end.line else { continue }
            var range = location.range
            range.end.character = range.start.character + length
            if sources[url] == nil, let source = text(url) { sources[url] = (source as NSString, LineIndex(source as NSString)) }
            guard let source = sources[url] else { continue }
            let span = source.lines.range(of: range)
            guard NSMaxRange(span) <= source.text.length, source.text.substring(with: span) == name else { continue }
            changes[url, default: []].append(LSPTextEdit(range: range, newText: newName))
        }
    }
}
