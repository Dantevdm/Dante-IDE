import DanteKit
import SwiftUI

/// Security: Dante's scanner and any installed ones, a grade, findings explained, fixes by
/// the agent in charge with the other checking, and a deep audit that reads the code.
struct SecurityView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    @State private var category: SecurityFinding.Category?
    @State private var showsLow = true
    @State private var expanded: Set<String> = []
    @State private var limit = 120
    @State private var tools: [(tool: SecurityTool, path: String?)] = []

    private var model: SecurityModel { session.security }
    private var lead: AgentEngine { session.claude?.engine ?? .claude }

    var body: some View {
        AreaPage(eyebrow: nil, title: "Security", subtitle: nil) {
            Button {
                Task { await model.scan(root: workspace.url, files: workspace.files) }
            } label: {
                Label(model.scanning ? "Scanning…" : "Scan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(DanteButtonStyle(primary: model.report == nil))
            .disabled(model.scanning)
            .keyboardShortcut("r", modifiers: [.command, .shift])
        } content: {
            hero
            if let overall = model.auditOverall {
                Card("What the audit says", accent: true) {
                    Text(overall).font(.dante(size: 13.5)).foregroundStyle(theme.text.color).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").font(.dante(size: 12.5)).foregroundStyle(theme.red.color)
            }
            if let report = model.report {
                categories(report)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        findings(report).frame(maxWidth: .infinity)
                        side(report).frame(width: 320)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        findings(report)
                        side(report)
                    }
                }
            }
        }
        .task {
            model.loadSaved(root: workspace.url)
            tools = SecurityTool.all.map { ($0, $0.locate()) }
            // Opening the page shows the project as it is now: files may have changed (or gone)
            // while it was closed.
            if model.report.map({ Date().timeIntervalSince($0.date) > 60 }) ?? true {
                await model.scan(root: workspace.url, files: workspace.files)
            }
        }
        .task(id: workspace.revision) {
            // Keep watching: files changed since the last scan get a fresh look after a pause.
            guard let date = model.report?.date, Date().timeIntervalSince(date) > 20 else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await model.scan(root: workspace.url, files: workspace.files)
        }
    }

    // MARK: Hero

    private var hero: some View {
        let report = model.report
        return HStack(alignment: .center, spacing: 26) {
            GradeRing(report: report, scanning: model.scanning)
                .frame(width: 150, height: 150)
            VStack(alignment: .leading, spacing: 12) {
                if let report {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(headline(report)).font(.dante(size: 20, weight: .semibold)).foregroundStyle(theme.text.color)
                            .contentTransition(.numericText())
                        Text(details(report)).font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                    }
                    HStack(spacing: 6) {
                        ForEach(SecurityFinding.Severity.allCases.filter { report.count($0) > 0 }, id: \.self) { severity in
                            SeverityPill(severity: severity, count: report.count(severity))
                        }
                        if let changes = changes {
                            if !changes.new.isEmpty { Chip(text: "\(changes.new.count) new", symbol: "plus.circle", color: theme.amber.color) }
                            if !changes.fixed.isEmpty { Chip(text: "\(changes.fixed.count) fixed", symbol: "checkmark.circle", color: theme.green.color) }
                        }
                    }
                } else {
                    Text(model.scanning ? "Looking through the project…" : "Not scanned yet")
                        .font(.dante(size: 20, weight: .semibold)).foregroundStyle(theme.text.color)
                }
                if model.scanning {
                    Text(model.progress).font(.dante(size: 12)).foregroundStyle(theme.text3.color).transition(.opacity)
                }
                actions(report)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [heroTint.opacity(0.14), theme.card.color], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(heroTint.opacity(0.35)))
        .animation(.snappy(duration: 0.35), value: model.scanning)
        .animation(.snappy(duration: 0.35), value: report?.score)
    }

    private var heroTint: Color { Severity.color(gradeSeverity, theme: theme) }

    private var gradeSeverity: SecurityFinding.Severity {
        guard let report = model.report else { return .info }
        return report.findings.first?.severity ?? .info
    }

    private var changes: (new: [SecurityFinding], fixed: [SecurityFinding])? {
        guard let report = model.report, let previous = model.previous else { return nil }
        return report.changes(since: previous)
    }

    private func headline(_ report: SecurityReport) -> String {
        if report.findings.isEmpty { return "Nothing found · \(report.score)/100" }
        let serious = report.count(.critical) + report.count(.high)
        return serious > 0 ? "\(serious) serious problem\(serious == 1 ? "" : "s") · \(report.score)/100"
                           : "\(report.findings.count) to tidy up · \(report.score)/100"
    }

    private func details(_ report: SecurityReport) -> String {
        "\(report.files) files · \(report.scanners.joined(separator: ", ")) · scanned \(report.date.relative)"
    }

    @ViewBuilder
    private func actions(_ report: SecurityReport?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            buttons(report)
            Toggle(isOn: Binding(get: { Preferences.shared.checksDependenciesOnline }, set: { Preferences.shared.checksDependenciesOnline = $0 })) {
                Text("Check dependencies online").font(.dante(size: 12)).foregroundStyle(theme.text2.color)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Asks OSV.dev, Google's open vulnerability database, about the exact versions in your lockfiles, and lets installed scanners that look dependencies up online run (OSV-Scanner, govulncheck, npm audit, pip-audit). Sends package names and versions, never code.")
        }
    }

    @ViewBuilder
    private func buttons(_ report: SecurityReport?) -> some View {
        HStack(spacing: 8) {
            let serious = report?.findings.filter { $0.severity >= .high } ?? []
            if !serious.isEmpty {
                Button { session.fixSecurity(serious) } label: {
                    AgentButtonLabel(engine: lead, title: "Fix \(serious.count) serious with \(lead.title)", filled: true)
                }
                .buttonStyle(DanteButtonStyle(primary: true))
                .help("\(lead.title) fixes them in the panel, where you approve each edit\(session.reviewPartner.map { "; \($0.name) checks the result" } ?? "").")
            }
            if let auditing = model.auditing {
                AuditProgress(engine: auditing, started: model.auditStarted ?? Date())
            } else {
                Button {
                    Task { await model.audit(with: lead, root: workspace.url, claudeExecutable: session.claude?.executable) }
                } label: {
                    AgentButtonLabel(engine: lead, title: "Deep audit with \(lead.title)", filled: serious.isEmpty && report != nil)
                }
                .buttonStyle(DanteButtonStyle(primary: serious.isEmpty && report != nil))
                .disabled(session.claude?.remote != nil)
                .help("\(lead.title) reads the code, read-only, for what patterns miss: access control, data flows, POPIA. Takes a few minutes and uses your plan.")
                if let partner = session.reviewPartner, let engine = AgentEngine.allCases.first(where: { $0.title == partner.name }) {
                    Button {
                        Task { await model.audit(with: engine, root: workspace.url, claudeExecutable: session.claude?.executable) }
                    } label: {
                        AgentButtonLabel(engine: engine, title: "\(engine.title) too")
                    }
                    .buttonStyle(DanteButtonStyle(primary: false))
                    .disabled(session.claude?.remote != nil)
                    .help("A second audit by \(engine.title). Problems both agents find are marked with both names.")
                }
            }
        }
        .fixedSize()
    }

    // MARK: Categories

    private func categories(_ report: SecurityReport) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                CategoryChip(title: "All", symbol: "square.grid.2x2", count: report.findings.count, selected: category == nil) { category = nil }
                ForEach(SecurityFinding.Category.allCases.filter { report.count($0) > 0 }, id: \.self) { item in
                    CategoryChip(title: item.title, symbol: item.symbol, count: report.count(item), selected: category == item) {
                        category = category == item ? nil : item
                    }
                }
                Spacer(minLength: 12)
                Toggle("Low and info", isOn: $showsLow).toggleStyle(.checkbox).font(.dante(size: 12))
            }
        }
        .animation(.snappy(duration: 0.25), value: category)
    }

    // MARK: Findings

    private func shown(_ report: SecurityReport) -> [SecurityFinding] {
        report.findings.filter { (category == nil || $0.category == category) && (showsLow || $0.severity >= .medium) }
    }

    private func findings(_ report: SecurityReport) -> some View {
        let list = shown(report)
        return Card(category?.title ?? "Findings") {
            if !list.isEmpty {
                Button { session.fixSecurity(Array(list.prefix(25))) } label: {
                    AgentButtonLabel(engine: lead, title: list.count > 25 ? "Fix the first 25" : "Fix all \(list.count)")
                }
                .buttonStyle(.plain)
                .font(.dante(size: 12, weight: .medium))
                .foregroundStyle(theme.accent.color)
            }
        } content: {
            if list.isEmpty {
                EmptyFindings(scanned: !report.findings.isEmpty)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(SecurityFinding.Severity.allCases, id: \.self) { severity in
                    let group = list.filter { $0.severity == severity }
                    if !group.isEmpty {
                        HStack(spacing: 6) {
                            Circle().fill(Severity.color(severity, theme: theme)).frame(width: 7, height: 7)
                            Text(severity.title).font(.dante(size: 11.5, weight: .semibold)).foregroundStyle(theme.text2.color).textCase(.uppercase)
                            Text("\(group.count)").font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color)
                        }
                        .padding(.top, 10).padding(.bottom, 4)
                        ForEach(group.prefix(limit)) { finding in
                            FindingRow(finding: finding, expanded: expanded.contains(finding.id), lead: lead, session: session, workspace: workspace) {
                                if expanded.contains(finding.id) { expanded.remove(finding.id) } else { expanded.insert(finding.id) }
                            }
                            .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)), removal: .opacity))
                        }
                    }
                }
                if list.count > limit {
                    LinkButton("Show \(list.count - limit) more") { limit += 200 }.padding(.top, 8)
                }
            }
            .animation(.snappy(duration: 0.3), value: list.map(\.id))
            .animation(.snappy(duration: 0.22), value: expanded)
        }
    }

    // MARK: Side

    private func side(_ report: SecurityReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Card("Scanners") {
                VStack(alignment: .leading, spacing: 8) {
                    ScannerRow(name: "Dante", purpose: "Secrets, personal information, encryption, injection, containers, CI and infrastructure", ran: true, install: nil, session: session)
                    ForEach(tools, id: \.tool.id) { entry in
                        ScannerRow(name: entry.tool.name, purpose: entry.tool.purpose + (entry.tool.sendsDependencies ? " (when checking online)" : ""), ran: report.scanners.contains(entry.tool.name),
                                   install: entry.path == nil ? entry.tool.install : nil, session: session)
                    }
                    ScannerRow(name: "OSV.dev", purpose: "Advisories for exact dependency versions (when checking online)",
                               ran: report.scanners.contains("OSV.dev"), install: nil, session: session)
                }
            }
            if !report.ignored.isEmpty {
                Card("Accepted risks") {
                    let ignores = SecurityIgnores.load(root: workspace.url)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(report.ignored.prefix(12)) { finding in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(finding.title).font(.dante(size: 12, weight: .medium)).foregroundStyle(theme.text2.color).lineLimit(1)
                                Text((ignores.reason(for: finding) ?? nil) ?? finding.location).font(.dante(size: 11)).foregroundStyle(theme.text3.color).lineLimit(2)
                            }
                        }
                        if report.ignored.count > 12 {
                            Text("and \(report.ignored.count - 12) more").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                        }
                        LinkButton("Open \(SecurityIgnores.path)") { session.open(file: workspace.url.appending(path: SecurityIgnores.path)) }
                    }
                }
            }
            Card("In CI") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Fail a build on serious problems with the same scan:").font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                    Text("dante scan --fail-on high")
                        .font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text.color)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.codeBackground.color))
                        .textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - Pieces

