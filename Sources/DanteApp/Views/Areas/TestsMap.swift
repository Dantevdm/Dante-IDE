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

// MARK: Kinds

/// One kind of test (Front-end, Back-end, Integration…): what it is, how it stands, a Run
/// button, and its folders and tests folded away underneath.
struct TestKindCard: View {
    @Environment(\.theme) private var theme
    let kind: TestMap.Kind
    /// Where these tests run, such as "services/react".
    let place: String?
    let isRunning: Bool
    /// Runs some of the tests; nil when the runner can't be narrowed or there's no runner.
    let run: (([WrittenTest]) -> Void)?
    let open: (WrittenTest) -> Void
    @State private var expanded = false
    @State private var openAreas: Set<String> = []

    var body: some View {
        let tiles = kind.tiles
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(kind.name).font(.dante(size: 14.5, weight: .semibold)).foregroundStyle(theme.text.color)
                Text("\(tiles.count) test\(tiles.count == 1 ? "" : "s")\(place.map { " · \($0)" } ?? "")")
                    .font(.dante(size: 12)).foregroundStyle(theme.text3.color).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(Self.status(of: kind)).font(.dante(size: 12, weight: kind.count(.failed) > 0 ? .medium : .regular))
                    .foregroundStyle(kind.count(.failed) > 0 ? theme.red.color : theme.text2.color)
                Button { run?(tiles.map(\.test)) } label: { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(DanteButtonStyle())
                    .disabled(run == nil || isRunning)
                    .help(run == nil ? "Dante can’t run only these with this project’s runner" : "Run the \(kind.name.lowercased()) tests")
            }
            Text(TestInventory.summary(of: kind.name)).font(.dante(size: 12)).foregroundStyle(theme.text3.color)
            StateBar(kind: kind)
            LinkButton(expanded ? "Hide the tests" : "Show the tests by folder") { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    let names = Self.shortNames(kind.areas.map(\.name))
                    ForEach(kind.areas) { area in
                        areaRow(area, name: names[area.name] ?? area.name)
                        if openAreas.contains(area.id) {
                            ForEach(area.tiles) { tile in testRow(tile) }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(kind.count(.failed) > 0 ? theme.red.color.opacity(0.45) : theme.line.color))
    }

    private func areaRow(_ area: TestMap.Group, name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: openAreas.contains(area.id) ? "chevron.down" : "chevron.right")
                .font(.dante(size: 9, weight: .semibold)).foregroundStyle(theme.text3.color).frame(width: 10)
            Image(systemName: "folder").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
            Text(name).font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text.color).lineLimit(1).truncationMode(.head)
                .help(area.name)
            Spacer(minLength: 8)
            Text(Self.status(of: area)).font(.dante(size: 11.5)).foregroundStyle(area.count(.failed) > 0 ? theme.red.color : theme.text3.color)
            if let run {
                IconButton(symbol: "play.fill", label: "Run the tests in \(name)", size: 9) { run(area.tiles.map(\.test)) }
                    .disabled(isRunning)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if openAreas.contains(area.id) { openAreas.remove(area.id) } else { openAreas.insert(area.id) }
        }
    }

