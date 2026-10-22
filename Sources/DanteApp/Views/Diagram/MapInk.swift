import DanteKit
import SwiftUI

/// The Map's ink: how its links, cards, groups and boundaries are drawn. The Infra view, the
/// System map and the diagram editor all draw through these, so a copied picture looks
/// exactly like the map it came from.
enum MapInk {
    static func path(_ curve: LinkCurve) -> Path {
        var path = Path()
        path.move(to: curve.start)
        path.addCurve(to: curve.end, control1: curve.control1, control2: curve.control2)
        return path
    }

    static func stroke(_ path: Path, color: Color, width: CGFloat, dash: [CGFloat] = [], phase: Double = 0, in context: inout GraphicsContext) {
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash, dashPhase: CGFloat(phase)))
    }

    /// A small glowing packet travelling along the path.
    static func pulse(_ path: Path, time: Double, color: Color, in context: inout GraphicsContext) {
        let progress = CGFloat((time / 2.4).truncatingRemainder(dividingBy: 1))
        guard progress > 0.02, let point = path.trimmedPath(from: 0, to: progress).currentPoint else { return }
        let fade = min(1, min(progress, 1 - progress) * 6)
        context.fill(Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)), with: .color(color.opacity(0.18 * fade)))
        context.fill(Path(ellipseIn: CGRect(x: point.x - 2.6, y: point.y - 2.6, width: 5.2, height: 5.2)), with: .color(color.opacity(fade)))
    }

    static func arrowhead(_ path: Path, color: Color, in context: inout GraphicsContext) {
        guard let end = path.currentPoint, let before = path.trimmedPath(from: 0, to: 0.97).currentPoint else { return }
        let angle = atan2(end.y - before.y, end.x - before.x)
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - 7 * cos(angle - 0.45), y: end.y - 7 * sin(angle - 0.45)))
        head.addLine(to: CGPoint(x: end.x - 7 * cos(angle + 0.45), y: end.y - 7 * sin(angle + 0.45)))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }

    /// A pill with the link's words halfway along it. Returns where it was drawn.
    @discardableResult
    static func label(_ text: String, on path: Path, theme: Theme, emphasised: Bool = false, in context: inout GraphicsContext) -> CGRect? {
        guard !text.isEmpty, let point = path.trimmedPath(from: 0, to: 0.5).currentPoint else { return nil }
        let resolved = context.resolve(Text(text).font(.dante(size: 9.5, weight: .medium)).foregroundColor(emphasised ? theme.accent.color : theme.text2.color))
        let size = resolved.measure(in: CGSize(width: 200, height: 20))
        let box = CGRect(x: point.x - size.width / 2 - 5, y: point.y - size.height / 2 - 2, width: size.width + 10, height: size.height + 4)
        context.fill(Path(roundedRect: box, cornerRadius: box.height / 2), with: .color(theme.card.color))
        context.stroke(Path(roundedRect: box, cornerRadius: box.height / 2), with: .color(emphasised ? theme.accent.color : theme.line.color), lineWidth: emphasised ? 1.2 : 0.8)
        context.draw(resolved, at: point)
        return box
    }

    /// The picture's backdrop: the panel colour with a dot grid, in a rounded frame.
    static let backdropRadius: CGFloat = 12
}

// MARK: Cards

/// An Infra resource card: a tinted icon tile, the name, what it is and the stack it's in.
struct ResourceFace: View {
    @Environment(\.theme) private var theme
    let icon: String
    let title: String
    let kind: String
    let detail: String
    /// The detail reads as a note rather than a stack name ("outside the templates").
    var detailIsNote = false
    let hue: Color
    var dashed = false
    var selected = false
    var emphasised = false
    var width: CGFloat = 196
    var height: CGFloat?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon.isEmpty ? "cube" : icon)
                .font(.dante(size: 14, weight: .medium))
                .foregroundStyle(hue)
                .frame(width: 34, height: 34)
                // Mixed into the card's colour rather than see-through: a PDF drops a gradient's transparency.
                .background(LinearGradient(colors: [theme.card.color.mix(with: hue, by: 0.22), theme.card.color.mix(with: hue, by: 0.08)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(hue.opacity(0.35)))
            VStack(alignment: .leading, spacing: 1) {
                Text(Breakable.camel(title)).font(.dante(size: 12, weight: .semibold)).foregroundStyle(theme.text.color).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !kind.isEmpty {
                    Text(kind).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                }
                if !detail.isEmpty {
                    Text(detail).font(.dante(size: 9.5, design: detailIsNote ? .default : .monospaced)).foregroundStyle(theme.text3.color.opacity(0.85))
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: width, alignment: .leading)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? theme.accentTint.color : theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? theme.accent.color : (emphasised ? hue.opacity(0.7) : theme.line2.color),
                          style: StrokeStyle(lineWidth: selected ? 1.6 : 1, dash: dashed ? [4, 3] : [])))
    }
}

