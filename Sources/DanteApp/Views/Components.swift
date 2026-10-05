import DanteKit
import SwiftUI

/// Small uppercase label above a group.
struct Eyebrow: View {
    @Environment(\.theme) private var theme
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .medium))
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
            .font(.system(size: 12.5, weight: .medium))
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
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
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

/// A row of small dots showing how far through the lifecycle a project is.
struct PhaseDots: View {
    @Environment(\.theme) private var theme
    let lifecycle: Lifecycle

    var body: some View {
        HStack(spacing: 3) {
            ForEach(lifecycle.phases.indices, id: \.self) { index in
                Circle()
                    .fill(color(for: index))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    private func color(for index: Int) -> Color {
        guard let current = lifecycle.currentIndex else { return theme.track.color }
        if index < current { return theme.done.color }
        if index == current { return theme.accent.color }
        return theme.track.color
    }
}
