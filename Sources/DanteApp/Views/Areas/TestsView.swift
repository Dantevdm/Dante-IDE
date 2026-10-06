import DanteKit
import SwiftUI

/// Tests: run the project's tests, see what failed and where, and hand failures or gaps
/// to Claude. The run lives on the session, so it keeps going while you look elsewhere.
struct TestsView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    @State private var command: TestCommand?
    @State private var showsOutput = false

    var body: some View {
        AreaPage(
            eyebrow: "Quality",
            title: "Tests",
            subtitle: "Run the suite here and every failure links to its line. Claude can fix a failure or draft the tests a change is missing; you review each file first."
        ) {
            if let command {
                Chip(text: command.label, symbol: "terminal", mono: true)
                    .help(workspace.lifecycle.hasSpec ? "Set test.command in .dante/project.yaml to change this" : "Detected from the project files")
            }
            if session.testRun?.isRunning == true {
                Button { session.testRun?.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(DanteButtonStyle())
            } else {
                if let run = session.testRun, run.failed > 0, let failedOnly = command?.only(run.results.filter { $0.status == .failed }) {
                    Button { self.run(failedOnly) } label: { Label("Re-run failed", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(DanteButtonStyle())
                        .keyboardShortcut("u", modifiers: [.command, .shift])
                        .help(failedOnly.arguments.joined(separator: " "))
                }
                Button { run() } label: { Label(session.testRun == nil ? "Run tests" : "Run all again", systemImage: "play.fill") }
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .disabled(command == nil)
                    .keyboardShortcut("u", modifiers: .command)
            }
        } content: {
            if command == nil {
                EmptyState(
                    symbol: "testtube.2",
                    title: "No test runner found",
                    message: "Dante looks for Package.swift, Cargo.toml, go.mod, a package.json test script or pytest. Set test.command in .dante/project.yaml to use something else."
                ) {
                    Button("Ask Claude to set up tests") {
                        session.askClaude("This project has no test setup Dante can find. Suggest a test runner that fits the stack, add it with one example test, and set test.command in .dante/project.yaml.")
                    }
                    .buttonStyle(DanteButtonStyle(primary: true))
                }
            } else if let run = session.testRun {
                RunSummary(run: run, checklist: testChecklist)
                if run.failedOutsideTests || isCouldNotStart(run) {
                    OutputCard(run: run, title: "The run stopped before any test failed", expanded: true)
                }
                if run.failed > 0 {
                    FailuresCard(session: session, workspace: workspace, run: run, runOnly: runOnly)
                }
                HStack(alignment: .top, spacing: 16) {
                    SuitesCard(run: run, runOnly: runOnly)
                    VStack(spacing: 16) {
                        DraftTestsCard(session: session)
                        if !run.failedOutsideTests {
                            OutputCard(run: run, title: "Output", expanded: false)
                        }
                    }
                    .frame(width: 340)
                }
            } else {
                EmptyState(
                    symbol: "play.circle",
                    title: "Run \(command?.label ?? "the tests")",
                    message: "Results stream in as each test finishes, grouped by suite, with failures first."
                ) {
                    Button { run() } label: { Label("Run tests", systemImage: "play.fill") }
                        .buttonStyle(DanteButtonStyle(primary: true))
                }
                DraftTestsCard(session: session)
            }
        }
        .task(id: workspace.revision) { command = TestCommand.detect(projectRoot: workspace.url) }
    }

    private var testChecklist: (done: Int, total: Int)? {
        let phase = workspace.lifecycle.phases.first { $0.lowercased() == "test" } ?? "Test"
        guard let doc = workspace.phaseDocs[phase.lowercased()], !doc.doneWhen.isEmpty else { return nil }
        return (doc.doneWhen.count(where: \.done), doc.doneWhen.count)
    }

    private func isCouldNotStart(_ run: TestRun) -> Bool {
        if case .couldNotStart = run.state { true } else { false }
    }

    /// Runs some of the tests with the project's runner, when it can be narrowed.
    private var runOnly: (([TestResult]) -> Void)? {
        guard let command, command.only([TestResult(suite: "", name: "x", status: .passed)]) != nil else { return nil }
        return { tests in if let narrowed = command.only(tests) { run(narrowed) } }
    }

    private func run(_ chosen: TestCommand? = nil) {
        guard let command = chosen ?? command else { return }
        session.testRun?.stop()
        let run = TestRun(command: command, projectRoot: workspace.url)
        let root = workspace.url
        run.onFinish = { $0.record.append(for: root) }
        session.testRun = run
    }
}

// MARK: Summary

private struct RunSummary: View {
    @Environment(\.theme) private var theme
    let run: TestRun
    let checklist: (done: Int, total: Int)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 18) {
                statusIcon
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text.color)
                    Text(detail).font(.system(size: 12)).foregroundStyle(theme.text3.color)
                }
                Spacer()
                count(run.passed, "passed", theme.green.color)
                count(run.failed, "failed", run.failed > 0 ? theme.red.color : theme.text3.color)
                count(run.skipped, "skipped", theme.text3.color)
                if let checklist {
                    Rectangle().fill(theme.line.color).frame(width: 1, height: 34)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(checklist.done)/\(checklist.total)").font(.system(size: 18, weight: .medium, design: .monospaced)).foregroundStyle(theme.text.color)
                        Text("Test checklist").font(.system(size: 11)).foregroundStyle(theme.text3.color)
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(borderColor))
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch run.state {
        case .running:
            ProgressView().controlSize(.small).frame(width: 28, height: 28)
        default:
            Image(systemName: succeeded ? "checkmark.circle.fill" : (run.state == .stopped ? "stop.circle.fill" : "xmark.circle.fill"))
                .font(.system(size: 24))
                .foregroundStyle(succeeded ? theme.green.color : (run.state == .stopped ? theme.text3.color : theme.red.color))
        }
    }

    private var succeeded: Bool { run.state == .finished(exitStatus: 0) }

    private var borderColor: Color {
        if run.isRunning || run.state == .stopped { return theme.line.color }
        return succeeded ? theme.line.color : theme.red.color.opacity(0.5)
    }

    private var headline: String {
        switch run.state {
        case .running: return run.results.isEmpty ? "Building and starting…" : "Running… \(run.results.count) so far"
        case .stopped: return "Stopped"
        case .couldNotStart: return "Couldn’t start"
        case .finished(let status):
            if status == 0 { return run.results.isEmpty ? "Finished" : run.passed == 1 ? "Passed" : "All \(run.passed) passed" }
            if run.failed > 0 { return "\(run.failed) failing" }
            return "Failed before the tests ran"
        }
    }

    private var detail: String {
        let seconds = Int(run.duration.rounded())
        let time = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        if case .couldNotStart(let message) = run.state { return message }
        return "\(run.command.label) · \(run.isRunning ? "running for" : "took") \(time) · started \(run.started.formatted(date: .omitted, time: .shortened))"
    }

    private func count(_ value: Int, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(value)").font(.system(size: 18, weight: .medium, design: .monospaced)).foregroundStyle(value > 0 ? color : theme.text3.color)
            Text(label).font(.system(size: 11)).foregroundStyle(theme.text3.color)
        }
    }
}

