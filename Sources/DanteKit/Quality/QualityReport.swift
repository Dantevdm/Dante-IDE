import Foundation

/// Quality › Report: the project graded A to E on tests, security, review and coverage, each
/// for all the code and for new code (this branch's changes, or the last 30 days on the main
/// branch), and a quality gate that passes or fails on conditions like SonarQube's. Pure: the
/// page gathers the inputs.
public struct QualityReport: Equatable, Sendable {
    public enum Rating: String, CaseIterable, Comparable, Sendable {
        case a = "A", b = "B", c = "C", d = "D", e = "E"

        public static func < (lhs: Rating, rhs: Rating) -> Bool { lhs.rawValue < rhs.rawValue }

        /// A fraction where more is better, cut at the given lower bounds for A to D.
        public static func from(_ fraction: Double, cuts: (a: Double, b: Double, c: Double, d: Double)) -> Rating {
            fraction >= cuts.a ? .a : fraction >= cuts.b ? .b : fraction >= cuts.c ? .c : fraction >= cuts.d ? .d : .e
        }
    }

    public enum MeasureID: String, CaseIterable, Sendable {
        case tests, security, review, coverage

        public var title: String {
            switch self {
            case .tests: "Tests"
            case .security: "Security"
            case .review: "Review"
            case .coverage: "Coverage"
            }
        }
    }

    /// One measure for some code: its letter (nil when there's nothing to grade), the
    /// figure that drives it ("3 failing"), what that's out of, and the rule behind the letter.
    public struct Grade: Equatable, Sendable {
        public var rating: Rating?
        public var value: String
        public var detail: String
        public var why: String
    }

    public struct Measure: Equatable, Sendable, Identifiable {
        public var id: MeasureID
        public var all: Grade
        public var new: Grade
    }

    public struct Condition: Equatable, Sendable, Identifiable {
        public var title: String
        /// nil when there's nothing to judge it by yet (no test results, never scanned).
        public var passed: Bool?
        public var actual: String
        public var id: String { title }
    }

    /// Security findings of one severity, in all the code and in new code.
    public struct SeverityRow: Equatable, Sendable, Identifiable {
        public var severity: SecurityFinding.Severity
        public var all: Int
        public var new: Int
        public var id: String { severity.rawValue }
    }

    public var measures: [Measure]
    public var conditions: [Condition]
    public var severities: [SeverityRow]
    /// Lines covered of lines measured, when a coverage report is there.
    public var coverage: CoverageReport.Lines?
    /// Tests passing of tests that have a result.
    public var testsPassed: Int
    public var testsWithResult: Int
    public var testsWritten: Int
    /// What new code means here: "this branch" or "the last 30 days".
    public var newCodeMeans: String
    public var changedFiles: Int

    public enum Gate: Equatable, Sendable { case passed, failed, incomplete }

    /// Failed when any condition fails; incomplete when one can't be judged yet.
    public var gate: Gate {
        if conditions.contains(where: { $0.passed == false }) { return .failed }
        return conditions.contains { $0.passed == nil } ? .incomplete : .passed
    }

    public var gatePassed: Bool { gate == .passed }

    public func measure(_ id: MeasureID) -> Measure? { measures.first { $0.id == id } }

    // MARK: Grading

