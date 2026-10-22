import CoreGraphics
import Foundation

/// A picture the user draws in the Map's style: cards, groups with a coloured header and a
/// count, a dashed boundary, people, pipeline stages and labelled links that carry traffic.
/// Saved as plain JSON in the repo (`docs/diagrams/<name>.dante-diagram.json`), so it reads
/// well in a diff and an agent can write one. Pure: the editor in the app changes it only
/// through the functions here.
public struct Diagram: Codable, Equatable, Sendable {
    public static let fileSuffix = ".dante-diagram.json"
    public static let folder = "docs/diagrams"
    public static let currentVersion = 1

    public var version = Diagram.currentVersion
    public var title: String
    /// A line under the title, for the reader.
    public var note: String
    public var nodes: [Node]
    public var links: [Link]

    public init(title: String, note: String = "", nodes: [Node] = [], links: [Link] = []) {
        self.title = title
        self.note = note
        self.nodes = nodes
        self.links = links
    }

    // MARK: Colours

    /// A colour from the theme, by name, so a diagram looks right in every theme.
    public enum Hue: String, Codable, CaseIterable, Sendable {
        case blue, purple, teal, green, amber, red, gray
        case indigo, pink, orange, yellow, cyan, lime, brown

        public var name: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

        public func rgba(_ theme: Theme) -> RGBA {
            switch self {
            case .blue: theme.accent
            case .purple: theme.syntax.keyword
            case .teal: theme.syntax.type
            case .green: theme.green
            case .amber: theme.amber
            case .red: theme.red
            case .gray: theme.text3
            // Beyond the theme's own colours: a light and a dark shade of each, so they read on
            // Light and Paper as well as Dark.
            case .indigo: RGBA(theme.isDark ? 0x8B87F5 : 0x4F46E5)
            case .pink: RGBA(theme.isDark ? 0xF472B6 : 0xDB2777)
            case .orange: RGBA(theme.isDark ? 0xFB923C : 0xEA580C)
            case .yellow: RGBA(theme.isDark ? 0xFACC15 : 0xB88A04)
            case .cyan: RGBA(theme.isDark ? 0x22D3EE : 0x0891B2)
            case .lime: RGBA(theme.isDark ? 0xA3E635 : 0x65A30D)
            case .brown: RGBA(theme.isDark ? 0xC08457 : 0x92400E)
            }
        }

        /// Also the Map's own words for a colour ("edge", "data"…) and common colour names,
        /// so a hand-written or agent-written file reads as meant; nil for anything else.
        public init?(named name: String) {
            let key = name.lowercased().trimmingCharacters(in: .whitespaces)
            if let hue = Hue(rawValue: key) { self = hue; return }
            switch key {
            case "accent", "data", "images", "registry", "clients", "navy": self = .blue
            case "edge", "api", "violet", "keyword": self = .purple
            case "backend", "messaging", "network", "type": self = .teal
            case "observability", "outside", "string": self = .green
            case "compute": self = .amber
            case "magenta", "rose": self = .pink
            case "aqua", "sky": self = .cyan
            case "gold": self = .yellow
            case "tan", "chocolate": self = .brown
            case "security", "danger", "crimson": self = .red
            case "grey", "neutral", "other", "slate", "silver": self = .gray
            default: return nil
            }
        }

        public init(from decoder: Decoder) throws {
            let name = try decoder.singleValueContainer().decode(String.self)
            self = Hue(named: name) ?? .blue
        }

        public init(tier: Infrastructure.Tier) {
            switch tier {
            case .edge: self = .purple
            case .compute: self = .amber
            case .data, .registry: self = .blue
            case .messaging, .network: self = .teal
            case .security: self = .red
            case .observability: self = .green
            case .other: self = .gray
            }
        }

        public init(lane: SystemMap.Lane) {
            switch lane {
            case .clients: self = .blue
            case .api: self = .purple
            case .backend: self = .teal
            case .data: self = .amber
            case .outside: self = .green
            }
        }
    }

