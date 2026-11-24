import DanteKit
import SwiftUI

/// An opened route on Bliksem: how its requests went in the last load run, a picture of what
/// its handler does (functions it calls, three deep, with what each touches) coloured by
/// where the profiler found the time, and the project's methods it spent it in.
struct BliksemRouteDetail: View {
    @Environment(\.theme) private var theme
    let session: Session
    let root: URL
    let route: BliksemRoute

    private var model: BliksemModel { session.bliksem }

    var body: some View {
        let flow = model.flows[route.id] ?? nil
        let heat = (flow.flatMap { flow in model.profile.map { flow.heat($0) } }) ?? [:]
        VStack(alignment: .leading, spacing: 14) {
            timings
            if model.readingFlows.contains(route.id) || model.flows[route.id] == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Reading what it does…").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                }
            } else if let flow {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("What it does").font(.dante(size: 12.5, weight: .semibold)).foregroundStyle(theme.text.color)
                        Spacer()
                        if !heat.isEmpty { Text("Share of CPU samples").font(.dante(size: 11)).foregroundStyle(theme.text3.color) }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        RouteFlowPicture(flow: flow, heat: heat) { step in session.open(file: root.appending(path: step.file), line: step.line) }
                    }
                }
                hotMethods(flow)
            } else {
                Text("Dante can’t find this route’s handler in the code\(route.isTask ? " (no route in the Map matches \(route.method) \(route.path))" : ""), so there’s no picture of it.")
                    .font(.dante(size: 12)).foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button { session.askClaude(brief(flow: flow, heat: heat)) } label: {
                    Label("Ask \(session.agentName) to speed it up", systemImage: "wand.and.stars")
                }
                .buttonStyle(DanteButtonStyle())
                .help("Sends this route’s figures, what it does and where the time went to the agent in charge")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.accent.color.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.line.color))
        .padding(.bottom, 8)
        .task { model.loadFlow(route, root: root) }
    }

    // MARK: Timings

    @ViewBuilder
    private var timings: some View {
        let times = model.times(of: route)
        let stats = model.loadTick?.routes.first { $0.route == route.id }
        if let stats, !times.isEmpty {
            HStack(alignment: .bottom, spacing: 20) {
                figure("Requests", stats.requests.formatted())
                figure("Answer", stats.usual)
                figure("p50", BliksemStats.time(stats.p50))
                figure("p95", BliksemStats.time(stats.p95))
                figure("p99", BliksemStats.time(stats.p99))
                if stats.failures > 0 { figure("Failed", stats.failures.formatted(), bad: true) }
                LatencySpread(times: times)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .help("How long its requests took: each bar is a band of times, taller where more requests fell")
            }
        } else {
            Text(model.running == .load ? "Its timings come when the run ends." : "Run a load test with this route chosen to see its timings and, for a JVM, where it spends its time.")
                .font(.dante(size: 12)).foregroundStyle(theme.text3.color)
        }
    }

    private func figure(_ title: String, _ value: String, bad: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color)
            Text(value).font(.dante(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(bad ? theme.red.color : theme.text.color)
        }
    }

    // MARK: Profile

    @ViewBuilder
    private func hotMethods(_ flow: RouteFlow) -> some View {
        if let profile = model.profile {
            let (busy, methods) = profile.methods(matching: flow.isRoute)
            if busy > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Where its time went").font(.dante(size: 12.5, weight: .semibold)).foregroundStyle(theme.text.color)
                    Text("\(busy) samples caught this route’s code running. Own is time in the method or the libraries it calls; in it counts the methods below it too.")
                        .font(.dante(size: 11)).foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true)
                    ProfileList(methods: Array(methods.prefix(8)), busy: busy) { frame in open(frame) }
                }
            }
        }
    }

    private func open(_ frame: StackFrame) {
        guard let name = frame.file else { return }
        let match = model.flows.values.compactMap { $0 }.flatMap(\.steps).first { ($0.file as NSString).lastPathComponent == name }?.file
            ?? session.workspace?.files.first { ($0 as NSString).lastPathComponent == name }
        if let match { session.open(file: root.appending(path: match), line: frame.line ?? 1) }
    }

    private func brief(flow: RouteFlow?, heat: [Int: Double]) -> String {
        var lines = ["Make this route faster: \(route.name.map { "\($0) (\(route.method) \(route.path))" } ?? "\(route.method) \(route.path)")."]
        if let stats = model.loadTick?.routes.first(where: { $0.route == route.id }) {
            lines.append("Under Bliksem's load test: \(stats.requests) requests, p50 \(BliksemStats.time(stats.p50)), p95 \(BliksemStats.time(stats.p95)), p99 \(BliksemStats.time(stats.p99)), \(stats.failures) failed.")
        }
        if let flow {
            lines.append("What it does (from the code):")
            for step in flow.steps {
                let share = heat[step.id].map { " — \(Int(($0 * 100).rounded()))% of CPU samples" } ?? ""
                lines.append(String(repeating: "  ", count: step.depth) + "- \(step.name) (\(step.file):\(step.line))" + (step.effects.isEmpty ? "" : ": " + step.effects.joined(separator: ", ")) + share)
            }
        }
        if let profile = model.profile, let flow {
            let (busy, methods) = profile.methods(matching: flow.isRoute)
            if busy > 0 {
                lines.append("Hottest methods in \(busy) stack samples:")
                for method in methods.prefix(8) {
                    lines.append("- \(method.label): \(Int(Double(method.own) / Double(busy) * 100))% own, \(Int(Double(method.total) / Double(busy) * 100))% in it")
                }
            }
        }
        lines.append("Find the slow part, explain why, and fix it without changing what the route answers. Say how to measure it again (Bliksem's Hammer it).")
        return lines.joined(separator: "\n")
    }
}