enum Severity {
    static func color(_ severity: SecurityFinding.Severity, theme: Theme) -> Color {
        switch severity {
        case .critical: theme.red.color
        case .high: theme.claude.color
        case .medium: theme.amber.color
        case .low: theme.accent.color
        case .info: theme.text3.color
        }
    }
}

/// The grade in a ring that fills with the score; a radar sweep turns while a scan runs.
private struct GradeRing: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let report: SecurityReport?
    let scanning: Bool

    var body: some View {
        let score = Double(report?.score ?? 0) / 100
        let color = report.map { $0.findings.first.map { Severity.color($0.severity, theme: theme) } ?? theme.green.color } ?? theme.text3.color
        TimelineView(.animation(paused: !scanning || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().stroke(theme.line.color, lineWidth: 10)
                Circle().trim(from: 0, to: report == nil ? 0 : max(score, 0.02))
                    .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.45), radius: 8)
                if scanning {
                    Circle()
                        .fill(AngularGradient(colors: [theme.accent.color.opacity(0), theme.accent.color.opacity(0.35)], center: .center,
                                              startAngle: .degrees(0), endAngle: .degrees(90)))
                        .padding(14)
                        .rotationEffect(.degrees(reduceMotion ? 0 : (t * 160).truncatingRemainder(dividingBy: 360)))
                    ForEach(0..<3) { ring in
                        Circle().stroke(theme.accent.color.opacity(0.12), lineWidth: 1).padding(CGFloat(14 + ring * 16))
                    }
                }
                VStack(spacing: -2) {
                    Image(systemName: "shield.lefthalf.filled").font(.dante(size: 14)).foregroundStyle(color.opacity(0.8))
                    Text(report?.grade ?? "–").font(.dante(size: 46, weight: .bold)).foregroundStyle(theme.text.color)
                        .contentTransition(.numericText())
                    Text(report.map { "\($0.score)" } ?? "").font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text3.color)
                        .contentTransition(.numericText())
                }
            }
        }
        .animation(.spring(duration: 0.9, bounce: 0.25), value: report?.score)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(report.map { "Grade \($0.grade), \($0.score) out of 100" } ?? "Not scanned")
    }
}