    // MARK: Nodes

    public struct Rect: Equatable, Sendable, Hashable {
        public var x, y, width, height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }

        public init(_ rect: CGRect) {
            self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        }

        public var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
        public var center: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }
    }

    public struct Node: Equatable, Sendable, Identifiable, Hashable {
        public enum Kind: String, Codable, CaseIterable, Sendable {
            /// A resource: icon tile, bold title, a kind line and a monospaced line (the Infra view's).
            case card
            /// A part with a coloured stripe, as on the System map.
            case box
            /// A titled box with a coloured header and a count of what's in it.
            case group
            /// A dashed outer boundary with a title above it ("AWS cloud").
            case boundary
            /// People: a round badge with a name under it.
            case person
            /// A pipeline stage: its icon, name, environment and a row of step icons.
            case stage
            /// Where a pipeline starts: the repo, its branches and environment.
            case source
            /// A band title: icon, title in capitals and a note.
            case title
            /// A few lines of plain text.
            case text

            public var isContainer: Bool { self == .group || self == .boundary }

            public var name: String {
                switch self {
                case .card: "Card"
                case .box: "Part"
                case .group: "Group"
                case .boundary: "Boundary"
                case .person: "People"
                case .stage: "Stage"
                case .source: "Pipeline"
                case .title: "Title"
                case .text: "Text"
                }
            }

            public var defaultSize: CGSize {
                switch self {
                case .card: CGSize(width: 196, height: 64)
                case .box: CGSize(width: 180, height: 56)
                case .group: CGSize(width: 236, height: 180)
                case .boundary: CGSize(width: 560, height: 320)
                case .person: CGSize(width: 64, height: 72)
                case .stage: CGSize(width: 196, height: 76)
                case .source: CGSize(width: 190, height: 70)
                case .title: CGSize(width: 260, height: 20)
                case .text: CGSize(width: 220, height: 44)
                }
            }

            public var defaultIcon: String {
                switch self {
                case .card: "cube"
                case .box: "shippingbox"
                case .group: "square.stack.3d.up"
                case .boundary: "cloud"
                case .person: "person.2.fill"
                case .stage: "paperplane"
                case .source: "chevron.left.forwardslash.chevron.right"
                case .title: "arrow.triangle.branch"
                case .text: ""
                }
            }
        }

        public var id: String
        public var kind: Kind
        public var title: String
        /// The kind line under the title ("ECS service"), a pipeline's system, a group's note.
        public var subtitle: String
        /// The monospaced line: a stack name, a path.
        public var detail: String
        /// Longer wrapped text: a part's screens, or a text node's body.
        public var text: String
        /// An SF Symbol name.
        public var icon: String
        public var hue: Hue
        /// Nil until it's placed: `laidOut()` places nodes without one.
        public var frame: Rect?
        /// The group or boundary it sits in.
        public var parent: String?
        /// Drawn with a dashed border: outside the system, or not built yet.
        public var dashed: Bool
        /// Small capsules: branches, a container.
        public var chips: [String]
        /// A highlighted capsule: a pipeline's environment.
        public var tag: String
        /// A stage's steps, as a row of SF Symbols.
        public var icons: [String]

        public init(id: String, kind: Kind, title: String, subtitle: String = "", detail: String = "", text: String = "",
                    icon: String? = nil, hue: Hue = .blue, frame: Rect? = nil, parent: String? = nil, dashed: Bool = false,
                    chips: [String] = [], tag: String = "", icons: [String] = []) {
            self.id = id
            self.kind = kind
            self.title = title
            self.subtitle = subtitle
            self.detail = detail
            self.text = text
            self.icon = icon ?? kind.defaultIcon
            self.hue = hue
            self.frame = frame
            self.parent = parent
            self.dashed = dashed
            self.chips = chips
            self.tag = tag
            self.icons = icons
        }

        /// The frame, or the kind's size at the origin before it's placed.
        public var rect: CGRect { frame?.cg ?? CGRect(origin: .zero, size: kind.defaultSize) }
    }

    // MARK: Links

    public struct Link: Equatable, Sendable, Identifiable, Hashable {
        public enum Line: String, Codable, CaseIterable, Sendable {
            case solid, dashed
            /// Dashes that move along the link, as from Users and between pipeline stages.
            case flowing

            public var name: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
        }

        public enum Route: String, Codable, CaseIterable, Sendable {
            /// Side to side when one is beside the other, else top to bottom (the Infra view).
            case auto
            /// Side to side, and a loop out to the right within a column (the System map).
            case loop
        }

        public var id: String
        public var from: String
        public var to: String
        public var label: String
        public var line: Line
        /// A glowing packet travels along it.
        public var pulse: Bool
        public var arrow: Bool
        /// Nil draws it in the theme's quiet line colour.
        public var hue: Hue?
        public var width: Double
        public var route: Route

        public init(id: String, from: String, to: String, label: String = "", line: Line = .solid, pulse: Bool = false,
                    arrow: Bool = true, hue: Hue? = nil, width: Double = 1.5, route: Route = .auto) {
            self.id = id
            self.from = from
            self.to = to
            self.label = label
            self.line = line
            self.pulse = pulse
            self.arrow = arrow
            self.hue = hue
            self.width = width
            self.route = route
        }

        /// The look of traffic along the main path: solid, coloured by where it goes, with a pulse.
        public static func traffic(id: String, from: String, to: String, label: String = "", hue: Hue?) -> Link {
            Link(id: id, from: from, to: to, label: label, pulse: true, hue: hue, width: 1.7)
        }
    }

    // MARK: Looking things up

    public func node(_ id: String) -> Node? { nodes.first { $0.id == id } }
    public func link(_ id: String) -> Link? { links.first { $0.id == id } }

    public func children(of id: String) -> [Node] { nodes.filter { $0.parent == id } }

    /// Everything inside a container, at any depth.
    public func descendants(of id: String) -> [Node] {
        var found: [Node] = []
        var queue = [id]
        var seen: Set<String> = [id]
        while let next = queue.popLast() {
            for child in nodes where child.parent == next && seen.insert(child.id).inserted {
                found.append(child)
                queue.append(child.id)
            }
        }
        return found
    }

    public func ancestors(of id: String) -> [Node] {
        var found: [Node] = []
        var seen: Set<String> = [id]
        var current = node(id)?.parent
        while let parentID = current, seen.insert(parentID).inserted, let parent = node(parentID) {
            found.append(parent)
            current = parent.parent
        }
        return found
    }

    /// What a group's header counts: the cards and people directly in it.
    public func count(of id: String) -> Int {
        children(of: id).filter { ![.group, .boundary, .title, .text].contains($0.kind) }.count
    }

    /// Back to front: outer containers first, then inner ones, then everything else in order.
    public var drawingOrder: [Node] {
        let containers = nodes.filter(\.kind.isContainer).sorted { ancestors(of: $0.id).count < ancestors(of: $1.id).count }
        return containers + nodes.filter { !$0.kind.isContainer }
    }

    /// Everything drawn, including a boundary's title above its frame.
    public var bounds: CGRect {
        nodes.compactMap { $0.frame?.cg }.reduce(CGRect.null) { $0.union($1) }
    }

    public var isEmpty: Bool { nodes.isEmpty }

    /// Links whose ends both exist; the rest are skipped when drawing.
    public var drawableLinks: [Link] {
        let ids = Set(nodes.map(\.id))
        return links.filter { ids.contains($0.from) && ids.contains($0.to) && $0.from != $0.to }
    }

    // MARK: Ids

    /// A readable id from a title ("Shared ALB" → "shared-alb"), unique in the diagram.
    public func uniqueID(for title: String, taken extra: Set<String> = []) -> String {
        let taken = Set(nodes.map(\.id)).union(links.map(\.id)).union(extra)
        let base = Self.slug(title).isEmpty ? "node" : Self.slug(title)
        var candidate = base
        var number = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(number)"
            number += 1
        }
        return candidate
    }

    /// Lower case words joined by dashes; camel case is split ("OrdersPortal" → "orders-portal").
    public static func slug(_ text: String) -> String {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if character.isLetter || character.isNumber {
                if character.isUppercase, let previous, previous.isLowercase || previous.isNumber, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(contentsOf: character.lowercased())
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words.prefix(8).joined(separator: "-")
    }
}

