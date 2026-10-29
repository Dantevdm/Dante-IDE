import Foundation

/// The morning update: what changed in your projects, how the pipelines are doing, the mail
/// that needs you and today's meetings. The Mac gathers and writes it (mail never leaves the
/// Mac whole: only each message's sender, subject and a one-line gist), and the iPhone, the
/// iPad on the wall and the Mac's own voice all read the same value.
public struct Briefing: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Nothing worth saying.
        case quiet
        case good
        /// Something to look at today.
        case attention
        case bad
    }

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case projects, pipelines, mail, calendar

        public var title: String {
            switch self {
            case .projects: "Projects"
            case .pipelines: "Pipelines"
            case .mail: "Mail"
            case .calendar: "Today"
            }
        }

        public var symbol: String {
            switch self {
            case .projects: "folder"
            case .pipelines: "arrow.triangle.branch"
            case .mail: "envelope"
            case .calendar: "calendar"
            }
        }
    }

    public struct Item: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var detail: String?
        public var time: Date?
        public var status: Status
        /// The project the item belongs to, so a tap can open it.
        public var project: String?

        public init(id: String, title: String, detail: String? = nil, time: Date? = nil, status: Status = .good, project: String? = nil) {
            self.id = id
            self.title = title
            self.detail = detail
            self.time = time
            self.status = status
            self.project = project
        }
    }

    public struct Section: Codable, Equatable, Sendable, Identifiable {
        public var kind: Kind
        /// One or two sentences, as they're said.
        public var summary: String
        public var status: Status
        public var items: [Item]
        /// Why the section is empty when it couldn't be read (Outlook closed, no permission).
        public var problem: String?
        public var id: Kind { kind }

        public init(kind: Kind, summary: String, status: Status, items: [Item] = [], problem: String? = nil) {
            self.kind = kind
            self.summary = summary
            self.status = status
            self.items = items
            self.problem = problem
        }
    }

    public var date: Date
    public var greeting: String
    public var sections: [Section]
    /// Each pipeline's newest run with its stages, for the Pipelines card to open up. Nil from
    /// a Mac before this existed.
    public var pipelines: [Pipeline]?

    public init(date: Date, greeting: String, sections: [Section], pipelines: [Pipeline]? = nil) {
        self.date = date
        self.greeting = greeting
        self.sections = sections
        self.pipelines = pipelines
    }

    /// A pipeline (Azure DevOps) or workflow (GitHub Actions) as its newest run left it.
    public struct Pipeline: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        /// The project's name.
        public var project: String
        public var name: String
        public var branch: String
        /// "20261029.3", "#412".
        public var number: String?
        public var status: Status
        /// "Succeeded", "Running", "Partly succeeded".
        public var state: String
        public var started: Date?
        public var finished: Date?
        public var requestedBy: String?
        /// "Manual", "Individual CI", "push".
        public var reason: String?
        public var commit: String?
        /// "Prod", "Non-prod".
        public var environment: String?
        public var url: URL?
        public var stages: [Stage]
        /// The runs before this one, oldest first.
        public var history: [Status]

        public init(id: String, project: String, name: String, branch: String, number: String? = nil, status: Status, state: String,
                    started: Date? = nil, finished: Date? = nil, requestedBy: String? = nil, reason: String? = nil, commit: String? = nil,
                    environment: String? = nil, url: URL? = nil, stages: [Stage] = [], history: [Status] = []) {
            self.id = id
            self.project = project
            self.name = name
            self.branch = branch
            self.number = number
            self.status = status
            self.state = state
            self.started = started
            self.finished = finished
            self.requestedBy = requestedBy
            self.reason = reason
            self.commit = commit
            self.environment = environment
            self.url = url
            self.stages = stages
            self.history = history
        }

        public var isRunning: Bool { finished == nil && started != nil }

        public struct Stage: Codable, Equatable, Sendable, Identifiable {
            public var id: String { name }
            public var name: String
            public var status: Status
            public var state: String
            /// Still going or waiting to start.
            public var active: Bool

            public init(name: String, status: Status, state: String, active: Bool = false) {
                self.name = name
                self.status = status
                self.state = state
                self.active = active
            }
        }
    }

    /// What Dante says: the greeting, then each section's summary in order.
    public var spoken: String {
        ([greeting] + sections.map(\.summary).filter { !$0.isEmpty }).joined(separator: " ")
    }

    /// The worst status among the sections, for the wall's colour.
    public var status: Status {
        let order: [Status] = [.bad, .attention, .good, .quiet]
        return order.first { status in sections.contains { $0.status == status } } ?? .quiet
    }

    public func section(_ kind: Kind) -> Section? { sections.first { $0.kind == kind } }

    /// "Good morning", "Good afternoon" or "Good evening", for the hour in `calendar`.
    public static func greeting(at date: Date, name: String? = nil, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        if let name, !name.isEmpty { return "\(part), \(name)." }
        return part + "."
    }

    /// "Give me my morning update", "what did I miss", "brief me": asked for the briefing.
    /// `spoken` is lower-cased without punctuation or the wake word.
    public static func isRequest(_ spoken: String) -> Bool {
        var text = " " + spoken.replacingOccurrences(of: "'", with: "") + " "
        for filler in [" please ", " can you ", " could you ", " can i have ", " can i get ", " give me ", " tell me ", " lets have ", " i want ", " id like "] {
            text = text.replacingOccurrences(of: filler, with: " ")
        }
        let core = text.split(separator: " ").filter { !["my", "the", "a", "today", "todays", "this", "for"].contains($0) }.joined(separator: " ")
        return requests.contains(core)
    }

    static let requests: Set<String> = [
        "morning update", "morning briefing", "morning brief", "daily update", "daily briefing", "briefing", "brief me",
        "catch me up", "what did i miss", "what have i missed", "whats new", "morning report", "rundown", "days rundown",
        "day ahead", "update for day", "good morning", "morning",
    ]
}
