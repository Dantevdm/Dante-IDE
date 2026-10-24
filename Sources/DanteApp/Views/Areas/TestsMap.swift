import AppKit
import DanteKit
import SwiftUI

// MARK: Run strip

/// Every run on this Mac as a bar, oldest on the left: red for the share that failed, green
/// for the rest, a glyph underneath for who ran it. A run going now pulses at the end.
/// Choosing a bar shows the map and failures as that run left them.
struct TestRunStrip: View {
    @Environment(\.theme) private var theme
    let runs: [SavedTestRun]
    let live: TestRun?
    @Binding var selected: String?
    @State private var hovered: String?

    var body: some View {
        let shown = Array(runs.suffix(32))
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(shown) { run in
                    Button { selected = selected == run.id || run.id == shown.last?.id ? nil : run.id } label: {
                        bar(run, isSelected: isSelected(run, in: shown))
                    }
                    .buttonStyle(.plain)
                    .help(describe(run))
                    .onHover { hovered = $0 ? run.id : (hovered == run.id ? nil : hovered) }
                }
                if let live, live.isRunning { liveBar(live) }
                Spacer(minLength: 0)
            }
            .frame(height: 78, alignment: .bottom)
            HStack(spacing: 6) {
                if let run = (hovered ?? selected).flatMap({ id in runs.first { $0.id == id } }) ?? (live?.isRunning == true ? nil : runs.last) {
                    Text(describe(run)).font(.dante(size: 12)).foregroundStyle(theme.text2.color).lineLimit(1)
                } else if let live, live.isRunning {
                    Text("You · running \(live.command.label) now").font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                }
                Spacer()
                if selected != nil {
                    LinkButton("Back to the latest") { selected = nil }
                }
            }
        }
    }

    private func isSelected(_ run: SavedTestRun, in shown: [SavedTestRun]) -> Bool {
        if let selected { return selected == run.id }
        return live?.isRunning != true && run.id == shown.last?.id
    }

    private func bar(_ run: SavedTestRun, isSelected: Bool) -> some View {
        let total = max(run.results.count, 1)
        let failedShare = run.brokeOutsideTests ? 1 : Double(run.failed) / Double(total)
        let skippedShare = Double(run.skipped) / Double(total)
        // Narrowed runs are shorter, so a full run stands out.
        let height: CGFloat = run.narrowed ? 34 : 58
        return VStack(spacing: 4) {
            VStack(spacing: 0) {
                Rectangle().fill(theme.red.color).frame(height: height * failedShare)
                Rectangle().fill(theme.track.color).frame(height: height * skippedShare)
                Rectangle().fill(run.results.isEmpty && !run.brokeOutsideTests ? theme.track.color : theme.green.color)
            }
            .frame(width: 16, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(isSelected ? theme.accent.color : .clear, lineWidth: 2).padding(-3))
            .opacity(hovered == run.id || isSelected ? 1 : 0.85)
            Image(systemName: Self.symbol(run.by.kind))
                .font(.dante(size: 8.5, weight: .semibold))
                .foregroundStyle(run.by.kind == .you ? theme.text3.color : theme.accent.color)
                .frame(height: 10)
        }
    }

    private func liveBar(_ live: TestRun) -> some View {
        TimelineView(.animation) { context in
            let phase = (sin(context.date.timeIntervalSinceReferenceDate * 3) + 1) / 2
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(live.failed > 0 ? theme.red.color : theme.accent.color)
                    .opacity(0.35 + 0.5 * phase)
                    .frame(width: 16, height: 58)
                Image(systemName: Self.symbol(.you)).font(.dante(size: 8.5, weight: .semibold)).foregroundStyle(theme.text3.color).frame(height: 10)
            }
        }
        .help("Running \(live.command.label)")
    }

    static func symbol(_ kind: TestRunner.Kind) -> String {
        switch kind {
        case .you: "person.fill"
        case .agent: "sparkles"
        case .job: "hammer.fill"
        case .ci: "cloud.fill"
        }
    }

    func describe(_ run: SavedTestRun) -> String {
        let when = run.date.formatted(Calendar.current.isDateInToday(run.date) ? .dateTime.hour().minute() : .dateTime.day().month().hour().minute())
        let outcome = run.brokeOutsideTests ? "didn’t get to the tests"
            : run.results.isEmpty ? "no tests found"
            : run.failed > 0 ? "\(run.failed) failed, \(run.passed) passed" : "all \(run.passed) passed"
        return "\(run.by.label) · \(when) · \(run.command)\(run.narrowed ? " (some tests)" : "") · \(outcome)"
    }
}

// MARK: Map

