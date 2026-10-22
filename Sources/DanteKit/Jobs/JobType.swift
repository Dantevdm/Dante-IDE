import Foundation
import Yams

/// A kind of job, defined in `.dante/jobs/<id>.md`: front matter for when it starts, what it
/// works from, what it may touch and run, and how long it may go on alone; the markdown body
/// is how to do it.
///
///     ---
///     name: Pipeline watcher
///     description: When CI goes red, finds the failing step and fixes it
///     starts: ci-failed           # or manual (the default)
///     branches: [main]            # ci-failed: watch these branches while they're checked out
///     input: task                 # manual: a task from .dante/tasks.yaml rather than words
///     away: 30                    # away mode for this many minutes when it starts
///     agent: claude               # or codex
///     paths: [src/, tests/]       # edits elsewhere wait for the person
///     commands: [gh run view]     # more commands it may run while away
///     uses: ci-fixer              # a Claude Code agent in .claude/agents to work as
///     ---
///     How to do the job…
public struct JobType: Identifiable, Equatable, Sendable {
    public enum Trigger: String, Sendable {
        case manual
        case ciFailed = "ci-failed"
    }

    public enum Input: String, Sendable {
        case text, task
    }

    public var id: String
    public var name: String
    public var summary: String
    public var trigger: Trigger
    public var branches: [String]
    public var input: Input
    public var awayMinutes: Int?
    /// "claude" or "codex"; nil for the one in charge.
    public var agent: String?
    public var paths: [String]
    public var commands: [String]
    public var uses: String?
    public var brief: String
    /// The file it was read from; nil for a built-in type the project hasn't copied.
    public var file: URL?

    public init(id: String, name: String, summary: String = "", trigger: Trigger = .manual, branches: [String] = [],
                input: Input = .text, awayMinutes: Int? = nil, agent: String? = nil, paths: [String] = [],
                commands: [String] = [], uses: String? = nil, brief: String, file: URL? = nil) {
        self.id = id
        self.name = name
        self.summary = summary
        self.trigger = trigger
        self.branches = branches
        self.input = input
        self.awayMinutes = awayMinutes
        self.agent = agent
        self.paths = paths
        self.commands = commands
        self.uses = uses
        self.brief = brief
        self.file = file
    }

    public var isBuiltIn: Bool { file == nil }

    /// Where the project keeps its job types.
    public static func folder(in root: URL) -> URL { root.appending(path: ".dante/jobs", directoryHint: .isDirectory) }

    // MARK: Reading

    /// Reads a type from its file's text, leniently: unknown keys and odd values are ignored.
    public static func parse(_ text: String, id: String, file: URL? = nil) -> JobType {
        let (meta, body) = split(text)
        func string(_ key: String) -> String? {
            guard let value = meta[key] else { return nil }
            let text = "\(value)".trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        func list(_ key: String) -> [String] {
            if let values = meta[key] as? [Any] { return values.map { "\($0)" }.filter { !$0.isEmpty } }
            return string(key).map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } ?? []
        }
        let away = (meta["away"] as? Int) ?? string("away").flatMap { Int($0.split(separator: " ").first ?? "") }
        let trigger = string("starts").flatMap { Trigger(rawValue: $0.lowercased()) } ?? .manual
        return JobType(
            id: id,
            name: string("name") ?? id.replacingOccurrences(of: "-", with: " ").capitalized,
            summary: string("description") ?? "",
            trigger: trigger,
            branches: list("branches"),
            input: string("input").flatMap { Input(rawValue: $0.lowercased()) } ?? .text,
            awayMinutes: away.flatMap { $0 > 0 ? min($0, 24 * 60) : nil },
            agent: string("agent").map { $0.lowercased() }.flatMap { ["claude", "codex"].contains($0) ? $0 : nil },
            paths: list("paths"),
            commands: list("commands"),
            uses: string("uses"),
            brief: body.trimmingCharacters(in: .whitespacesAndNewlines),
            file: file
        )
    }