/// The System map's part chrome: a card with the lane's colour as a stripe down its left.
struct PartChrome: ViewModifier {
    @Environment(\.theme) private var theme
    let hue: Color
    var selected = false
    var emphasised = false
    var dashed = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? theme.accentTint.color : theme.card.color))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, style: .continuous)
                    .fill(hue)
                    .frame(width: 3)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? theme.accent.color : emphasised ? theme.accentLine.color : theme.line2.color,
                                  style: StrokeStyle(lineWidth: selected ? 1.6 : 1, dash: dashed ? [4, 3] : []))
            )
            .shadow(color: selected ? theme.accent.color.opacity(0.22) : .clear, radius: selected ? 12 : 0, y: selected ? 4 : 0)
    }
}

/// A part's icon in its small tinted tile.
struct PartIcon: View {
    let symbol: String
    let hue: Color

    var body: some View {
        Image(systemName: symbol.isEmpty ? "shippingbox" : symbol)
            .font(.dante(size: 11, weight: .semibold))
            .foregroundStyle(hue)
            .frame(width: 22, height: 22)
            .background(hue.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A grey capsule with a monospaced word: a container, a branch.
struct MapChip: View {
    @Environment(\.theme) private var theme
    let text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.dante(size: 9)) }
            Text(text).font(.dante(size: 10.5, design: .monospaced)).lineLimit(1)
        }
        .foregroundStyle(theme.text3.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(theme.raised.color, in: Capsule())
    }
}

// MARK: Groups and boundaries

/// A tier's header: icon, name in capitals and how many are in it.
struct GroupHeader: View {
    let symbol: String
    let title: String
    let count: Int?
    let hue: Color

    var body: some View {
        HStack(spacing: 6) {
            if !symbol.isEmpty { Image(systemName: symbol).font(.dante(size: 10, weight: .semibold)) }
            Text(title.uppercased()).font(.dante(size: 10.5, weight: .semibold)).tracking(0.8).lineLimit(1)
            if let count {
                Text("\(count)").font(.dante(size: 10.5, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 5).background(hue.opacity(0.14), in: Capsule())
            }
        }
        .foregroundStyle(hue)
    }
}

/// A tier's panel: a faint wash of its colour with a matching border.
struct GroupPanel: ViewModifier {
    let hue: Color
    var dashed = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hue.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hue.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: dashed ? [5, 4] : [])))
    }
}

/// The dashed frame round the cloud.
struct BoundaryPanel: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.card.color.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.line2.color, style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])))
    }
}

/// A band's heading: "DELIVERY  Azure DevOps", "AWS CLOUD  portal-alb-stack · …".
struct BandTitle: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let title: String
    let note: String

    var body: some View {
        HStack(spacing: 8) {
            if !symbol.isEmpty { Image(systemName: symbol).font(.dante(size: 12, weight: .semibold)).foregroundStyle(theme.text2.color) }
            Text(title.uppercased()).font(.dante(size: 11, weight: .semibold)).tracking(1).foregroundStyle(theme.text2.color).lineLimit(1)
            if !note.isEmpty {
                Text(note).font(.dante(size: 11)).foregroundStyle(theme.text3.color).lineLimit(1)
            }
        }
    }
}

// MARK: People and pipelines

