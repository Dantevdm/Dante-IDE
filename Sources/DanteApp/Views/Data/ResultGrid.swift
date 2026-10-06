import AppKit
import DanteKit
import SwiftUI

/// Rows from a query: a pinned header, row numbers, numbers right-aligned and NULLs
/// dimmed. Click a cell to inspect it in the footer; right-click to copy or filter.
struct ResultGrid: View {
    @Environment(\.theme) private var theme
    let result: QueryResult
    /// Row numbers start here, for paged tables.
    var firstRow = 0
    var sortColumn: String?
    var descending = false
    var onSort: ((String) -> Void)?
    /// "Show rows where this column has this value", for table browsing.
    var onFilter: ((String, String?) -> Void)?

    @State private var selected: Cell?

    struct Cell: Equatable {
        var row: Int
        var column: Int
    }

    private static let font = Font.dante(size: 12, design: .monospaced)
    private static let charWidth: CGFloat = 7.3
    private var numberWidth: CGFloat { CGFloat(String(firstRow + result.rows.count).count) * Self.charWidth + 22 }

    private var widths: [CGFloat] {
        result.columns.indices.map { index in
            let longest = result.rows.prefix(300).reduce(result.columns[index].count + 2) { longest, row in
                max(longest, index < row.count ? min(row[index]?.count ?? 4, 60) : 0)
            }
            return min(max(CGFloat(longest) * Self.charWidth + 34, 64), 420)
        }
    }

    var body: some View {
        let widths = widths
        let numeric = result.numericColumns
        VStack(spacing: 0) {
            GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(result.rows.indices, id: \.self) { row in
                            rowView(row, widths: widths, numeric: numeric)
                        }
                    } header: {
                        header(widths: widths, numeric: numeric)
                    }
                }
                .padding(.bottom, 8)
                // Narrow results start at the left rather than floating in the middle.
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
            }
            }
            .background(theme.ground.color)
            inspector
        }
        .onChange(of: result) { selected = nil }
    }

    private func header(widths: [CGFloat], numeric: Set<Int>) -> some View {
        HStack(spacing: 0) {
            Text("#")
                .frame(width: numberWidth, alignment: .trailing)
                .padding(.trailing, 4)
                .foregroundStyle(theme.text3.color)
            ForEach(result.columns.indices, id: \.self) { index in
                let name = result.columns[index]
                Button {
                    onSort?(name)
                } label: {
                    HStack(spacing: 4) {
                        if numeric.contains(index) { Spacer(minLength: 0) }
                        Text(name).lineLimit(1)
                        if sortColumn == name {
                            Image(systemName: descending ? "chevron.down" : "chevron.up").font(.dante(size: 8, weight: .bold))
                        }
                        if !numeric.contains(index) { Spacer(minLength: 0) }
                    }
                    .padding(.horizontal, 10)
                    .frame(width: widths[index], height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onSort == nil)
                .foregroundStyle(theme.text.color)
                .overlay(alignment: .leading) { Rectangle().fill(theme.line.color).frame(width: 1) }
                .help(onSort == nil ? name : "Sort by \(name)")
            }
        }
        .font(.dante(size: 11.5, weight: .semibold))
        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
        .background(theme.panel.color)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line2.color).frame(height: 1) }
    }

    private func rowView(_ row: Int, widths: [CGFloat], numeric: Set<Int>) -> some View {
        let values = result.rows[row]
        return HStack(spacing: 0) {
            Text("\(firstRow + row + 1)")
                .font(.dante(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.text3.color)
                .frame(width: numberWidth, alignment: .trailing)
                .padding(.trailing, 4)
            ForEach(result.columns.indices, id: \.self) { column in
                let value = column < values.count ? values[column] : nil
                let isSelected = selected == Cell(row: row, column: column)
                Button { selected = Cell(row: row, column: column) } label: {
                Group {
                    if let value {
                        Text(value.replacingOccurrences(of: "\n", with: "⏎ "))
                            .foregroundStyle(theme.text.color)
                    } else {
                        Text("NULL").italic().foregroundStyle(theme.text3.color.opacity(0.7))
                    }
                }
                .font(Self.font)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .frame(width: widths[column], height: 24, alignment: numeric.contains(column) ? .trailing : .leading)
                .background(isSelected ? theme.accentTint.color : .clear)
                .overlay {
                    if isSelected { Rectangle().strokeBorder(theme.accent.color, lineWidth: 1) }
                }
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { menu(row: row, column: column) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(row % 2 == 1 ? theme.panel.color.opacity(0.55) : .clear)
    }

    @ViewBuilder
    private func menu(row: Int, column: Int) -> some View {
        let value = result.rows[row].indices.contains(column) ? result.rows[row][column] : nil
        Button("Copy Value") { copy(value ?? "NULL") }
        Button("Copy Row as JSON") { copy(result.json(row: row)) }
        Button("Copy Column Name") { copy(result.columns[column]) }
        if let onFilter {
            Divider()
            Button(value == nil ? "Show Rows Where \(result.columns[column]) Is NULL" : "Show Rows With This \(result.columns[column])") {
                onFilter(result.columns[column], value)
            }
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let selected, result.rows.indices.contains(selected.row), result.columns.indices.contains(selected.column) {
            let value = result.rows[selected.row].indices.contains(selected.column) ? result.rows[selected.row][selected.column] : nil
            HStack(alignment: .top, spacing: 10) {
                Text(result.columns[selected.column])
                    .font(.dante(size: 11, weight: .semibold))
                    .foregroundStyle(theme.text2.color)
                ScrollView {
                    Text(value ?? "NULL")
                        .font(Self.font)
                        .foregroundStyle(value == nil ? theme.text3.color : theme.text.color)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
                .fixedSize(horizontal: false, vertical: true)
                IconButton(symbol: "doc.on.doc", label: "Copy value", size: 11) { copy(value ?? "NULL") }
                IconButton(symbol: "xmark", label: "Close", size: 10) { self.selected = nil }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(theme.panel.color)
            .overlay(alignment: .top) { Rectangle().fill(theme.line.color).frame(height: 1) }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
