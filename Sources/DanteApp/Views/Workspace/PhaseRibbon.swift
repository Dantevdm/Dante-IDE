import DanteKit
import SwiftUI

/// The lifecycle strip in the title bar: done phases ticked, the current one filled.
/// Phases are guidance, so nothing here blocks anything.
struct PhaseRibbon: View {
    @Environment(\.theme) private var theme
    let lifecycle: Lifecycle

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
        .help(lifecycle.hasSpec ? "Lifecycle phases" : "No .dante/project.yaml yet, so no current phase")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private func segment(_ phase: String, index: Int) -> some View {
        let current = lifecycle.currentIndex
        if let current, index < current {
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.green.color)
                Text(phase)
            }
            .font(.system(size: 12))
            .foregroundStyle(theme.text2.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        } else if index == current {
            Text(phase)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.onAccent.color)
                .padding(.horizontal, 11)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.accent.color))
        } else {
            Text(phase)
                .font(.system(size: 12))
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
