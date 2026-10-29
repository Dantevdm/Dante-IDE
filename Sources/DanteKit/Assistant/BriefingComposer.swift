import Foundation

/// What happened in one project since the last update: commits, the latest test run, the
/// security score and the pipelines. Gathered on the Mac (`BriefingGatherer`); this part is pure.
public struct ProjectDigest: Equatable, Sendable {
    public struct Commit: Equatable, Sendable {
        public var hash: String
        public var author: String
        public var email: String
        public var date: Date
        public var subject: String

        public init(hash: String, author: String, email: String = "", date: Date, subject: String) {
            self.hash = hash
            self.author = author
            self.email = email
            self.date = date
            self.subject = subject
        }
    }

    /// The companion's id for the project, so a tap can open it.
    public var id: String
    public var name: String
    public var commits: [Commit]
    public var tests: TestRecord?
    public var securityScore: Int?
    public var criticalFindings: Int
    /// GitHub Actions runs and Azure DevOps runs since the cut-off, newest first.
    public var ci: [CIRun]
    public var pipelines: [PipelineRun]

    public init(id: String, name: String, commits: [Commit] = [], tests: TestRecord? = nil, securityScore: Int? = nil,
                criticalFindings: Int = 0, ci: [CIRun] = [], pipelines: [PipelineRun] = []) {
        self.id = id
        self.name = name
        self.commits = commits
        self.tests = tests
        self.securityScore = securityScore
        self.criticalFindings = criticalFindings
        self.ci = ci
        self.pipelines = pipelines
    }

    /// `git log` arguments whose output `parseLog` reads: merges left out, every branch.
    public static func logArguments(since: Date) -> [String] {
        ["git", "log", "--all", "--no-merges", "--since=\(Int(since.timeIntervalSince1970))", "--format=%H%x1f%an%x1f%ae%x1f%aI%x1f%s%x1e"]
    }

    public static func parseLog(_ output: String) -> [Commit] {
        let formatter = ISO8601DateFormatter()
        var seen = Set<String>()
        return output.components(separatedBy: "\u{1E}").compactMap { record in
            let fields = record.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1F}")
            guard fields.count >= 5, let date = formatter.date(from: fields[3]), seen.insert(fields[0]).inserted else { return nil }
            return Commit(hash: fields[0], author: fields[1], email: fields[2], date: date, subject: fields[4...].joined(separator: " "))
        }
    }

    /// Where an update looks back to: six this morning's day before, or Friday morning on a
    /// Monday, so a weekend's work isn't missed.
    public static func cutOff(at now: Date, calendar: Calendar = .current) -> Date {
        let back = calendar.component(.weekday, from: now) == 2 ? 3 : 1
        let day = calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(-86_400)
        return calendar.date(bySettingHour: 6, minute: 0, second: 0, of: day) ?? day
    }
}

/// Writes the morning update from what the Mac gathered, in short sentences meant to be heard.
public enum BriefingComposer {
    public struct Input: Sendable {
        public var now: Date
        /// The person's first name for the greeting.
        public var name: String?
        /// Their names and addresses in git, so their own commits read as "you".
        public var me: [String]
        public var projects: [ProjectDigest]
        /// Nil when mail isn't part of the update.
        public var mail: Result<[ImportantMail], Outlook.Failure>?
        public var calendar: Result<[CalendarEntry], Outlook.Failure>?

        public init(now: Date, name: String? = nil, me: [String] = [], projects: [ProjectDigest],
                    mail: Result<[ImportantMail], Outlook.Failure>? = nil, calendar: Result<[CalendarEntry], Outlook.Failure>? = nil) {
            self.now = now
            self.name = name
            self.me = me
            self.projects = projects
            self.mail = mail
            self.calendar = calendar
        }
    }

    public static func compose(_ input: Input, calendar: Calendar = .current, locale: Locale = .current) -> Briefing {
        var sections = [projects(input), pipelines(input)]
        if let mail = input.mail { sections.append(self.mail(mail)) }
        if let entries = input.calendar { sections.append(today(entries, now: input.now, calendar: calendar, locale: locale)) }
        return Briefing(date: input.now, greeting: Briefing.greeting(at: input.now, name: input.name, calendar: calendar), sections: sections,
                        pipelines: pipelineList(input))
    }

