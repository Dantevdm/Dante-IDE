import AppKit
import DanteKit
import SwiftUI
import UniformTypeIdentifiers

/// Quality › Report: an executive report in SonarQube's manner. The quality gate, then Tests,
/// Security, Review and Coverage graded A to E for all the code with a tinted box for new
/// code, then security findings by severity and rings for coverage and tests. Export PDF
/// writes the same report as a page to hand on.
struct QualityReportView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    @State private var report: QualityReport?
    @State private var loading = false
    @State private var exportProblem: String?

    var body: some View {
        AreaPage(eyebrow: nil, title: "Report", subtitle: nil) {
            if let exportProblem { Text(exportProblem).font(.dante(size: 12)).foregroundStyle(theme.red.color) }
            if loading { ProgressView().controlSize(.small) }
            Button { Task { await load() } } label: { Label("Check again", systemImage: "arrow.clockwise") }
                .buttonStyle(DanteButtonStyle())
                .disabled(loading)
            Button { export() } label: { Label("Export PDF", systemImage: "square.and.arrow.up") }
                .buttonStyle(DanteButtonStyle(primary: true))
                .disabled(report == nil)
                .help("Save the report as a one-page PDF")
        } content: {
            if let report {
                QualityReportContent(report: report, facts: facts, animated: true, open: { session.area = $0 })
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task(id: workspace.revision) { await load() }
    }

    private var facts: QualityReportContent.Facts {
        QualityReportContent.Facts(project: workspace.name, branch: session.git.status?.branch ?? Git.currentBranch(in: workspace.git.root) ?? "no branch",
                                   codeFiles: workspace.files.count { CodeReview.isCode($0) },
                                   languages: HomePulse.languages(workspace.files).map(\.name), date: Date())
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let root = workspace.url, files = workspace.files, location = workspace.git
        if session.security.report == nil { session.security.loadSaved(root: root) }
        await session.review.load(root: location.root, revision: workspace.revision)
        let runs = TestRunLog.load(for: root)
        let (inventory, coverage) = await Task.detached(priority: .utility) {
            let suites = TestSuites.find(files: files) { try? String(contentsOf: root.appending(path: $0), encoding: .utf8) }
            return (TestInventory.load(root: root, files: files, suites: suites), CoverageReport.load(root: root, files: files))
        }.value
        let newCode = await NewCode.load(in: location.root)
        let changed = Set(newCode.files.map(location.projectPath))
        let map = TestMap.build(inventory: inventory, runs: runs)
        let newTests = Set(TestImpact.tests(for: Array(changed), in: inventory).map(\.id))
        // Review's paths are the repository's; the report speaks in the project's.
        let review = session.review.coverage.map { coverage in
            var copy = coverage
            copy.files = coverage.files.map { var file = $0; file.path = location.projectPath($0.path); return file }
            return copy
        }
        let inUse = review?.files.contains { !$0.current.isEmpty || !$0.stale.isEmpty } ?? false
        withAnimation(.easeOut(duration: 0.3)) {
            report = QualityReport.make(tests: inventory.tests.isEmpty ? nil : map, newTests: newTests, security: session.security.report,
                                        review: review, reviewInUse: inUse, coverage: coverage, changed: changed, newCodeMeans: newCode.means,
                                        runBroke: runs.last?.brokeOutsideTests == true)
        }
    }

    private func export() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(workspace.name) quality report.pdf"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let page = QualityReportContent(report: report, facts: facts, animated: false, open: nil)
            .padding(28)
            .frame(width: 900)
            .background(theme.ground.color)
            .environment(\.theme, theme)
            .environment(\.colorScheme, theme.colorScheme)
        let renderer = ImageRenderer(content: page)
        let data = NSMutableData()
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
        }
        do {
            try (data as Data).write(to: destination, options: .atomic)
            exportProblem = nil
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            exportProblem = "Couldn’t save the PDF: \(error.localizedDescription)"
        }
    }
}

/// The report itself, shared by the page and its PDF.
struct QualityReportContent: View {
    @Environment(\.theme) private var theme
    let report: QualityReport
    let facts: Facts
    let animated: Bool
    let open: ((Area) -> Void)?
    @State private var shown = false

    struct Facts {
        var project: String
        var branch: String
        var codeFiles: Int
        var languages: [String]
        var date: Date
    }