// MARK: The file

extension Diagram {
    private enum Keys: String, CodingKey { case version, title, note, nodes, links }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Diagram"
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        nodes = try container.decodeIfPresent([Node].self, forKey: .nodes) ?? []
        var links = try container.decodeIfPresent([Link].self, forKey: .links) ?? []
        // Links written without ids get one, so the editor can select them.
        var seen: Set<String> = []
        for index in links.indices {
            if links[index].id.isEmpty || seen.contains(links[index].id) {
                var id = "\(links[index].from)-\(links[index].to)"
                var number = 2
                while seen.contains(id) { id = "\(links[index].from)-\(links[index].to)-\(number)"; number += 1 }
                links[index].id = id
            }
            seen.insert(links[index].id)
        }
        self.links = links
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(version, forKey: .version)
        try container.encode(title, forKey: .title)
        if !note.isEmpty { try container.encode(note, forKey: .note) }
        try container.encode(nodes, forKey: .nodes)
        try container.encode(links, forKey: .links)
    }

    /// The file's text: pretty, keys in a fixed order, numbers rounded, so a small move is a small diff.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }

    /// Reads a file leniently: unknown fields are ignored and missing ones take defaults.
    public static func decode(_ data: Data) throws -> Diagram {
        do {
            return try JSONDecoder().decode(Diagram.self, from: data)
        } catch let DecodingError.dataCorrupted(context) {
            throw Failure(message: "The diagram isn’t valid JSON: \(context.underlyingError?.localizedDescription ?? context.debugDescription)")
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            let place = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            throw Failure(message: "The diagram has an unexpected value at \(place.isEmpty ? "the top" : String(place.dropFirst())): \(context.debugDescription)")
        }
    }

    public struct Failure: LocalizedError, Equatable {
        public var message: String
        public var errorDescription: String? { message }
    }

    public static func isDiagram(_ path: String) -> Bool { path.lowercased().hasSuffix(fileSuffix) }

    /// "docs/diagrams/umbrella-target.dante-diagram.json" reads "Umbrella target".
    public static func title(ofPath path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let base = name.lowercased().hasSuffix(fileSuffix) ? String(name.dropLast(fileSuffix.count)) : name
        let spaced = base.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// Where a new diagram called `title` goes, numbered when the name is taken.
    public static func path(for title: String, existing: Set<String>) -> String {
        let base = slug(title).isEmpty ? "diagram" : slug(title)
        var candidate = "\(folder)/\(base)\(fileSuffix)"
        var number = 2
        while existing.contains(candidate) {
            candidate = "\(folder)/\(base)-\(number)\(fileSuffix)"
            number += 1
        }
        return candidate
    }
}