    private func testRow(_ tile: TestMap.Tile) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Self.color(tile.state, theme: theme)).frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(tile.state == .notRun ? theme.text3.color.opacity(0.6) : .clear))
                .padding(.leading, 30)
            Text(tile.test.name).font(.dante(size: 12)).foregroundStyle(theme.text.color).lineLimit(1)
            Text("\((tile.test.file as NSString).lastPathComponent):\(tile.test.line)")
                .font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color).lineLimit(1)
            if tile.stale { Chip(text: "changed since").help("Its file changed after the run that set this result") }
            Spacer(minLength: 8)
            Text(TestMapView.name(tile.state)).font(.dante(size: 11)).foregroundStyle(theme.text3.color)
            if let run {
                IconButton(symbol: "play.fill", label: "Run \(tile.test.name)", size: 9) { run([tile.test]) }
                    .disabled(isRunning)
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { open(tile.test) }
        .help(TestMapView.describe(tile))
    }

    /// "3 failing · 40 passing · 12 not run".
    static func status(of kind: TestMap.Kind) -> String {
        status(failed: kind.count(.failed), flaky: kind.count(.flaky), passed: kind.count(.passed), skipped: kind.count(.skipped), notRun: kind.count(.notRun))
    }

    static func status(of group: TestMap.Group) -> String {
        status(failed: group.count(.failed), flaky: group.count(.flaky), passed: group.count(.passed), skipped: group.count(.skipped), notRun: group.count(.notRun))
    }

    static func status(failed: Int, flaky: Int, passed: Int, skipped: Int, notRun: Int) -> String {
        let total = failed + flaky + passed + skipped + notRun
        if notRun == total { return "not run yet" }
        var parts: [String] = []
        if failed > 0 { parts.append("\(failed) failing") }
        if flaky > 0 { parts.append("\(flaky) flaky") }
        if passed > 0 { parts.append(failed == 0 && flaky == 0 && notRun == 0 && skipped == 0 ? "all \(passed) passing" : "\(passed) passing") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if notRun > 0 { parts.append("\(notRun) not run") }
        return parts.joined(separator: " · ")
    }

    /// Folder paths without the part they all share: `controllers`, `services/ingest`.
    static func shortNames(_ paths: [String]) -> [String: String] {
        let split = paths.map { $0.split(separator: "/").map(String.init) }
        guard split.count > 1, var shared = split.first else {
            return Dictionary(uniqueKeysWithValues: paths.map { ($0, $0.split(separator: "/").suffix(2).joined(separator: "/")) })
        }
        for parts in split.dropFirst() {
            var count = 0
            while count < min(shared.count, parts.count), shared[count] == parts[count] { count += 1 }
            shared = Array(shared.prefix(count))
        }
        var names: [String: String] = [:]
        for (path, parts) in zip(paths, split) {
            let rest = parts.dropFirst(shared.count)
            names[path] = rest.isEmpty ? (parts.last ?? path) : rest.joined(separator: "/")
        }
        return names
    }

    static func color(_ state: TestMap.State, theme: Theme) -> Color {
        switch state {
        case .failed: theme.red.color
        case .flaky: theme.amber.color
        case .passed: theme.green.color
        case .skipped: theme.track.color
        case .notRun: .clear
        }
    }
}

/// A kind's tests as one bar: failing, flaky, passing, skipped, then not run.
private struct StateBar: View {
    @Environment(\.theme) private var theme
    let kind: TestMap.Kind

    var body: some View {
        let total = max(kind.tiles.count, 1)
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach([TestMap.State.failed, .flaky, .passed, .skipped], id: \.self) { state in
                    let count = kind.count(state)
                    if count > 0 {
                        Rectangle().fill(TestKindCard.color(state, theme: theme))
                            .frame(width: geometry.size.width * CGFloat(count) / CGFloat(total))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 6)
        .background(theme.track.color.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

/// Names and descriptions for a test's state.
enum TestMapView {
    static func name(_ state: TestMap.State) -> String {
        switch state {
        case .failed: "failing"
        case .flaky: "flaky"
        case .passed: "passing"
        case .skipped: "skipped"
        case .notRun: "not run"
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
                lines.append("\(name(tile.state).capitalized) · \(who), \(ranAt.formatted(.relative(presentation: .named)))")
            }
        }
        if tile.flaky, tile.state == .failed { lines.append("Flaky: it has passed in recent runs too") }
        if tile.stale { lines.append("Its file changed since then") }
        if tile.waiting { lines.append("Waiting for this run") }
        if let message = tile.result?.issues.first?.message { lines.append(String(message.prefix(200))) }
        return lines.joined(separator: "\n")
    }
}
