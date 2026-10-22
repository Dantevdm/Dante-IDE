import DanteKit
import SwiftUI

/// Home: where the project is. The system drawn as a living map, vital-sign tiles (code,
/// security, tests, activity, agents), what changed since your last visit, then git, the
/// local environment, what Claude knows and the docs.
struct HomeView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    @State private var git: GitSnapshot?
    @State private var containers: Result<[ContainerState], DockerUnavailable>?
    @State private var compose: ComposeFile?
    @State private var sketch: HomePulse.Sketch?
    @State private var commits: [Date] = []
    @State private var lastTests: TestRecord?
    @State private var office: AgentOffice?

    var body: some View {
        AreaPage(
            eyebrow: nil,
            title: workspace.info.name ?? workspace.name,
            subtitle: workspace.info.summary
        ) {
            Button {
                session.palette = .all
            } label: {
                Label("Search or ask", systemImage: "magnifyingglass")
            }
            .buttonStyle(DanteButtonStyle())
        } content: {
            facts
            if let sketch, sketch.lanes.count >= 2 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("How it fits together").font(.dante(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
                        Spacer()
                        LinkButton("Open the map") { session.area = .map }
                    }
                    HomeMap(session: session, sketch: sketch)
                }
            }
            vitals
            if let since = session.sinceLastVisit {
                SinceLastVisitCard(session: session, since: since)
            }
            EvenGrid(minimum: 340) {
                GitCard(git: git) { session.area = .ship }
                EnvironmentCard(compose: compose, containers: containers) { session.area = .environments }
                ClaudeKnowsCard(session: session, workspace: workspace)
                DocsCard(session: session, workspace: workspace)
            }
            .environment(\.cardFillsRow, true)
        }
        .task(id: workspace.revision) { await load() }
    }

    private var facts: some View {
        HStack(spacing: 8) {
            ForEach(LanguageStats.top(workspace.files), id: \.language) { entry in
                Chip(text: entry.language.displayName, symbol: "chevron.left.forwardslash.chevron.right")
            }
            if let branch = Git.currentBranch(in: workspace.url) {
                Chip(text: branch, symbol: "arrow.triangle.branch")
            }
            if !workspace.files.isEmpty {
                Chip(text: "\(workspace.files.count) files", symbol: "doc")
            }
            if let compose, !compose.services.isEmpty {
                Chip(text: "\(compose.services.count) services", symbol: "shippingbox")
            }
        }
    }

    // MARK: Vital signs

    private var vitals: some View {
        let languages = HomePulse.languages(workspace.files)
        let report = session.security.report
        let grid = HomePulse.commitGrid(commits)
        let thisWeek = grid.last?.filter { $0 > 0 }.reduce(0, +) ?? 0
        return EvenGrid(minimum: 150) {
            VitalTile(title: "Code", symbol: "chevron.left.forwardslash.chevron.right",
                      caption: "\(workspace.files.count) files", action: { session.area = .code }) {
                if languages.isEmpty {
                    Image(systemName: "doc.text").font(.dante(size: 30)).foregroundStyle(theme.text3.color)
                } else {
                    ShareRing(shares: languages)
                }
            }
            VitalTile(title: "Security", symbol: "shield.lefthalf.filled", caption: securityCaption(report), action: { session.area = .security }) {
                if let report {
                    ScoreRing(value: Double(report.score) / 100, label: report.grade,
                              color: report.findings.first.map { Severity.color($0.severity, theme: theme) } ?? theme.green.color)
                } else {
                    ScoreRing(value: 0, label: "–", color: theme.text3.color)
                }
            }
            VitalTile(title: "Tests", symbol: "testtube.2", caption: testsCaption, action: { session.area = .tests }) {
                TestBar(record: lastTests)
            }
            VitalTile(title: "Activity", symbol: "point.3.connected.trianglepath.dotted",
                      caption: thisWeek == 0 ? "No commits this week" : "\(thisWeek) commit\(thisWeek == 1 ? "" : "s") this week",
                      action: { session.area = .timeline }) {
                CommitGrid(grid: grid)
            }
            VitalTile(title: "Agents", symbol: "building.2", caption: officeCaption, action: { session.area = .office }) {
                OfficeRooms(office: office)
            }
        }
    }

    private func securityCaption(_ report: SecurityReport?) -> String {
        guard let report else { return session.security.scanning ? "Scanning…" : "Not scanned yet" }
        if report.findings.isEmpty { return "Nothing found" }
        let serious = report.count(.critical) + report.count(.high)
        return serious > 0 ? "\(serious) serious problem\(serious == 1 ? "" : "s")" : "\(report.findings.count) to tidy up"
    }

    private var testsCaption: String {
        guard let lastTests else { return "No run yet" }
        return "Last run \(lastTests.date.relative)"
    }

    private var officeCaption: String {
        guard let office else { return "HQ" }
        return office.totalJobs == 0 ? "HQ: a \(office.era.title.lowercased()), no jobs yet" : "HQ: a \(office.era.title.lowercased()), \(office.totalJobs) job\(office.totalJobs == 1 ? "" : "s")"
    }

    private func load() async {
        // The map takes longest on a big repo, so it's built alongside the rest.
        async let mapped: Void = loadSketch()
        compose = ComposeFile.load(projectRoot: workspace.url)
        async let snapshot = GitSnapshot.load(in: workspace.url)
        if compose != nil {
            containers = await ContainerState.load(projectRoot: workspace.url)
        }
        git = await snapshot
        lastTests = TestRecord.load(for: workspace.url).last
        if session.security.report == nil { session.security.loadSaved(root: workspace.url) }
        let root = workspace.url
        let log = await Shell.run(["git", "log", "-n", "50000", "--format=%ct"], in: root)
        commits = log.stdout.split(separator: "\n").compactMap { Double($0.trimmingCharacters(in: .whitespaces)).map { Date(timeIntervalSince1970: $0) } }
        let project = workspace.name, files = workspace.files, growth = AgentOffice.Growth(commits: commits, files: files.count)
        office = await Task.detached(priority: .utility) {
            AgentOffice.build(jobs: AgentLedger.standard.jobs().filter { $0.project == project }, project: project, growth: growth)
        }.value
        await mapped
    }

    /// The Map's build when it's for this revision, else one of our own.
    private func loadSketch() async {
        if let cache = session.mapCache, cache.revision == workspace.revision, let system = cache.system {
            sketch = system.isUseful ? HomePulse.sketch(system) : nil
            return
        }
        // Built as the Map builds it, so a part clicked here is the same part there.
        let root = workspace.url, files = workspace.files
        let compose = ComposeFile.load(projectRoot: root)
        let read = MapView.reader(root: root)
        let modules = await MapView.modules(root: root, files: files)
        let system = await Task.detached(priority: .utility) { SystemMap.build(files: files, read: read, compose: compose, modules: modules) }.value
        sketch = system.isUseful ? HomePulse.sketch(system) : nil
    }
}