    /// The front matter as a dictionary, and the text after it.
    static func split(_ text: String) -> ([String: Any], String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([:], text)
        }
        let yaml = lines[1..<end].joined(separator: "\n")
        let meta = ((try? Yams.load(yaml: yaml)) as? [String: Any]) ?? [:]
        return (meta, lines[(end + 1)...].joined(separator: "\n"))
    }

    /// The project's types from `.dante/jobs/`, then the built-in ones it hasn't replaced.
    public static func load(projectRoot root: URL) -> [JobType] {
        let folder = folder(in: root)
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let project = files.compactMap { file -> JobType? in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return parse(text, id: file.deletingPathExtension().lastPathComponent, file: file)
        }
        let ids = Set(project.map(\.id))
        return project + builtIn.filter { !ids.contains($0.id) }
    }

    // MARK: Writing

    /// The type as a file for `.dante/jobs/`, so a built-in one can be copied and changed.
    public var markdown: String {
        func quoted(_ text: String) -> String {
            text.contains(where: { ":#[]{},&*!|>'\"%@`".contains($0) }) ? "\"\(text.replacingOccurrences(of: "\"", with: "\\\""))\"" : text
        }
        func list(_ values: [String]) -> String { "[" + values.map(quoted).joined(separator: ", ") + "]" }
        var lines = ["---", "name: \(quoted(name))"]
        if !summary.isEmpty { lines.append("description: \(quoted(summary))") }
        lines.append("starts: \(trigger.rawValue)")
        if !branches.isEmpty { lines.append("branches: \(list(branches))") }
        if input != .text { lines.append("input: \(input.rawValue)") }
        if let awayMinutes { lines.append("away: \(awayMinutes)") }
        if let agent { lines.append("agent: \(agent)") }
        if !paths.isEmpty { lines.append("paths: \(list(paths))") }
        if !commands.isEmpty { lines.append("commands: \(list(commands))") }
        if let uses { lines.append("uses: \(quoted(uses))") }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n" + brief + "\n"
    }

    /// Writes the type into the project's `.dante/jobs/` (a built-in one becomes the project's
    /// own to change) and returns the file. An existing file is left as it is.
    public func copy(into root: URL) throws -> URL {
        if let file { return file }
        let folder = Self.folder(in: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(id).md")
        if !FileManager.default.fileExists(atPath: url.path) {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    // MARK: Briefing

    /// The job's first message: what to do this time, then how this kind of job is done
    /// (and the Claude Code agent it works as, when it names one).
    public func request(_ subject: String, projectRoot root: URL) -> String {
        var text = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        var how = brief
        if let uses, let agent = Self.agentBrief(uses, in: root) {
            how += (how.isEmpty ? "" : "\n\n") + "Work as the `\(uses)` agent (.claude/agents/\(uses).md):\n\n" + agent
        }
        if !how.isEmpty { text += "\n\n## How to do this job (\(name))\n\n" + how }
        if !paths.isEmpty { text += "\n\nKeep your changes to \(paths.joined(separator: ", ")); anything else waits for the person." }
        return text
    }

    /// What a task asks, for a job that works from one.
    public static func subject(for task: PlanTask, in root: URL) -> String {
        var lines = ["Take \(task.id): \(task.title)"]
        if let note = task.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty { lines.append("Notes: \(note)") }
        if let spec = task.specPath(in: root) { lines.append("Spec: \(spec)") }
        return lines.joined(separator: "\n")
    }

    /// What a failed CI run asks.
    public static func subject(for run: CIRun) -> String {
        var line = "CI is red: \(run.workflow.isEmpty ? "a workflow" : run.workflow) failed on \(run.branch)"
        if !run.title.isEmpty { line += " (\(run.title))" }
        line += ". Run \(run.id)"
        if let url = run.url { line += ", \(url.absoluteString)" }
        return line + "."
    }

    /// The body of a Claude Code agent file in `.claude/agents/`.
    static func agentBrief(_ name: String, in root: URL) -> String? {
        guard !name.contains("/"), !name.contains("..") else { return nil }
        let url = root.appending(path: ".claude/agents/\(name).md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let body = split(text).1.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    // MARK: Built in

    public static let builder = JobType(
        id: "builder",
        name: "Builder",
        summary: "Takes a task from .dante/tasks.yaml and builds it on its own branch",
        input: .task,
        awayMinutes: 60,
        brief: """
        Build the task end to end on this branch.

        1. Read the task, its spec if it names one, and the code it touches before changing anything.
        2. Make the change in small steps, following the project's conventions (CLAUDE.md and the code around it).
        3. Add or update tests for what you changed, and run the project's tests until they pass.
        4. In `.dante/tasks.yaml`, move the task's `state:` to `review` and add a short `notes:` line on what was done.
        5. Commit with a message that names the task's id.

        If the task is unclear or bigger than it looks, stop and ask rather than guessing.
        """
    )

    public static let pipelineWatcher = JobType(
        id: "pipeline-watcher",
        name: "Pipeline watcher",
        summary: "When CI goes red, finds the failing step and fixes it on a branch",
        trigger: .ciFailed,
        awayMinutes: 30,
        commands: ["gh run view", "gh run list"],
        brief: """
        Find out why CI failed and fix it on this branch.

        1. Read the failing step's log with `gh run view <run id> --log-failed`.
        2. Reproduce the failure here if you can, with the same build or test command.
        3. Fix the cause, not the symptom: don't skip or delete failing tests, loosen checks or retry until it's green.
        4. Run the failing command again until it passes, then commit with a message that says what broke.

        If the failure is in CI itself (a secret, a runner, an outside service) rather than in the code, don't change code: explain what's wrong and what the person needs to do.
        """
    )

    public static let verifier = JobType(
        id: "verifier",
        name: "Verifier",
        summary: "Tries the running app in its own browser and reports what's broken, with screenshots",
        awayMinutes: 30,
        commands: ["curl", "lsof -i", "npm run", "pnpm run", "pnpm dev", "yarn dev", "yarn run", "bun run", "docker compose up", "docker compose ps"],
        brief: """
        Check the app as a user would, in your own browser (the browser_ tools), and report what's wrong. Don't change the code.

        1. Find how the app runs (README, package.json scripts, docker-compose, CLAUDE.md) and its address. If nothing answers there, start it in the background with the project's own dev command, wait for the port, and stop it when you're done.
        2. Open it and go through what this request names; with no particular flow, the main screens: the first page, navigation, lists, detail pages and the main form.
        3. On each page look for page errors and failed requests (every read lists them), broken links, empty or stuck loading states, forms that accept bad input or lose what was typed, and text that doesn't make sense.
        4. Check the main screens at phone width too (browser_resize to 390 wide).
        5. Take a screenshot of each problem.
        6. Sign in only with test accounts from the project's seed, fixture or example files. If a page needs anything else, say so and move on.

        Finish with one line per finding, worst first, then a sentence on what you covered:
        - [blocker|issue|nit] page or address: what's wrong, how to see it, and the screenshot's path
        """
    )

    public static let builtIn: [JobType] = [builder, pipelineWatcher, verifier]
}

/// When Dante starts jobs by itself. Waiting is Dante's job, not the agent's: Dante watches
/// CI and wakes a job with what happened, so no model sits polling.
public enum JobTrigger {
    /// The record's `trigger` for a job started by a CI run.
    public static func ci(_ run: CIRun) -> String { "ci:\(run.workflow)@\(run.branch)#\(run.id)" }

    static let failed: Set<String> = ["failure", "timed_out", "startup_failure"]

    /// Failed runs worth a job: finished since Dante started watching (not in `baseline`),
    /// on a watched branch, not handled before, and with no open job on the same workflow and
    /// branch. The newest failure per workflow and branch only.
    public static func newFailures(in runs: [CIRun], baseline: Set<Int>, branches: Set<String>, jobs: [JobRecord]) -> [CIRun] {
        let handled = Set(jobs.compactMap(\.trigger))
        let busy = Set(jobs.filter { $0.outcome == .open }.compactMap { $0.trigger.map(workflowAndBranch) })
        var seen: Set<String> = []
        return runs
            .filter { !$0.isRunning && failed.contains($0.conclusion) && !baseline.contains($0.id) && branches.contains($0.branch) }
            .sorted { ($0.created ?? .distantPast, $0.id) > ($1.created ?? .distantPast, $1.id) }
            .filter { run in
                let key = workflowAndBranch(ci(run))
                guard !handled.contains(ci(run)), !busy.contains(key), !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
    }

    /// Runs that had already finished when watching began: their failures aren't news.
    public static func baseline(_ runs: [CIRun]) -> Set<Int> { Set(runs.filter { !$0.isRunning }.map(\.id)) }

    static func workflowAndBranch(_ trigger: String) -> String {
        trigger.split(separator: "#").first.map(String.init) ?? trigger
    }
}