/// The project's hottest methods as bars: own time solid, time in it lighter behind.
struct ProfileList: View {
    @Environment(\.theme) private var theme
    let methods: [Profile.Method]
    let busy: Int
    let open: (StackFrame) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(methods) { method in
                Button { open(method.frame) } label: {
                    HStack(spacing: 10) {
                        Text(method.label).font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text.color).lineLimit(1)
                            .frame(width: 260, alignment: .leading)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(theme.track.color)
                                RoundedRectangle(cornerRadius: 3).fill(theme.amber.color.opacity(0.35))
                                    .frame(width: geometry.size.width * share(method.total))
                                RoundedRectangle(cornerRadius: 3).fill(theme.amber.color)
                                    .frame(width: geometry.size.width * share(method.own))
                            }
                        }
                        .frame(height: 8)
                        Text("\(percent(method.own)) own · \(percent(method.total)) in it")
                            .font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color)
                            .frame(width: 140, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(method.frame.file.map { "Open \($0)\(method.frame.line.map { ":\($0)" } ?? "")" } ?? method.frame.type)
            }
        }
    }

    private func share(_ count: Int) -> CGFloat { busy == 0 ? 0 : CGFloat(count) / CGFloat(busy) }
    private func percent(_ count: Int) -> String { "\(Int((Double(share(count)) * 100).rounded()))%" }
}

/// A histogram of request times on a log scale, the p95 marked.
struct LatencySpread: View {
    @Environment(\.theme) private var theme
    let times: [Double]

    var body: some View {
        Canvas { context, size in
            guard let first = times.first, let last = times.last, last > 0 else { return }
            let low = log10(max(first, 0.0005)), high = log10(max(last, first * 1.01, 0.001))
            let buckets = 28
            var counts = Array(repeating: 0, count: buckets)
            for time in times {
                let position = (log10(max(time, 0.0005)) - low) / max(high - low, 0.0001)
                counts[min(buckets - 1, max(0, Int(position * Double(buckets))))] += 1
            }
            let most = Double(counts.max() ?? 1)
            let width = size.width / CGFloat(buckets)
            let p95 = BliksemStats.percentile(times, 95)
            let p95Bucket = Int((log10(max(p95, 0.0005)) - low) / max(high - low, 0.0001) * Double(buckets))
            for (index, count) in counts.enumerated() where count > 0 {
                let height = max(2, (size.height - 12) * CGFloat(Double(count) / most))
                let rect = CGRect(x: CGFloat(index) * width + 1, y: size.height - 12 - height, width: width - 2, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(index >= p95Bucket ? theme.amber.color : theme.accent.color.opacity(0.7)))
            }
            context.draw(Text(BliksemStats.time(first)).font(.dante(size: 9.5)).foregroundStyle(theme.text3.color), at: CGPoint(x: 0, y: size.height), anchor: .bottomLeading)
            context.draw(Text(BliksemStats.time(last)).font(.dante(size: 9.5)).foregroundStyle(theme.text3.color), at: CGPoint(x: size.width, y: size.height), anchor: .bottomTrailing)
        }
    }
}

/// The handler and the functions it calls as boxes in columns by depth, linked like the
/// Infra view (dashes flowing from caller to callee), each box tinted by its share of CPU.
struct RouteFlowPicture: View {
    @Environment(\.theme) private var theme
    let flow: RouteFlow
    let heat: [Int: Double]
    let open: (RouteFlow.Step) -> Void

    private let boxWidth: CGFloat = 210
    private let boxHeight: CGFloat = 64
    private let columnGap: CGFloat = 44
    private let rowGap: CGFloat = 10

    private var positions: [Int: CGPoint] {
        var rows: [Int: Int] = [:]
        var result: [Int: CGPoint] = [:]
        for step in flow.steps {
            let row = rows[step.depth, default: 0]
            rows[step.depth] = row + 1
            result[step.id] = CGPoint(x: CGFloat(step.depth) * (boxWidth + columnGap) + boxWidth / 2,
                                      y: CGFloat(row) * (boxHeight + rowGap) + boxHeight / 2)
        }
        return result
    }

