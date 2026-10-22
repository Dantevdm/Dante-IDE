import DanteKit
import SwiftUI

// MARK: The map

/// Home's top: the project drawn as its system (`HomePulse.sketch` of the Map's
/// `SystemMap`), with traffic running along the links like the Infra view. A part opens the
/// Map with it selected.
struct HomeMap: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: Session
    let sketch: HomePulse.Sketch

    var body: some View {
        HStack(alignment: .top, spacing: 44) {
            ForEach(sketch.lanes, id: \.lane) { entry in
                lane(entry.lane, parts: entry.parts, more: entry.more)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 22).padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .backgroundPreferenceValue(HomePartKey.self) { anchors in
            GeometryReader { proxy in
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                    Canvas { context, _ in
                        let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                        draw(in: &context, frames: anchors.mapValues { proxy[$0] }, time: time)
                    }
                }
            }
        }
        .background(DotGrid(color: theme.line2.color, spacing: 16))
        .background(theme.panel.color)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.line.color))
    }

    private func lane(_ lane: SystemMap.Lane, parts: [SystemMap.Part], more: Int) -> some View {
        let hue = SystemDiagram.hue(lane, theme: theme)
        return VStack(alignment: .leading, spacing: 8) {
            Text(lane.title.uppercased()).font(.dante(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(hue)
            // Titles line up along the top; each lane's boxes sit centred under them.
            VStack(alignment: .leading, spacing: 8) {
            ForEach(parts) { part in
                Button {
                    session.mapFocus = part.id
                    session.area = .map
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: PartBox.symbol(part.kind)).font(.dante(size: 11)).foregroundStyle(hue).frame(width: 15)
                        Text(part.name).font(.dante(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color).lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: 170, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.card.color))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(hue.opacity(0.4)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(part.detail.isEmpty ? "Open \(part.name) on the Map" : part.detail)
                .anchorPreference(key: HomePartKey.self, value: .bounds) { [part.id: $0] }
            }
            if more > 0 {
                Text("+\(more) more").font(.dante(size: 11)).foregroundStyle(theme.text3.color).padding(.leading, 4)
            }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func lane(of id: String) -> SystemMap.Lane? {
        sketch.lanes.first { $0.parts.contains { $0.id == id } }?.lane
    }

    private func draw(in context: inout GraphicsContext, frames: [String: CGRect], time: Double) {
        for (index, link) in sketch.links.enumerated() {
            guard let a = frames[link.from], let b = frames[link.to], let lane = lane(of: link.to) else { continue }
            let hue = SystemDiagram.hue(lane, theme: theme)
            let path = curve(a, b)
            context.stroke(path, with: .color(hue.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 6], dashPhase: CGFloat(-time * 20)))
            let progress = CGFloat(((time + Double(index) * 0.37) / 2.6).truncatingRemainder(dividingBy: 1))
            guard progress > 0.02, let point = path.trimmedPath(from: 0, to: progress).currentPoint else { continue }
            let fade = min(1, min(progress, 1 - progress) * 6)
            context.fill(Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)), with: .color(hue.opacity(0.18 * fade)))
            context.fill(Path(ellipseIn: CGRect(x: point.x - 2.6, y: point.y - 2.6, width: 5.2, height: 5.2)), with: .color(hue.opacity(fade)))
        }
    }

    /// Right edge to left edge between lanes; a loop out to the right within one.
    private func curve(_ a: CGRect, _ b: CGRect) -> Path {
        var path = Path()
        if b.minX > a.maxX {
            let start = CGPoint(x: a.maxX, y: a.midY), end = CGPoint(x: b.minX, y: b.midY)
            let bend = (end.x - start.x) / 2
            path.move(to: start)
            path.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y), control2: CGPoint(x: end.x - bend, y: end.y))
        } else if b.maxX < a.minX {
            let start = CGPoint(x: a.minX, y: a.midY), end = CGPoint(x: b.maxX, y: b.midY)
            let bend = (start.x - end.x) / 2
            path.move(to: start)
            path.addCurve(to: end, control1: CGPoint(x: start.x - bend, y: start.y), control2: CGPoint(x: end.x + bend, y: end.y))
        } else {
            let start = CGPoint(x: a.maxX, y: a.midY), end = CGPoint(x: b.maxX, y: b.midY)
            let out = max(a.maxX, b.maxX) + 18
            path.move(to: start)
            path.addCurve(to: end, control1: CGPoint(x: out, y: start.y), control2: CGPoint(x: out, y: end.y))
        }
        return path
    }
}

