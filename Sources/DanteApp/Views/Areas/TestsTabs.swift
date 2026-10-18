import Charts
import DanteKit
import SwiftUI

enum TestsTab: String, CaseIterable, Identifiable {
    case run, written, history, untested
    var id: String { rawValue }

    var title: String {
        switch self {
        case .run: "Last run"
        case .written: "Written"
        case .history: "History"
        case .untested: "Untested"
        }
    }
}

/// The name a runner prints, matched to the one written in the file: `adds()` and
/// `adds`, `TestSend/subtest` and `TestSend`.
func testKey(_ name: String) -> String {
    var key = name.components(separatedBy: "/")[0]
    if key.hasSuffix("()") { key = String(key.dropLast(2)) }
    if let paren = key.firstIndex(of: "("), key.hasSuffix(")") { key = String(key[..<paren]) }
    return key.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
}

struct TestsTabBar: View {
    @Environment(\.theme) private var theme
    @Binding var tab: TestsTab
    let counts: [TestsTab: String]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TestsTab.allCases) { item in
                Button { tab = item } label: {
                    HStack(spacing: 6) {
                        Text(item.title).font(.dante(size: 12.5, weight: tab == item ? .medium : .regular))
                        if let count = counts[item] {
                            Text(count).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color)
                        }
                    }
                    .foregroundStyle(tab == item ? theme.text.color : theme.text2.color)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(tab == item ? theme.card.color : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Written

/// Every test in the code, by category and file, with its result from the last run.
struct WrittenTestsView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let inventory: TestInventory?
    let results: [TestResult]
    /// Runs the chosen tests; nil when the runner can't be narrowed to some tests.
    let runTests: (([WrittenTest]) -> Void)?
    let showUntested: () -> Void

    @State private var category: String?
    @State private var query = ""
    @State private var collapsed: Set<String> = []
    /// Tests ticked to run, by id.
    @State private var selected: Set<String> = []

    var body: some View {
        if let inventory {
            if inventory.tests.isEmpty {
                EmptyState(
                    symbol: "testtube.2",
                    title: "No tests written yet"
                ) {
                    HStack(spacing: 8) {
                        Button("See what’s untested", action: showUntested).buttonStyle(DanteButtonStyle())
                        Button("Ask Claude to set up tests") {
                            session.askClaude("This project has no tests yet. Suggest a test setup that fits the stack, add it with one or two tests for the most important code, and set test.command in .dante/project.yaml if Dante can't detect the runner.")
                        }
                        .buttonStyle(DanteButtonStyle(primary: true))
                    }
                }
            } else {
                categoryStrip(inventory)
                if runTests != nil { selectionBar(inventory) }
                list(inventory)
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private var statuses: [String: TestResult.Status] {
        var map: [String: TestResult.Status] = [:]
        for result in results {
            let key = testKey(result.name)
            // A failing subtest marks its test as failing.
            if map[key] != .failed { map[key] = result.status }
        }
        return map
    }

    private func categoryStrip(_ inventory: TestInventory) -> some View {
        HStack(spacing: 10) {
            ForEach([nil] + inventory.categories.map(Optional.some), id: \.self) { name in
                let count = name.map { inventory.count(in: $0) } ?? inventory.tests.count
                Button { category = name } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(count)").font(.dante(size: 18, weight: .medium, design: .monospaced)).foregroundStyle(theme.text.color)
                        Text(name ?? "All tests").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(minWidth: 100, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(category == name ? theme.accentTint.color : theme.card.color))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(category == name ? theme.accentLine.color : theme.line.color))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private func shown(_ inventory: TestInventory) -> [WrittenTest] {
        inventory.tests.filter { test in
            (category == nil || test.category == category) &&
                (query.isEmpty || test.name.localizedCaseInsensitiveContains(query) || test.file.localizedCaseInsensitiveContains(query))
        }
    }

    /// Run what's ticked, or everything the filter shows.
    private func selectionBar(_ inventory: TestInventory) -> some View {
        let visible = shown(inventory)
        let chosen = inventory.tests.filter { selected.contains($0.id) }
        return HStack(spacing: 10) {
            Image(systemName: "checklist").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
            if chosen.isEmpty {
                Text("No tests ticked")
                    .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
            } else {
                Text("\(chosen.count) test\(chosen.count == 1 ? "" : "s") ticked")
                    .font(.dante(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color)
                Button("Clear") { selected = [] }.buttonStyle(.plain).font(.dante(size: 12)).foregroundStyle(theme.accent.color)
            }
            Spacer()
            if !visible.isEmpty, visible.count < inventory.tests.count {
                Button { runTests?(visible) } label: {
                    Label("Run \(category.map { "\($0) " } ?? "")shown (\(visible.count))", systemImage: "play")
                }
                .buttonStyle(DanteButtonStyle())
            }
            if !chosen.isEmpty {
                Button { runTests?(chosen) } label: { Label("Run ticked (\(chosen.count))", systemImage: "play.fill") }
                    .buttonStyle(DanteButtonStyle(primary: true))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(chosen.isEmpty ? theme.card.color : theme.accentTint.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(chosen.isEmpty ? theme.line.color : theme.accentLine.color))
    }

    private func checkbox(_ on: Bool, mixed: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: on ? "checkmark.square.fill" : mixed ? "minus.square.fill" : "square")
                .font(.dante(size: 12))
                .foregroundStyle(on || mixed ? theme.accent.color : theme.text3.color)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func list(_ inventory: TestInventory) -> some View {
        let statuses = self.statuses
        let shown = self.shown(inventory)
        let files = Dictionary(grouping: shown, by: \.file).sorted { $0.key < $1.key }
        return Card(category.map { "\($0) tests" } ?? "Tests by file") {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                TextField("Filter tests", text: $query).textFieldStyle(.plain).font(.dante(size: 12.5))
            }
            .padding(.horizontal, 8)
            .frame(width: 220, height: 26)
            .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line.color))
        } content: {
            if files.isEmpty {
                Text("No tests match.").font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
            }
            RowList(data: files.map { FileGroup(path: $0.key, tests: $0.value) }, padding: 0) { group in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                    if runTests != nil {
                        let ids = Set(group.tests.map(\.id))
                        let all = ids.isSubset(of: selected)
                        checkbox(all, mixed: !all && !ids.isDisjoint(with: selected)) {
                            if all { selected.subtract(ids) } else { selected.formUnion(ids) }
                        }
                        .help("Tick every test in this file")
                    }
                    Button {
                        if collapsed.contains(group.path) { collapsed.remove(group.path) } else { collapsed.insert(group.path) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: collapsed.contains(group.path) ? "chevron.right" : "chevron.down")
                                .font(.dante(size: 9, weight: .semibold)).foregroundStyle(theme.text3.color).frame(width: 10)
                            Text((group.path as NSString).lastPathComponent).font(.dante(size: 12.5, weight: .medium, design: .monospaced)).foregroundStyle(theme.text.color)
                            Text((group.path as NSString).deletingLastPathComponent).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(1).truncationMode(.head)
                            Spacer()
                            let categories = Set(group.tests.map(\.category))
                            if category == nil, categories.count == 1, let only = categories.first { Chip(text: only) }
                            Text("\(group.tests.count)").font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text3.color)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    }
                    if !collapsed.contains(group.path) {
                        ForEach(group.tests) { test in
                            HStack(spacing: 4) {
                            if runTests != nil {
                                checkbox(selected.contains(test.id)) {
                                    if selected.contains(test.id) { selected.remove(test.id) } else { selected.insert(test.id) }
                                }
                            }
                            Button { session.open(file: workspace.url.appending(path: test.file), line: test.line) } label: {
                                HStack(spacing: 8) {
                                    statusIcon(statuses[testKey(test.name)])
                                    Text(test.name).font(.dante(size: 12)).foregroundStyle(theme.text2.color).lineLimit(1)
                                    Spacer()
                                    if category == nil, Set(group.tests.map(\.category)).count > 1 {
                                        Text(test.category).font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                                    }
                                    Text(":\(test.line)").font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color)
                                }
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Open \(test.file):\(test.line)")
                            }
                            .padding(.leading, 18)
                        }
                        Spacer().frame(height: 6)
                    }
                }
            }
        }
    }

    private struct FileGroup: Identifiable {
        let path: String
        let tests: [WrittenTest]
        var id: String { path }
    }

    @ViewBuilder
    private func statusIcon(_ status: TestResult.Status?) -> some View {
        let (symbol, color): (String, Color) = switch status {
        case .passed: ("checkmark", theme.green.color)
        case .failed: ("xmark", theme.red.color)
        case .skipped: ("minus", theme.text3.color)
        case nil: ("circle", theme.text3.color.opacity(0.5))
        }
        Image(systemName: symbol)
            .font(.dante(size: status == nil ? 6 : 10, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 12)
            .help(status == nil ? "Not in the last run" : "Last run: \(String(describing: status!))")
    }
}

// MARK: History

/// Runs on this Mac: a chart of passes and failures, flaky tests, and every run.
struct TestHistoryView: View {
    @Environment(\.theme) private var theme
    let records: [TestRecord]

    var body: some View {
        if records.isEmpty {
            EmptyState(symbol: "clock.arrow.circlepath", title: "No runs yet") { EmptyView() }
        } else {
            summary
            if records.contains(where: { $0.total > 0 || $0.brokeOutsideTests }) { chart }
            HStack(alignment: .top, spacing: 12) {
                problemTests.frame(maxWidth: .infinity)
                runs.frame(maxWidth: .infinity)
            }
        }
    }

    /// Full runs that ran something: the pass rate and trends ignore runs that found no tests.
    private var full: [TestRecord] { records.filter { $0.isFullRun && !$0.foundNoTests } }

    private var summary: some View {
        let recent = Array(full.suffix(20))
        let rate = recent.isEmpty ? 0 : Double(recent.count(where: \.succeeded)) / Double(recent.count)
        let average = recent.isEmpty ? 0 : recent.map(\.duration).reduce(0, +) / Double(recent.count)
        let growth = (full.first?.total, full.last?.total)
        return HStack(spacing: 12) {
            stat("\(records.count)", "runs recorded")
            if recent.isEmpty {
                stat("—", "no run has found a test yet")
            } else {
                stat("\(Int((rate * 100).rounded()))%", "of the last \(recent.count) full runs passed")
                stat(duration(average), "average full run")
            }
            if let first = growth.0, let last = growth.1 {
                stat("\(last)", last == first ? "tests, unchanged" : "tests, \(last > first ? "up" : "down") from \(first)")
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.dante(size: 18, weight: .medium, design: .monospaced)).foregroundStyle(theme.text.color)
            Text(label).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.line.color))
    }

    private struct Bar: Identifiable {
        let id: String
        let run: Int
        let kind: String
        let count: Int
    }

    private var chart: some View {
        let shown = Array(records.suffix(40).enumerated())
        let bars = shown.flatMap { index, record in
            [Bar(id: "\(index)p", run: index + 1, kind: "Passed", count: record.passed),
             Bar(id: "\(index)f", run: index + 1, kind: "Failed", count: record.failed),
             Bar(id: "\(index)b", run: index + 1, kind: "Didn’t run", count: record.brokeOutsideTests ? max(full.last?.total ?? 1, 1) : 0)]
        }
        return Card("Last \(shown.count) runs") {
            Text("Oldest on the left").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
        } content: {
            Chart(bars) { bar in
                // One slot per run, so a short history doesn't sit squashed against an edge.
                BarMark(x: .value("Run", "\(bar.run)"), y: .value("Tests", bar.count), width: .fixed(18))
                    .foregroundStyle(by: .value("Result", bar.kind))
            }
            .chartForegroundStyleScale(["Passed": theme.green.color, "Failed": theme.red.color, "Didn’t run": theme.amber.color])
            .chartXAxis(.hidden)
            .frame(height: 160)
        }
    }

    private var problemTests: some View {
        let flaky = TestHistory.flaky(records)
        let streaks = TestHistory.failingStreaks(records)
        return Card("Tests to look at") {
            EmptyView()
        } content: {
            if flaky.isEmpty && streaks.isEmpty {
                Text(full.count < 2 ? "After a few full runs, flaky and long-failing tests show here." : "Nothing flaky or stuck failing in the recent runs.")
                    .font(.dante(size: 12.5)).foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(streaks.prefix(6), id: \.test) { item in
                row(item.test, item.runs == 1 ? "failing in the last run" : "failing for \(item.runs) runs", theme.red.color)
            }
            ForEach(flaky.prefix(6), id: \.test) { item in
                row(item.test, "flaky: failed \(item.failures) of \(item.runs) runs", theme.amber.color)
            }
        }
    }

    private func row(_ test: String, _ detail: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            StatusDot(color: color, size: 7)
            Text(test.hasPrefix("/") ? String(test.dropFirst()) : test).font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text.color).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(detail).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
        }
    }

    private var runs: some View {
        Card("Runs") {
            Text("On this Mac").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
        } content: {
            RowList(data: Array(records.reversed().prefix(30).enumerated()).map { RunRow(index: $0.offset, record: $0.element) }, padding: 6) { row in
                HStack(spacing: 8) {
                    StatusDot(color: row.record.foundNoTests ? theme.text3.color : row.record.succeeded ? theme.green.color : (row.record.brokeOutsideTests ? theme.amber.color : theme.red.color), size: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.record.foundNoTests ? "No tests found"
                             : row.record.brokeOutsideTests ? "Didn’t run: build or runner failed"
                             : row.record.failed > 0 ? "\(row.record.failed) failed, \(row.record.passed) passed" : "\(row.record.passed) passed")
                            .font(.dante(size: 12.5)).foregroundStyle(theme.text.color)
                        Text(row.record.label).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color).lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(row.record.date.formatted(.relative(presentation: .named))).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                        Text(duration(row.record.duration)).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color)
                    }
                }
            }
        }
    }

    private struct RunRow: Identifiable {
        let index: Int
        let record: TestRecord
        var id: Int { index }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return whole < 60 ? "\(whole)s" : "\(whole / 60)m \(whole % 60)s"
    }
}

