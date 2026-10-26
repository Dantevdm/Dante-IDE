import Foundation

/// A notification for something the foreman noticed, for when the phone isn't in front: a step
/// waiting (with Approve and Decline when it's a plain yes or no), a job ready, stopped or
/// asking, or a reply finished. Questions with options open the app instead, since a
/// notification can't offer their choices.
public struct CompanionNotice: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Approve and Decline on the notification.
        case approval
        /// Opens the app: a question with options, a job, a reply.
        case open
    }

    public var kind: Kind
    public var title: String
    public var body: String
    /// The project's id: notifications are grouped by it, and a tap focuses it.
    public var project: String
    /// The waiting step's id, for Approve and Decline.
    public var approval: String?
    /// One notification per step or job: a newer one replaces it.
    public var identifier: String
    /// Waiting steps and stopped jobs sound; finished replies arrive quietly.
    public var sounds: Bool

    /// The category the app registers for Approve and Decline.
    public static let approvalCategory = "dante.approval"
    public static let approveAction = "dante.approve"
    public static let declineAction = "dante.decline"

    public static func make(_ event: CompanionForeman.Event, in snapshot: CompanionSnapshot) -> CompanionNotice {
        let project = { (id: String) in snapshot.projects.first { $0.id == id } }
        switch event {
        case .waiting(let id, let approval):
            let name = project(id)?.name ?? "Dante"
            let who = approval.job == nil ? (project(id)?.lead ?? "The agent") : approval.from
            if let question = approval.questions.first {
                let options = question.options.prefix(4).joined(separator: " · ")
                return CompanionNotice(kind: .open, title: "\(who) asks · \(name)", body: question.question + (options.isEmpty ? "" : "\n" + options),
                                       project: id, approval: approval.id, identifier: "approval." + approval.id, sounds: true)
            }
            var body = approval.title
            // "Run go test ./..." needn't say "go test ./..." again.
            if let line = firstLine(of: approval.detail), !approval.title.contains(line) { body += "\n" + line }
            if let note = approval.note { body += "\n⚠︎ " + note }
            return CompanionNotice(kind: .approval, title: "\(who) waits · \(name)", body: body,
                                   project: id, approval: approval.id, identifier: "approval." + approval.id, sounds: true)
        case .jobChanged(let id, let job):
            let name = project(id)?.name ?? "Dante"
            let title: String = switch job.state {
            case .ready: "Ready to review · \(name)"
            case .failed: "Job stopped · \(name)"
            default: "A job asks · \(name)"
            }
            let detail = job.state == .failed ? job.label : firstLine(of: job.lastReply) ?? job.label
            return CompanionNotice(kind: .open, title: title, body: job.title + (detail.isEmpty ? "" : "\n" + detail),
                                   project: id, approval: nil, identifier: "job." + job.id, sounds: true)
        case .replied(let id, let job, let text):
            let lead = project(id)?.lead ?? "Dante"
            let name = project(id)?.name ?? "Dante"
            return CompanionNotice(kind: .open, title: "\(lead) replied · \(name)", body: excerpt(text),
                                   project: id, approval: nil, identifier: "reply." + id + (job.map { "." + $0 } ?? ""), sounds: false)
        }
    }

    /// The first line with words in it, without markdown marks.
    static func firstLine(of text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("diff ") || line.hasPrefix("@@") || line.hasPrefix("---") || line.hasPrefix("+++") { continue }
            while let first = line.first, "#>*-+ ".contains(first) { line.removeFirst() }
            if !line.isEmpty { return line.count > 140 ? String(line.prefix(139)) + "…" : line }
        }
        return nil
    }

    /// A reply as plain text, about three lines' worth.
    static func excerpt(_ text: String) -> String {
        let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        let lines = plain.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }
        let joined = lines.prefix(4).joined(separator: " ")
        return joined.count > 220 ? String(joined.prefix(219)) + "…" : joined
    }
}

