import Foundation

/// The rooms of Agent HQ, one per kind of work. A job lands in a room by what it touched
/// (a turn's files), what it was (an audit, a look, a triage) or what it said it was about.
public enum OfficeRole: String, CaseIterable, Codable, Sendable {
    case research, backend, frontend, devops, quality, docs, security, data

    public var title: String {
        switch self {
        case .research: "Research"
        case .backend: "Backend"
        case .frontend: "Front-end"
        case .devops: "DevOps"
        case .quality: "Quality"
        case .docs: "Docs"
        case .security: "Security"
        case .data: "Data"
        }
    }

    /// The room's letter on its sign.
    public var icon: String {
        switch self {
        case .research: "R"
        case .backend: "B"
        case .frontend: "F"
        case .devops: "O"
        case .quality: "Q"
        case .docs: "D"
        case .security: "S"
        case .data: "T"
        }
    }

    /// Where a changed file's work belongs. Tests win over their language, infrastructure over
    /// its format, and anything unclaimed is backend.
    public static func of(path: String) -> OfficeRole {
        let lower = "/" + path.lowercased()
        let name = (lower as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        if lower.contains("/security") || name.hasPrefix(".gitleaks") || name == "security.yaml" { return .security }
        if ["test", "tests", "__tests__", "spec", "e2e", "testing"].contains(where: { lower.contains("/\($0)/") })
            || name.contains(".test.") || name.contains(".spec.") || name.hasSuffix("_test.go") || name.hasPrefix("test_")
            || name.hasSuffix("tests.swift") || name.hasSuffix("test.swift") || name.hasSuffix("test.java") || name.hasSuffix("tests.cs") {
            return .quality
        }
        if ext == "sql" || ext == "prisma" || lower.contains("/migrations/") || lower.contains("/migrate/") || lower.contains("/db/") || lower.contains("/schema/") {
            return .data
        }
        if lower.contains("/.github/") || lower.contains("/.gitlab") || lower.contains("/.circleci/") || lower.contains("/infra/")
            || lower.contains("/deploy/") || lower.contains("/k8s/") || lower.contains("/helm/") || lower.contains("/terraform/")
            || ["tf", "tfvars", "bicep"].contains(ext) || name.hasPrefix("dockerfile") || name.hasPrefix("docker-compose")
            || name.hasPrefix("compose.") || name == "jenkinsfile" || name == "azure-pipelines.yml" || name == "makefile"
            || lower.contains("/scripts/") && ["sh", "bash", "zsh"].contains(ext) {
            return .devops
        }
        if ["md", "mdx", "rst", "adoc", "txt"].contains(ext) || lower.contains("/docs/") || lower.contains("/spec/pages/") { return .docs }
        if ["tsx", "jsx", "css", "scss", "sass", "less", "vue", "svelte", "astro", "html", "htm"].contains(ext)
            || ["/components/", "/views/", "/pages/", "/screens/", "/ui/", "/styles/", "/public/", "/assets/"].contains(where: lower.contains) {
            return .frontend
        }
        return .backend
    }

    /// The room for a job in the ledger.
    public static func of(job: AgentJob) -> OfficeRole {
        switch job.kind {
        case "audit": return .security
        case Looker.kind, "critique": return .frontend
        case DelegateKind.triage.rawValue: return .quality
        case DelegateKind.summary.rawValue, "opinion", "decision": return .research
        case DelegateKind.writing.rawValue: return .docs
        case DelegateKind.commitMessage.rawValue: return .devops
        case "subagent":
            if ["explore", "plan"].contains(job.model.lowercased()) { return .research }
            return of(words: job.title) ?? .research
        default: break
        }
        if let files = job.files, !files.isEmpty {
            // The room most of the files belong to; the first-listed breaks a tie.
            var counts: [OfficeRole: Int] = [:]
            for file in files { counts[of(path: file), default: 0] += 1 }
            let top = counts.values.max() ?? 0
            return files.map(of(path:)).first { counts[$0] == top } ?? .backend
        }
        // A turn that changed nothing was talk: questions, reading, plans.
        return of(words: job.title) ?? (job.kind == "turn" ? .research : .backend)
    }

    /// A room named by the words of a title, when they clearly say one.
    public static func of(words: String) -> OfficeRole? {
        let lower = " " + words.lowercased() + " "
        func has(_ list: [String]) -> Bool { list.contains { lower.contains($0) } }
        if has([" security", "secret", "vulnerab", " audit", " cve", "popia", " xss", "injection"]) { return .security }
        if has([" test", "flaky", " coverage", " lint", " qa "]) { return .quality }
        if has([" sql", "database", " table", "migration", " schema", " query", " index "]) { return .data }
        if has([" deploy", "docker", "pipeline", " ci ", " ci/", "workflow", "terraform", "release", "kubernetes"]) { return .devops }
        if has([" readme", " docs", "documentation", "changelog", " spec page", "write-up"]) { return .docs }
        if has([" ui ", " css", "screen", " page", "button", "layout", "design", " icon", "animation", "front-end", "frontend"]) { return .frontend }
        return nil
    }

    /// The room for a tool call in progress: edits by their file, commands by what they run,
    /// reading and searching in Research.
    public static func of(tool name: String, path: String?, command: String?) -> OfficeRole {
        switch name {
        case "Edit", "MultiEdit", "Write", "NotebookEdit", CodexTranslator.patchTool:
            return path.map(of(path:)) ?? .backend
        case "Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch", "TodoWrite", "ToolSearch", "Skill",
             "mcp__dante__search_code", "mcp__dante__dante_pages", "mcp__dante__show_page", "mcp__dante__diagram_guide", "mcp__dante__ask_grok", "mcp__dante__decide":
            return .research
        case "mcp__dante__security_report": return .security
        case "mcp__dante__look", "mcp__dante__motion_frames": return .frontend
        case "mcp__dante__ask_codex", "mcp__dante__ask_claude": return .quality
        case "Bash":
            let line = " " + (command ?? "").lowercased() + " "
            func has(_ list: [String]) -> Bool { list.contains { line.contains($0) } }
            if has(["gitleaks", "semgrep", "osv-scanner", "govulncheck", "npm audit", "pip-audit", "trivy"]) { return .security }
            if has([" test", "pytest", "jest", "vitest", "playwright", " lint", "eslint", "swiftlint", "rspec", "phpunit"]) { return .quality }
            if has(["psql", "mysql", "sqlite3", " migrate", "prisma", "flyway", "liquibase"]) { return .data }
            if has(["docker", "kubectl", "terraform", "helm ", " gh run", " gh workflow", "aws ", "az ", "gcloud", "git push", "ansible"]) { return .devops }
            return .backend
        default:
            return .backend
        }
    }
}

/// Agent HQ as it stands: the rooms the agents have opened and furnished by working in them,
/// the era the office has grown into, and the milestones on the way. Everything is derived
/// from the ledger, so the office changes as the work does and can be replayed from the start.
public struct AgentOffice: Codable, Equatable, Sendable {
    /// How big the whole place has grown. An era needs both jobs and days with work, so a
    /// busy afternoon doesn't build a campus.
    public enum Era: Int, Codable, CaseIterable, Comparable, Sendable {
        case garage, studio, office, headquarters, campus

