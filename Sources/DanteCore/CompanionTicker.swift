import Foundation

/// What the screensaver and the splash say about the Mac: what's going on now, and what
/// happened while nobody was looking (from the foreman's events), newest first. Short lines,
/// nothing spoken, no code.
public struct CompanionTicker: Equatable, Sendable {
    public struct Line: Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable { case working, waiting, done, trouble, quiet }
        public var id: String
        public var kind: Kind
        public var title: String
        public var detail: String?
        public var at: Date?

        public init(id: String, kind: Kind, title: String, detail: String? = nil, at: Date? = nil) {
            self.id = id
            self.kind = kind
            self.title = title
            self.detail = detail
            self.at = at
        }
    }

    /// A foreman event and when the device saw it.
    public struct Noted: Equatable, Sendable {
        public var event: CompanionForeman.Event
        public var at: Date
        public init(_ event: CompanionForeman.Event, at: Date) {
            self.event = event
            self.at = at
        }
    }

    public var now: [Line]
    public var since: [Line]

    /// The most worth keeping: `maxNoted` events, the oldest dropped first.
    public static let maxNoted = 6

    public static func make(_ snapshot: CompanionSnapshot?, connected: Bool, noted: [Noted]) -> CompanionTicker {
        guard let snapshot, connected else {
            return CompanionTicker(now: [Line(id: "offline", kind: .quiet, title: "Not connected to your Mac")], since: lines(noted, snapshot))
        }
        var now: [Line] = []
        let waiting = snapshot.waiting
        if waiting > 0 {
            let first = snapshot.projects.first { !$0.approvals.isEmpty }
            now.append(Line(id: "waiting", kind: .waiting, title: waiting == 1 ? "1 step waits for you" : "\(waiting) steps wait for you",
                            detail: first.flatMap { project in project.approvals.first.map { "\(project.name): \($0.title)" } }))
        }
        for project in snapshot.projects where project.working {
            now.append(Line(id: "working:\(project.id)", kind: .working, title: "\(project.lead) is working in \(project.name)"))
        }
        let jobs = snapshot.projects.flatMap { project in project.jobs.map { (project, $0) } }
        let running = jobs.filter { [.starting, .working].contains($0.1.state) }
        if !running.isEmpty {
            now.append(Line(id: "jobs", kind: .working, title: running.count == 1 ? "1 job running" : "\(running.count) jobs running",
                            detail: running.prefix(2).map(\.1.title).joined(separator: " · ")))
        }
        let ready = jobs.filter { $0.1.state == .ready }
        if !ready.isEmpty {
            now.append(Line(id: "ready", kind: .done, title: ready.count == 1 ? "1 job ready to review" : "\(ready.count) jobs ready to review",
                            detail: ready.prefix(2).map(\.1.title).joined(separator: " · ")))
        }
        if now.isEmpty {
            now.append(Line(id: "quiet", kind: .quiet, title: "All quiet on \(snapshot.server)"))
        }
        return CompanionTicker(now: now, since: lines(noted, snapshot))
    }

    private static func lines(_ noted: [Noted], _ snapshot: CompanionSnapshot?) -> [Line] {
        let name = { (id: String) in snapshot?.projects.first { $0.id == id }?.name ?? (id as NSString).lastPathComponent }
        return noted.reversed().enumerated().map { index, note in
            switch note.event {
            case .replied(let project, let job, let text):
                let who = job == nil ? (snapshot?.projects.first { $0.id == project }?.lead ?? "The agent") : "A job"
                return Line(id: "n\(index)", kind: .done, title: "\(who) finished in \(name(project))", detail: gist(text), at: note.at)
            case .waiting(let project, let approval):
                return Line(id: "n\(index)", kind: .waiting, title: "\(name(project)) asked for you", detail: approval.title, at: note.at)
            case .jobChanged(let project, let job):
                let title = switch job.state {
                case .ready: "Job ready in \(name(project))"
                case .failed: "Job stopped in \(name(project))"
                default: "A job in \(name(project)) has a question"
                }
                return Line(id: "n\(index)", kind: job.state == .failed ? .trouble : job.state == .ready ? .done : .waiting, title: title, detail: job.title, at: note.at)
            }
        }
    }

    /// The first sentence of a reply, without markdown, at most 110 characters.
    public static func gist(_ text: String) -> String? {
        let plain = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") && !$0.hasPrefix("|") }
            .map { $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "#-* ")) }
        guard var line = plain, !line.isEmpty else { return nil }
        if let stop = line.range(of: ". ") { line = String(line[..<stop.lowerBound]) + "." }
        return line.count > 110 ? String(line.prefix(109)) + "…" : line
    }
}
