import DanteEditor
import DanteKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// The rendered document. Paper sets body text in a serif, as the design does.
struct DocumentBody: View {
    @Environment(\.theme) private var theme
    let document: MarkdownDocument
    let path: String
    let root: URL
    /// Some of the blocks, for export, which lays out pages one block at a time.
    var only: [MarkdownDocument.Block]?
    var showsPath = true

    private var serif: Bool { theme.id == .paper }
    private var bodySize: CGFloat { serif ? 17 : 14.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsPath {
                Text(path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.text3.color)
            }
            ForEach(Array((only ?? document.blocks).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: serif ? .serif : .default)
    }

    private func inline(_ text: String, size: CGFloat? = nil) -> Text {
        Text(MarkdownText.attributed(text, theme: theme, codeSize: (size ?? bodySize) - 2))
    }

    @ViewBuilder
    private func view(for block: MarkdownDocument.Block) -> some View {
        switch block {
        case .heading(let level, let text, let anchor):
            let size: CGFloat = [serif ? 40 : 30, serif ? 26 : 21, serif ? 21 : 17, 15, 14, 13][min(level, 6) - 1]
            inline(text, size: size)
                .font(font(size, weight: level == 1 ? (serif ? .medium : .semibold) : .semibold))
                .foregroundStyle(theme.text.color)
                .padding(.top, level == 1 ? 0 : 10)
                .id(anchor)
        case .paragraph(let text):
            inline(text)
                .font(font(bodySize))
                .lineSpacing(serif ? 6 : 4)
                .foregroundStyle(theme.text.color)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let items, _):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        if let checked = item.checked {
                            Image(systemName: checked ? "checkmark.square.fill" : "square")
                                .font(.system(size: bodySize - 2))
                                .foregroundStyle(checked ? theme.green.color : theme.text3.color)
                        } else if let number = item.number {
                            Text("\(number).").font(font(bodySize)).foregroundStyle(theme.text3.color).monospacedDigit()
                        } else {
                            Text("•").font(font(bodySize)).foregroundStyle(theme.text3.color)
                        }
                        inline(item.text)
                            .font(font(bodySize))
                            .lineSpacing(serif ? 5 : 3)
                            .foregroundStyle(item.checked == true ? theme.text2.color : theme.text.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
            }
        case .quote(let text):
            HStack(spacing: 12) {
                Rectangle().fill(theme.line2.color).frame(width: 3)
                inline(text).font(font(bodySize).italic()).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let code, let language) where language?.lowercased() == "mermaid":
            MermaidBlock(source: code)
        case .code(let code, let language):
            CodeBlock(text: code, language: language)
        case .table(let header, let rows):
            DocTable(header: header, rows: rows, inline: { inline($0, size: 13) })
        case .rule:
            Rectangle().fill(theme.line.color).frame(height: 1).padding(.vertical, 6)
        case .image(let alt, let source):
            DocImage(alt: alt, source: source, base: root.appending(path: (path as NSString).deletingLastPathComponent))
        }
    }
}

struct DocTable: View {
    @Environment(\.theme) private var theme
    let header: [String]
    let rows: [[String]]
    let inline: (String) -> Text

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    Text(cell.uppercased())
                        .font(.system(size: 10.5, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(theme.text3.color)
                        .padding(.bottom, 8)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider().overlay(theme.line.color).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        inline(cell)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.text.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 8)
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.line.color))
    }
}