        public var title: String {
            switch self {
            case .garage: "Garage"
            case .studio: "Studio"
            case .office: "Office"
            case .headquarters: "Headquarters"
            case .campus: "Campus"
            }
        }

        /// Jobs and active days it takes.
        public var needs: (jobs: Int, days: Int) {
            switch self {
            case .garage: (0, 0)
            case .studio: (10, 2)
            case .office: (50, 5)
            case .headquarters: (200, 14)
            case .campus: (600, 40)
            }
        }

        /// What the era adds, for the milestone and the board.
        public var adds: String {
            switch self {
            case .garage: "a desk, a lamp and the brain's first spark"
            case .studio: "lit roads and a ring round the brain"
            case .office: "the brain's beam and packets on the roads"
            case .headquarters: "a second ring, arcs to every room and a plaza"
            case .campus: "a ring road, trees and a brain at full size"
            }
        }

        var article: String { self == .office ? "an" : "a" }

        public static func < (a: Era, b: Era) -> Bool { a.rawValue < b.rawValue }

        static func reached(jobs: Int, days: Int) -> Era {
            allCases.last { jobs >= $0.needs.jobs && days >= $0.needs.days } ?? .garage
        }
    }

    /// Jobs a room needs for each level; level 5 is the top, and every hundred jobs after it
    /// puts a trophy on the shelf.
    public static let levels = [1, 4, 12, 30, 75]
    public static let maxTrophies = 5

