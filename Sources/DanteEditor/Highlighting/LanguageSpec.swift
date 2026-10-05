import DanteKit

/// What the regex highlighter needs to know about a language.
public struct LanguageSpec: Sendable {
    public var keywords: [String] = []
    public var caseInsensitiveKeywords = false
    public var lineComments: [String] = []
    public var blockComment: (String, String)?
    public var strings: [Character] = ["\"", "'"]
    public var multilineStrings: [String] = []
    /// Numbers, capitalised types and function calls.
    public var highlightsCode = true
    /// Extra patterns whose first capture group gets the kind. Applied before keywords.
    public var extraRules: [(String, TokenKind)] = []

    public static func `for`(_ language: Language) -> LanguageSpec {
        switch language {
        case .swift:
            return LanguageSpec(
                keywords: ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue",
                           "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate",
                           "final", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "lazy",
                           "mutating", "nil", "nonisolated", "open", "operator", "override", "private", "protocol", "public",
                           "repeat", "rethrows", "return", "self", "Self", "some", "static", "struct", "subscript", "super", "switch",
                           "throw", "throws", "true", "try", "typealias", "var", "weak", "where", "while", "@MainActor",
                           "@Observable", "@State", "@Binding", "@Environment", "@escaping", "@discardableResult"],
                lineComments: ["//"], blockComment: ("/*", "*/"), strings: ["\""], multilineStrings: ["\"\"\""]
            )
        case .typescript, .javascript:
            return LanguageSpec(
                keywords: ["abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
                           "declare", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for",
                           "from", "function", "get", "if", "implements", "import", "in", "instanceof", "interface", "keyof", "let",
                           "new", "null", "of", "private", "protected", "public", "readonly", "return", "set", "static", "super",
                           "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield"],
                lineComments: ["//"], blockComment: ("/*", "*/"), strings: ["\"", "'", "`"]
            )
        case .python:
            return LanguageSpec(
                keywords: ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else",
                           "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None",
                           "nonlocal", "not", "or", "pass", "raise", "return", "self", "True", "try", "while", "with", "yield"],
                lineComments: ["#"], multilineStrings: ["\"\"\"", "'''"]
            )
        case .go:
            return LanguageSpec(
                keywords: ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for",
                           "func", "go", "goto", "if", "import", "interface", "map", "nil", "package", "range", "return", "select",
                           "struct", "switch", "true", "type", "var"],
                lineComments: ["//"], blockComment: ("/*", "*/"), strings: ["\"", "'", "`"]
            )
        case .rust:
            return LanguageSpec(
                keywords: ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false",
                           "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
                           "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"],
                lineComments: ["//"], blockComment: ("/*", "*/"), strings: ["\""]
            )
        case .java, .kotlin, .csharp, .c, .cpp, .php:
            return LanguageSpec(
                keywords: ["abstract", "auto", "bool", "break", "case", "catch", "char", "class", "const", "continue", "data",
                           "default", "do", "double", "else", "enum", "extends", "false", "final", "float", "for", "fun", "function",
                           "if", "implements", "import", "include", "int", "interface", "internal", "is", "let", "long", "namespace",
                           "new", "null", "nullptr", "object", "override", "package", "private", "protected", "public", "return",
                           "static", "struct", "switch", "this", "throw", "throws", "true", "try", "typedef", "using", "val", "var",
                           "virtual", "void", "when", "while"],
                lineComments: ["//"], blockComment: ("/*", "*/")
            )
        case .ruby:
            return LanguageSpec(
                keywords: ["begin", "class", "def", "do", "else", "elsif", "end", "ensure", "false", "if", "in", "module", "nil",
                           "require", "rescue", "return", "self", "then", "true", "unless", "until", "when", "while", "yield"],
                lineComments: ["#"]
            )
        case .shell, .dockerfile:
            return LanguageSpec(
                keywords: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function",
                           "return", "export", "local", "FROM", "RUN", "CMD", "COPY", "ADD", "WORKDIR", "ENV", "ARG", "EXPOSE",
                           "ENTRYPOINT", "USER", "VOLUME", "LABEL", "AS"],
                lineComments: ["#"],
                extraRules: [("(\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?)", .type)]
            )
        case .sql:
            return LanguageSpec(
                keywords: ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table",
                           "index", "alter", "add", "drop", "primary", "key", "foreign", "references", "not", "null", "and", "or",
                           "join", "left", "inner", "on", "group", "by", "order", "limit", "as", "unique", "default", "begin",
                           "commit", "if", "exists", "bigint", "text", "uuid", "jsonb", "timestamptz", "integer", "boolean"],
                caseInsensitiveKeywords: true,
                lineComments: ["--"], blockComment: ("/*", "*/"), strings: ["'"]
            )
        case .json:
            return LanguageSpec(
                keywords: ["true", "false", "null"], strings: [], highlightsCode: false,
                extraRules: [("(\"(?:\\\\.|[^\"\\\\])*\")\\s*:", .function), ("(\"(?:\\\\.|[^\"\\\\])*\")", .string),
                             ("(-?\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)", .number)]
            )
        case .yaml, .toml:
            return LanguageSpec(
                keywords: ["true", "false", "null", "yes", "no", "on", "off"],
                lineComments: ["#"], highlightsCode: false,
                extraRules: [("^\\s*-?\\s*([\\w.\\-\"]+)\\s*[:=]", .function), ("^\\s*(\\[[^\\]]+\\])", .keyword),
                             ("(?<![\\w.])(-?\\d+(?:\\.\\d+)?)(?![\\w.])", .number)]
            )
        case .markdown:
            return LanguageSpec(
                strings: [], highlightsCode: false,
                extraRules: [("^(#{1,6} .*)$", .keyword), ("(`[^`\\n]+`)", .string), ("(\\*\\*[^*\\n]+\\*\\*)", .type),
                             ("(\\[[^\\]\\n]+\\]\\([^)\\n]+\\))", .function), ("^(\\s*(?:[-*+]|\\d+\\.) )", .number)]
            )
        case .html:
            return LanguageSpec(
                blockComment: ("<!--", "-->"), highlightsCode: false,
                extraRules: [("</?([A-Za-z][\\w:-]*)", .keyword), ("\\s([A-Za-z_:][\\w:.-]*)=", .function)]
            )
        case .css:
            return LanguageSpec(
                blockComment: ("/*", "*/"), highlightsCode: false,
                extraRules: [("([\\w-]+)\\s*:(?!:)", .function), ("(#[0-9a-fA-F]{3,8})\\b", .number),
                             ("(-?\\d+(?:\\.\\d+)?(?:px|rem|em|%|s|ms|vh|vw)?)", .number), ("^\\s*([.#]?[\\w-]+)\\s*\\{", .type)]
            )
        case .plain:
            return LanguageSpec(strings: [], highlightsCode: false)
        }
    }
}