    var body: some View {
        let positions = positions
        let width = (positions.values.map(\.x).max() ?? 0) + boxWidth / 2
        let height = (positions.values.map(\.y).max() ?? 0) + boxHeight / 2
        ZStack(alignment: .topLeading) {
            TimelineView(.animation(minimumInterval: 1 / 20)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                Canvas { context, _ in
                    for step in flow.steps {
                        guard let parent = step.parent, let from = positions[parent], let to = positions[step.id] else { continue }
                        let start = CGPoint(x: from.x + boxWidth / 2, y: from.y)
                        let end = CGPoint(x: to.x - boxWidth / 2, y: to.y)
                        var path = Path()
                        path.move(to: start)
                        path.addCurve(to: end, control1: CGPoint(x: start.x + columnGap * 0.6, y: start.y), control2: CGPoint(x: end.x - columnGap * 0.6, y: end.y))
                        let hot = heat[step.id] ?? 0
                        let color = hot > 0.2 ? theme.amber.color : theme.accent.color
                        context.stroke(path, with: .color(color.opacity(0.25)), lineWidth: 1.5)
                        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 7], dashPhase: -phase * 18))
                    }
                }
            }
            .frame(width: width, height: height)
            ForEach(flow.steps) { step in
                box(step)
                    .frame(width: boxWidth, height: boxHeight)
                    .position(positions[step.id] ?? .zero)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private func box(_ step: RouteFlow.Step) -> some View {
        let hot = heat[step.id]
        return Button { open(step) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(step.name).font(.dante(size: 12, weight: .semibold, design: step.depth == 0 ? .default : .monospaced))
                        .foregroundStyle(theme.text.color).lineLimit(1)
                    Spacer(minLength: 0)
                    if let hot { Text("\(Int((hot * 100).rounded()))%").font(.dante(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(hot > 0.2 ? theme.amber.color : theme.text3.color) }
                }
                Text("\((step.file as NSString).lastPathComponent):\(step.line)").font(.dante(size: 10, design: .monospaced)).foregroundStyle(theme.text3.color).lineLimit(1)
                Text(step.effects.isEmpty ? " " : step.effects.joined(separator: " · ")).font(.dante(size: 10.5)).foregroundStyle(theme.green.color).lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.card.color))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.amber.color.opacity(min(0.35, (hot ?? 0) * 0.6))))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder((hot ?? 0) > 0.2 ? theme.amber.color : theme.line.color, lineWidth: (hot ?? 0) > 0.2 ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(step.file):\(step.line)" + (step.effects.isEmpty ? "" : " — " + step.effects.joined(separator: ", ")))
    }
}

/// CPU and memory of the target over the run, side by side.
struct ResourceCharts: View {
    @Environment(\.theme) private var theme
    let samples: [ResourceSample]
    let duration: Double
    let source: WatchSource

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CPU and memory of \(source.label)").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            HStack(spacing: 16) {
                chart("CPU", values: samples.map { ($0.t, $0.cpu) }, color: theme.accent.color,
                      label: { "\(Int($0.rounded()))%" }, note: "peak \(Int((samples.map(\.cpu).max() ?? 0).rounded()))% of a core")
                chart("Memory", values: samples.map { ($0.t, $0.memory) }, color: theme.green.color,
                      label: ResourceReading.memory, note: memoryNote)
            }
        }
    }

    private var memoryNote: String {
        guard let first = samples.first?.memory, let last = samples.last?.memory else { return "" }
        let peak = samples.map(\.memory).max() ?? last
        return "\(ResourceReading.memory(first)) → \(ResourceReading.memory(last)), peak \(ResourceReading.memory(peak))"
    }

    private func chart(_ title: String, values: [(Double, Double)], color: Color, label: @escaping (Double) -> String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.dante(size: 12, weight: .semibold)).foregroundStyle(theme.text.color)
                Spacer()
                Text(note).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color)
            }
            Canvas { context, size in
                guard values.count > 1 else {
                    context.draw(Text("Waiting for readings…").font(.dante(size: 11)).foregroundStyle(theme.text3.color), at: CGPoint(x: size.width / 2, y: size.height / 2))
                    return
                }
                let top = max(values.map(\.1).max() ?? 1, 1) * 1.15
                let span = max(duration, values.last?.0 ?? 1)
                func point(_ value: (Double, Double)) -> CGPoint {
                    CGPoint(x: size.width * value.0 / span, y: size.height - size.height * value.1 / top)
                }
                var line = Path()
                line.move(to: point(values[0]))
                for value in values.dropFirst() { line.addLine(to: point(value)) }
                var area = line
                area.addLine(to: CGPoint(x: point(values.last!).x, y: size.height))
                area.addLine(to: CGPoint(x: point(values[0]).x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(color.opacity(0.14)))
                context.stroke(line, with: .color(color), lineWidth: 1.6)
                context.draw(Text(label(top / 1.15)).font(.dante(size: 9.5)).foregroundStyle(theme.text3.color), at: CGPoint(x: 2, y: 2), anchor: .topLeading)
            }
            .frame(height: 80)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.track.color.opacity(0.4)))
        }
        .frame(maxWidth: .infinity)
    }
}