    /// What a room gains at a level.
    public static func furnishing(level: Int) -> String {
        switch level {
        case 1: "walls and a desk"
        case 2: "a rug and a lamp"
        case 3: "a second desk and a plant"
        case 4: "a bookshelf and a screen wall"
        case 5: "a glowing ring and gold trim"
        default: "a trophy"
        }
    }

    public static func levelName(_ level: Int) -> String {
        ["Vacant", "Opened", "Settled", "Team room", "Established", "Flagship"][max(0, min(5, level))]
    }

    public struct Crew: Codable, Equatable, Sendable {
        public var name: String
        /// The figure to draw: claude, codex, local, looker, cloud or subagent.
        public var look: String
        public var jobs: Int
    }

    public struct Work: Codable, Equatable, Sendable {
        public var date: Date
        public var title: String
        public var agent: String
        public var look: String
        public var failed: Bool
    }

    public struct Room: Codable, Equatable, Sendable {
        public var role: OfficeRole
        public var jobs: Int
        public var level: Int
        /// The way to the next level, 0…1 (1 at the top level).
        public var progress: Double
        /// "4 more jobs: a second desk and a plant", nil at the top.
        public var next: String?
        public var trophies: Int
        public var opened: Date?
        public var openedBy: String?
        public var lastWork: Date?
        public var week: Int
        public var today: Int
        public var averageSeconds: Double
        /// How lived-in it looks now: 1 busy this hour, falling to 0.15 after a month quiet;
        /// 0 for a room never opened.
        public var warmth: Double
        /// Its road's wear from all the work ever done, 0…1.
        public var wear: Double
        /// This week's share of the busiest room's traffic, 0…1.
        public var traffic: Double
        /// Who works here, most jobs first; the first is the lead.
        public var crew: [Crew]
        public var recent: [Work]
    }

    public struct Milestone: Codable, Equatable, Sendable {
        public var date: Date
        public var text: String
        public var role: OfficeRole?
        /// "era", "open", "level" or "count".
        public var kind: String
    }

    /// How much the app itself has grown: its commits (with their dates, so a replay grows the
    /// grounds too) and files. Commits count towards the era, a fifth of a job each, and their
    /// days count as days with work.
    public struct Growth: Codable, Equatable, Sendable {
        public var commits: [Date]
        public var files: Int

        public init(commits: [Date] = [], files: Int = 0) {
            self.commits = commits
            self.files = files
        }
    }

    /// The grounds around the rooms, from how big the app is: trees for files, floors under the
    /// brain for commits.
    public struct Grounds: Codable, Equatable, Sendable {
        public var trees: Int
        public var floors: Int
        public var commits: Int
        public var files: Int
    }

    public static let commitsPerJob = 5

    public var project: String
    public var rooms: [Room]
    public var grounds: Grounds
    public var era: Era
    /// The way to the next era, 0…1.
    public var eraProgress: Double
    /// "120 more jobs and 3 more days with work: Headquarters", nil at the last era.
    public var nextEra: String?
    public var totalJobs: Int
    public var activeDays: Int
    public var since: Date?
    public var now: Date
    /// Newest first.
    public var milestones: [Milestone]

    public static func level(jobs: Int) -> Int { levels.lastIndex { jobs >= $0 }.map { $0 + 1 } ?? 0 }