/// The tests written in the code, one square each, in a box per folder. Click a square to open
/// the test; ⌘-click to pick several and run them.
struct TestMapView: View {
    @Environment(\.theme) private var theme
    let map: TestMap
    let open: (WrittenTest) -> Void
    @Binding var picked: Set<String>
    let canPick: Bool
    @State private var filter: TestMap.State?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            legend
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 520), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(groups) { group in groupBox(group) }
            }
        }
    }

    /// Bigger squares when there are few tests, small ones for thousands.
    private var tileSize: CGFloat {
        let count = map.tiles.count
        return count < 120 ? 18 : count < 600 ? 14 : 11
    }

    private var groups: [TestMap.Group] {
        guard let filter else { return map.groups }
        return map.groups.compactMap { group in
            var kept = group
            kept.tiles = group.tiles.filter { $0.state == filter }
            return kept.tiles.isEmpty ? nil : kept
        }
    }

    private var legend: some View {
        HStack(spacing: 6) {
            ForEach(TestMap.State.allCases, id: \.self) { state in
                let count = map.count(state)
                if count > 0 {
                    Button { filter = filter == state ? nil : state } label: {
                        HStack(spacing: 6) {
                            TestTile.swatch(state, theme: theme).frame(width: 10, height: 10)
                            Text("\(count) \(Self.name(state))").font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(filter == state ? theme.accentTint.color : theme.raised.color))
                    }
                    .buttonStyle(.plain)
                    .help(filter == state ? "Show every test" : "Show only these")
                }
            }
            if map.staleCount > 0 {
                HStack(spacing: 6) {
                    TestTile.swatch(.passed, theme: theme).opacity(0.4).overlay(TestTile.edge(.passed, theme: theme)).frame(width: 10, height: 10)
                    Text("\(map.staleCount) changed since they ran").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                }
                .padding(.horizontal, 8)
                .help("Faded squares: the test’s file changed after the run that set its colour, so it may be out of date")
            }
            Spacer()
            if canPick {
                Text("⌘-click to pick tests to run").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            }
        }
    }

    private func groupBox(_ group: TestMap.Group) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(group.name).font(.dante(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(theme.text.color)
                    .lineLimit(1).truncationMode(.head)
                Text(group.category).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color)
                Spacer(minLength: 4)
                Text(summary(group)).font(.dante(size: 11)).foregroundStyle(group.count(.failed) > 0 ? theme.red.color : theme.text3.color)
            }
            FlowLayout(spacing: 3) {
                ForEach(group.tiles) { tile in
                    TestTile(tile: tile, picked: picked.contains(tile.id), size: tileSize)
                        .onTapGesture {
                            if canPick, NSEvent.modifierFlags.contains(.command) {
                                if picked.contains(tile.id) { picked.remove(tile.id) } else { picked.insert(tile.id) }
                            } else {
                                open(tile.test)
                            }
                        }
                        .help(TestTile.describe(tile))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.raised.color.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(group.count(.failed) > 0 ? theme.red.color.opacity(0.45) : theme.line.color))
    }

    private func summary(_ group: TestMap.Group) -> String {
        let failed = group.count(.failed)
        if failed > 0 { return "\(failed) of \(group.tiles.count) failing" }
        let notRun = group.count(.notRun)
        if notRun == group.tiles.count { return "\(group.tiles.count) not run" }
        return "\(group.tiles.count) test\(group.tiles.count == 1 ? "" : "s")"
    }

    static func name(_ state: TestMap.State) -> String {
        switch state {
        case .failed: "failing"
        case .flaky: "flaky"
        case .passed: "passing"
        case .skipped: "skipped"
        case .notRun: "not run"
        }
    }
}

/// One test's square.
struct TestTile: View {
    @Environment(\.theme) private var theme
    let tile: TestMap.Tile
    let picked: Bool
    var size: CGFloat = 13

    var body: some View {
        Group {
            if tile.waiting {
                TimelineView(.animation) { context in
                    let phase = (sin(context.date.timeIntervalSinceReferenceDate * 4 + Double(abs(tile.id.hashValue % 100)) / 10) + 1) / 2
                    square.opacity(0.3 + 0.5 * phase)
                }
            } else if tile.stale {
                // Out of date: the colour stays readable, faded inside a full-colour edge.
                square.opacity(0.4).overlay(Self.edge(tile.state, theme: theme))
            } else {
                square
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if tile.flaky && tile.state == .failed {
                Circle().fill(theme.amber.color).frame(width: size / 3, height: size / 3).offset(x: 1, y: -1)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(picked ? theme.accent.color : .clear, lineWidth: 2).padding(-2))
        .contentShape(Rectangle())
    }

    private var square: some View {
        Self.swatch(tile.state, theme: theme)
    }

    @ViewBuilder
    static func swatch(_ state: TestMap.State, theme: Theme) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        switch state {
        case .failed: shape.fill(theme.red.color)
        case .flaky: shape.fill(theme.amber.color)
        case .passed: shape.fill(theme.green.color)
        case .skipped: shape.fill(theme.track.color)
        case .notRun: shape.strokeBorder(theme.text3.color.opacity(0.6), lineWidth: 1)
        }
    }

    @ViewBuilder
    static func edge(_ state: TestMap.State, theme: Theme) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        switch state {
        case .failed: shape.strokeBorder(theme.red.color, lineWidth: 1.5)
        case .flaky: shape.strokeBorder(theme.amber.color, lineWidth: 1.5)
        case .passed: shape.strokeBorder(theme.green.color, lineWidth: 1.5)
        case .skipped, .notRun: EmptyView()
        }
    }

    static func describe(_ tile: TestMap.Tile) -> String {
        var lines = ["\(tile.test.name) — \((tile.test.file as NSString).lastPathComponent):\(tile.test.line)"]
        switch tile.state {
        case .notRun: lines.append("Not run on this Mac yet")
        case .flaky: lines.append("Flaky: passed and failed in recent runs")
        default:
            if let ranAt = tile.ranAt {
                let who = tile.ranBy?.label ?? "You"
                lines.append("\(TestMapView.name(tile.state).capitalized) · \(who), \(ranAt.formatted(.relative(presentation: .named)))")
            }
        }
        if tile.flaky, tile.state == .failed { lines.append("Flaky: it has passed in recent runs too") }
        if tile.stale { lines.append("Its file changed since then") }
        if tile.waiting { lines.append("Waiting for this run") }
        if let message = tile.result?.issues.first?.message { lines.append(String(message.prefix(200))) }
        return lines.joined(separator: "\n")
    }
}
