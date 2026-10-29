import Foundation

/// Writes a `CompanionPlace` from what the Mac keeps for a project. Pure: `CompanionHub`
/// gathers the input (`gather`) and this turns it into numbers and rows.
public enum CompanionPlaces {
    public struct Input: Sendable {
        public var now: Date
        public var project: String
        /// Newest first, the last fortnight.
        public var commits: [ProjectDigest.Commit]
        /// Oldest first, as `TestRunLog` keeps them.
        public var testRuns: [SavedTestRun]
        public var security: SecurityReport?
        public var pipelines: [Briefing.Pipeline]
        /// This project's ledger lines, oldest first.
        public var jobs: [AgentJob]

        public init(now: Date, project: String, commits: [ProjectDigest.Commit] = [], testRuns: [SavedTestRun] = [], security: SecurityReport? = nil,
                    pipelines: [Briefing.Pipeline] = [], jobs: [AgentJob] = []) {
            self.now = now
            self.project = project
            self.commits = commits
            self.testRuns = testRuns
            self.security = security
            self.pipelines = pipelines
            self.jobs = jobs
        }
    }

    /// What the Mac keeps for a project, read without opening it: two weeks of git, the kept
    /// test runs, the saved security report, the pipelines and a month of the agents' ledger.
    public static func gather(project id: String, name: String, root: URL, now: Date = .now) async -> Input {
        let since = now.addingTimeInterval(-14 * 86_400)
        async let log = Shell.run(ProjectDigest.logArguments(since: since), in: root)
        async let ci: [CIRun] = CIRun.hasWorkflows(projectRoot: root) ? ((try? await CIRun.load(projectRoot: root, limit: 30).get()) ?? []) : []
        let runs = TestRunLog.load(for: root)
        let security = SecurityReport.load(for: root)
        let pipelineRuns = PipelineHistory.load(for: root).runs
        let jobs = AgentLedger.standard.jobs(since: now.addingTimeInterval(-30 * 86_400)).filter { $0.project == name }
        let commits = await log.succeeded ? ProjectDigest.parseLog(await log.stdout).sorted { $0.date > $1.date } : []
        let digest = ProjectDigest(id: id, name: name, ci: await ci, pipelines: pipelineRuns)
        let pipelines = BriefingComposer.pipelineList(.init(now: now, projects: [digest]))
        return Input(now: now, project: name, commits: commits, testRuns: runs, security: security, pipelines: pipelines, jobs: jobs)
    }

    public static func make(_ kind: CompanionPlace.Kind, _ input: Input) -> CompanionPlace {
        switch kind {
        case .home: home(input)
        case .tests: tests(input)
        case .security: security(input)
        case .ship: ship(input)
        case .activity: activity(input)
        }
    }

    // MARK: Home

    static func home(_ input: Input) -> CompanionPlace {
        let tiles = [testsTile(input), securityTile(input), changesTile(input), pipelinesTile(input), agentsTile(input)].compactMap { $0 }
        var said: [String] = []
        if let run = lastFullRun(input) {
            said.append(run.failed > 0 ? "\(count(run.failed, "test")) failing" : run.brokeOutsideTests ? "the last test run broke before the tests" : "tests pass")
        }
        if let report = input.security { said.append("security \(report.grade) (\(report.score))") }
        let failing = input.pipelines.filter { $0.status == .bad }
        if !input.pipelines.isEmpty { said.append(failing.isEmpty ? "pipelines passing" : "\(count(failing.count, "pipeline")) failing") }
        let week = commitsThisWeek(input)
        said.append(week == 0 ? "no changes this week" : "\(count(week, "change")) this week")
        let headline = said.isEmpty ? "Nothing recorded yet." : (said.joined(separator: ", ") + ".").capitalizedFirst
        let recent = input.commits.prefix(8).map(commitRow)
        let status = worst(tiles.map(\.status))
        var sections: [CompanionPlace.Section] = []
        if !recent.isEmpty { sections.append(.init(title: "Recent changes", rows: Array(recent), more: max(0, input.commits.count - 8))) }
        let jobs = input.jobs.suffix(5).reversed().map(jobRow)
        if !jobs.isEmpty { sections.append(.init(title: "Agents lately", rows: jobs)) }
        return CompanionPlace(kind: .home, project: input.project, date: input.now, headline: headline, status: status, tiles: tiles,
                              pipelines: Array(input.pipelines.prefix(3)), sections: sections)
    }

