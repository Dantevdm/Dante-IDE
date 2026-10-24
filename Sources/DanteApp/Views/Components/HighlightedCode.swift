import DanteEditor
import DanteKit
import SwiftUI

/// Source text coloured with the editor's highlighter, for read-only views.
enum HighlightedCode {
    static func attributed(_ text: String, language: Language, theme: Theme) -> AttributedString {
        let tokens = Highlighters.make(for: language).tokens(in: text)
        return colored(text, offset: 0, tokens: tokens, theme: theme)
    }

    /// One attributed string per line, tokenised as a whole first so multi-line strings
    /// and comments keep their colour.
    static func lines(_ text: String, language: Language, theme: Theme) -> [AttributedString] {
        let tokens = Highlighters.make(for: language).tokens(in: text)
        var lines: [AttributedString] = []
        var offset = 0
        for line in text.components(separatedBy: "\n") {
            let length = (line as NSString).length
            let range = NSRange(location: offset, length: length)
            let inLine = tokens.filter { NSIntersectionRange($0.range, range).length > 0 }
            lines.append(colored(line, offset: offset, tokens: inLine, theme: theme))
            offset += length + 1
        }
        return lines
    }

    /// Colours `text`, which starts at `offset` in the string the tokens were found in.
    private static func colored(_ text: String, offset: Int, tokens: [Token], theme: Theme) -> AttributedString {
        var attributed = AttributedString(text)
        let length = (text as NSString).length
        for token in tokens {
            let local = NSIntersectionRange(NSRange(location: token.range.location - offset, length: token.range.length), NSRange(location: 0, length: length))
            guard local.length > 0, let range = Range(local, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].foregroundColor = color(for: token.kind, in: theme)
        }
        return attributed
    }

    private static func color(for kind: TokenKind, in theme: Theme) -> Color {
        let palette = theme.syntax
        return switch kind {
        case .keyword: palette.keyword.color
        case .string: palette.string.color
        case .comment: palette.comment.color
        case .number: palette.number.color
        case .type: palette.type.color
        case .function: palette.function.color
        }
    }

    /// A language from a fence tag like `swift` or `yaml`.
    static func language(forTag tag: String?) -> Language {
        guard let tag, !tag.isEmpty else { return .plain }
        let aliases = ["sh": "sh", "bash": "sh", "zsh": "sh", "shell": "sh", "console": "sh", "yml": "yaml", "ts": "ts", "js": "js", "py": "py", "rb": "rb"]
        let ext = aliases[tag.lowercased()] ?? tag.lowercased()
        return Language(url: URL(filePath: "file.\(ext)"))
    }
}