private struct SeverityPill: View {
    @Environment(\.theme) private var theme
    let severity: SecurityFinding.Severity
    let count: Int

    var body: some View {
        let color = Severity.color(severity, theme: theme)
        HStack(spacing: 4) {
            Text("\(count)").font(.dante(size: 12, weight: .semibold, design: .monospaced)).contentTransition(.numericText())
            Text(severity.title).font(.dante(size: 11.5))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().strokeBorder(color.opacity(0.35)))
    }
}

private struct CategoryChip: View {
    @Environment(\.theme) private var theme
    let title: String
    let symbol: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.dante(size: 10.5))
                Text(title).font(.dante(size: 12, weight: selected ? .semibold : .regular))
                Text("\(count)").font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color)
            }
            .foregroundStyle(selected ? theme.text.color : theme.text2.color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(selected ? theme.raised.color : .clear))
            .overlay(Capsule().strokeBorder(selected ? theme.line2.color : theme.line.color))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The mark of the agent that will do the job, beside what it will do.
struct AgentButtonLabel: View {
    @Environment(\.theme) private var theme
    let engine: AgentEngine
    let title: String
    /// On a filled (primary) button, where the brand colour would vanish.
    var filled = false

    var body: some View {
        Label { Text(title) } icon: { AgentIcon(engine: engine, size: 12, tint: filled ? theme.onAccent.color : nil) }
    }
}

