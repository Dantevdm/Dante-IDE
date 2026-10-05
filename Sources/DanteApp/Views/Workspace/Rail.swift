import SwiftUI

/// The left strip that switches between areas of the workspace.
struct Rail: View {
    @Environment(\.theme) private var theme
    let session: Session

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Area.main) { item(for: $0) }
            Spacer(minLength: 8)
            ForEach(Area.footer) { item(for: $0) }
        }
        .padding(.vertical, 10)
        .frame(width: 68)
        .background(theme.panel.color)
        .overlay(alignment: .trailing) { Rectangle().fill(theme.line.color).frame(width: 1) }
    }

    private func item(for area: Area) -> some View {
        RailItem(area: area, isSelected: session.area == area) {
            session.area = area
        }
    }
}

private struct RailItem: View {
    @Environment(\.theme) private var theme
    let area: Area
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: area.symbol)
                    .font(.system(size: 16, weight: .regular))
                    .frame(height: 20)
                Text(area.title)
                    .font(.system(size: 10, weight: .medium))
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
        .help(area.isBuilt ? area.title : "\(area.title) (designed, not built yet)")
        .accessibilityLabel(area.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Stands in for areas that are designed but not built yet.
struct PlaceholderView: View {
    @Environment(\.theme) private var theme
    let area: Area

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: area.symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(theme.accent.color)
            Text(area.title == "Env" ? "Environments" : area.title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.text.color)
            Text(area.summary)
                .font(.system(size: 13.5))
                .foregroundStyle(theme.text2.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Text("Designed, not built yet.")
                .font(.system(size: 12))
                .foregroundStyle(theme.text3.color)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.ground.color)
    }
}