    /// Each pipeline's newest run, failures first, then running, then by time.
    static func pipelineList(_ input: Input) -> [Briefing.Pipeline] {
        var list: [Briefing.Pipeline] = []
        for project in input.projects {
            let byPipeline = Dictionary(grouping: project.pipelines) { $0.pipeline + "|" + $0.branch }
            for (key, runs) in byPipeline {
                let sorted = runs.sorted { ($0.queued ?? .distantPast) < ($1.queued ?? .distantPast) }
                guard let run = sorted.last else { continue }
                list.append(.init(id: project.id + "|" + key, project: project.name, name: run.pipeline, branch: run.branch, number: run.number,
                                  status: status(run.status), state: run.status.title, started: run.started ?? run.queued, finished: run.finished,
                                  requestedBy: run.requestedBy.isEmpty ? nil : run.requestedBy, reason: run.reason.isEmpty ? nil : run.reason,
                                  commit: run.commit.isEmpty ? nil : String(run.commit.prefix(7)), environment: run.environment.title, url: run.url,
                                  stages: run.stages.map { .init(name: $0.name, status: status($0.state), state: $0.state.title, active: $0.state.isActive) },
                                  history: sorted.dropLast().suffix(9).map { status($0.status) }))
            }
            let byWorkflow = Dictionary(grouping: project.ci) { $0.workflow + "|" + $0.branch }
            for (key, runs) in byWorkflow {
                let sorted = runs.sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
                guard let run = sorted.last else { continue }
                let state = run.isRunning ? "Running" : run.succeeded ? "Succeeded" : run.conclusion.isEmpty ? "Finished" : run.conclusion.capitalized
                list.append(.init(id: project.id + "|ci|" + key, project: project.name, name: run.workflow, branch: run.branch, status: status(run),
                                  state: state, started: run.created, finished: run.isRunning ? nil : run.created, url: run.url,
                                  history: sorted.dropLast().suffix(9).map(status)))
            }
        }
        func rank(_ pipeline: Briefing.Pipeline) -> Int { pipeline.status == .bad ? 0 : pipeline.isRunning ? 1 : 2 }
        return list.sorted { (rank($0), $1.started ?? .distantPast) < (rank($1), $0.started ?? .distantPast) }
    }

    static func status(_ status: PipelineRun.Status) -> Briefing.Status {
        switch status {
        case .succeeded: .good
        case .failed: .bad
        case .partial, .queued, .running: .attention
        case .canceled, .skipped: .quiet
        }
    }

    static func status(_ run: CIRun) -> Briefing.Status {
        if run.isRunning { return .attention }
        if run.succeeded { return .good }
        return run.conclusion == "cancelled" || run.conclusion == "skipped" ? .quiet : .bad
    }

    // MARK: Projects

    static func projects(_ input: Input) -> Briefing.Section {
        let me = Set(input.me.map { $0.lowercased() })
        var lines: [String] = []
        var items: [Briefing.Item] = []
        var status: Briefing.Status = .quiet
        let busy = input.projects.filter { !$0.commits.isEmpty }.sorted { $0.commits.count > $1.commits.count }
        for (index, project) in busy.enumerated() {
            let byAuthor = Dictionary(grouping: project.commits) { commit in
                me.contains(commit.author.lowercased()) || me.contains(commit.email.lowercased()) ? "You" : commit.author
            }
            let authors = byAuthor.sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
            status = .good
            for (name, commits) in authors {
                items.append(.init(id: "\(project.id)|\(name)", title: "\(name) · \(project.name)", detail: topics(commits, limit: 3),
                                   time: commits.map(\.date).max(), status: .good, project: project.id))
            }
            // The three busiest projects are said; the rest are counted.
            guard index < 3 else { continue }
            let who = authors.prefix(2).map { author in
                "\(author.key == "You" ? "you" : author.key) made \(count(author.value.count, "change"))"
            }
            var sentence = "In \(project.name), " + list(Array(who))
            if authors.count > 2 { sentence += ", with \(count(authors.count - 2, "other")) helping" }
            let what = topics(project.commits)
            if !what.isEmpty { sentence += ": " + what }
            lines.append(sentence + ".")
        }
        if busy.count > 3 { lines.append("And changes in \(count(busy.count - 3, "other project")).") }
        // Problems in any project, quiet or not.
        for project in input.projects {
            if let tests = project.tests, !tests.succeeded {
                lines.append(tests.brokeOutsideTests ? "The build is broken in \(project.name)." : "\(Count(tests.failed, "test")) \(tests.failed == 1 ? "is" : "are") failing in \(project.name).")
                items.append(.init(id: "\(project.id)|tests", title: "Tests failing · \(project.name)", detail: tests.failedTests?.prefix(3).joined(separator: ", "),
                                   time: tests.date, status: .attention, project: project.id))
                status = .attention
            }
            if project.criticalFindings > 0 {
                lines.append("\(project.name) has \(count(project.criticalFindings, "critical security finding")).")
                items.append(.init(id: "\(project.id)|security", title: "Security · \(project.name)",
                                   detail: project.securityScore.map { "Score \($0)" }, status: .attention, project: project.id))
                status = .attention
            }
        }
        if busy.isEmpty, lines.isEmpty { lines.append(input.projects.isEmpty ? "" : "No new changes in your projects.") }
        else if !busy.isEmpty, status == .good, input.projects.allSatisfy({ $0.tests?.succeeded ?? true }) {
            if input.projects.contains(where: { $0.tests != nil }) { lines.append("Tests are passing.") }
        }
        return .init(kind: .projects, summary: lines.prefix(5).joined(separator: " "), status: status, items: items)
    }