private struct HomePartKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: Vital signs

/// One of Home's tiles: a title, a picture and a line under it. The whole tile opens its page.
struct VitalTile<Picture: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    let symbol: String
    let caption: String
    let action: () -> Void
    @ViewBuilder let picture: Picture
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.dante(size: 11))
                    Text(title).font(.dante(size: 12.5, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.dante(size: 9.5, weight: .semibold)).opacity(hovering ? 1 : 0)
                }
                .foregroundStyle(theme.text2.color)
                picture.frame(maxWidth: .infinity, minHeight: 84, maxHeight: 84)
                Text(caption).font(.dante(size: 12)).foregroundStyle(theme.text2.color).lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hovering ? theme.accentLine.color : theme.line.color))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.18), value: hovering)
    }
}

/// A ring of shares, largest first, with the biggest named in the middle.
struct ShareRing: View {
    @Environment(\.theme) private var theme
    let shares: [(name: String, share: Double)]

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(theme.line.color, lineWidth: 10)
                ForEach(Array(shares.enumerated()), id: \.offset) { index, entry in
                    let start = shares.prefix(index).reduce(0) { $0 + $1.share }
                    Circle().trim(from: start, to: start + entry.share - 0.008)
                        .stroke(color(index), style: StrokeStyle(lineWidth: 10, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                Text(shares.first.map { "\(Int(($0.share * 100).rounded()))%" } ?? "")
                    .font(.dante(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(theme.text.color)
            }
            .frame(width: 66, height: 66)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(shares.prefix(4).enumerated()), id: \.offset) { index, entry in
                    HStack(spacing: 5) {
                        Circle().fill(color(index)).frame(width: 6, height: 6)
                        Text(entry.name).font(.dante(size: 11)).foregroundStyle(theme.text2.color).lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func color(_ index: Int) -> Color {
        [theme.accent.color, theme.amber.color, theme.green.color, theme.syntax.keyword.color, theme.text3.color][min(index, 4)]
    }
}

/// A score in a ring, the grade in the middle.
struct ScoreRing: View {
    @Environment(\.theme) private var theme
    let value: Double
    let label: String
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(theme.line.color, lineWidth: 8)
            Circle().trim(from: 0, to: max(value, 0.02))
                .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label).font(.dante(size: 22, weight: .bold)).foregroundStyle(theme.text.color)
        }
        .frame(width: 74, height: 74)
        .frame(maxWidth: .infinity)
    }
}

/// Commit days, a column per week, like a contributions graph.
struct CommitGrid: View {
    @Environment(\.theme) private var theme
    let grid: [[Int]]

    var body: some View {
        let busiest = max(grid.flatMap { $0 }.max() ?? 1, 1)
        HStack(spacing: 3) {
            ForEach(Array(grid.enumerated()), id: \.offset) { _, week in
                VStack(spacing: 3) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, count in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(count < 0 ? Color.clear : count == 0 ? theme.line.color : theme.green.color.opacity(0.3 + 0.7 * Double(count) / Double(busiest)))
                            .frame(width: 9, height: 9)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The last test run as a bar of passed, failed and skipped.
struct TestBar: View {
    @Environment(\.theme) private var theme
    let record: TestRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let record, record.total > 0 {
                Text(record.succeeded ? "\(record.passed) passed" : "\(record.failed) failing")
                    .font(.dante(size: 20, weight: .semibold)).foregroundStyle(record.succeeded ? theme.green.color : theme.red.color)
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        ForEach([(record.passed, theme.green.color), (record.failed, theme.red.color), (record.skipped, theme.text3.color)].filter { $0.0 > 0 }, id: \.0) { count, color in
                            RoundedRectangle(cornerRadius: 3).fill(color)
                                .frame(width: max(4, proxy.size.width * CGFloat(count) / CGFloat(record.total)))
                        }
                    }
                }
                .frame(height: 10)
            } else {
                Image(systemName: "testtube.2").font(.dante(size: 30)).foregroundStyle(theme.text3.color).frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }
}
