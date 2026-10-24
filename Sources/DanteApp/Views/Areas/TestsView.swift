import DanteKit
import SwiftUI

/// Tests, on one page: every run on this Mac (yours from here, the agents' and jobs'), the
/// tests written in the code as a map coloured by their last result, what failed and why, and
/// the code no test names. The run lives on the session, so it keeps going while you look
/// elsewhere.
struct TestsView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    @State private var command: TestCommand?
    /// Tests found by reading the code, and code no test names. Loaded off the main thread.
    @State private var inventory: TestInventory?
    @State private var gaps: TestGaps?
    /// Every saved run, oldest first.
    @State private var runs: [SavedTestRun] = []
    /// When each test file last changed, for marking results that may be out of date.
    @State private var modified: [String: Date] = [:]
    /// A run chosen in the strip; nil shows the latest.
    @State private var selectedRun: String?
    /// Tests ⌘-clicked on the map.
    @State private var picked: Set<String> = []
    @State private var showsUntested = false

    var body: some View {
        AreaPage(eyebrow: nil, title: "Tests", subtitle: nil) {
            actions
        } content: {
            if command == nil, inventory?.tests.isEmpty ?? false, runs.isEmpty {
                EmptyState(symbol: "testtube.2", title: "No tests yet") {
                    Button {
                        session.askClaude("This project has no test setup Dante can find. Suggest a test runner that fits the stack, add it with one example test, and set test.command in .dante/project.yaml.")
                    } label: { ClaudeLabel("Ask \(session.agentName) to set up tests") }
                        .buttonStyle(DanteButtonStyle(primary: true))
                }
            } else {
                overview
                if !runs.isEmpty || live != nil {
                    Card("Runs on this Mac") {
                        Text("Yours from here, \(session.agentName)’s and jobs’").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                    } content: {
                        TestRunStrip(runs: runs, live: live, selected: $selectedRun)
                    }
                }
                if let shown = shownRun, shown.brokeOutsideTests, live == nil {
                    BrokenRunCard(run: shown)
                }
                if !shownFailures.isEmpty {
                    FailuresCard(session: session, workspace: workspace, failures: shownFailures, command: shownCommand,
                                 isRunning: live != nil, flaky: map?.flakyKeys ?? [], runOnly: runOnly)
                }
                mapCard
                if let live, live.failedOutsideTests || !live.output.isEmpty {
                    OutputCard(run: live, title: "Output", expanded: live.failedOutsideTests)
                }
                untested
            }
        }
        .task(id: workspace.revision) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: TestRunLog.changed)) { note in
            if note.object as? String == workspace.url.standardizedFileURL.path { runs = TestRunLog.load(for: workspace.url) }
        }
    }

    /// The run going now, while it runs; once it finishes it's in `runs`.
    private var live: TestRun? { session.testRun?.isRunning == true ? session.testRun : nil }

    private var shownRun: SavedTestRun? {
        if let selectedRun { return runs.first { $0.id == selectedRun } }
        return runs.last
    }

    private var shownFailures: [TestResult] {
        if let live { return live.results.filter { $0.status == .failed } }
        return shownRun?.failures ?? []
    }

    private var shownCommand: String { live?.command.label ?? shownRun?.command ?? command?.label ?? "the tests" }

    /// The map as the shown run left it: later runs don't count.
    private var map: TestMap? {
        guard let inventory else { return nil }
        let upTo: [SavedTestRun]
        if let selectedRun, let index = runs.firstIndex(where: { $0.id == selectedRun }) { upTo = Array(runs[...index]) } else { upTo = runs }
        return TestMap.build(inventory: inventory, runs: upTo, live: live?.results, liveCoversAll: live.map { !$0.command.label.contains(" · ") } ?? false,
                             modified: selectedRun == nil ? modified : [:])
    }

    // MARK: Header

    @ViewBuilder
    private var actions: some View {
        if let command {
            Chip(text: command.label, symbol: "terminal", mono: true)
                .help(workspace.lifecycle.hasSpec ? "Set test.command in .dante/project.yaml to change this" : "Detected from the project files")
        }
        if let run = session.testRun, run.isRunning {
            Button { run.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(DanteButtonStyle())
        } else {
            if let runWritten, !picked.isEmpty, let tests = pickedTests {
                Button { runWritten(tests); picked = [] } label: { Label("Run \(tests.count) picked", systemImage: "checklist") }
                    .buttonStyle(DanteButtonStyle())
            }
            if let runOnly, !shownFailures.isEmpty {
                Button { runOnly(shownFailures) } label: { Label("Re-run failed", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(DanteButtonStyle())
                    .keyboardShortcut("u", modifiers: [.command, .shift])
            }
            if runWritten != nil, (!changedTests.isEmpty || (inventory?.categories.count ?? 0) > 1) {
                Menu {
                    if !changedTests.isEmpty {
                        Button("Tests for changed files (\(changedTests.count))") { runWritten?(changedTests) }
                    }
                    if let inventory, inventory.categories.count > 1 {
                        Section("By kind") {
                            ForEach(inventory.categories, id: \.self) { name in
                                Button("\(name) (\(inventory.count(in: name)))") { runWritten?(inventory.tests.filter { $0.category == name }) }
                            }
                        }
                    }
                } label: { Label("Run some", systemImage: "line.3.horizontal.decrease") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Run the tests for changed files, or one kind of test")
            }
            if let last = session.testRun?.command, last != command, !last.label.isEmpty {
                Button { run(last) } label: { Label("Run these again", systemImage: "play") }
                    .buttonStyle(DanteButtonStyle())
                    .help(last.label)
            }
            Button { run() } label: { Label("Run all", systemImage: "play.fill") }
                .buttonStyle(DanteButtonStyle(primary: true))
                .disabled(command == nil)
                .keyboardShortcut("u", modifiers: .command)
        }
    }

    // MARK: Overview

    /// One sentence for where the tests stand, and the counts behind it.
    private var overview: some View {
        let map = self.map
        let failing = map?.count(.failed) ?? 0, flaky = map?.count(.flaky) ?? 0, passing = map?.count(.passed) ?? 0
        let notRun = map?.count(.notRun) ?? 0, stale = map?.staleCount ?? 0
        let total = inventory?.tests.count ?? 0
        let headline: String = {
            if let live { return live.results.isEmpty ? "Building and starting \(live.command.label)…" : "Running: \(live.results.count) results so far" }
            if inventory == nil { return "Reading the tests…" }
            if total == 0 { return runs.isEmpty ? "No tests found in the code" : "Runs found tests Dante can’t place in the code" }
            if runs.isEmpty { return "\(total) tests in the code, none run on this Mac yet" }
            if let shown = shownRun, shown.brokeOutsideTests { return "The last run didn’t get to the tests" }
            if failing > 0 {
                let flakyFailing = map?.tiles.count { $0.state == .failed && $0.flaky } ?? 0
                return "\(failing) failing of \(total)" + (flakyFailing > 0 ? ", \(flakyFailing == failing ? (failing == 1 ? "it’s" : "all") : "\(flakyFailing)") flaky" : "")
            }
            if flaky > 0 { return "Passing, with \(flaky) flaky" }
            return notRun > 0 ? "Everything that ran passed" : "All \(total) passing"
        }()
        let state: Color = live != nil ? theme.accent.color : failing > 0 || shownRun?.brokeOutsideTests == true ? theme.red.color
            : flaky > 0 ? theme.amber.color : runs.isEmpty ? theme.text3.color : theme.green.color
        return HStack(spacing: 18) {
            Circle().fill(state).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(.dante(size: 16, weight: .semibold)).foregroundStyle(theme.text.color)
                if let live {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let seconds = Int(live.duration.rounded())
                        Text("\(live.command.label) · running for \(seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s") · \(live.passed) passed, \(live.failed) failed so far")
                            .font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                    }
                } else {
                    Text(subline).font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                }
            }
            Spacer()
            stat(passing, "passing", theme.green.color)
            stat(failing, "failing", theme.red.color)
            stat(flaky, "flaky", theme.amber.color)
            stat(notRun, "not run", theme.text2.color)
            if stale > 0 { stat(stale, "changed since", theme.text2.color) }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(failing > 0 ? theme.red.color.opacity(0.45) : theme.line.color))
    }

    private var subline: String {
        if selectedRun != nil, let shown = shownRun { return "As of the run by \(Self.who(shown.by)) \(shown.date.formatted(.relative(presentation: .named)))" }
        guard let last = runs.last else { return "Run them from here, or ask \(session.agentName): every run is kept here, whoever starts it" }
        return "Last run by \(Self.who(last.by)) \(last.date.formatted(.relative(presentation: .named))) · \(last.command)"
    }

    /// "you", "Codex", "the job “Fix the rounding”".
    static func who(_ runner: TestRunner) -> String {
        switch runner.kind {
        case .you: "you"
        case .job: runner.name.isEmpty ? "a job" : "the job “\(runner.name)”"
        case .agent, .ci: runner.label
        }
    }

    private func stat(_ value: Int, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(value)").font(.dante(size: 18, weight: .medium, design: .monospaced)).foregroundStyle(value > 0 ? color : theme.text3.color)
            Text(label).font(.dante(size: 11)).foregroundStyle(theme.text3.color)
        }
    }

    // MARK: Map

    @ViewBuilder
    private var mapCard: some View {
        if let map, !map.groups.isEmpty {
            Card("Every test") {
                Text("\(map.tiles.count) in \(map.groups.count) folder\(map.groups.count == 1 ? "" : "s")").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
            } content: {
                TestMapView(map: map, open: { test in session.open(file: workspace.url.appending(path: test.file), line: test.line) },
                            picked: $picked, canPick: runWritten != nil)
                if !map.unmatched.isEmpty {
                    Text("\(map.unmatched.count) result\(map.unmatched.count == 1 ? "" : "s") from the last run don’t match a test Dante read in the code (display names, generated or parameterised tests).")
                        .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                }
            }
        } else if inventory == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 80)
        }
    }

    // MARK: Untested

    @ViewBuilder
    private var untested: some View {
        if let gaps, gaps.untestedCount > 0 {
            Card("Code no test names") {
                Text("\(gaps.untestedCount) of \(gaps.declarations) functions and types").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                LinkButton(showsUntested ? "Hide" : "Show") { showsUntested.toggle() }
                Button { session.askClaude(gaps.prompt()) } label: { ClaudeLabel("Ask what matters most") }
                    .buttonStyle(DanteButtonStyle())
            } content: {
                if showsUntested {
                    UntestedView(session: session, workspace: workspace, gaps: gaps, hasTests: !(inventory?.tests.isEmpty ?? true), showsHeader: false)
                } else {
                    UntestedStrip(gaps: gaps)
                }
            }
        }
    }

    // MARK: Running

    private func load() async {
        command = TestCommand.detect(projectRoot: workspace.url)
        runs = TestRunLog.load(for: workspace.url)
        let root = workspace.url
        let files = workspace.files
        let (found, untested, dates) = await Task.detached(priority: .utility) {
            let inventory = TestInventory.load(root: root, files: files)
            var dates: [String: Date] = [:]
            for file in inventory.testFiles {
                dates[file] = (try? root.appending(path: file).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
            return (inventory, TestGaps.load(root: root, files: files, inventory: inventory), dates)
        }.value
        inventory = found
        gaps = untested
        modified = dates
    }

    private var pickedTests: [WrittenTest]? {
        let tests = (inventory?.tests ?? []).filter { picked.contains($0.id) }
        return tests.isEmpty ? nil : tests
    }

    /// Tests that go with the files changed in the working tree.
    private var changedTests: [WrittenTest] {
        guard let inventory, let changes = session.git.status?.changes, !changes.isEmpty else { return [] }
        return TestImpact.tests(for: changes.map(\.path), in: inventory)
    }

    /// Runs some of the tests with the project's runner, when it can be narrowed.
    private var runOnly: (([TestResult]) -> Void)? {
        guard let command, command.only([TestResult(suite: "", name: "x", status: .passed)]) != nil else { return nil }
        return { tests in if let narrowed = command.only(tests) { run(narrowed) } }
    }

    /// Runs tests read from the code, when the runner can be narrowed.
    private var runWritten: (([WrittenTest]) -> Void)? {
        guard let command, let sample = inventory?.tests.first, command.only(written: [sample]) != nil else { return nil }
        return { tests in if let narrowed = command.only(written: tests) { run(narrowed) } }
    }

    private func run(_ chosen: TestCommand? = nil) {
        guard let command = chosen ?? command else { return }
        session.testRun?.stop()
        selectedRun = nil
        let run = TestRun(command: command, projectRoot: workspace.url)
        let root = workspace.url
        run.onFinish = { TestRunLog.append($0.saved(), for: root) }
        session.testRun = run
    }
}

/// A run that stopped before its tests: the end of what it printed.
private struct BrokenRunCard: View {
    @Environment(\.theme) private var theme
    let run: SavedTestRun

    var body: some View {
        Card("The run stopped before any test ran") {
            Text("\(run.by.label) · \(run.command)").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
        } content: {
            if run.tail.isEmpty {
                Text("It failed without printing why.").font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
            } else {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(run.tail.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.dante(size: 11, design: .monospaced))
                                .foregroundStyle(line.contains("error") ? theme.red.color : theme.text2.color).fixedSize()
                        }
                    }
                    .textSelection(.enabled)
                    .padding(10)
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.codeBackground.color))
            }
        }
    }
}