    private var drawn: Bool { shown || !animated }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(QualityReport.MeasureID.allCases.enumerated()), id: \.element) { index, id in
                    if let measure = report.measure(id) {
                        RatingCard(measure: measure, newCodeMeans: report.newCodeMeans, drawn: drawn, delay: Double(index) * 0.08,
                                   open: open.map { open in { open(Self.area(id)) } })
                    }
                }
            }
            HStack(alignment: .top, spacing: 14) {
                severityCard
                ringCard(title: "Coverage", fraction: report.coverage.map(\.fraction),
                         value: report.coverage.map { "\($0.covered) of \($0.total) lines" } ?? "No coverage report found",
                         note: "On new code: \(report.measure(.coverage)?.new.value ?? "—")", area: .tests)
                ringCard(title: "Tests passing", fraction: report.testsWithResult == 0 ? nil : Double(report.testsPassed) / Double(report.testsWithResult),
                         value: "\(report.testsPassed) of \(report.testsWithResult) with a result",
                         note: "\(report.testsWritten) written", area: .tests)
            }
        }
        .onAppear {
            guard animated else { return }
            withAnimation(.spring(response: 0.7, dampingFraction: 0.75)) { shown = true }
        }
    }

    static func area(_ id: QualityReport.MeasureID) -> Area {
        switch id {
        case .tests, .coverage: .tests
        case .security: .security
        case .review: .review
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 28) {
            fact("Project", facts.project, big: false)
            fact("Branch", facts.branch, big: false, symbol: "arrow.triangle.branch")
            fact("Checked", facts.date.formatted(date: .abbreviated, time: .shortened), big: false)
            VStack(alignment: .leading, spacing: 4) {
                Text("Code files").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                Text("\(facts.codeFiles)").font(.dante(size: 26, weight: .semibold).monospacedDigit()).foregroundStyle(theme.text.color)
                if !facts.languages.isEmpty {
                    Text(facts.languages.joined(separator: " · ")).font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                }
            }
            Spacer(minLength: 12)
            gate
        }
            Rectangle().fill(theme.line.color).frame(height: 1)
            conditions
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line.color))
    }

    private func fact(_ label: String, _ value: String, big: Bool, symbol: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.dante(size: 11)).foregroundStyle(theme.text3.color)
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.dante(size: 11)).foregroundStyle(theme.text3.color) }
                Text(value).font(.dante(size: 14, weight: .medium)).foregroundStyle(theme.text.color).lineLimit(1)
            }
        }
    }

    private var gate: some View {
        let (label, color): (String, Color) = switch report.gate {
        case .passed: ("PASSED", theme.green.color)
        case .failed: ("FAILED", theme.red.color)
        case .incomplete: ("INCOMPLETE", theme.amber.color)
        }
        return VStack(alignment: .trailing, spacing: 8) {
            Text("Quality gate").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
            Text(label)
                .font(.dante(size: 13, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(theme.onAccent.color)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(color))
                .scaleEffect(drawn ? 1 : 0.6)
                .opacity(drawn ? 1 : 0)
                .help(report.gate == .incomplete ? "Nothing fails, but some conditions can’t be judged yet: run the tests or scan the code." : "")
        }
    }

    /// The gate's conditions in a row under the facts, each with its verdict.
    private var conditions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10, alignment: .topLeading)], alignment: .leading, spacing: 8) {
            ForEach(report.conditions) { condition in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: condition.passed.map { $0 ? "checkmark.circle.fill" : "xmark.circle.fill" } ?? "questionmark.circle.fill")
                        .font(.dante(size: 13))
                        .foregroundStyle(condition.passed.map { $0 ? theme.green.color : theme.red.color } ?? theme.amber.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(condition.title).font(.dante(size: 12, weight: .medium)).foregroundStyle(theme.text.color)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(condition.actual).font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Severities

    private var severityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Security findings by severity").font(.dante(size: 14, weight: .semibold)).foregroundStyle(theme.text.color)
            HStack {
                Spacer().frame(width: 92)
                Text("All code").frame(maxWidth: .infinity)
                Text("New code").frame(maxWidth: .infinity)
            }
            .font(.dante(size: 11)).foregroundStyle(theme.text3.color)
            ForEach(Array(report.severities.enumerated()), id: \.element.id) { index, row in
                let tint = Self.tint(row.severity, theme: theme)
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: Self.symbol(row.severity)).foregroundStyle(tint)
                        Text(row.severity.title).font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                    }
                    .frame(width: 92, alignment: .leading)
                    Text("\(row.all)").frame(maxWidth: .infinity)
                    Text("\(row.new)").frame(maxWidth: .infinity)
                }
                .font(.dante(size: 14, weight: row.all > 0 ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(row.all > 0 ? theme.text.color : theme.text3.color)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(row.all > 0 ? 0.14 : 0.05)))
                .opacity(drawn ? 1 : 0)
                .offset(x: drawn ? 0 : -12)
                .animation(.easeOut(duration: 0.4).delay(animated ? 0.25 + Double(index) * 0.06 : 0), value: drawn)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line.color))
        .onTapGesture { open?(.security) }
    }

    static func tint(_ severity: SecurityFinding.Severity, theme: Theme) -> Color {
        switch severity {
        case .critical, .high: theme.red.color
        case .medium: theme.amber.color
        case .low: theme.green.color
        case .info: theme.accent.color
        }
    }

    static func symbol(_ severity: SecurityFinding.Severity) -> String {
        switch severity {
        case .critical: "exclamationmark.octagon.fill"
        case .high: "arrow.up.circle.fill"
        case .medium: "chevron.up.circle.fill"
        case .low: "arrow.down.circle.fill"
        case .info: "info.circle.fill"
        }
    }

    // MARK: Rings

    private func ringCard(title: String, fraction: Double?, value: String, note: String, area: Area) -> some View {
        let rating = fraction.map { QualityReport.Rating.from($0, cuts: (0.8, 0.7, 0.5, 0.3)) }
        let color = rating.map { RatingBadge.color($0, theme: theme) } ?? theme.text3.color
        return VStack(spacing: 10) {
            Text(title).font(.dante(size: 14, weight: .semibold)).foregroundStyle(theme.text.color)
            ZStack {
                Circle().stroke(theme.track.color, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: drawn ? (fraction ?? 0) : 0)
                    .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: animated ? 1.1 : 0).delay(animated ? 0.3 : 0), value: drawn)
                Text(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(.dante(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.text.color)
            }
            .frame(width: 104, height: 104)
            Text(value).font(.dante(size: 11.5)).foregroundStyle(theme.text2.color).multilineTextAlignment(.center)
            Text(note)
                .font(.dante(size: 11.5)).foregroundStyle(theme.amber.color)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.amber.color.opacity(0.1)))
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line.color))
        .onTapGesture { open?(area) }
    }
}

