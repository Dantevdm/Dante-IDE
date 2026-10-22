import Foundation

/// The foreman: what the phone says in your ear while you walk. It watches snapshots for the
/// moments worth speaking (a reply finished, something needs an answer, a job is done),
/// answers "status" from the snapshot without a turn, and reads what you say.
public enum CompanionForeman {
    public enum Event: Equatable, Sendable {
        /// A conversation finished a turn: the main one (job nil) or a job's.
        case replied(project: String, job: String?, text: String)
        /// A step waits for an answer.
        case waiting(project: String, CompanionSnapshot.Approval)
        /// A job stopped working: ready to review, stopped, or asking.
        case jobChanged(project: String, CompanionSnapshot.Job)
    }

    /// What changed between two snapshots that's worth saying, in order.
    public static func events(from old: CompanionSnapshot?, to new: CompanionSnapshot) -> [Event] {
        guard let old else { return [] }
        var events: [Event] = []
        let before = Dictionary(old.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for project in new.projects {
            guard let previous = before[project.id] else { continue }
            if previous.working, !project.working, !project.lastReply.isEmpty {
                events.append(.replied(project: project.id, job: nil, text: project.lastReply))
            }
            let jobs = Dictionary(previous.jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for job in project.jobs {
                guard let was = jobs[job.id], was.state != job.state else { continue }
                if [.ready, .failed, .asking].contains(job.state) { events.append(.jobChanged(project: project.id, job)) }
            }
            let known = Set(previous.approvals.map(\.id))
            for approval in project.approvals where !known.contains(approval.id) {
                events.append(.waiting(project: project.id, approval))
            }
        }
        return events
    }

    /// What to say for an event: short, with no code.
    public static func spoken(_ event: Event, in snapshot: CompanionSnapshot) -> String {
        let name = { (id: String) in snapshot.projects.first { $0.id == id }?.name ?? "the project" }
        switch event {
        case .replied(_, _, let text):
            return SpokenReply.text(from: text)
        case .waiting(let project, let approval):
            return ask(approval, project: name(project), lead: snapshot.projects.first { $0.id == project }?.lead ?? "Claude")
        case .jobChanged(let project, let job):
            switch job.state {
            case .ready: return "The job \(job.title) in \(name(project)) is ready to review."
            case .failed: return "The job \(job.title) in \(name(project)) stopped. \(job.label)."
            default: return "The job \(job.title) in \(name(project)) has a question."
            }
        }
    }

    /// "Claude wants to run go test in shop. Yes or no?"
    public static func ask(_ approval: CompanionSnapshot.Approval, project: String, lead: String) -> String {
        let who = approval.job == nil ? lead : "The job \(approval.from)"
        if let question = approval.questions.first {
            let options = question.options.prefix(4)
            let choices = options.isEmpty ? "" : " The options are " + list(options.map { $0 }, or: true) + "."
            return "\(who) in \(project) asks: \(question.question)\(choices)"
        }
        let step = approval.title.prefix(1).lowercased() + approval.title.dropFirst()
        let note = approval.note.map { " Note: \($0)" } ?? ""
        return "\(who) wants to \(SpokenReply.plain(String(step))) in \(project).\(note) Yes or no?"
    }

    /// Everything at a glance, most urgent first.
    public static func status(_ snapshot: CompanionSnapshot) -> String {
        guard !snapshot.projects.isEmpty else { return "No projects are open on \(snapshot.server)." }
        var lines: [String] = []
        for project in snapshot.projects where !project.approvals.isEmpty {
            let count = project.approvals.count
            lines.append("\(project.name) needs you: \(count == 1 ? "one thing is" : "\(count) things are") waiting.")
        }
        for project in snapshot.projects {
            if project.working { lines.append("\(project.lead) is working in \(project.name).") }
            let working = project.jobs.filter { [.starting, .working].contains($0.state) }
            let ready = project.jobs.filter { $0.state == .ready }
            if !working.isEmpty { lines.append("\(count(working.count, "job")) running in \(project.name).") }
            if !ready.isEmpty { lines.append("\(count(ready.count, "job")) ready to review in \(project.name).") }
        }
        if lines.isEmpty { return "All quiet in " + list(snapshot.projects.map(\.name)) + "." }
        return lines.prefix(4).joined(separator: " ")
    }

    // MARK: Listening

    public enum Command: Equatable, Sendable {
        case approve, decline, stop, status, repeatLast, goodbye, cancel
        case switchProject(String)
        case startJob(String)
        case ask(String)
    }

    public static func parse(_ utterance: String, projects: [String]) -> Command {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let lower = text.lowercased().filter { !",.!?;:".contains($0) }.replacingOccurrences(of: "’", with: "'")
        guard !lower.isEmpty else { return .cancel }
        if ["yes", "yeah", "yep", "yes please", "do it", "go ahead", "approve", "approve it", "ok do it", "sure"].contains(lower) { return .approve }
        if ["no", "nope", "don't", "dont", "decline", "no thanks", "don't do that", "skip it"].contains(lower) { return .decline }
        if ["stop", "stop it", "stop that", "hold on", "wait"].contains(lower) { return .stop }
        if ["never mind", "nevermind", "forget it", "nothing"].contains(lower) { return .cancel }
        if ["status", "what's the status", "whats the status", "what's happening", "whats happening", "what's going on",
            "whats going on", "how's it going", "hows it going", "any update", "give me an update", "update", "where are we"].contains(lower) { return .status }
        if ["say that again", "repeat that", "repeat", "again", "what did you say", "come again"].contains(lower) { return .repeatLast }
        if ["thanks", "thank you", "bye", "goodbye", "that's all", "thats all", "that's it", "thats it"].contains(lower) { return .goodbye }
        for prefix in ["start a job to ", "start a job ", "new job to ", "new job ", "make a job to ", "job "] where lower.hasPrefix(prefix) {
            let brief = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if !brief.isEmpty { return .startJob(brief.prefix(1).uppercased() + brief.dropFirst()) }
        }
        for prefix in ["switch to ", "go to ", "talk to ", "let's work on ", "lets work on ", "work on "] where lower.hasPrefix(prefix) {
            let spoken = String(lower.dropFirst(prefix.count)).replacingOccurrences(of: "the ", with: "")
            if let project = projects.first(where: { matches($0, spoken) }) { return .switchProject(project) }
        }
        return .ask(text)
    }

    static func matches(_ project: String, _ spoken: String) -> Bool {
        let squash = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let (a, b) = (squash(project), squash(spoken.replacingOccurrences(of: " project", with: "")))
        return !b.isEmpty && (a == b || a.hasPrefix(b) || b.hasPrefix(a))
    }

    static func count(_ n: Int, _ noun: String) -> String {
        let words = ["no", "one", "two", "three", "four", "five", "six"]
        return (n < words.count ? words[n].capitalized : "\(n)") + " \(noun)" + (n == 1 ? "" : "s")
    }

    static func list(_ items: [String], or: Bool = false) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + (or ? " or " : " and ") + items[items.count - 1]
        }
    }
}
