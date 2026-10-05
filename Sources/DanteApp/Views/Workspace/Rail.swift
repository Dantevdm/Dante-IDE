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
        .help(area.summary.isEmpty ? area.title : "\(area.title): \(area.summary)")
        .accessibilityLabel(area.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
