import ActivityKit
import SwiftUI
import WidgetKit

/// The Live Activity: on the Lock Screen, the most urgent thing on the Mac (a step waiting on
/// you, an agent or job working, a job ready) with counts; in the Dynamic Island, the same
/// in short. Tapping it opens the app, where waiting steps have Approve and Decline.
@main
struct DanteWidgets: WidgetBundle {
    var body: some Widget {
        DanteLiveActivity()
    }
}

struct DanteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DanteActivityAttributes.self) { context in
            LockScreenGlance(state: context.state, server: context.attributes.server)
                .activityBackgroundTint(Palette.card.opacity(0.9))
                .activitySystemActionForegroundColor(Mood.accent)
        } dynamicIsland: { context in
            let mood = Mood(context.state.mood)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label { Text(mood.word) } icon: { Image(systemName: mood.symbol) }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(mood.color)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Counts(state: context.state).font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.headline).font(.callout.weight(.semibold)).lineLimit(2)
                        Text(context.state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: mood.symbol).foregroundStyle(mood.color)
            } compactTrailing: {
                if context.state.waiting > 0 {
                    Text("\(context.state.waiting)").font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(mood.color)
                } else if context.state.working > 0 {
                    Text("\(context.state.working)").font(.caption2.monospacedDigit())
                }
            } minimal: {
                Image(systemName: mood.symbol).foregroundStyle(mood.color)
            }
        }
    }
}

private struct LockScreenGlance: View {
    let state: DanteActivityAttributes.ContentState
    let server: String

    var body: some View {
        let mood = Mood(state.mood)
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(mood.color.opacity(0.18))
                Image(systemName: mood.symbol).font(.title3.weight(.semibold)).foregroundStyle(mood.color)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(mood.word.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(mood.color)
                Text(state.headline).font(.headline).lineLimit(2)
                Text(state.detail.isEmpty ? server : state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Counts(state: state).font(.caption.monospacedDigit())
        }
        .padding(14)
    }
}

private struct Counts: View {
    let state: DanteActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if state.waiting > 0 { Label("\(state.waiting)", systemImage: "hand.raised.fill").foregroundStyle(Mood.waiting.color) }
            if state.working > 0 { Label("\(state.working)", systemImage: "gearshape.2").foregroundStyle(.secondary) }
        }
        .labelStyle(.titleAndIcon)
    }
}

/// How each mood looks, in the app's colours (`Palette`, shared with the app).
private enum Mood {
    case waiting, working, review, offline, quiet

    init(_ raw: String) {
        switch raw {
        case "waiting": self = .waiting
        case "working": self = .working
        case "review": self = .review
        case "offline": self = .offline
        default: self = .quiet
        }
    }

    static let accent = Palette.accent

    var color: Color {
        switch self {
        case .waiting: Palette.amber
        case .working: Palette.accent
        case .review: Palette.green
        case .offline, .quiet: Palette.text3
        }
    }

    var symbol: String {
        switch self {
        case .waiting: "hand.raised.fill"
        case .working: "sparkles"
        case .review: "checkmark.seal"
        case .offline: "wifi.slash"
        case .quiet: "leaf"
        }
    }

    var word: String {
        switch self {
        case .waiting: "Waiting on you"
        case .working: "Working"
        case .review: "Ready"
        case .offline: "Offline"
        case .quiet: "Quiet"
        }
    }
}