    /// The office from every job in the project's ledger up to `now`.
    public static func build(jobs all: [AgentJob], project: String, growth: Growth = Growth(), now: Date = Date(), calendar: Calendar = .current) -> AgentOffice {
        let jobs = all.filter { $0.date <= now }.sorted { $0.date < $1.date }
        let commits = growth.commits.filter { $0 <= now }
        let today = calendar.startOfDay(for: now)
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        var byRole: [OfficeRole: [AgentJob]] = [:]
        for job in jobs { byRole[OfficeRole.of(job: job), default: []].append(job) }
        let busiest = max(1, OfficeRole.allCases.map { byRole[$0, default: []].filter { $0.date >= weekAgo }.count }.max() ?? 0)

        let rooms = OfficeRole.allCases.map { role -> Room in
            let work = byRole[role, default: []]
            let count = work.count
            let level = level(jobs: count)
            let progress: Double
            var next: String?
            if level < levels.count {
                let from = level == 0 ? 0 : levels[level - 1], to = levels[level]
                progress = Double(count - from) / Double(to - from)
                let left = to - count
                next = "\(left) more job\(left == 1 ? "" : "s"): \(furnishing(level: level + 1))"
            } else {
                progress = 1
            }
            var crew: [String: Crew] = [:]
            for job in work {
                let name = AgentStats.agent(of: job)
                crew[name, default: Crew(name: name, look: look(of: job), jobs: 0)].jobs += 1
            }
            let last = work.last?.date
            let age = last.map { now.timeIntervalSince($0) } ?? .infinity
            let warmth: Double = count == 0 ? 0 : age < 3_600 ? 1 : age < 86_400 ? 0.82 : age < 7 * 86_400 ? 0.6 : age < 30 * 86_400 ? 0.35 : 0.15
            let week = work.filter { $0.date >= weekAgo }.count
            return Room(
                role: role, jobs: count, level: level, progress: max(0, min(1, progress)), next: next,
                trophies: min(maxTrophies, max(0, (count - levels.last!) / 100)),
                opened: work.first?.date, openedBy: work.first.map(AgentStats.agent(of:)), lastWork: last,
                week: week, today: work.filter { $0.date >= today }.count,
                averageSeconds: count == 0 ? 0 : work.reduce(0) { $0 + $1.seconds } / Double(count),
                warmth: warmth, wear: min(1, log10(Double(count) + 1) / 2.4), traffic: Double(week) / Double(busiest),
                crew: crew.values.sorted { $0.jobs != $1.jobs ? $0.jobs > $1.jobs : $0.name < $1.name }.prefix(4).map { $0 },
                recent: work.suffix(6).reversed().map {
                    Work(date: $0.date, title: title(of: $0), agent: AgentStats.agent(of: $0), look: look(of: $0), failed: $0.outcome == .failed)
                }
            )
        }

        let days = Set((jobs.map(\.date) + commits).map { calendar.startOfDay(for: $0) }).count
        let work = jobs.count + commits.count / commitsPerJob
        let era = Era.reached(jobs: work, days: days)
        var eraProgress = 1.0
        var nextEra: String?
        if let following = Era(rawValue: era.rawValue + 1) {
            let need = following.needs, have = era.needs
            let byJobs = Double(work - have.jobs) / Double(need.jobs - have.jobs)
            let byDays = Double(days - have.days) / Double(need.days - have.days)
            eraProgress = max(0, min(1, min(byJobs, byDays)))
            var parts: [String] = []
            if work < need.jobs { let n = need.jobs - work; parts.append("\(n) more job\(n == 1 ? "" : "s")") }
            if days < need.days { let n = need.days - days; parts.append("\(n) more day\(n == 1 ? "" : "s") with work") }
            nextEra = parts.joined(separator: " and ") + " to become \(following.article) \(following.title.lowercased())"
        }
        // Files grow with the commits during a replay: the app was smaller back then.
        let share = growth.commits.isEmpty ? 1 : Double(commits.count) / Double(growth.commits.count)
        let files = Int((Double(growth.files) * share).rounded())
        let grounds = Grounds(trees: min(16, files / 40), floors: min(6, commits.count / 150), commits: commits.count, files: files)
        return AgentOffice(project: project, rooms: rooms, grounds: grounds, era: era, eraProgress: eraProgress, nextEra: nextEra,
                           totalJobs: jobs.count, activeDays: days, since: jobs.first?.date, now: now,
                           milestones: milestones(jobs, commits: commits, calendar: calendar))
    }