    static func testsTile(_ input: Input) -> CompanionPlace.Tile? {
        guard let run = lastFullRun(input) else { return .init(label: "Tests", value: "Not run", detail: "No runs kept on the Mac", opens: .tests) }
        let total = run.passed + run.failed
        if run.brokeOutsideTests, run.failed == 0 {
            return .init(label: "Tests", value: "Broke", detail: "Before the tests ran", status: .bad, opens: .tests)
        }
        return .init(label: "Tests", value: run.failed > 0 ? "\(run.failed) failing" : "\(run.passed) passed",
                     detail: relative(run.date, input.now), status: run.failed > 0 ? .bad : .good,
                     share: total == 0 ? nil : Double(run.passed) / Double(total), opens: .tests)
    }

    static func securityTile(_ input: Input) -> CompanionPlace.Tile? {
        guard let report = input.security else { return .init(label: "Security", value: "Not scanned", opens: .security) }
        let critical = report.count(.critical), high = report.count(.high)
        let detail = critical > 0 ? "\(critical) critical" : high > 0 ? "\(high) high" : "\(count(report.findings.count, "finding"))"
        return .init(label: "Security", value: "\(report.grade) · \(report.score)", detail: detail,
                     status: report.score >= 80 ? .good : report.score >= 50 ? .attention : .bad, share: Double(report.score) / 100, opens: .security)
    }

    static func changesTile(_ input: Input) -> CompanionPlace.Tile? {
        let week = commitsThisWeek(input)
        let authors = Set(input.commits.filter { $0.date > input.now.addingTimeInterval(-7 * 86_400) }.map(\.author)).count
        return .init(label: "Changes", value: "\(week)", detail: week == 0 ? "This week" : "This week · \(count(authors, "person", "people"))", opens: .ship)
    }

    static func pipelinesTile(_ input: Input) -> CompanionPlace.Tile? {
        guard !input.pipelines.isEmpty else { return nil }
        let failing = input.pipelines.filter { $0.status == .bad }.count
        let running = input.pipelines.filter(\.isRunning).count
        return .init(label: "Pipelines", value: failing > 0 ? "\(failing) failing" : "\(input.pipelines.count) passing",
                     detail: running > 0 ? "\(running) running" : nil, status: failing > 0 ? .bad : .good,
                     share: Double(input.pipelines.count - failing) / Double(input.pipelines.count), opens: .ship)
    }

    static func agentsTile(_ input: Input) -> CompanionPlace.Tile? {
        let week = input.jobs.filter { $0.date > input.now.addingTimeInterval(-7 * 86_400) }
        return .init(label: "Agents", value: "\(week.count)", detail: "Jobs this week", opens: .activity)
    }

    // MARK: Tests

    static func tests(_ input: Input) -> CompanionPlace {
        guard let run = lastFullRun(input) ?? input.testRuns.last else {
            return CompanionPlace(kind: .tests, project: input.project, date: input.now,
                                  headline: "No test runs are kept on the Mac for this project yet. Run them in Dante or ask the agent to.", status: .quiet)
        }
        let headline: String
        if run.brokeOutsideTests, run.failed == 0 {
            headline = "The last run didn’t get to the tests: something broke first."
        } else if run.failed > 0 {
            headline = "\(count(run.failed, "test")) failed in the last run, \(relative(run.date, input.now))."
        } else {
            headline = "All \(run.passed) tests passed in the last run, \(relative(run.date, input.now))."
        }
        let tiles: [CompanionPlace.Tile] = [
            .init(label: "Passed", value: "\(run.passed)", status: run.passed > 0 ? .good : .quiet),
            .init(label: "Failed", value: "\(run.failed)", status: run.failed > 0 ? .bad : .quiet),
            .init(label: "Skipped", value: "\(run.skipped)"),
            .init(label: "Took", value: duration(run.duration), detail: run.by.label),
        ]
        var sections: [CompanionPlace.Section] = []
        if run.brokeOutsideTests, !run.tail.isEmpty {
            let why = BrokenRunLines.reason(in: run.tail) ?? "The run failed outside its tests"
            sections.append(.init(title: "Why it broke", rows: [.init(id: "broke", title: why, detail: run.command, status: .bad,
                                                                  expanded: run.tail.suffix(30).joined(separator: "\n"), monospaced: true)]))
        }
        let failures = run.results.filter { $0.status == .failed }
        if !failures.isEmpty {
            sections.append(.init(title: "Failing", rows: failures.prefix(40).map { result in
                let issue = result.issues.first
                let place = issue?.file.map { ($0 as NSString).lastPathComponent + (issue?.line.map { ":\($0)" } ?? "") }
                return .init(id: result.id, title: result.name, detail: [result.suite, place].compactMap { $0 }.joined(separator: " · "),
                             status: .bad, expanded: result.issues.map(\.message).joined(separator: "\n\n"), monospaced: true)
            }, more: max(0, failures.count - 40)))
        }
        let slow = run.results.filter { ($0.duration ?? 0) >= 1 }.sorted { ($0.duration ?? 0) > ($1.duration ?? 0) }
        if !slow.isEmpty {
            sections.append(.init(title: "Slowest", rows: slow.prefix(8).map {
                .init(id: "slow" + $0.id, title: $0.name, detail: $0.suite, trailing: duration($0.duration ?? 0))
            }))
        }
        let runs = input.testRuns.suffix(10).reversed().map { saved in
            CompanionPlace.Row(id: saved.id, title: saved.failed > 0 ? "\(saved.failed) failed, \(saved.passed) passed"
                                : saved.brokeOutsideTests ? "Broke outside the tests" : "\(saved.passed) passed",
                               detail: "\(saved.by.label) · \(saved.command)", trailing: duration(saved.duration),
                               status: saved.failed > 0 || saved.brokeOutsideTests ? .bad : .good, time: saved.date)
        }
        sections.append(.init(title: "Runs", rows: Array(runs)))
        return CompanionPlace(kind: .tests, project: input.project, date: input.now, headline: headline,
                              status: run.failed > 0 || run.brokeOutsideTests ? .bad : .good, tiles: tiles, sections: sections)
    }