/// HQ's rooms as dots: bigger for higher levels, fainter when quiet, empty while unopened.
private struct OfficeRooms: View {
    @Environment(\.theme) private var theme
    let office: AgentOffice?

    var body: some View {
        if let office {
            HStack(alignment: .center, spacing: 8) {
                ForEach(Array(office.rooms.enumerated()), id: \.offset) { _, room in
                    let side = 10 + CGFloat(min(room.level, 5)) * 5
                    ZStack {
                        if room.level == 0 {
                            Circle().strokeBorder(theme.line2.color, style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                        } else {
                            Circle().fill(theme.accent.color.opacity(0.25 + 0.75 * room.warmth))
                        }
                    }
                    .frame(width: side, height: side)
                    .help("\(room.role.title): \(room.jobs) jobs")
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

// MARK: Since last visit

/// Commits, task moves and a branch switch since the project was last closed in Dante.
private struct SinceLastVisitCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let since: SinceLastVisit

    var body: some View {
        Card("Since you were last here", accent: true) {
            Text(since.since.relative).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            IconButton(symbol: "xmark", label: "Dismiss", size: 9.5) { session.sinceLastVisit = nil }
        } content: {
            HStack(spacing: 14) {
                if !since.commits.isEmpty {
                    let count = since.commits.count + since.moreCommits
                    stat("\(count) commit\(count == 1 ? "" : "s")", symbol: "point.3.connected.trianglepath.dotted")
                }
                if since.filesChanged > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: "doc").font(.dante(size: 10.5))
                        Text("\(since.filesChanged) file\(since.filesChanged == 1 ? "" : "s")")
                        Text("+\(since.insertions)").foregroundStyle(theme.green.color)
                        Text("−\(since.deletions)").foregroundStyle(theme.red.color)
                    }
                    .font(.dante(size: 12))
                    .foregroundStyle(theme.text2.color)
                }
                if let change = since.branchChange {
                    stat("\(change.from) → \(change.to)", symbol: "arrow.triangle.branch")
                }
            }
            if !since.commits.isEmpty {
                RowList(data: since.commits, padding: 6) { commit in
                    HStack(spacing: 10) {
                        Text(String(commit.hash.prefix(7)))
                            .font(.dante(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.text3.color)
                        Text(commit.subject).font(.dante(size: 12.5)).foregroundStyle(theme.text.color).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(commit.author).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                        if let date = commit.date {
                            Text(date.relative).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                        }
                    }
                }
                if since.moreCommits > 0 {
                    Text("and \(since.moreCommits) more").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                }
            }
        }
    }

    private func stat(_ text: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.dante(size: 10.5))
            Text(text).font(.dante(size: 12))
        }
        .foregroundStyle(theme.text2.color)
    }
}

// MARK: Cards

private struct GitCard: View {
    @Environment(\.theme) private var theme
    let git: GitSnapshot?
    let openShip: () -> Void

