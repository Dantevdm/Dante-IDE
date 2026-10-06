import DanteKit
import SwiftUI

/// The shared frame of the lifecycle areas: a scrolling column with an eyebrow, title,
/// one-line description and actions on the right, then the area's cards.
struct AreaPage<Actions: View, Content: View>: View {
    @Environment(\.theme) private var theme
    let eyebrow: String
    let title: String
    let subtitle: String?
    /// Pages fill the window by default, so wide and ultra-wide screens get more columns.
    var maxWidth: CGFloat = .infinity
    @ViewBuilder let actions: Actions
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(eyebrow)
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(title)
                            .font(.dante(size: 28, weight: .semibold))
                            .foregroundStyle(theme.text.color)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        HStack(spacing: 8) { actions }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.dante(size: 13.5))
                            .foregroundStyle(theme.text2.color)
                            .frame(maxWidth: 680, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                content
            }
            .padding(28)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.ground.color)
    }
}

extension AreaPage where Actions == EmptyView {
    init(eyebrow: String, title: String, subtitle: String?, maxWidth: CGFloat = .infinity, @ViewBuilder content: () -> Content) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle, maxWidth: maxWidth, actions: { EmptyView() }, content: content)
    }
}

/// A rounded panel with an optional header row.
struct Card<Trailing: View, Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String?
    var accent = false
    var spacing: CGFloat = 12
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let title {
                HStack(spacing: 8) {
                    Text(title).font(.dante(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
                    Spacer(minLength: 8)
                    trailing
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(accent ? theme.accentLine.color : theme.line.color))
    }
}

extension Card where Trailing == EmptyView {
    init(_ title: String? = nil, accent: Bool = false, spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.init(title: title, accent: accent, spacing: spacing, trailing: { EmptyView() }, content: content)
    }
}

extension Card {
    init(_ title: String?, accent: Bool = false, spacing: CGFloat = 12, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.init(title: title, accent: accent, spacing: spacing, trailing: trailing, content: content)
    }
}

/// Rows separated by hairlines, as in the design's lists.
struct RowList<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
    @Environment(\.theme) private var theme
    let data: Data
    var padding: CGFloat = 9
    @ViewBuilder let row: (Data.Element) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(data) { element in
                VStack(spacing: 0) {
                    Rectangle().fill(theme.line.color).frame(height: 1)
                    row(element)
                        .padding(.vertical, padding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// A small text link in the accent colour, used in card headers.
struct LinkButton: View {
    @Environment(\.theme) private var theme
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.dante(size: 12))
            .foregroundStyle(theme.accent.color)
    }
}

/// A rounded label for facts like the language or branch.
struct Chip: View {
    @Environment(\.theme) private var theme
    let text: String
    var symbol: String?
    var color: Color?
    var mono = false

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.dante(size: 10.5)) }
            Text(text).font(.dante(size: 12, design: mono ? .monospaced : .default))
        }
        .foregroundStyle(color ?? theme.text2.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(theme.raised.color))
        .overlay(Capsule().strokeBorder(theme.line.color))
        .lineLimit(1)
    }
}

/// What an area shows when the project has nothing for it yet, with a way forward.
struct EmptyState<Actions: View>: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.dante(size: 26, weight: .light))
                .foregroundStyle(theme.text3.color)
            Text(title).font(.dante(size: 15, weight: .semibold)).foregroundStyle(theme.text.color)
            Text(message)
                .font(.dante(size: 12.5))
                .foregroundStyle(theme.text2.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { actions }.padding(.top, 4)
        }
        .padding(.vertical, 36)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line.color, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

/// A grid of cards that wraps to fewer columns as the window narrows.
struct CardGrid<Content: View>: View {
    var minimum: CGFloat = 300
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
            content
        }
    }
}

extension Date {
    /// "3 min ago", "2 days ago".
    var relative: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: .now)
    }
}