    /// - Parameters:
    ///   - tests: the Tests page's map, nil before the code has been read.
    ///   - newTests: ids of the tests that go with the changed files (`TestImpact`).
    ///   - review: Review's coverage with project paths, nil when it isn't loaded.
    ///   - reviewInUse: whether anyone has marked a file yet; until then review isn't a gate condition.
    ///   - changed: project paths changed in new code.
    ///   - runBroke: the latest run failed outside the tests (a package that doesn't build, a setup step).
    public static func make(tests: TestMap?, newTests: Set<String>, security: SecurityReport?, review: CodeReview.Coverage?,
                            reviewInUse: Bool, coverage: CoverageReport?, changed: Set<String>, newCodeMeans: String,
                            runBroke: Bool = false) -> QualityReport {
        let tiles = tests?.tiles ?? []
        let newTiles = tiles.filter { newTests.contains($0.id) || changed.contains($0.test.file) }
        let findings = security?.findings ?? []
        let newFindings = findings.filter { changed.contains($0.file) }
        let files = review?.files ?? []
        let newFiles = files.filter { changed.contains($0.path) }
        let covered = coverage?.files ?? [:]
        let newCovered = covered.filter { changed.contains($0.key) }

        let measures = [
            Measure(id: .tests, all: grade(tests: tiles, runBroke: runBroke), new: grade(tests: newTiles)),
            Measure(id: .security, all: grade(security: findings, scanned: security != nil), new: grade(security: newFindings, scanned: security != nil)),
            Measure(id: .review, all: grade(review: files, loaded: review != nil, inUse: reviewInUse),
                    new: grade(review: newFiles, loaded: review != nil, inUse: reviewInUse)),
            Measure(id: .coverage, all: grade(coverage: Array(covered.values), measured: coverage != nil),
                    new: grade(coverage: Array(newCovered.values), measured: coverage != nil)),
        ]

        var conditions: [Condition] = []
        let failing = tiles.count { $0.state == .failed }
        let results = tiles.count { $0.state != .notRun }
        conditions.append(Condition(title: "No failing tests", passed: runBroke ? false : results == 0 ? nil : failing == 0,
                                    actual: failing > 0 ? "\(failing) failing" : runBroke ? "the last run failed outside them"
                                        : results == 0 ? "none run yet" : "none failing"))
        let serious = newFindings.count { $0.severity >= .high }
        conditions.append(Condition(title: "No new high or critical security findings", passed: security == nil ? nil : serious == 0,
                                    actual: security == nil ? "not scanned" : serious == 0 ? "none" : "\(serious) in new code"))
        if reviewInUse, !newFiles.isEmpty {
            let unread = newFiles.count { $0.state != .reviewed }
            conditions.append(Condition(title: "Changed files reviewed", passed: unread == 0,
                                        actual: unread == 0 ? "all \(newFiles.count)" : "\(unread) of \(newFiles.count) not reviewed"))
        }
        if coverage != nil, !newCovered.isEmpty {
            let lines = sum(Array(newCovered.values))
            conditions.append(Condition(title: "Coverage on new code at least 80%", passed: lines.fraction >= 0.8, actual: percent(lines.fraction)))
        }

        let severities = SecurityFinding.Severity.allCases.filter { $0 != .info }.map { severity in
            SeverityRow(severity: severity, all: findings.count { $0.severity == severity }, new: newFindings.count { $0.severity == severity })
        }
        let withResult = tiles.filter { $0.state != .notRun && $0.state != .skipped }
        return QualityReport(measures: measures, conditions: conditions, severities: severities,
                             coverage: coverage.map { sum(Array($0.files.values)) },
                             testsPassed: withResult.count { $0.state == .passed || $0.state == .flaky },
                             testsWithResult: withResult.count, testsWritten: tiles.count,
                             newCodeMeans: newCodeMeans, changedFiles: changed.count)
    }

    /// E with more than a tenth failing, D with any failing, C when flaky or when most never
    /// ran, B when some never ran or changed since their run, A otherwise. A run that broke
    /// outside the tests is at best D: something around them doesn't work.
    static func grade(tests tiles: [TestMap.Tile], runBroke: Bool = false) -> Grade {
        guard !tiles.isEmpty else { return Grade(rating: nil, value: "No tests", detail: "", why: "No tests are written for this code.") }
        let failing = tiles.count { $0.state == .failed }
        let flaky = tiles.count { $0.state == .flaky || $0.flaky }
        let notRun = tiles.count { $0.state == .notRun }
        let stale = tiles.count { $0.stale && $0.state != .notRun }
        let total = tiles.count
        if notRun == total {
            return Grade(rating: nil, value: "Not run", detail: "\(total) test\(total == 1 ? "" : "s") written", why: "None of these tests has a result on this Mac yet.")
        }
        let rating: Rating
        let why: String
        if Double(failing) > Double(total) * 0.1 { rating = .e; why = "More than a tenth of the tests fail." }
        else if failing > 0 { rating = .d; why = "Some tests fail." }
        else if runBroke { rating = .d; why = "The latest run failed outside the tests: a package that doesn’t build, or a setup step." }
        else if flaky > 0 { rating = .c; why = "Nothing fails, but some tests are flaky." }
        else if Double(notRun) > Double(total) * 0.5 { rating = .c; why = "Most of the tests haven’t been run on this Mac." }
        else if notRun > 0 || stale > 0 { rating = .b; why = "Everything that ran passed; some tests haven’t run, or their code changed since." }
        else { rating = .a; why = "Every test passed on its latest run." }
        let value = failing > 0 ? "\(failing) failing" : runBroke ? "Run failed" : flaky > 0 ? "\(flaky) flaky" : notRun == total ? "Not run" : "\(total - notRun) passing"
        return Grade(rating: rating, value: value, detail: "of \(total) test\(total == 1 ? "" : "s")", why: why)
    }