    var body: some View {
        Card("Recent commits") {
            LinkButton("Release", action: openShip)
        } content: {
            if let git {
                if !git.isRepository {
                    Text("Not a git repository.").font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
                } else {
                    HStack(spacing: 14) {
                        stat(git.changedFiles == 0 ? "Clean" : "\(git.changedFiles) changed", color: git.changedFiles == 0 ? theme.green.color : theme.amber.color)
                        if let ahead = git.ahead, ahead > 0 { stat("\(ahead) to push", color: theme.accent.color) }
                        if let tag = git.latestTag { stat(tag, color: theme.text2.color, symbol: "tag") }
                    }
                    RowList(data: Array(git.recent.prefix(5)), padding: 7) { commit in
                        HStack(spacing: 10) {
                            Text(String(commit.hash.prefix(7)))
                                .font(.dante(size: 11.5, design: .monospaced))
                                .foregroundStyle(theme.text3.color)
                            Text(commit.subject).font(.dante(size: 12.5)).foregroundStyle(theme.text.color).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(commit.date.relative).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func stat(_ text: String, color: Color, symbol: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.dante(size: 10.5)) } else { StatusDot(color: color, size: 6) }
            Text(text).font(.dante(size: 12))
        }
        .foregroundStyle(color)
    }
}

private struct EnvironmentCard: View {
    @Environment(\.theme) private var theme
    let compose: ComposeFile?
    let containers: Result<[ContainerState], DockerUnavailable>?
    let openEnv: () -> Void

    var body: some View {
        Card("Local environment") {
            LinkButton(compose == nil ? "Set up" : "Containers", action: openEnv)
        } content: {
            if let compose {
                if let error = compose.parseError {
                    Text(error).font(.dante(size: 12.5)).foregroundStyle(theme.red.color)
                } else {
                    RowList(data: compose.services, padding: 7) { service in
                        let state = running.first { $0.service == service.name }
                        HStack(spacing: 8) {
                            StatusDot(color: color(for: state), size: 7)
                            Text(service.name).font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text.color)
                            Spacer()
                            Text(state?.ports.first ?? service.ports.first.map { ":" + ($0.split(separator: ":").first.map(String.init) ?? $0) } ?? "")
                                .font(.dante(size: 12))
                                .foregroundStyle(theme.text3.color)
                            Text(state?.label ?? "stopped")
                                .font(.dante(size: 12))
                                .foregroundStyle(color(for: state))
                                .frame(width: 76, alignment: .trailing)
                        }
                    }
                    if case .failure(let reason) = containers {
                        Text(reason.message).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("No docker-compose.yml")
                    .font(.dante(size: 12.5))
                    .foregroundStyle(theme.text3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var running: [ContainerState] {
        if case .success(let list) = containers { list } else { [] }
    }

    private func color(for state: ContainerState?) -> Color {
        guard let state else { return theme.text3.color }
        if state.state == "restarting" || state.health == "unhealthy" || state.health == "starting" { return theme.amber.color }
        if state.state == "running" { return theme.green.color }
        if state.state == "exited", !state.status.contains("(0)") { return theme.red.color }
        return theme.text3.color
    }
}

private struct ClaudeKnowsCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    private struct Fact: Identifiable {
        let label: String
        let value: String
        let present: Bool
        var id: String { label }
    }

    var body: some View {
        let rules = workspace.claudeRules
        let fileManager = FileManager.default
        let facts = [
            Fact(label: "Rules for Claude", value: rules.isEmpty ? "none" : "\(rules.propose.count) · \(rules.flag.count) · \(rules.never.count)", present: !rules.isEmpty),
            Fact(label: "Project notes", value: fileManager.fileExists(atPath: workspace.url.appending(path: "CLAUDE.md").path) ? "CLAUDE.md" : "none",
                 present: fileManager.fileExists(atPath: workspace.url.appending(path: "CLAUDE.md").path)),
            Fact(label: "Skills", value: skillCount == 0 ? "none" : "\(skillCount) in .claude/skills", present: skillCount > 0),
        ]
        let reviewDue = ClaudeSkills.reviewDue(lastReview: UserDefaults.standard.object(forKey: "skillsReview." + workspace.url.path) as? Date)
        Card("What Claude knows") {
            LinkButton("Manage") { session.area = .claude }
        } content: {
            RowList(data: facts, padding: 7) { fact in
                HStack {
                    Text(fact.label).font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
                    Spacer()
                    Text(fact.value)
                        .font(.dante(size: 12, design: .monospaced))
                        .foregroundStyle(fact.present ? theme.text.color : theme.text3.color)
                }
            }
            if reviewDue, workspace.files.count > 20 {
                Button { session.area = .claude } label: {
                    ClaudeLabel(skillCount == 0 ? "Claude could use skills for this project’s repeated work. See suggestions" : "Time to check the skills still fit the project")
                        .font(.dante(size: 12))
                        .foregroundStyle(theme.accent.color)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var skillCount: Int {
        let folder = workspace.url.appending(path: ".claude/skills")
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.count
    }
}

private struct DocsCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    var body: some View {
        let library = DocLibrary(paths: workspace.files)
        let docs = library.all.filter { !$0.path.hasPrefix(".dante/phases/") }
        Card("Documentation") {
            LinkButton("Read") { session.area = .docs }
        } content: {
            if docs.isEmpty {
                Text("No markdown docs yet.").font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
            } else {
                RowList(data: Array(docs.prefix(6)), padding: 7) { doc in
                    Button { session.showDoc(doc.path) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                            Text(doc.title).font(.dante(size: 12.5)).foregroundStyle(theme.text.color).lineLimit(1)
                            Spacer()
                            Text(doc.path).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color).lineLimit(1).truncationMode(.head)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