extension Diagram.Rect: Codable {
    /// `[x, y, width, height]`, or an object with those names.
    public init(from decoder: Decoder) throws {
        if var list = try? decoder.unkeyedContainer() {
            var values: [Double] = []
            while !list.isAtEnd { values.append(try list.decode(Double.self)) }
            guard values.count == 4 else {
                throw DecodingError.dataCorruptedError(in: list, debugDescription: "A frame is [x, y, width, height].")
            }
            self.init(x: values[0], y: values[1], width: values[2], height: values[3])
            return
        }
        struct Named: Decodable { var x, y: Double; var width, height: Double?; var w, h: Double? }
        let named = try Named(from: decoder)
        self.init(x: named.x, y: named.y, width: named.width ?? named.w ?? 0, height: named.height ?? named.h ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var list = encoder.unkeyedContainer()
        for value in [x, y, width, height] {
            let rounded = (value * 2).rounded() / 2
            if rounded == rounded.rounded() { try list.encode(Int(rounded)) } else { try list.encode(rounded) }
        }
    }
}

extension Diagram.Node: Codable {
    private enum Keys: String, CodingKey { case id, kind, title, subtitle, detail, text, icon, hue, frame, parent, dashed, chips, tag, icons }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap(Kind.init(rawValue:)) ?? .card
        let title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.init(
            id: try c.decodeIfPresent(String.self, forKey: .id) ?? Diagram.slug(title),
            kind: kind,
            title: title,
            subtitle: try c.decodeIfPresent(String.self, forKey: .subtitle) ?? "",
            detail: try c.decodeIfPresent(String.self, forKey: .detail) ?? "",
            text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
            icon: try c.decodeIfPresent(String.self, forKey: .icon),
            hue: try c.decodeIfPresent(Diagram.Hue.self, forKey: .hue) ?? .blue,
            frame: try c.decodeIfPresent(Diagram.Rect.self, forKey: .frame),
            parent: try c.decodeIfPresent(String.self, forKey: .parent),
            dashed: try c.decodeIfPresent(Bool.self, forKey: .dashed) ?? false,
            chips: try c.decodeIfPresent([String].self, forKey: .chips) ?? [],
            tag: try c.decodeIfPresent(String.self, forKey: .tag) ?? "",
            icons: try c.decodeIfPresent([String].self, forKey: .icons) ?? []
        )
    }