/// An audit running: the agent's mark at work and the time so far.
private struct AuditProgress: View {
    @Environment(\.theme) private var theme
    let engine: AgentEngine
    let started: Date

    var body: some View {
        TimelineView(.periodic(from: started, by: 1)) { context in
            let seconds = Int(context.date.timeIntervalSince(started))
            HStack(spacing: 7) {
                AgentIcon(engine: engine, size: 14, isWorking: true)
                Text("\(engine.title) is auditing the code · \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                    .font(.dante(size: 12, weight: .medium)).foregroundStyle(theme.text2.color).monospacedDigit()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(theme.raised.color))
        }
    }
}

private struct EmptyFindings: View {
    @Environment(\.theme) private var theme
    let scanned: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield").font(.dante(size: 22)).foregroundStyle(theme.green.color)
            Text(scanned ? "Nothing here with these filters." : "Nothing found. Run a deep audit for what patterns can't see.")
                .font(.dante(size: 13)).foregroundStyle(theme.text2.color)
        }
        .padding(.vertical, 8)
    }
}

private struct FindingRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    let finding: SecurityFinding
    let expanded: Bool
    let lead: AgentEngine
    let session: Session
    let workspace: Workspace
    let toggle: () -> Void
    @State private var ignoring = false
    @State private var reason = ""
    @State private var wholeRule = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chevron.right").font(.dante(size: 9, weight: .semibold)).foregroundStyle(theme.text3.color)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Image(systemName: finding.category.symbol).font(.dante(size: 11)).foregroundStyle(Severity.color(finding.severity, theme: theme))
                        .frame(width: 14)
                    Text(finding.title).font(.dante(size: 13, weight: .medium)).foregroundStyle(theme.text.color).lineLimit(1)
                    if finding.source != "Dante" {
                        Text(finding.source).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().strokeBorder(theme.line2.color))
                    }
                    Spacer(minLength: 8)
                    Text(finding.location.isEmpty ? "project" : finding.location)
                        .font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color).lineLimit(1).truncationMode(.head)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(finding.why).font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                    if !finding.evidence.isEmpty {
                        Text(finding.evidence)
                            .font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text.color)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(theme.codeBackground.color))
                            .textSelection(.enabled)
                    }
                    Label { Text(finding.fix).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "wrench.and.screwdriver") }
                        .font(.dante(size: 12.5)).foregroundStyle(theme.text.color)
                    HStack(spacing: 10) {
                        Button { session.fixSecurity([finding]) } label: { AgentButtonLabel(engine: lead, title: "Fix with \(lead.title)", filled: true) }
                            .buttonStyle(DanteButtonStyle(primary: true))
                        if !finding.file.isEmpty, FileManager.default.fileExists(atPath: workspace.url.appending(path: finding.file).path) {
                            Button("Open") { session.open(file: workspace.url.appending(path: finding.file), line: max(finding.line, 1)) }
                                .buttonStyle(DanteButtonStyle(primary: false))
                        }
                        Button("Accept the risk…") { ignoring = true }
                            .buttonStyle(DanteButtonStyle(primary: false))
                            .popover(isPresented: $ignoring, arrowEdge: .bottom) { ignorePopover }
                        Spacer(minLength: 0)
                        if let reference = finding.reference, let url = Self.link(for: reference) {
                            Button { openURL(url) } label: { Label(reference, systemImage: "arrow.up.right.square") }
                                .buttonStyle(.plain).font(.dante(size: 11.5)).foregroundStyle(theme.accent.color)
                        }
                    }
                }
                .padding(.leading, 30)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line.color.opacity(0.6)).frame(height: 1) }
    }

    private var ignorePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Accept this risk").font(.dante(size: 13, weight: .semibold))
            TextField("Why it's fine", text: $reason).textFieldStyle(.roundedBorder).frame(width: 320)
            Toggle("Every “\(finding.title)” finding", isOn: $wholeRule).toggleStyle(.checkbox).font(.dante(size: 12))
            Text("Saved in \(SecurityIgnores.path), so everyone on the project sees it.").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
            HStack {
                Spacer()
                Button("Cancel") { ignoring = false }
                Button("Accept") {
                    session.security.ignore(finding, reason: reason, wholeRule: wholeRule, root: workspace.url)
                    ignoring = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    static func link(for reference: String) -> URL? {
        if reference.hasPrefix("CWE-"), let number = Int(reference.dropFirst(4)) {
            return URL(string: "https://cwe.mitre.org/data/definitions/\(number).html")
        }
        if reference.hasPrefix("GHSA-") || reference.hasPrefix("CVE-") || reference.hasPrefix("GO-") || reference.hasPrefix("PYSEC-") || reference.hasPrefix("RUSTSEC-") {
            return URL(string: "https://osv.dev/vulnerability/\(reference)")
        }
        if reference.hasPrefix("POPIA") { return URL(string: "https://popia.co.za") }
        return nil
    }
}

private struct ScannerRow: View {
    @Environment(\.theme) private var theme
    let name: String
    let purpose: String
    let ran: Bool
    let install: String?
    let session: Session

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: install != nil ? "circle.dashed" : ran ? "checkmark.circle.fill" : "circle")
                .font(.dante(size: 12))
                .foregroundStyle(install != nil ? theme.text3.color : ran ? theme.green.color : theme.text3.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.dante(size: 12.5, weight: .medium)).foregroundStyle(install != nil ? theme.text2.color : theme.text.color)
                Text(purpose).font(.dante(size: 11)).foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true)
                if let install {
                    Button("Type the install command") {
                        session.showsTerminal = true
                        session.typeInTerminal(install)
                    }
                    .buttonStyle(.plain).font(.dante(size: 11)).foregroundStyle(theme.accent.color)
                    .help("Types \(install) into the terminal for you to run. Dante never installs anything itself.")
                }
            }
        }
    }
}
