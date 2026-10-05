import DanteKit
import SwiftUI

/// The language server's hover text: code blocks highlighted, prose in the UI font.
struct HoverView: View {
    let markdown: String
    let theme: Theme
    let fontSize: CGFloat

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Self.segments(markdown).enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .code(let code, let language):
                        Text(highlighted(code, language))
                            .font(.system(size: fontSize - 0.5, design: .monospaced))
                            .textSelection(.enabled)
                    case .prose(let text):
                        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                            .font(.system(size: 12))
                            .foregroundStyle(theme.text2.color)
                            .textSelection(.enabled)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 520)
        .frame(maxHeight: 300)
        .background(theme.panel.color)
    }

    enum Segment: Equatable {
        case code(String, Language)
        case prose(String)
    }

    /// Splits on ``` fences. An unclosed fence runs to the end.
    nonisolated static func segments(_ markdown: String) -> [Segment] {
        var segments: [Segment] = []
        var lines: [Substring] = []
        var fence: Language?
        func flush() {
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { segments.append(fence.map { .code(text, $0) } ?? .prose(text)) }
            lines = []
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                if fence == nil {
                    let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                    fence = Language(rawValue: tag) ?? Language(url: URL(filePath: "x.\(tag)"))
                } else {
                    fence = nil
                }
            } else {
                lines.append(line)
            }
        }
        flush()
        return segments
    }

    private func highlighted(_ code: String, _ language: Language) -> AttributedString {
        var result = AttributedString(code)
        result.foregroundColor = theme.syntax.plain.color
        let ns = code as NSString
        for token in Highlighters.make(for: language).tokens(in: code) where NSMaxRange(token.range) <= ns.length {
            guard let range = Range(token.range, in: code), let target = Range(range, in: result) else { continue }
            result[target].foregroundColor = color(token.kind)
        }
        return result
    }

    private func color(_ kind: TokenKind) -> Color {
        switch kind {
        case .keyword: theme.syntax.keyword.color
        case .string: theme.syntax.string.color
        case .comment: theme.syntax.comment.color
        case .number: theme.syntax.number.color
        case .type: theme.syntax.type.color
        case .function: theme.syntax.function.color
        }
    }
}