/// One measure: its letter, the figure behind it, and a tinted box for new code.
private struct RatingCard: View {
    @Environment(\.theme) private var theme
    let measure: QualityReport.Measure
    let newCodeMeans: String
    let drawn: Bool
    let delay: Double
    let open: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            Text(measure.id.title).font(.dante(size: 15, weight: .semibold)).foregroundStyle(theme.text2.color)
            RatingBadge(rating: measure.all.rating, size: 72, drawn: drawn, delay: delay)
                .help(measure.all.why)
            Text(measure.all.value)
                .font(.dante(size: 24, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.text.color)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(measure.all.detail).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            Spacer(minLength: 4)
            VStack(spacing: 5) {
                Text("On new code").font(.dante(size: 11)).foregroundStyle(theme.amber.color)
                HStack(spacing: 8) {
                    RatingBadge(rating: measure.new.rating, size: 30, drawn: drawn, delay: delay + 0.15)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(measure.new.value).font(.dante(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(theme.text.color)
                        if !measure.new.detail.isEmpty {
                            Text(measure.new.detail).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.amber.color.opacity(0.1)))
            .help("New code is \(newCodeMeans). \(measure.new.why)")
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 280)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hovering && open != nil ? theme.accentLine.color : theme.line.color))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { open?() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(measure.id.title): \(measure.all.rating?.rawValue ?? "not graded"), \(measure.all.value)")
    }
}

/// A letter in a filled circle, A green to E red, drawn in with a ring.
struct RatingBadge: View {
    @Environment(\.theme) private var theme
    let rating: QualityReport.Rating?
    let size: CGFloat
    var drawn = true
    var delay: Double = 0

    static func color(_ rating: QualityReport.Rating, theme: Theme) -> Color {
        switch rating {
        case .a: theme.green.color
        case .b: theme.green.color.mix(with: theme.amber.color, by: 0.45)
        case .c: theme.amber.color
        case .d: theme.amber.color.mix(with: theme.red.color, by: 0.55)
        case .e: theme.red.color
        }
    }

    var body: some View {
        let color = rating.map { Self.color($0, theme: theme) } ?? theme.text3.color
        ZStack {
            Circle().fill(rating == nil ? theme.track.color : color)
            Circle()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(color.opacity(0.35), lineWidth: max(2, size / 14))
                .rotationEffect(.degrees(-90))
                .padding(-size / 10)
            Text(rating?.rawValue ?? "–")
                .font(.dante(size: size * 0.5, weight: .medium))
                .foregroundStyle(rating == nil ? theme.text3.color : theme.onAccent.color)
        }
        .frame(width: size, height: size)
        .padding(size / 10)
        .scaleEffect(drawn ? 1 : 0.4)
        .opacity(drawn ? 1 : 0)
        .animation(.spring(response: 0.55, dampingFraction: 0.6).delay(delay), value: drawn)
    }
}