    // MARK: Security

    static func security(_ input: Input) -> CompanionPlace {
        guard let report = input.security else {
            return CompanionPlace(kind: .security, project: input.project, date: input.now,
                                  headline: "This project hasn’t been scanned on the Mac yet. Open Security there and press Scan.", status: .quiet)
        }
        let open = report.findings
        let headline = open.isEmpty ? "Nothing open: graded \(report.grade), scanned \(relative(report.date, input.now))."
            : "Graded \(report.grade) (\(report.score)) with \(count(open.count, "open finding")), scanned \(relative(report.date, input.now))."
        let tiles: [CompanionPlace.Tile] = [
            .init(label: "Score", value: "\(report.grade) · \(report.score)", status: report.score >= 80 ? .good : report.score >= 50 ? .attention : .bad,
                  share: Double(report.score) / 100),
            .init(label: "Critical", value: "\(report.count(.critical))", status: report.count(.critical) > 0 ? .bad : .quiet),
            .init(label: "High", value: "\(report.count(.high))", status: report.count(.high) > 0 ? .attention : .quiet),
            .init(label: "Medium and low", value: "\(report.count(.medium) + report.count(.low))"),
        ]
        var sections: [CompanionPlace.Section] = []
        for severity in [SecurityFinding.Severity.critical, .high, .medium, .low] {
            let found = open.filter { $0.severity == severity }
            guard !found.isEmpty else { continue }
            sections.append(.init(title: severity.title, rows: found.prefix(25).map { finding in
                .init(id: finding.id, title: finding.title, detail: finding.file.isEmpty ? finding.category.title : finding.file + (finding.line > 0 ? ":\(finding.line)" : ""),
                      trailing: finding.category.title, status: severity == .critical ? .bad : severity == .high ? .attention : .quiet,
                      expanded: [finding.why, finding.fix.isEmpty ? nil : "Fix: " + finding.fix].compactMap { $0 }.joined(separator: "\n\n"))
            }, more: max(0, found.count - 25)))
        }
        if !report.aside.isEmpty {
            sections.append(.init(title: "In tests and docs (not graded)", rows: [], more: report.aside.count))
        }
        return CompanionPlace(kind: .security, project: input.project, date: input.now, headline: headline,
                              status: tiles[0].status, tiles: tiles, sections: sections)
    }

    // MARK: Ship