    /// Graded by the worst finding, like SonarQube's security rating: E critical, D high,
    /// C medium, B low, A none.
    static func grade(security findings: [SecurityFinding], scanned: Bool) -> Grade {
        guard scanned else { return Grade(rating: nil, value: "Not scanned", detail: "", why: "Open Security to scan the code.") }
        let worst = findings.map(\.severity).filter { $0 != .info }.max()
        let rating: Rating = switch worst {
        case .critical: .e
        case .high: .d
        case .medium: .c
        case .low: .b
        default: .a
        }
        let counted = findings.count { $0.severity != .info }
        let serious = findings.count { $0.severity >= .high }
        let why = worst.map { "The worst finding is \($0.title.lowercased())." } ?? "No findings."
        return Grade(rating: rating, value: serious > 0 ? "\(serious) serious" : counted == 0 ? "None" : "\(counted) finding\(counted == 1 ? "" : "s")",
                     detail: serious > 0 ? "\(counted) finding\(counted == 1 ? "" : "s") in all" : counted == 0 ? "found" : "none serious", why: why)
    }

    /// The share of files read as they are now: A 90%, B 75%, C 50%, D 25%. A concern on a
    /// file holds it at C at best.
    static func grade(review files: [CodeReview.FileReview], loaded: Bool, inUse: Bool = true) -> Grade {
        guard loaded else { return Grade(rating: nil, value: "—", detail: "", why: "Review hasn’t loaded.") }
        guard inUse else { return Grade(rating: nil, value: "Not started", detail: "", why: "Nobody has marked a file in Review yet.") }
        guard !files.isEmpty else { return Grade(rating: nil, value: "No files", detail: "", why: "No code files changed here.") }
        let reviewed = files.count { $0.state == .reviewed }
        let fraction = Double(reviewed) / Double(files.count)
        var rating = Rating.from(fraction, cuts: (0.9, 0.75, 0.5, 0.25))
        let concerns = files.count { $0.state == .concern }
        if concerns > 0 { rating = max(rating, .c) }
        let why = concerns > 0 ? "\(concerns) file\(concerns == 1 ? " has" : "s have") a concern raised." : "\(percent(fraction)) of the files have been read as they are now."
        return Grade(rating: rating, value: percent(fraction), detail: "\(reviewed) of \(files.count) files reviewed", why: why)
    }

    /// Lines covered: A 80%, B 70%, C 50%, D 30%.
    static func grade(coverage files: [CoverageReport.Lines], measured: Bool) -> Grade {
        guard measured else { return Grade(rating: nil, value: "Not measured", detail: "", why: "No coverage report was found; run the tests with coverage on.") }
        let lines = sum(files)
        guard lines.total > 0 else { return Grade(rating: nil, value: "—", detail: "", why: "The coverage report covers none of this code.") }
        return Grade(rating: Rating.from(lines.fraction, cuts: (0.8, 0.7, 0.5, 0.3)), value: percent(lines.fraction),
                     detail: "\(lines.covered) of \(lines.total) lines", why: "\(percent(lines.fraction)) of the measured lines run in a test.")
    }

    static func sum(_ files: [CoverageReport.Lines]) -> CoverageReport.Lines {
        files.reduce(CoverageReport.Lines(covered: 0, total: 0)) { CoverageReport.Lines(covered: $0.covered + $1.covered, total: $0.total + $1.total) }
    }

    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
}

// MARK: New code

/// What counts as new code: on a branch, everything it changed since it left the main branch
/// (and the working tree's changes); on the main branch itself, the last 30 days.
public struct NewCode: Equatable, Sendable {
    /// Repository paths.
    public var files: Set<String>
    public var means: String

    public static func load(in repo: URL) async -> NewCode {
        let branch = await Shell.run(["git", "rev-parse", "--abbrev-ref", "HEAD"], in: repo).stdout
        let working = await Shell.run(["git", "status", "--porcelain", "-z", "--untracked-files=all"], in: repo, trimming: false).stdout
        var files = Set(GitStatus.parse(working).changes.map(\.path))
        let bases = ["origin/HEAD", "origin/main", "origin/master", "main", "master", "develop"]
        var base: String?
        for candidate in bases where await Shell.run(["git", "rev-parse", "--verify", "--quiet", candidate], in: repo).succeeded {
            base = candidate
            break
        }
        let onMain = base.map { candidate in
            ["main", "master", "develop"].contains(branch) || candidate.hasSuffix("/\(branch)")
        } ?? true
        if let base, !onMain {
            let diff = await Shell.run(["git", "diff", "--name-only", "\(base)...HEAD"], in: repo).stdout
            files.formUnion(lines(diff))
            return NewCode(files: files, means: "this branch")
        }
        let log = await Shell.run(["git", "log", "--since=30.days", "--name-only", "--format="], in: repo).stdout
        files.formUnion(lines(log))
        return NewCode(files: files, means: "the last 30 days")
    }

    static func lines(_ output: String) -> [String] {
        output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