/// Code no test names, as a bar of files: the share of each file's functions with no test.
private struct UntestedStrip: View {
    @Environment(\.theme) private var theme
    let gaps: TestGaps

    var body: some View {
        let files = gaps.files.filter { !$0.untested.isEmpty && !$0.isInterface }.prefix(60)
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: gaps.declarations == 0 ? 1 : Double(gaps.declarations - gaps.untestedCount) / Double(gaps.declarations))
                .tint(theme.green.color)
            FlowLayout(spacing: 3) {
                ForEach(Array(files)) { file in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(theme.amber.color.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .background(RoundedRectangle(cornerRadius: 2).fill(theme.amber.color.opacity(0.15 + 0.5 * (1 - file.testedFraction))))
                        .frame(width: 13, height: 13)
                        .help("\(file.path): \(file.untested.count) of \(file.declared.count) untested")
                }
            }
        }
    }
}

// MARK: Failures

private struct FailuresCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let failures: [TestResult]
    /// The command that found them, for the agent.
    let command: String
    let isRunning: Bool
    /// `TestMap.key`s of tests that pass and fail from run to run.
    let flaky: Set<String>
    let runOnly: (([TestResult]) -> Void)?

    var body: some View {
        Card("Failures", accent: false) {
            if let runOnly, !isRunning {
                Button { runOnly(failures) } label: { Label("Re-run", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(DanteButtonStyle())
                    .help(failures.count == 1 ? "Run this test again" : "Run these \(failures.count) tests again")
            }
            Button {
                session.askClaude(prompt(for: failures))
            } label: {
                ClaudeLabel(failures.count == 1 ? "Ask Claude to fix it" : "Ask Claude to fix these")
            }
            .buttonStyle(DanteButtonStyle(primary: true))
        } content: {
            RowList(data: failures, padding: 10) { result in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        StatusDot(color: theme.red.color)
                        if !result.suite.isEmpty {
                            Text(result.suite).font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text3.color)
                        }
                        Text(result.name).font(.dante(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color)
                        if flaky.contains(TestMap.key(result.name)) {
                            Chip(text: "flaky").help("This test has passed and failed in recent runs: the cause may be timing or shared state rather than the code")
                        }
                        Spacer()
                        if let duration = result.duration {
                            Text(String(format: "%.2fs", duration)).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color)
                        }
                        IconButton(symbol: "sparkle", label: "Fix \(result.name) with Claude", size: 10) { session.askClaude(prompt(for: [result])) }
                        if let runOnly, !isRunning {
                            IconButton(symbol: "play.fill", label: "Run \(result.name)", size: 10) { runOnly([result]) }
                        }
                    }
                    ForEach(Array(result.issues.enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(issue.message)
                                .font(.dante(size: 12, design: .monospaced))
                                .foregroundStyle(theme.text.color)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if let file = issue.file {
                                let location = "\((file as NSString).lastPathComponent)\(issue.line.map { ":\($0)" } ?? "")"
                                if let url = resolve(file) {
                                    LinkButton(location) { session.open(file: url) }
                                } else {
                                    Text(location).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.codeBackground.color))
                        .padding(.leading, 15)
                    }
                }
            }
        }
    }

    /// The project file a runner named: absolute, relative to the root, or a bare file name
    /// matched against the index.
    private func resolve(_ file: String) -> URL? {
        if file.hasPrefix("/") {
            let url = URL(filePath: file)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        if workspace.files.contains(file) { return workspace.url.appending(path: file) }
        let matches = workspace.files.filter { ($0 as NSString).lastPathComponent == file }
        return matches.count == 1 ? workspace.url.appending(path: matches[0]) : nil
    }

    private func prompt(for failures: [TestResult]) -> String {
        let opening = failures.count == 1 ? "This test fails" : "These tests fail"
        var lines = ["\(opening) when I run `\(command)`. Read the test and the code it calls, find the cause and propose a fix. If the test is wrong rather than the code, say so before changing it. Afterwards, tell me the command to run just these tests."]
        for failure in failures.prefix(10) {
            lines.append("- \(failure.suite.isEmpty ? "" : failure.suite + ".")\(failure.name)")
            for issue in failure.issues.prefix(3) {
                let location = issue.file.map { " (\($0)\(issue.line.map { ":\($0)" } ?? ""))" } ?? ""
                lines.append("  \(issue.message.replacingOccurrences(of: "\n", with: " "))\(location)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

private struct OutputCard: View {
    @Environment(\.theme) private var theme
    let run: TestRun
    let title: String
    @State private var expanded: Bool

    init(run: TestRun, title: String, expanded: Bool) {
        self.run = run
        self.title = title
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        Card(title) {
            LinkButton(expanded ? "Hide" : "Show") { expanded.toggle() }
        } content: {
            if expanded {
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(run.output.suffix(600).enumerated()), id: \.offset) { index, line in
                                Text(line.isEmpty ? " " : line)
                                    .font(.dante(size: 11, design: .monospaced))
                                    .foregroundStyle(lineColor(line))
                                    .fixedSize()
                                    .id(index)
                            }
                        }
                        .textSelection(.enabled)
                        .padding(10)
                    }
                    .frame(height: 260)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.codeBackground.color))
                    .onAppear { proxy.scrollTo(min(run.output.count, 600) - 1, anchor: .bottom) }
                    .onChange(of: run.output.count) { _, count in proxy.scrollTo(min(count, 600) - 1, anchor: .bottom) }
                }
            } else {
                Text("\(run.output.count) lines from \(run.command.label)").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
            }
        }
    }

    private func lineColor(_ line: String) -> Color {
        if line.contains("error:") || line.hasPrefix("✘") || line.contains("FAIL") { return theme.red.color }
        if line.contains("warning:") { return theme.amber.color }
        return theme.text2.color
    }
}