// MARK: Untested

/// Code that no test names, logic first, with a button per file to have Claude cover it.
struct UntestedView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let gaps: TestGaps?
    let hasTests: Bool

    @State private var showsInterface = false
    @State private var expanded: Set<String> = []

    var body: some View {
        if let gaps {
            let logic = gaps.files.filter { !$0.isInterface && !$0.untested.isEmpty }
            let interface = gaps.files.filter { $0.isInterface && !$0.untested.isEmpty }
            header(gaps)
            if logic.isEmpty && interface.isEmpty {
                EmptyState(symbol: "checkmark.seal", title: "Every function is named in a test") { EmptyView() }
            } else {
                Card("Logic") {
                    Text("\(logic.count) file\(logic.count == 1 ? "" : "s"), most untested first").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                } content: {
                    rows(logic)
                }
                if !interface.isEmpty {
                    Card("Views and screens") {
                        LinkButton(showsInterface ? "Hide" : "Show \(interface.count)") { showsInterface.toggle() }
                    } content: {
                        if showsInterface {
                            rows(interface)
                        } else {
                        }
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private func header(_ gaps: TestGaps) -> some View {
        let tested = gaps.declarations - gaps.untestedCount
        let fraction = gaps.declarations == 0 ? 1 : Double(tested) / Double(gaps.declarations)
        return HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(gaps.untestedCount) of \(gaps.declarations) functions and types aren’t named in any test")
                    .font(.dante(size: 15, weight: .semibold)).foregroundStyle(theme.text.color)
                ProgressView(value: fraction).tint(theme.green.color).frame(maxWidth: 360)
            }
            Spacer()
            Button {
                session.askClaude(gaps.prompt())
            } label: { Label("Ask Claude what matters most", systemImage: "sparkle") }
                .buttonStyle(DanteButtonStyle(primary: true))
                .disabled(gaps.untestedCount == 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line.color))
    }

    private func rows(_ files: [UntestedFile]) -> some View {
        RowList(data: files, padding: 8) { file in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button { session.open(file: workspace.url.appending(path: file.path)) } label: {
                        HStack(spacing: 6) {
                            Text((file.path as NSString).lastPathComponent).font(.dante(size: 12.5, weight: .medium, design: .monospaced)).foregroundStyle(theme.text.color)
                            Text((file.path as NSString).deletingLastPathComponent).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(1).truncationMode(.head)
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 6)
                    if file.hasTestFile { Chip(text: "has a test file") }
                    Text("\(file.untested.count) of \(file.declared.count) untested · \(file.lines) lines")
                        .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                    Button("Write tests") {
                        session.askClaude("Write tests for \(file.path). Nothing tests these yet: \(file.untested.prefix(15).joined(separator: ", ")). \(hasTests ? "Follow the project's existing test style and runner." : "The project has no tests yet: pick the standard runner for this language and set test.command in .dante/project.yaml if Dante can't detect it.") Start with the behaviour most likely to break, and show me each file before writing it.")
                    }
                    .buttonStyle(DanteButtonStyle())
                }
                let names = expanded.contains(file.id) ? file.untested : Array(file.untested.prefix(8))
                FlowLayout(spacing: 4) {
                    ForEach(names, id: \.self) { name in
                        Text(name).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text2.color)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 4))
                    }
                    if file.untested.count > 8 {
                        LinkButton(expanded.contains(file.id) ? "fewer" : "+\(file.untested.count - 8) more") {
                            if expanded.contains(file.id) { expanded.remove(file.id) } else { expanded.insert(file.id) }
                        }
                    }
                }
            }
        }
    }
}