    /// The story of the office, newest first: the doors opening, each room opening and
    /// levelling up, each era, and round numbers of jobs.
    static func milestones(_ jobs: [AgentJob], commits: [Date] = [], calendar: Calendar, limit: Int = 24) -> [Milestone] {
        var found: [Milestone] = []
        var counts: [OfficeRole: Int] = [:]
        var days = Set<Date>()
        var era = Era.garage
        var done = 0, committed = 0
        // Jobs and commits in date order; a commit only moves the era and the round numbers.
        let events: [(date: Date, job: AgentJob?)] = (jobs.map { ($0.date, Optional($0)) } + commits.map { ($0, nil) }).sorted { $0.date < $1.date }
        for event in events {
            days.insert(calendar.startOfDay(for: event.date))
            if let job = event.job {
                if done == 0 {
                    found.append(Milestone(date: job.date, text: "The doors opened: \(AgentStats.agent(of: job)) did the first job, \(title(of: job))", role: nil, kind: "era"))
                }
                done += 1
                let role = OfficeRole.of(job: job)
                let before = level(jobs: counts[role, default: 0])
                counts[role, default: 0] += 1
                let after = level(jobs: counts[role]!)
                if after > before {
                    found.append(after == 1
                        ? Milestone(date: job.date, text: "\(role.title) opened: \(AgentStats.agent(of: job)) moved in for \(title(of: job))", role: role, kind: "open")
                        : Milestone(date: job.date, text: "\(role.title) got \(furnishing(level: after))", role: role, kind: "level"))
                }
                if done == 100 || done == 250 || done % 500 == 0 {
                    found.append(Milestone(date: job.date, text: "\(done.formatted()) jobs done", role: nil, kind: "count"))
                }
            } else {
                committed += 1
                if committed == 100 || committed % 500 == 0 {
                    found.append(Milestone(date: event.date, text: "\(committed.formatted()) commits: the brain's tower grew", role: nil, kind: "count"))
                }
            }
            let reached = Era.reached(jobs: done + committed / commitsPerJob, days: days.count)
            if reached > era, done > 0 {
                era = reached
                found.append(Milestone(date: event.date, text: "Now \(reached.article) \(reached.title.lowercased()): \(reached.adds)", role: nil, kind: "era"))
            }
        }
        return Array(found.reversed().prefix(limit))
    }

    /// The office at `frames` moments from the first job to `now`, oldest first, for the replay.
    public static func timeline(jobs: [AgentJob], project: String, growth: Growth = Growth(), frames: Int = 24, now: Date = Date(), calendar: Calendar = .current) -> [AgentOffice] {
        let whole = build(jobs: jobs, project: project, growth: growth, now: now, calendar: calendar)
        guard let first = (jobs.map(\.date) + growth.commits).min(), frames > 1 else { return [whole] }
        let start = first.addingTimeInterval(1)
        let span = now.timeIntervalSince(start)
        guard span > 60 else { return [whole] }
        return (0..<frames).map { index in
            let at = index == frames - 1 ? now : start.addingTimeInterval(span * Double(index) / Double(frames - 1))
            var office = build(jobs: jobs, project: project, growth: growth, now: at, calendar: calendar)
            office.milestones = Array(office.milestones.prefix(3))
            return office
        }
    }

    /// How to draw whoever did a job.
    static func look(of job: AgentJob) -> String {
        if job.kind == Looker.kind { return "looker" }
        if job.kind == "subagent" { return "subagent" }
        switch job.provider {
        case .claude: return "claude"
        case .codex: return "codex"
        case .local: return "local"
        case .grok, .jev: return "cloud"
        }
    }