// MARK: Failures

private struct FailuresCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let run: TestRun
    let runOnly: (([TestResult]) -> Void)?

    var body: some View {
        let failures = run.results.filter { $0.status == .failed }
        Card("Failures", accent: false) {
            if let runOnly, !run.isRunning {
                Button { runOnly(failures) } label: { Label("Re-run", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(DanteButtonStyle())
                    .help(failures.count == 1 ? "Run this test again" : "Run these \(failures.count) tests again")
            }
            Button {
                session.askClaude(prompt(for: failures))
            } label: {
                Label(failures.count == 1 ? "Ask Claude to fix it" : "Ask Claude to fix these", systemImage: "sparkle")
            }
            .buttonStyle(DanteButtonStyle(primary: true))
        } content: {
            RowList(data: failures, padding: 10) { result in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        StatusDot(color: theme.red.color)
                        if !result.suite.isEmpty {
                            Text(result.suite).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.text3.color)
                        }
                        Text(result.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color)
                        Spacer()
                        if let duration = result.duration {
                            Text(String(format: "%.2fs", duration)).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color)
                        }
                        if let runOnly, !run.isRunning {
                            IconButton(symbol: "play.fill", label: "Run \(result.name)", size: 10) { runOnly([result]) }
                        }
                    }
                    ForEach(Array(result.issues.enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(issue.message)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(theme.text.color)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if let file = issue.file {
                                let location = "\((file as NSString).lastPathComponent)\(issue.line.map { ":\($0)" } ?? "")"
                                if let url = resolve(file) {
                                    LinkButton(location) { session.open(file: url) }
                                } else {
                                    Text(location).font(.system(size: 11.5)).foregroundStyle(theme.text3.color)
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
        var lines = ["These tests fail when I run `\(run.command.label)`. Find the cause and propose a fix. If the test is wrong rather than the code, say so before changing it."]
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

// MARK: Suites

private struct SuitesCard: View {
    @Environment(\.theme) private var theme
    let run: TestRun
    let runOnly: (([TestResult]) -> Void)?
    @State private var expanded: Set<String> = []
    @State private var hovered: String?

    private struct Suite: Identifiable {
        let name: String
        let results: [TestResult]
        var id: String { name }
        var failed: Int { results.count { $0.status == .failed } }
    }

    var body: some View {
        let suites = Dictionary(grouping: run.results, by: { $0.suite.isEmpty ? "Tests" : $0.suite })
            .map { Suite(name: $0.key, results: $0.value) }
            .sorted { $0.failed != $1.failed ? $0.failed > $1.failed : $0.name < $1.name }
        Card("Results by suite") {
            Text("\(run.results.count) tests · \(suites.count) suites").font(.system(size: 12)).foregroundStyle(theme.text3.color)
        } content: {
            if suites.isEmpty {
                Text(run.isRunning ? "Waiting for the first result…" : "No test results in the output.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.text3.color)
            }
            RowList(data: suites, padding: 0) { suite in
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        if expanded.contains(suite.id) { expanded.remove(suite.id) } else { expanded.insert(suite.id) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: expanded.contains(suite.id) ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(theme.text3.color)
                                .frame(width: 10)
                            StatusDot(color: suite.failed > 0 ? theme.red.color : theme.green.color, size: 6)
                            Text(suite.name).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(theme.text.color)
                            Spacer()
                            Text(suite.failed > 0 ? "\(suite.failed) of \(suite.results.count) failing" : "\(suite.results.count) passed")
                                .font(.system(size: 12))
                                .foregroundStyle(suite.failed > 0 ? theme.red.color : theme.text3.color)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if expanded.contains(suite.id) {
                        ForEach(suite.results) { result in
                            HStack(spacing: 8) {
                                Image(systemName: symbol(for: result.status))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(color(for: result.status))
                                    .frame(width: 12)
                                Text(result.name).font(.system(size: 12)).foregroundStyle(theme.text2.color).lineLimit(1)
                                Spacer()
                                if let duration = result.duration {
                                    Text(String(format: "%.3fs", duration)).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color)
                                }
                                if let runOnly, !run.isRunning {
                                    IconButton(symbol: "play.fill", label: "Run \(result.name)", size: 9.5) { runOnly([result]) }
                                        .opacity(hovered == result.id ? 1 : 0)
                                }
                            }
                            .padding(.leading, 32)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                            .onHover { hovered = $0 ? result.id : (hovered == result.id ? nil : hovered) }
                        }
                        Spacer().frame(height: 6)
                    }
                }
            }
        }
    }

    private func symbol(for status: TestResult.Status) -> String {
        switch status {
        case .passed: "checkmark"
        case .failed: "xmark"
        case .skipped: "minus"
        }
    }

    private func color(for status: TestResult.Status) -> Color {
        switch status {
        case .passed: theme.green.color
        case .failed: theme.red.color
        case .skipped: theme.text3.color
        }
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
                                    .font(.system(size: 11, design: .monospaced))
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
                Text("\(run.output.count) lines from \(run.command.label)").font(.system(size: 12)).foregroundStyle(theme.text3.color)
            }
        }
    }

    private func lineColor(_ line: String) -> Color {
        if line.contains("error:") || line.hasPrefix("✘") || line.contains("FAIL") { return theme.red.color }
        if line.contains("warning:") { return theme.amber.color }
        return theme.text2.color
    }
}

private struct DraftTestsCard: View {
    @Environment(\.theme) private var theme
    let session: Session

    var body: some View {
        Card("Tests Claude can draft") {
            Text("Claude looks for code and spec rules that no test covers, then proposes tests one file at a time.")
                .font(.system(size: 12))
                .foregroundStyle(theme.text2.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Find untested code") {
                    session.askClaude("Find the most important code paths and spec rules in this project that no test covers. List up to five, with the file and why each matters. Don't write tests yet.")
                }
                .buttonStyle(DanteButtonStyle())
                if let file = session.workspace?.activeDocument {
                    Button("Test the open file") {
                        session.askClaude("Write tests for \(file.url.lastPathComponent), following the project's existing test style. Cover the edge cases, then show me each file before writing it.")
                    }
                    .buttonStyle(DanteButtonStyle())
                }
            }
        }
    }
}