/// What the Lock Screen and Dynamic Island show while the agents work: the most urgent thing
/// first (steps waiting on you, then work going on), the project it's in, and counts. It's the
/// Live Activity's state, so it stays small and plain.
public struct CompanionGlance: Codable, Hashable, Sendable {
    public enum Mood: String, Codable, Hashable, Sendable {
        /// Something waits for an answer.
        case waiting
        /// An agent or job is working.
        case working
        /// A job finished or stopped and wants a look.
        case review
        /// Nothing going on.
        case quiet
        /// The Mac can't be reached; what's shown may be stale.
        case offline
    }

    public var mood: Mood
    /// "Approve: Run go test ./...", "Claude is working", "All quiet".
    public var headline: String
    /// The project, or "2 projects".
    public var detail: String
    public var waiting: Int
    /// Conversations and jobs working.
    public var working: Int
    /// The project the headline is about, so a tap can open it.
    public var project: String?

    public init(mood: Mood, headline: String, detail: String, waiting: Int, working: Int, project: String?) {
        self.mood = mood
        self.headline = headline
        self.detail = detail
        self.waiting = waiting
        self.working = working
        self.project = project
    }

    /// Whether there's anything to keep on the Lock Screen.
    public var isActive: Bool { mood != .quiet }

    public static func make(_ snapshot: CompanionSnapshot?, connected: Bool) -> CompanionGlance {
        guard let snapshot else {
            return CompanionGlance(mood: connected ? .quiet : .offline, headline: connected ? "All quiet" : "Can’t reach your Mac", detail: "", waiting: 0, working: 0, project: nil)
        }
        let busy: Set<CompanionSnapshot.Job.State> = [.starting, .working]
        let waiting = snapshot.waiting
        let working = snapshot.projects.reduce(0) { $0 + ($1.working ? 1 : 0) + $1.jobs.filter { busy.contains($0.state) }.count }
        let projectCount = { (count: Int) in count == 1 ? "" : " · \(count) projects" }
        var glance: CompanionGlance
        if let project = snapshot.projects.first(where: { !$0.approvals.isEmpty }), let approval = project.approvals.first {
            let what = approval.questions.first?.question ?? approval.title
            let others = snapshot.projects.filter { !$0.approvals.isEmpty }.count
            glance = CompanionGlance(mood: .waiting, headline: what, detail: (approval.job == nil ? project.lead : approval.from) + " · " + project.name + projectCount(others),
                                     waiting: waiting, working: working, project: project.id)
        } else if let project = snapshot.projects.first(where: { $0.working }) {
            let others = snapshot.projects.filter { $0.working }.count
            glance = CompanionGlance(mood: .working, headline: "\(project.lead) is working", detail: project.name + projectCount(others),
                                     waiting: 0, working: working, project: project.id)
        } else if let (project, job) = snapshot.projects.lazy.compactMap({ project in project.jobs.first { busy.contains($0.state) }.map { (project, $0) } }).first {
            glance = CompanionGlance(mood: .working, headline: "Job: \(job.title)", detail: project.name + (job.away.map { " · " + $0 } ?? ""),
                                     waiting: 0, working: working, project: project.id)
        } else if let (project, job) = snapshot.projects.lazy.compactMap({ project in project.jobs.first { [.ready, .failed, .asking].contains($0.state) }.map { (project, $0) } }).first {
            glance = CompanionGlance(mood: .review, headline: job.state == .ready ? "Ready to review: \(job.title)" : job.state == .failed ? "Job stopped: \(job.title)" : "A job asks: \(job.title)",
                                     detail: project.name, waiting: 0, working: 0, project: project.id)
        } else {
            glance = CompanionGlance(mood: .quiet, headline: "All quiet", detail: snapshot.server, waiting: 0, working: 0, project: nil)
        }
        if !connected, glance.mood != .quiet {
            glance.mood = .offline
            glance.detail = "Can’t reach \(snapshot.server) · " + glance.detail
        }
        return glance
    }
}
