import DanteKit
import SwiftUI

/// Renders Claude's replies: paragraphs with inline markdown, headings, lists and fenced
/// code blocks. Enough for chat; full CommonMark can come later.
struct MarkdownText: View {
    @Environment(\.theme) private var theme
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(in: text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code, let language):
                    CodeBlock(text: code, language: language)
                case .heading(let text):
                    inline(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
                case .paragraph(let text):
                    inline(text)
                }
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(theme.text.color)
        .lineSpacing(2)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> Text {
        Text(Self.attributed(text, theme: theme))
    }

    /// Inline markdown (bold, italics, links, `code`) with code in the theme's accent.
    static func attributed(_ text: String, theme: Theme, codeSize: CGFloat = 11.5) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(size: codeSize, design: .monospaced)
            attributed[run.range].foregroundColor = theme.accent.color
        }
        return attributed
    }

    enum Block: Equatable {
        case paragraph(String)
        case heading(String)
        case code(String, language: String?)
    }

    static func blocks(in text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var language: String?

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n"), language: language))
                    code = nil
                } else {
                    flushParagraph()
                    let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else if trimmed.hasPrefix("#") {
                flushParagraph()
                blocks.append(.heading(String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.isEmpty {
                flushParagraph()
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let indent = line.prefix { $0 == " " }
                paragraph.append(indent + "•  " + trimmed.dropFirst(2))
            } else {
                paragraph.append(line)
            }
        }
        // An unclosed fence while streaming still shows as code.
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"), language: language)) }
        flushParagraph()
        return blocks
    }
}
