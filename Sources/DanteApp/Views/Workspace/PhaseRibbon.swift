import DanteKit
import SwiftUI

/// The lifecycle strip in the title bar: done phases ticked, the current one filled.
/// Clicking a phase opens it in Plan. Phases are guidance, so nothing here blocks anything.
struct PhaseRibbon: View {
    @Environment(\.theme) private var theme
    let lifecycle: Lifecycle
    /// The phase Plan is showing, outlined when it isn't the current one.
    var selected: String?
    let open: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(lifecycle.phases.enumerated()), id: \.offset) { index, phase in
                segment(phase, index: index)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.line.color))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    private func segment(_ phase: String, index: Int) -> some View {
        Segment(phase: phase, isSelected: phase == selected && index != lifecycle.currentIndex) {
            label(phase, index: index)
        } action: {
            open(phase)
        }
        .help(lifecycle.hasSpec ? "Open \(phase) in Plan" : "Open \(phase) in Plan. No .dante/project.yaml yet, so no current phase")
    }

    @ViewBuilder
    private func label(_ phase: String, index: Int) -> some View {
        let current = lifecycle.currentIndex
        if let current, index < current {
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.dante(size: 9, weight: .bold)).foregroundStyle(theme.green.color)
                Text(phase)
            }
            .font(.dante(size: 12))
            .foregroundStyle(theme.text2.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        } else if index == current {
            Text(phase)
                .font(.dante(size: 12, weight: .semibold))
                .foregroundStyle(theme.onAccent.color)
                .padding(.horizontal, 11)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.accent.color))
        } else {
            Text(phase)
                .font(.dante(size: 12))
                .foregroundStyle(theme.text3.color)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
        }
    }

    private var accessibilityText: String {
        guard let current = lifecycle.currentIndex else { return "Lifecycle: no current phase" }
        return "Lifecycle: \(lifecycle.phases[current]), phase \(current + 1) of \(lifecycle.phases.count)"
    }
}

/// One clickable phase, with a hover wash and an outline when Plan is showing it.
private struct Segment<Label: View>: View {
    @Environment(\.theme) private var theme
    let phase: String
    let isSelected: Bool
    @ViewBuilder let label: Label
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering ? theme.raised.color : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isSelected ? theme.accentLine.color : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(phase)
    }
}