    static func ship(_ input: Input) -> CompanionPlace {
        let failing = input.pipelines.filter { $0.status == .bad }
        var said: [String] = []
        if !input.pipelines.isEmpty {
            said.append(failing.isEmpty ? "Every pipeline’s last run passed" : "\(list(failing.prefix(2).map(\.name))) failed")
        }
        let week = commitsThisWeek(input)
        said.append(week == 0 ? "no changes this week" : "\(count(week, "change")) this week")
        let headline = said.joined(separator: "; ").capitalizedFirst + "."
        let tiles: [CompanionPlace.Tile] = [pipelinesTile(input), changesTile(input)].compactMap { $0 }.map { var tile = $0; tile.opens = nil; return tile }
        let byAuthor = Dictionary(grouping: input.commits, by: \.author).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        var sections = [CompanionPlace.Section(title: "Changes", rows: input.commits.prefix(30).map(commitRow), more: max(0, input.commits.count - 30))]
        if byAuthor.count > 1 {
            sections.append(.init(title: "Who changed it", rows: byAuthor.prefix(8).map { .init(id: "author" + $0.0, title: $0.0, trailing: count($0.1, "change")) }))
        }
        return CompanionPlace(kind: .ship, project: input.project, date: input.now, headline: headline,
                              status: failing.isEmpty ? (input.pipelines.isEmpty ? .quiet : .good) : .bad, tiles: tiles,
                              pipelines: input.pipelines, sections: sections)
    }

    // MARK: Activity

    static func activity(_ input: Input) -> CompanionPlace {
        let week = input.jobs.filter { $0.date > input.now.addingTimeInterval(-7 * 86_400) }
        let models = Dictionary(grouping: week) { $0.model }.map { ($0.key, $0.value) }.sorted { $0.1.count > $1.1.count }
        let headline = week.isEmpty ? "No agent work recorded for this project this week."
            : "\(count(week.count, "job")) this week, most by \(models.first.map { $0.0 } ?? "the agents")."
        let failed = week.filter { $0.outcome == .failed }.count
        let minutes = week.reduce(0) { $0 + $1.seconds } / 60
        let tiles: [CompanionPlace.Tile] = [
            .init(label: "Jobs", value: "\(week.count)", detail: "This week"),
            .init(label: "Working time", value: minutes < 60 ? "\(Int(minutes.rounded())) min" : String(format: "%.1f h", minutes / 60)),
            .init(label: "Failed", value: "\(failed)", status: failed > 0 ? .attention : .quiet),
            .init(label: "Models", value: "\(models.count)", detail: models.prefix(2).map(\.0).joined(separator: ", ")),
        ]
        var sections = [CompanionPlace.Section(title: "Recent work", rows: input.jobs.suffix(30).reversed().map(jobRow))]
        if !models.isEmpty {
            sections.append(.init(title: "By model", rows: models.prefix(8).map { .init(id: "model" + $0.0, title: $0.0, trailing: count($0.1.count, "job")) }))
        }
        return CompanionPlace(kind: .activity, project: input.project, date: input.now, headline: headline,
                              status: failed > 0 ? .attention : .quiet, tiles: tiles, sections: sections)
    }

    // MARK: Pieces

    static func lastFullRun(_ input: Input) -> SavedTestRun? {
        input.testRuns.last { !$0.narrowed }
    }

    static func commitsThisWeek(_ input: Input) -> Int {
        input.commits.filter { $0.date > input.now.addingTimeInterval(-7 * 86_400) }.count
    }

    static func commitRow(_ commit: ProjectDigest.Commit) -> CompanionPlace.Row {
        .init(id: commit.hash, title: commit.subject, detail: "\(commit.author) · \(commit.hash.prefix(7))", time: commit.date)
    }

    static func jobRow(_ job: AgentJob) -> CompanionPlace.Row {
        .init(id: job.id.uuidString, title: job.title.isEmpty ? job.kind.capitalized : job.title,
              detail: [job.model, job.kind].filter { !$0.isEmpty }.joined(separator: " · "),
              trailing: job.seconds >= 1 ? duration(job.seconds) : nil, status: job.outcome == .failed ? .attention : .quiet,
              time: job.date, expanded: [job.why, job.gist].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n").nilIfEmpty)
    }

    static func worst(_ statuses: [Briefing.Status]) -> Briefing.Status {
        if statuses.contains(.bad) { return .bad }
        if statuses.contains(.attention) { return .attention }
        return statuses.contains(.good) ? .good : .quiet
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let minutes = Int(seconds) / 60
        return minutes < 60 ? "\(minutes) min \(Int(seconds) % 60) s" : "\(minutes / 60) h \(minutes % 60) min"
    }

    static func relative(_ date: Date, _ now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func count(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n) \(n == 1 ? one : many ?? one + "s")"
    }

    static func list(_ names: [String]) -> String {
        names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
