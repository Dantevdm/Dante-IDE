import DanteKit
import SwiftUI

/// Tests, on one page: every run on this Mac (yours from here, the agents' and jobs'), the
/// tests written in the code by kind (Front-end, Back-end, Integration, Security…) with a Run
/// button each, what failed and why, and the code no test names. The run lives on the
/// session, so it keeps going while you look elsewhere.
struct TestsView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    /// `test.command` from project.yaml, which wins over the suites found.
    @State private var custom: TestCommand?
    /// Every folder with its own test runner.
    @State private var suites: [TestSuite] = []
    @State private var loaded = false
    /// Tests found by reading the code, and code no test names. Loaded off the main thread.
    @State private var inventory: TestInventory?
    @State private var gaps: TestGaps?
    /// Every saved run, oldest first.
    @State private var runs: [SavedTestRun] = []
    /// When each test file last changed, for marking results that may be out of date.
    @State private var modified: [String: Date] = [:]
    /// A run chosen in the strip; nil shows the latest.
    @State private var selectedRun: String?
    @State private var showsUntested = false

    /// Everything, with the project's command or each suite in its folder.
    private var command: TestCommand? { custom ?? TestSuites.command(suites) }

    var body: some View {
        AreaPage(eyebrow: nil, title: "Tests", subtitle: nil) {
            actions
        } content: {
            if loaded, command == nil, inventory?.tests.isEmpty ?? false, runs.isEmpty {
                EmptyState(symbol: "testtube.2", title: "No tests yet") {
                    Button {
                        session.askClaude("This project has no test setup Dante can find. Suggest a test runner that fits the stack, add it with one example test, and set test.command in .dante/project.yaml.")
                    } label: { ClaudeLabel("Ask \(session.agentName) to set up tests") }
                        .buttonStyle(DanteButtonStyle(primary: true))
                }
            } else {
                overview
                if loaded, command == nil, !(inventory?.tests.isEmpty ?? true) { noRunner }
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
                if let live, live.failedOutsideTests || !live.output.isEmpty {
                    OutputCard(run: live, title: "Output", expanded: live.failedOutsideTests)
                }
                kindsSection
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
        if let custom {
            Chip(text: custom.label, symbol: "terminal", mono: true).help("test.command in .dante/project.yaml")
        } else {
            ForEach(suites) { suite in
                Chip(text: suite.label, symbol: "terminal", mono: true).help("Found from the project’s files; set test.command in .dante/project.yaml to change it")
            }
        }
        if let run = session.testRun, run.isRunning {
            Button { run.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(DanteButtonStyle())
        } else {
            if let runOnly, !shownFailures.isEmpty {
                Button { runOnly(shownFailures) } label: { Label("Re-run failed", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(DanteButtonStyle())
                    .keyboardShortcut("u", modifiers: [.command, .shift])
            }
            if let runWritten, !changedTests.isEmpty {
                Button { runWritten(changedTests) } label: { Label("Run for changes (\(changedTests.count))", systemImage: "line.3.horizontal.decrease") }
                    .buttonStyle(DanteButtonStyle())
                    .help("The tests that go with the files changed in the working tree")
            }
            Button { run() } label: { Label("Run all", systemImage: "play.fill") }
                .buttonStyle(DanteButtonStyle(primary: true))
                .disabled(command == nil)
                .help(command == nil ? "Dante couldn’t find how to run this project’s tests" : command?.label ?? "")
                .keyboardShortcut("u", modifiers: .command)
        }
    }

    /// Tests in the code, but nothing Dante knows to run them with.
    private var noRunner: some View {
        HStack(spacing: 14) {
            Image(systemName: "questionmark.circle").font(.dante(size: 18)).foregroundStyle(theme.amber.color)
            VStack(alignment: .leading, spacing: 3) {
                Text("Dante can’t tell how to run these tests").font(.dante(size: 13.5, weight: .semibold)).foregroundStyle(theme.text.color)
                Text("It looks for a pom.xml, build.gradle, a package.json with a test script, go.mod, Cargo.toml, Package.swift or a pytest setup, up to four folders down. Set test.command in .dante/project.yaml, or let \(session.agentName) work it out.")
                    .font(.dante(size: 12)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                session.askClaude("Dante can't find how to run this project's tests. Work out the command (each app in its own folder if there are several), check it runs, and set test.command in .dante/project.yaml.")
            } label: { ClaudeLabel("Ask \(session.agentName)") }
                .buttonStyle(DanteButtonStyle(primary: true))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.amber.color.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.amber.color.opacity(0.35)))
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
        guard let last = runs.last else {
            return command == nil ? "Ask \(session.agentName) to run them, or set how below" : "Run them all, or one kind at a time: every run is kept here, whoever starts it"
        }
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

    // MARK: Kinds

    @ViewBuilder
    private var kindsSection: some View {
        if let map, let inventory, !map.tiles.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(map.kinds(order: inventory.categories)) { kind in
                    TestKindCard(kind: kind, place: place(of: kind), isRunning: live != nil, run: runWritten,
                                 open: { test in session.open(file: workspace.url.appending(path: test.file), line: test.line) })
                }
                if !map.unmatched.isEmpty {
                    Text("\(map.unmatched.count) result\(map.unmatched.count == 1 ? "" : "s") from the last run don’t match a test Dante read in the code (display names, generated or parameterised tests).")
                        .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                }
            }
        } else if inventory == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 80)
        }
    }

    /// The app folders a kind's tests are in: "services/react", or "services/api and services/react".
    private func place(of kind: TestMap.Kind) -> String? {
        let folders = Set(kind.tiles.compactMap { TestSuites.suite(for: $0.test.file, in: suites)?.folder }).filter { !$0.isEmpty }.sorted()
        guard !folders.isEmpty else { return nil }
        return folders.count <= 2 ? folders.joined(separator: " and ") : "\(folders.count) apps"
    }

    // MARK: Untested

    static func untestedSentence(_ untested: Int, of all: Int) -> String {
        let what = untested == all
            ? (all == 1 ? "The one function or type in the code isn’t" : "None of the \(all) functions and types in the code are")
            : "\(untested) of the \(all) functions and types in the code \(untested == 1 ? "isn’t" : "aren’t")"
        return what + " named in any test, so no test is clearly aimed at \(untested == 1 ? "it" : "them"). " + (untested == 1 ? "It’s in:" : "These files have the most:")
    }

    @ViewBuilder
    private var untested: some View {
        if let gaps, gaps.untestedCount > 0 {
            let named = gaps.declarations - gaps.untestedCount
            Card("Code without tests") {
                Button { session.askClaude(gaps.prompt()) } label: { ClaudeLabel("Ask what matters most") }
                    .buttonStyle(DanteButtonStyle())
            } content: {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Self.untestedSentence(gaps.untestedCount, of: gaps.declarations))
                        .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        ProgressView(value: gaps.declarations == 0 ? 1 : Double(named) / Double(gaps.declarations))
                            .tint(theme.green.color).frame(maxWidth: 320)
                        Text("\(gaps.declarations == 0 ? 100 : named * 100 / gaps.declarations)% named in a test")
                            .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                    }
                    UntestedView(session: session, workspace: workspace, gaps: gaps, hasTests: !(inventory?.tests.isEmpty ?? true),
                                 showsHeader: false, limit: showsUntested ? 1000 : 5)
                    let files = gaps.files.filter { !$0.untested.isEmpty }.count
                    if files > 5 {
                        LinkButton(showsUntested ? "Show fewer" : "Show all \(files) files") { showsUntested.toggle() }
                    }
                }
            }
        }
    }

    // MARK: Running

    private func load() async {
        let root = workspace.url
        let files = workspace.files
        custom = TestCommand.custom(projectRoot: root)
        runs = TestRunLog.load(for: root)
        let (foundSuites, found, untested, dates) = await Task.detached(priority: .utility) {
            let suites = TestSuites.find(files: files) { try? String(contentsOf: root.appending(path: $0), encoding: .utf8) }
            let inventory = TestInventory.load(root: root, files: files, suites: suites)
            var dates: [String: Date] = [:]
            for file in inventory.testFiles {
                dates[file] = (try? root.appending(path: file).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
            return (suites, inventory, TestGaps.load(root: root, files: files, inventory: inventory), dates)
        }.value
        suites = foundSuites
        inventory = found
        gaps = untested
        modified = dates
        loaded = true
    }

    /// Tests that go with the files changed in the working tree.
    private var changedTests: [WrittenTest] {
        guard let inventory, let changes = session.git.status?.changes, !changes.isEmpty else { return [] }
        return TestImpact.tests(for: changes.map(\.path), in: inventory)
    }

    /// Runs some of the tests a run reported, when the runner can be narrowed.
    private var runOnly: (([TestResult]) -> Void)? {
        if let custom {
            guard custom.only([TestResult(suite: "", name: "x", status: .passed)]) != nil else { return nil }
            return { tests in if let narrowed = custom.only(tests) { run(narrowed) } }
        }
        guard !suites.isEmpty, let inventory else { return nil }
        // Results name tests; find them in the code to know each one's suite.
        return { results in
            let keys = Set(results.map { TestMap.key($0.name) })
            let tests = inventory.tests.filter { keys.contains(TestMap.key($0.name)) }
            if let narrowed = TestSuites.command(suites, only: tests) { run(narrowed) }
        }
    }

    /// Runs tests read from the code, each with its own suite's runner.
    private var runWritten: (([WrittenTest]) -> Void)? {
        if let custom {
            guard let sample = inventory?.tests.first, custom.only(written: [sample]) != nil else { return nil }
            return { tests in if let narrowed = custom.only(written: tests) { run(narrowed) } }
        }
        guard !suites.isEmpty else { return nil }
        return { tests in if let narrowed = TestSuites.command(suites, only: tests) { run(narrowed) } }
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

