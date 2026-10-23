import Foundation

/// Gathers the morning update on the Mac: each recent project's git log, latest test run,
/// saved security report and pipelines (GitHub Actions through `gh`, Azure DevOps from the
/// runs Dante already keeps), and, when switched on, Outlook's mail and calendar. Nothing is
/// opened, built or scanned; the projects don't need a window.
public enum BriefingGatherer {
    public struct Project: Sendable {
        public var id: String
        public var name: String
        public var root: URL

        public init(id: String, name: String, root: URL) {
            self.id = id
            self.name = name
            self.root = root
        }
    }

    public struct Options: Sendable {
        public var now: Date
        public var projects: [Project]
        public var name: String?
        public var readsMail: Bool
        public var readsCalendar: Bool
        public var vips: [String]

        public init(now: Date = .now, projects: [Project], name: String? = nil, readsMail: Bool = false, readsCalendar: Bool = false, vips: [String] = []) {
            self.now = now
            self.projects = projects
            self.name = name
            self.readsMail = readsMail
            self.readsCalendar = readsCalendar
            self.vips = vips
        }

        /// From the preferences.
        @MainActor public static func current(projects: [Project], now: Date = .now) -> Options {
            let preferences = Preferences.shared
            let vips = preferences.briefingVIPs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return Options(now: now, projects: projects, name: preferences.assistantName.isEmpty ? nil : preferences.assistantName,
                           readsMail: preferences.briefingReadsMail, readsCalendar: preferences.briefingReadsCalendar, vips: vips)
        }
    }

    public static func gather(_ options: Options) async -> Briefing {
        let since = ProjectDigest.cutOff(at: options.now)
        async let digests = withTaskGroup(of: (Int, ProjectDigest).self) { group in
            for (index, project) in options.projects.enumerated() {
                group.addTask { (index, await digest(project, since: since)) }
            }
            var all: [(Int, ProjectDigest)] = []
            for await item in group { all.append(item) }
            return all.sorted { $0.0 < $1.0 }.map(\.1)
        }
        async let me = identities(options.projects.map(\.root))
        async let mail: Result<[ImportantMail], Outlook.Failure>? = options.readsMail ? readMail(since: since, now: options.now, vips: options.vips) : nil
        async let calendar: Result<[CalendarEntry], Outlook.Failure>? = options.readsCalendar ? readCalendar(on: options.now) : nil
        let input = BriefingComposer.Input(now: options.now, name: options.name, me: await me, projects: await digests,
                                           mail: await mail, calendar: await calendar)
        return BriefingComposer.compose(input)
    }

    static func digest(_ project: Project, since: Date) async -> ProjectDigest {
        let root = project.root
        async let log = Shell.run(ProjectDigest.logArguments(since: since), in: root)
        async let ci: [CIRun] = CIRun.hasWorkflows(projectRoot: root) ? ((try? await CIRun.load(projectRoot: root, limit: 20).get()) ?? []) : []
        let tests = TestRecord.load(for: root).last.flatMap { $0.date >= since.addingTimeInterval(-6 * 86_400) ? $0 : nil }
        let security = SecurityReport.load(for: root)
        let pipelines = PipelineHistory.load(for: root).runs.filter { ($0.queued ?? .distantPast) >= since }
        let commits = await log.succeeded ? ProjectDigest.parseLog(await log.stdout) : []
        return ProjectDigest(id: project.id, name: project.name, commits: commits, tests: tests, securityScore: security?.score,
                             criticalFindings: security?.count(.critical) ?? 0,
                             ci: await ci.filter { ($0.created ?? .distantPast) >= since }, pipelines: pipelines)
    }

    /// Your names and addresses in git, global and each project's own, so your own commits
    /// read as "you".
    static func identities(_ roots: [URL]) async -> [String] {
        var found = Set<String>()
        for folder in [FileManager.default.homeDirectoryForCurrentUser] + roots {
            async let name = Shell.run(["git", "config", "user.name"], in: folder)
            async let email = Shell.run(["git", "config", "user.email"], in: folder)
            for value in [await name.stdout, await email.stdout] {
                let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { found.insert(value) }
            }
        }
        return found.sorted()
    }

    static func readMail(since: Date, now: Date, vips: [String]) async -> Result<[ImportantMail], Outlook.Failure> {
        let hours = max(12, Int(now.timeIntervalSince(since) / 3600) + 1)
        do { return .success(MailTriage.important(try await Outlook.mail(hours: hours, limit: 80), vips: vips)) } catch { return .failure(error) }
    }

    static func readCalendar(on day: Date) async -> Result<[CalendarEntry], Outlook.Failure> {
        do { return .success(try await Outlook.calendar(on: day)) } catch { return .failure(error) }
    }
}
