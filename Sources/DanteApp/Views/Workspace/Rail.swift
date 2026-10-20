import SwiftUI

/// The left strip that switches between the workspace's places. A place with several pages
/// opens on the one last shown, and `PlaceTabs` switches between them.
struct Rail: View {
    @Environment(\.theme) private var theme
    let session: Session

    var body: some View {
        VStack(spacing: 2) {
            ForEach(RailPlace.main) { item(for: $0) }
            Spacer(minLength: 8)
            ForEach(RailPlace.footer) { item(for: $0) }
        }
        .padding(.vertical, 10)
        .frame(width: 68)
        .background(theme.panel.color)
        .overlay(alignment: .trailing) { Rectangle().fill(theme.line.color).frame(width: 1) }
    }

    private func item(for place: RailPlace) -> some View {
        RailItem(place: place, isSelected: session.area.place == place) {
            guard session.area.place != place else { return }
            session.area = session.lastPage[place.id] ?? place.pages[0]
        }
    }
}

private struct RailItem: View {
    @Environment(\.theme) private var theme
    let place: RailPlace
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image.symbol(place.symbol, side: 17)
                    .font(.dante(size: 16, weight: .regular))
                    .frame(height: 20)
                Text(place.title)
                    .font(.dante(size: 10, weight: .medium))
            }
            .foregroundStyle(isSelected ? theme.accent.color : (hovering ? theme.text2.color : theme.text3.color))
            .frame(width: 54, height: 48)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? theme.accentTint.color : (hovering ? theme.raised.color : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(place.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var help: String {
        let pages = place.pages.count > 1 ? " (" + place.pages.map(\.title).joined(separator: " · ") + ")" : ""
        return "\(place.title)\(pages): \(place.summary)"
    }
}

/// The pages of a place with several, above its content. The marker slides between tabs and
/// the page cross-fades.
struct PlaceTabs: View {
    @Environment(\.theme) private var theme
    let session: Session
    @Namespace private var marker
    @State private var hovered: Area?

    var body: some View {
        let place = session.area.place
        HStack(spacing: 4) {
            ForEach(place.pages) { page in
                let selected = page == session.area
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { session.area = page }
                } label: {
                    HStack(spacing: 7) {
                        Image.symbol(page.symbol, side: 13)
                            .font(.dante(size: 12.5, weight: .medium))
                        Text(page.title)
                            .font(.dante(size: 14, weight: selected ? .semibold : .medium))
                    }
                    .foregroundStyle(selected ? theme.text.color : (hovered == page ? theme.text2.color : theme.text3.color))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(theme.raised.color)
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.line.color))
                                .matchedGeometryEffect(id: "tab", in: marker)
                        } else if hovered == page {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.raised.color.opacity(0.5))
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if selected {
                            Capsule().fill(theme.accent.color)
                                .frame(width: 18, height: 2.5)
                                .offset(y: 7)
                                .matchedGeometryEffect(id: "line", in: marker)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? page : (hovered == page ? nil : hovered) }
                .help(page.summary)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity)
        .background(theme.ground.color)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line.color).frame(height: 1) }
    }
}

extension EnvironmentValues {
    /// True under `PlaceTabs`, where an area page's own title would repeat its tab.
    @Entry var underPlaceTabs = false
}
