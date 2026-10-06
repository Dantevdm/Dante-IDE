import DanteKit
import SwiftUI

/// The launch mark: seven arcs, one per lifecycle phase, that draw themselves
/// in turn, settle, and pulse once around the "D".
struct PhaseRing: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Flipping this from false to true plays the animation.
    let drawn: Bool

    private let segments = 7
    private let radius: CGFloat = 80
    private let lineWidth: CGFloat = 7
    private static let ease = Animation.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.6)

    var body: some View {
        let gap = 8 / (2 * .pi * radius)
        ZStack {
            Circle()
                .stroke(theme.raised.color, lineWidth: lineWidth)

            ZStack {
                ForEach(0..<segments, id: \.self) { index in
                    let start = Double(index) / Double(segments) + gap / 2
                    let end = Double(index + 1) / Double(segments) - gap / 2
                    Circle()
                        .trim(from: start, to: drawn ? end : start)
                        .stroke(
                            theme.accent.color.opacity(0.55 + Double(index) * 0.075),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : Self.ease.delay(0.15 + Double(index) * 0.11), value: drawn)
                }
            }
            .rotationEffect(.degrees(drawn || reduceMotion ? 0 : -40))
            .animation(reduceMotion ? nil : .timingCurve(0.2, 0.7, 0.2, 1, duration: 1.7), value: drawn)

            if !reduceMotion {
                Circle()
                    .stroke(theme.accent.color, lineWidth: 1)
                    .keyframeAnimator(initialValue: Pulse(), trigger: drawn) { ring, pulse in
                        ring.scaleEffect(pulse.scale).opacity(pulse.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(0, duration: 1.15)
                            LinearKeyframe(0.6, duration: 0.3)
                            LinearKeyframe(0, duration: 0.9)
                        }
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(1, duration: 1.15)
                            CubicKeyframe(1.35, duration: 1.2)
                        }
                    }
            }

            Text("D")
                .font(.dante(size: 60, weight: .semibold))
                .foregroundStyle(theme.text.color)
                .opacity(drawn ? 1 : 0)
                .offset(y: drawn ? 0 : 10)
                .animation(reduceMotion ? nil : Self.ease.delay(0.95), value: drawn)
        }
        .frame(width: radius * 2 + lineWidth, height: radius * 2 + lineWidth)
        .accessibilityHidden(true)
    }

    private struct Pulse {
        var scale: CGFloat = 1
        var opacity: Double = 0
    }
}