    /// Only what differs from the defaults, so a file stays short.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        if !subtitle.isEmpty { try c.encode(subtitle, forKey: .subtitle) }
        if !detail.isEmpty { try c.encode(detail, forKey: .detail) }
        if !text.isEmpty { try c.encode(text, forKey: .text) }
        if icon != kind.defaultIcon { try c.encode(icon, forKey: .icon) }
        try c.encode(hue, forKey: .hue)
        try c.encodeIfPresent(frame, forKey: .frame)
        try c.encodeIfPresent(parent, forKey: .parent)
        if dashed { try c.encode(dashed, forKey: .dashed) }
        if !chips.isEmpty { try c.encode(chips, forKey: .chips) }
        if !tag.isEmpty { try c.encode(tag, forKey: .tag) }
        if !icons.isEmpty { try c.encode(icons, forKey: .icons) }
    }
}

extension Diagram.Link: Codable {
    private enum Keys: String, CodingKey { case id, from, to, label, line, pulse, arrow, hue, width, route }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(
            id: try c.decodeIfPresent(String.self, forKey: .id) ?? "",
            from: try c.decode(String.self, forKey: .from),
            to: try c.decode(String.self, forKey: .to),
            label: try c.decodeIfPresent(String.self, forKey: .label) ?? "",
            line: (try? c.decodeIfPresent(String.self, forKey: .line)).flatMap(Line.init(rawValue:)) ?? .solid,
            pulse: try c.decodeIfPresent(Bool.self, forKey: .pulse) ?? false,
            arrow: try c.decodeIfPresent(Bool.self, forKey: .arrow) ?? true,
            hue: try c.decodeIfPresent(Diagram.Hue.self, forKey: .hue),
            width: try c.decodeIfPresent(Double.self, forKey: .width) ?? 1.5,
            route: (try? c.decodeIfPresent(String.self, forKey: .route)).flatMap(Route.init(rawValue:)) ?? .auto
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(from, forKey: .from)
        try c.encode(to, forKey: .to)
        if !label.isEmpty { try c.encode(label, forKey: .label) }
        if line != .solid { try c.encode(line, forKey: .line) }
        if pulse { try c.encode(pulse, forKey: .pulse) }
        if !arrow { try c.encode(arrow, forKey: .arrow) }
        try c.encodeIfPresent(hue, forKey: .hue)
        if width != 1.5 { try c.encode((width * 10).rounded() / 10, forKey: .width) }
        if route != .auto { try c.encode(route, forKey: .route) }
    }
}