struct PeopleBadge: View {
    @Environment(\.theme) private var theme
    var symbol = "person.2.fill"
    var title = "Users"
    var selected = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol.isEmpty ? "person.2.fill" : symbol)
                .font(.dante(size: 16))
                .foregroundStyle(theme.text2.color)
                .frame(width: 46, height: 46)
                .background(selected ? theme.accentTint.color : theme.card.color, in: Circle())
                .overlay(Circle().strokeBorder(selected ? theme.accent.color : theme.line2.color, lineWidth: selected ? 1.6 : 1))
            Text(title).font(.dante(size: 11, weight: .medium)).foregroundStyle(theme.text2.color).lineLimit(1)
        }
    }
}

/// A pipeline stage: what it mostly does, its name and environment, and its steps as icons.
struct StageFace: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let title: String
    let environment: String
    /// Each step's icon, with its title on hover when there is one.
    let steps: [(symbol: String, help: String)]
    var selected = false
    var emphasised = false
    var dashed = false
    var width: CGFloat = 196
    var height: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: symbol.isEmpty ? "paperplane" : symbol)
                    .font(.dante(size: 11, weight: .semibold))
                    .foregroundStyle(theme.accent.color)
                    .frame(width: 24, height: 24)
                    .background(theme.accentTint.color, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.dante(size: 12.5, weight: .semibold)).foregroundStyle(theme.text.color).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !environment.isEmpty {
                        Text(environment).font(.dante(size: 10)).foregroundStyle(theme.text3.color).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            if !steps.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(steps.prefix(8).enumerated()), id: \.offset) { _, step in
                        Image(systemName: step.symbol)
                            .font(.dante(size: 9.5))
                            .foregroundStyle(theme.text2.color)
                            .frame(width: 20, height: 20)
                            .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .help(step.help)
                    }
                    if steps.count > 8 {
                        Text("+\(steps.count - 8)").font(.dante(size: 10)).foregroundStyle(theme.text3.color)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: width, alignment: .leading)
        .frame(height: height, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? theme.accentTint.color : theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(selected ? theme.accent.color : (emphasised ? theme.accentLine.color : theme.line2.color),
                          style: StrokeStyle(lineWidth: selected ? 1.6 : 1, dash: dashed ? [4, 3] : [])))
        .shadow(color: theme.accent.color.opacity(selected ? 0.25 : 0), radius: 10)
    }
}

/// Where a pipeline starts: its name and system, its branches and environment.
struct SourceFace: View {
    @Environment(\.theme) private var theme
    var symbol = "chevron.left.forwardslash.chevron.right"
    let title: String
    let system: String
    let branches: [String]
    let environment: String
    var selected = false
    var width: CGFloat = 190
    var height: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: symbol.isEmpty ? "chevron.left.forwardslash.chevron.right" : symbol)
                    .font(.dante(size: 10.5, weight: .bold))
                    .foregroundStyle(theme.onAccent.color)
                    .frame(width: 22, height: 22)
                    .background(theme.accent.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.dante(size: 12.5, weight: .semibold)).foregroundStyle(theme.text.color).lineLimit(1)
                    if !system.isEmpty { Text(system).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color).lineLimit(1) }
                }
            }
            if !branches.isEmpty || !environment.isEmpty {
                HStack(spacing: 4) {
                    ForEach(branches.prefix(3), id: \.self) { branch in
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.dante(size: 10, design: .monospaced))
                            .foregroundStyle(theme.text2.color)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(theme.raised.color, in: Capsule())
                            .lineLimit(1)
                    }
                    if !environment.isEmpty {
                        Text(environment).font(.dante(size: 10, weight: .medium)).foregroundStyle(theme.accent.color)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(theme.accentTint.color, in: Capsule())
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: width, alignment: .leading)
        .frame(height: height, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? theme.accentTint.color : theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? theme.accent.color : theme.accentLine.color, lineWidth: selected ? 1.6 : 1))
    }
}

/// Where a Map view's boxes were drawn last, by the view's own ids, for Copy and edit.
/// Written as the view lays out; reading it doesn't redraw anything.
@MainActor
final class MapLayoutRecorder {
    var frames: [String: CGRect] = [:]
}

/// Records anchors' frames into a recorder from inside a `backgroundPreferenceValue`.
struct RecordFrames: View {
    let frames: [String: CGRect]
    let recorder: MapLayoutRecorder?

    var body: some View {
        Color.clear
            .onAppear { recorder?.frames = frames }
            .onChange(of: frames) { _, new in recorder?.frames = new }
    }
}