    static func title(of job: AgentJob) -> String {
        let text = job.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = text.isEmpty ? (job.gist ?? job.kind) : text
        return shown.count > 70 ? String(shown.prefix(69)) + "…" : shown
    }

    /// The light outside, by the hour: night, dawn, day or dusk.
    public static func ambience(hour: Int) -> String {
        switch hour {
        case 6..<8: "dawn"
        case 8..<18: "day"
        case 18..<20: "dusk"
        default: "night"
        }
    }
}

/// Someone at work in the office right now: the lead at the room of the file it's editing,
/// sub-agents and local models it handed work to, and anything waiting for you.
public struct OfficeWorker: Codable, Equatable, Sendable {
    public var role: OfficeRole
    public var look: String
    public var name: String
    public var doing: String
    public var waiting: Bool
    public var lead: Bool
    /// The job's title when the worker belongs to a job rather than the main conversation.
    public var job: String?

    public init(role: OfficeRole, look: String, name: String, doing: String, waiting: Bool = false, lead: Bool = false, job: String? = nil) {
        self.role = role
        self.look = look
        self.name = name
        self.doing = doing
        self.waiting = waiting
        self.lead = lead
        self.job = job
    }

    /// The workers in one conversation: its lead where its newest tool is, waiting edits and
    /// commands, and every hand-off still running.
    public static func from(tools: [ToolActivity], working: Bool, lead: String, root: URL, job: String? = nil) -> [OfficeWorker] {
        let leadLook = lead == "Codex" ? "codex" : "claude"
        var workers: [OfficeWorker] = []
        for tool in tools where tool.isAwaitingApproval {
            let role = OfficeRole.of(tool: tool.name, path: tool.input["file_path"]?.string.map { relative($0, root) }, command: tool.input["command"]?.string)
            workers.append(OfficeWorker(role: role, look: leadLook, name: lead, doing: line(tool, root), waiting: true, lead: true, job: job))
        }
        guard working else { return workers }
        for satellite in OrbSatellite.running(in: tools, lead: lead) {
            let role: OfficeRole
            let look: String
            switch satellite.kind {
            case .subagent(let type):
                role = ["explore", "plan"].contains(type.lowercased()) ? .research : OfficeRole.of(words: satellite.title) ?? .research
                look = "subagent"
            case .local(let kind):
                role = kind == Looker.kind ? .frontend : OfficeRole.of(job: AgentJob(kind: kind, provider: .local, model: "", project: ""))
                look = kind == Looker.kind ? "looker" : "local"
            case .cloud: role = .research; look = "cloud"
            case .codex: role = .quality; look = "codex"
            case .claude: role = .quality; look = "claude"
            }
            workers.append(OfficeWorker(role: role, look: look, name: satellite.agent, doing: satellite.task.isEmpty ? satellite.title : satellite.task, job: job))
        }
        if !workers.contains(where: { $0.lead }) {
            // The lead sits where its newest tool call is, thinking when there's none yet.
            let newest = tools.last { $0.name != "Task" && $0.name != "Agent" && !$0.name.hasPrefix("mcp__dante__delegate") }
            let role = newest.map { OfficeRole.of(tool: $0.name, path: $0.input["file_path"]?.string.map { relative($0, root) }, command: $0.input["command"]?.string) } ?? .research
            let doing = newest.flatMap { $0.status == .running ? line($0, root) : nil } ?? "thinking"
            workers.insert(OfficeWorker(role: role, look: leadLook, name: lead, doing: doing, lead: true, job: job), at: 0)
        }
        return workers
    }

    static func line(_ tool: ToolActivity, _ root: URL) -> String {
        let text = [tool.verb, tool.target(in: root)].filter { !$0.isEmpty }.joined(separator: " ")
        return text.count > 60 ? String(text.prefix(59)) + "…" : text
    }

    static func relative(_ path: String, _ root: URL) -> String {
        ProposedChange.relativePath(of: URL(filePath: path), in: root)
    }
}
