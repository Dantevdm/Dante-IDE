import DanteKit
import SwiftUI

/// Small uppercase label above a group.
struct Eyebrow: View {
    @Environment(\.theme) private var theme
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.dante(size: 10.5, weight: .medium))
            .tracking(0.9)
            .foregroundStyle(theme.text3.color)
    }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Secondary and primary buttons in the theme's style.
struct DanteButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.dante(size: 12.5, weight: .medium))
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .foregroundStyle(primary ? theme.onAccent.color : theme.text.color)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(primary ? theme.accent.color : theme.raised.color)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(primary ? theme.accent.color : theme.line2.color, lineWidth: 1)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}

/// A borderless icon button with a hover background.
struct IconButton: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let label: String
    var size: CGFloat = 13
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image.symbol(symbol, side: size + 1)
                .font(.dante(size: size, weight: .medium))
                .frame(width: 26, height: 26)
                .foregroundStyle(hovering ? theme.text.color : theme.text3.color)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme.raised.color : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The dotted backdrop used behind the launch window and diagrams.
struct DotGrid: View {
    let color: Color
    var spacing: CGFloat = 22

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var y: CGFloat = spacing / 2
            while y < size.height {
                var x: CGFloat = spacing / 2
                while x < size.width {
                    path.addEllipse(in: CGRect(x: x, y: y, width: 1.2, height: 1.2))
                    x += spacing
                }
                y += spacing
            }
            context.fill(path, with: .color(color))
        }
        .accessibilityHidden(true)
    }
}

/// Lays children out left to right, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