    /// Two or three commit subjects made speakable: "fix(login): Handle expired tokens" →
    /// "handle expired tokens".
    static func topics(_ commits: [ProjectDigest.Commit], limit: Int = 2) -> String {
        var seen = Set<String>()
        let subjects = commits.sorted { $0.date > $1.date }.compactMap { commit -> String? in
            let topic = speakable(commit.subject)
            guard !topic.isEmpty, seen.insert(topic.lowercased()).inserted else { return nil }
            return topic
        }
        guard !subjects.isEmpty else { return "" }
        let shown = Array(subjects.prefix(limit))
        return list(shown) + (subjects.count > limit ? ", and more" : "")
    }

    static func speakable(_ subject: String) -> String {
        var text = subject.trimmingCharacters(in: .whitespaces)
        // Conventional commit prefixes and ticket ids.
        if let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) <= 20,
           text[text.startIndex..<colon].allSatisfy({ $0.isLetter || $0.isNumber || "()-_!/ ".contains($0) }) {
            text = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        text = text.replacingOccurrences(of: #"^\[?[A-Z][A-Z0-9]+-\d+\]?[: ]*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s*\(#\d+\)$"#, with: "", options: .regularExpression)
        // "Explore from the iPhone: docs, pictures…" → "Explore from the iPhone".
        for separator in [": ", " — ", " - ", "; "] {
            if let range = text.range(of: separator), text[..<range.lowerBound].split(separator: " ").count >= 3 {
                text = String(text[..<range.lowerBound])
            }
        }
        if text.count > 70, let space = text.prefix(70).lastIndex(of: " ") { text = String(text[..<space]) }
        if text.hasSuffix(".") || text.hasSuffix(",") { text.removeLast() }
        guard let first = text.first else { return "" }
        // Lower-case the first word unless it's a name or an acronym.
        let word = text.prefix { !$0.isWhitespace }
        if word.count > 1, word.dropFirst().allSatisfy({ $0.isLowercase || !$0.isLetter }) { return first.lowercased() + text.dropFirst() }
        return text
    }

    // MARK: Pipelines

    static func pipelines(_ input: Input) -> Briefing.Section {
        var failed: [(project: ProjectDigest, name: String, branch: String, date: Date?)] = []
        var passed = 0
        var running = 0
        var items: [Briefing.Item] = []
        for project in input.projects {
            for run in project.ci {
                if run.isRunning { running += 1 } else if run.succeeded { passed += 1 } else if run.conclusion != "cancelled" && run.conclusion != "skipped" {
                    failed.append((project, run.workflow, run.branch, run.created))
                }
            }
            for run in project.pipelines {
                switch run.status {
                case .queued, .running: running += 1
                case .succeeded: passed += 1
                case .failed, .partial: failed.append((project, run.pipeline, run.branch, run.finished ?? run.queued))
                case .canceled, .skipped: break
                }
            }
        }
        // Only the newest failure per pipeline counts; a later pass clears it.
        var newest: [String: (project: ProjectDigest, name: String, branch: String, date: Date?)] = [:]
        for failure in failed {
            let key = failure.project.id + "|" + failure.name + "|" + failure.branch
            if newest[key] == nil || (failure.date ?? .distantPast) > (newest[key]?.date ?? .distantPast) { newest[key] = failure }
        }
        let cleared = newest.filter { key, failure in
            input.projects.contains { project in
                project.id == failure.project.id && (project.ci.contains { $0.workflow == failure.name && $0.branch == failure.branch && $0.succeeded && ($0.created ?? .distantPast) > (failure.date ?? .distantPast) }
                    || project.pipelines.contains { $0.pipeline == failure.name && $0.branch == failure.branch && $0.status == .succeeded && ($0.finished ?? $0.queued ?? .distantPast) > (failure.date ?? .distantPast) })
            }
        }
        let open = newest.filter { cleared[$0.key] == nil }.values.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        for failure in open {
            items.append(.init(id: "\(failure.project.id)|\(failure.name)|\(failure.branch)", title: "\(failure.name) failed · \(failure.project.name)",
                               detail: failure.branch.isEmpty ? nil : failure.branch, time: failure.date, status: .bad, project: failure.project.id))
        }
        let total = passed + running + failed.count
        guard total > 0 else { return .init(kind: .pipelines, summary: "", status: .quiet) }
        var lines: [String] = []
        if open.isEmpty {
            lines.append(passed > 0 ? "Pipelines look good: \(count(passed, "run")) passed." : "")
        } else {
            let named = open.prefix(2).map { "\($0.name) in \($0.project.name)" + ($0.branch.isEmpty ? "" : " on \($0.branch)") }
            lines.append(list(named) + " failed." + (open.count > 2 ? " \(Count(open.count - 2, "other pipeline")) too." : ""))
            if passed > 0 { lines.append("\(Count(passed, "other run")) passed.") }
        }
        if running > 0 { lines.append("\(Count(running, "run")) still going.") }
        return .init(kind: .pipelines, summary: lines.filter { !$0.isEmpty }.joined(separator: " "), status: open.isEmpty ? .good : .bad, items: items)
    }

    // MARK: Mail

    static func mail(_ result: Result<[ImportantMail], Outlook.Failure>) -> Briefing.Section {
        switch result {
        case .failure(let failure):
            return .init(kind: .mail, summary: "I couldn't read your mail.", status: .quiet, problem: failure.errorDescription)
        case .success(let mail) where mail.isEmpty:
            return .init(kind: .mail, summary: "Nothing in your inbox needs you.", status: .good)
        case .success(let mail):
            let named = mail.prefix(3).map { "\($0.message.sender) about \(speakableSubject($0.message.subject))" }
            let summary = (mail.count == 1 ? "One email looks important: " : "\(Count(mail.count, "email")) look important: ") + list(Array(named)) + "."
            let items = mail.map { mail in
                Briefing.Item(id: "mail|" + mail.id, title: "\(mail.message.sender): \(mail.message.subject)", detail: mail.gist,
                              time: mail.message.received, status: mail.reasons.contains("flagged") || mail.message.priority == .high ? .attention : .good)
            }
            return .init(kind: .mail, summary: summary, status: .attention, items: items)
        }
    }

    /// "RE: FW: Q3 budget sign-off" → "the Q3 budget sign-off".
    static func speakableSubject(_ subject: String) -> String {
        var text = subject.trimmingCharacters(in: .whitespaces)
        while let range = text.range(of: #"^(re|fw|fwd|aw|sv)\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) { text.removeSubrange(range) }
        text = text.replacingOccurrences(of: #"^\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
        if text.isEmpty { return "something with no subject" }
        let lower = text.lowercased()
        return lower.hasPrefix("the ") || lower.hasPrefix("a ") || lower.hasPrefix("your ") ? text : "the " + text
    }

    // MARK: Calendar

    static func today(_ result: Result<[CalendarEntry], Outlook.Failure>, now: Date, calendar: Calendar, locale: Locale) -> Briefing.Section {
        switch result {
        case .failure(let failure):
            return .init(kind: .calendar, summary: "I couldn't read your calendar.", status: .quiet, problem: failure.errorDescription)
        case .success(let entries):
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("jmm")
            let timed = entries.filter { !$0.isAllDay && $0.end > now }
            let allDay = entries.filter(\.isAllDay)
            let items = entries.map { entry in
                Briefing.Item(id: "cal|" + entry.id, title: entry.title, detail: entry.isAllDay ? "All day" : [formatter.string(from: entry.start), entry.location].filter { !$0.isEmpty }.joined(separator: " · "),
                              time: entry.start, status: .good)
            }
            var lines: [String] = []
            if timed.isEmpty {
                lines.append(entries.contains { !$0.isAllDay } ? "No more meetings today." : "Your calendar is clear today.")
            } else {
                let first = timed[0]
                let lead = timed.count == 1 ? "One meeting today" : "\(Count(timed.count, "meeting")) today"
                let when = first.start <= now ? "\(first.title) is on now" : "the first is \(first.title) at \(formatter.string(from: first.start))"
                lines.append("\(lead): \(when).")
                if let clash = clashes(timed) { lines.append("\(clash.0.title) and \(clash.1.title) overlap.") }
            }
            if let day = allDay.first { lines.append(allDay.count == 1 ? "All day: \(day.title)." : "\(Count(allDay.count, "all-day item")) too.") }
            return .init(kind: .calendar, summary: lines.joined(separator: " "), status: timed.isEmpty ? .quiet : .good, items: items)
        }
    }

    static func clashes(_ entries: [CalendarEntry]) -> (CalendarEntry, CalendarEntry)? {
        let sorted = entries.sorted { $0.start < $1.start }
        for (a, b) in zip(sorted, sorted.dropFirst()) where b.start < a.end { return (a, b) }
        return nil
    }

    // MARK: Words

    static func count(_ n: Int, _ noun: String) -> String {
        let words = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        let number = n < words.count ? words[n] : "\(n)"
        return number + " " + noun + (n == 1 ? "" : "s")
    }

    /// `count` at the start of a sentence.
    static func Count(_ n: Int, _ noun: String) -> String {
        let text = count(n, noun)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}
