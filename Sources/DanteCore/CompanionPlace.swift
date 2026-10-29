import Foundation

/// One of the Mac's places for a paired iPad: Home, Tests, Security, Ship or the agents'
/// Activity, as numbers and rows the device draws natively. The Mac reads what it already
/// keeps (the test runs, the saved security report, git, the pipelines, the agents' ledger);
/// nothing is run or scanned to answer.
public struct CompanionPlace: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable, Identifiable {
        case home, tests, security, ship, activity

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .home: "Home"
            case .tests: "Tests"
            case .security: "Security"
            case .ship: "Ship"
            case .activity: "Activity"
            }
        }
        public var symbol: String {
            switch self {
            case .home: "house"
            case .tests: "checkmark.seal"
            case .security: "lock.shield"
            case .ship: "shippingbox"
            case .activity: "sparkles"
            }
        }
    }

    public var kind: Kind
    /// The project's name.
    public var project: String
    public var date: Date
    /// A sentence saying how it stands.
    public var headline: String
    public var status: Briefing.Status
    public var tiles: [Tile]
    public var pipelines: [Briefing.Pipeline]
    public var sections: [Section]

    public init(kind: Kind, project: String, date: Date, headline: String, status: Briefing.Status, tiles: [Tile] = [],
                pipelines: [Briefing.Pipeline] = [], sections: [Section] = []) {
        self.kind = kind
        self.project = project
        self.date = date
        self.headline = headline
        self.status = status
        self.tiles = tiles
        self.pipelines = pipelines
        self.sections = sections
    }

    /// A number with its label: "Tests · 412 passed".
    public struct Tile: Codable, Equatable, Sendable, Identifiable {
        public var id: String { label }
        public var label: String
        public var value: String
        public var detail: String?
        public var status: Briefing.Status
        /// 0…1 for a bar under the number.
        public var share: Double?
        /// The place it opens, from Home.
        public var opens: Kind?

        public init(label: String, value: String, detail: String? = nil, status: Briefing.Status = .quiet, share: Double? = nil, opens: Kind? = nil) {
            self.label = label
            self.value = value
            self.detail = detail
            self.status = status
            self.share = share
            self.opens = opens
        }
    }

    public struct Section: Codable, Equatable, Sendable, Identifiable {
        public var id: String { title }
        public var title: String
        public var rows: [Row]
        /// Rows beyond those sent ("and 40 more").
        public var more: Int

        public init(title: String, rows: [Row], more: Int = 0) {
            self.title = title
            self.rows = rows
            self.more = more
        }
    }

    public struct Row: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        /// A line under the title: a file, an author, a command.
        public var detail: String?
        /// On the right: "2.1 s", "High".
        public var trailing: String?
        public var status: Briefing.Status
        public var time: Date?
        /// Shown when the row is tapped open: the failure, why it matters and the fix.
        public var expanded: String?
        /// `expanded` is code or output, drawn in a fixed-width font.
        public var monospaced: Bool

        public init(id: String, title: String, detail: String? = nil, trailing: String? = nil, status: Briefing.Status = .quiet,
                    time: Date? = nil, expanded: String? = nil, monospaced: Bool = false) {
            self.id = id
            self.title = title
            self.detail = detail
            self.trailing = trailing
            self.status = status
            self.time = time
            self.expanded = expanded
            self.monospaced = monospaced
        }
    }
}
