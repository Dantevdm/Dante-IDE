import Foundation

/// The parts of Mermaid that Dante draws natively: flowcharts, sequence diagrams and ER
/// diagrams. Anything else stays as source.
public enum Mermaid: Equatable, Sendable {
    case flowchart(Flowchart)
    case sequence(SequenceDiagram)
    case entityRelationship(ERDiagram)
    case unsupported(String)

    public static func parse(_ source: String) -> Mermaid {
        let lines = source.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"%%.*$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let header = lines.first else { return .unsupported("") }
        let body = Array(lines.dropFirst())
        let kind = header.split(separator: " ").first.map(String.init) ?? header
        switch kind {
        case "graph", "flowchart": return .flowchart(Flowchart.parse(header: header, body))
        case "sequenceDiagram": return .sequence(SequenceDiagram.parse(body))
        case "erDiagram": return .entityRelationship(ERDiagram.parse(body))
        default: return .unsupported(kind)
        }
    }

    /// Splits `A["label"]`-style tokens into an id and its label text.
    static func unquote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") { return String(trimmed.dropFirst().dropLast()) }
        return trimmed
    }
}

// MARK: Flowchart

public struct Flowchart: Equatable, Sendable {
    public enum Direction: Sendable { case down, right }

    public struct Node: Equatable, Sendable, Identifiable {
        public enum Shape: Sendable { case box, round, diamond, circle, database }
        public var id: String
        public var label: String
        public var shape: Shape
    }

    public struct Edge: Equatable, Sendable {
        public enum Style: Sendable { case solid, dotted, thick }
        public var from: String
        public var to: String
        public var label: String?
        public var style: Style
        public var arrow: Bool
    }

    public struct Group: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var nodes: [String]
    }

    public var direction: Direction
    public var nodes: [Node]
    public var edges: [Edge]
    public var groups: [Group]

    public func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    /// Layers along the flow: each node sits one past the furthest node pointing at it.
    public var layers: [[Node]] {
        var depth: [String: Int] = [:]
        func visit(_ id: String, _ seen: Set<String>) -> Int {
            if let known = depth[id] { return known }
            let parents = edges.filter { $0.to == id && $0.from != id && !seen.contains($0.from) }.map(\.from)
            let value = parents.map { visit($0, seen.union([id])) + 1 }.max() ?? 0
            depth[id] = value
            return value
        }
        for node in nodes { _ = visit(node.id, []) }
        let count = (depth.values.max() ?? 0) + 1
        var layers = Array(repeating: [Node](), count: count)
        for node in nodes { layers[depth[node.id] ?? 0].append(node) }
        return layers.filter { !$0.isEmpty }
    }

    static func parse(header: String, _ lines: [String]) -> Flowchart {
        let parts = header.split(separator: " ")
        let directionWord = parts.count > 1 ? parts[1].uppercased() : "TD"
        var chart = Flowchart(direction: ["LR", "RL"].contains(directionWord) ? .right : .down, nodes: [], edges: [], groups: [])
        var groupStack: [Int] = []

        func addNode(_ token: String) -> String? {
            guard let (id, label, shape) = Self.node(token) else { return nil }
            if let index = chart.nodes.firstIndex(where: { $0.id == id }) {
                if let label { chart.nodes[index].label = label; chart.nodes[index].shape = shape }
            } else {
                chart.nodes.append(Node(id: id, label: label ?? id, shape: shape))
            }
            if let group = groupStack.last, !chart.groups[group].nodes.contains(id) { chart.groups[group].nodes.append(id) }
            return id
        }

        for line in lines {
            let first = line.split(separator: " ").first.map(String.init) ?? ""
            if first == "subgraph" {
                let rest = line.dropFirst("subgraph".count).trimmingCharacters(in: .whitespaces)
                let (id, label, _) = Self.node(rest) ?? (rest, nil, .box)
                chart.groups.append(Group(id: id, title: Mermaid.unquote(label ?? rest), nodes: []))
                groupStack.append(chart.groups.count - 1)
                continue
            }
            if line == "end" { _ = groupStack.popLast(); continue }
            if ["classDef", "class", "style", "linkStyle", "click", "direction"].contains(first) { continue }

            // A chain: node (link node)*
            let pieces = Self.splitLinks(line.trimmingCharacters(in: CharacterSet(charactersIn: ";")))
            var previous: String?
            var pendingLink: (label: String?, style: Edge.Style, arrow: Bool)?
            for piece in pieces {
                switch piece {
                case .node(let token):
                    guard let id = addNode(token) else { continue }
                    if let from = previous, let link = pendingLink {
                        chart.edges.append(Edge(from: from, to: id, label: link.label, style: link.style, arrow: link.arrow))
                    }
                    previous = id
                    pendingLink = nil
                case .link(let label, let style, let arrow):
                    pendingLink = (label, style, arrow)
                }
            }
        }
        return chart
    }

    private enum Piece { case node(String), link(String?, Edge.Style, Bool) }

    /// Splits a line into node tokens and the links between them, outside brackets and quotes.
    private static func splitLinks(_ line: String) -> [Piece] {
        let pattern = #"\s*(?:(-{2,3}|={2,3}|-\.+-)\s*([^>\-=|]+?)\s*)?(-{2,}>|-\.+->|={2,}>|-{3,}|-\.+-|={3,})(?:\|([^|]*)\|)?\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [.node(line)] }
        let ns = line as NSString
        var pieces: [Piece] = []
        var cursor = 0
        var depth = 0
        var inQuote = false
        // Positions inside brackets or quotes can't start a link.
        var masked = Set<Int>()
        for index in 0..<ns.length {
            let character = ns.character(at: index)
            if character == 0x22 { inQuote.toggle() }
            if !inQuote {
                if "[({".utf16.contains(character) { depth += 1 }
                if "])}".utf16.contains(character) { depth = max(depth - 1, 0) }
            }
            if inQuote || depth > 0 { masked.insert(index) }
        }
        for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) where !masked.contains(match.range.location) {
            let token = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if !token.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append(.node(token)) }
            let arrowText = ns.substring(with: match.range(at: 3))
            let inlineLabel = match.range(at: 2).location != NSNotFound ? ns.substring(with: match.range(at: 2)) : nil
            let pipeLabel = match.range(at: 4).location != NSNotFound ? ns.substring(with: match.range(at: 4)) : nil
            let style: Edge.Style = arrowText.contains(".") ? .dotted : (arrowText.contains("=") ? .thick : .solid)
            let label = (pipeLabel ?? inlineLabel).map(Mermaid.unquote).flatMap { $0.isEmpty ? nil : $0 }
            pieces.append(.link(label, style, arrowText.hasSuffix(">")))
            cursor = NSMaxRange(match.range)
        }
        let rest = ns.substring(from: cursor)
        if !rest.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append(.node(rest)) }
        return pieces
    }

    /// `A`, `A[Label]`, `A(Label)`, `A{Label}`, `A((Label))`, `A[(Label)]`, `A(["Label"])`.
    static func node(_ token: String) -> (String, String?, Node.Shape)? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard let idEnd = trimmed.firstIndex(where: { "[({>".contains($0) }) else {
            let id = trimmed.split(separator: " ").first.map(String.init) ?? ""
            return id.isEmpty ? nil : (id, nil, .box)
        }
        let id = String(trimmed[..<idEnd]).trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        let shapeText = String(trimmed[idEnd...])
        let shapes: [(String, String, Node.Shape)] = [
            ("((", "))", .circle), ("[(", ")]", .database), ("([", "])", .round), ("[[", "]]", .box),
            ("{{", "}}", .diamond), ("[", "]", .box), ("(", ")", .round), ("{", "}", .diamond), (">", "]", .box),
        ]
        for (open, close, shape) in shapes where shapeText.hasPrefix(open) && shapeText.hasSuffix(close) {
            let inner = shapeText.dropFirst(open.count).dropLast(close.count)
            return (id, Mermaid.unquote(String(inner)).replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n"), shape)
        }
        return (id, nil, .box)
    }
}

// MARK: Sequence

public struct SequenceDiagram: Equatable, Sendable {
    public struct Participant: Equatable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var isActor: Bool
    }

    public enum Item: Equatable, Sendable {
        case message(from: String, to: String, text: String, dashed: Bool, arrow: Bool)
        case note(over: [String], text: String)
        /// `loop`, `alt`, `opt`, `par`, `else`… with their label; `end` closes one.
        case blockStart(kind: String, label: String)
        case blockEnd
    }

    public var participants: [Participant]
    public var items: [Item]

    public func index(of id: String) -> Int? { participants.firstIndex { $0.id == id } }

    static func parse(_ lines: [String]) -> SequenceDiagram {
        var diagram = SequenceDiagram(participants: [], items: [])
        func ensure(_ id: String) {
            if !diagram.participants.contains(where: { $0.id == id }) {
                diagram.participants.append(Participant(id: id, label: id, isActor: false))
            }
        }
        let message = try? NSRegularExpression(pattern: #"^([^-+>:]+?)\s*(-{1,2})(>>|>|x|\))\s*[+-]?\s*([^:]+?)\s*:\s*(.*)$"#)
        for line in lines {
            let words = line.split(separator: " ", maxSplits: 1).map(String.init)
            let keyword = words.first ?? ""
            let rest = words.count > 1 ? words[1] : ""
            switch keyword {
            case "participant", "actor":
                let parts = rest.components(separatedBy: " as ")
                let id = parts[0].trimmingCharacters(in: .whitespaces)
                let label = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : id
                if let index = diagram.index(of: id) {
                    diagram.participants[index].label = label
                    diagram.participants[index].isActor = keyword == "actor"
                } else {
                    diagram.participants.append(Participant(id: id, label: label, isActor: keyword == "actor"))
                }
                continue
            case "loop", "alt", "opt", "par", "critical", "break", "rect", "else", "and":
                if keyword == "else" || keyword == "and" { diagram.items.append(.blockEnd) }
                diagram.items.append(.blockStart(kind: keyword, label: rest))
                continue
            case "end":
                diagram.items.append(.blockEnd)
                continue
            case "autonumber", "activate", "deactivate", "title":
                continue
            default:
                break
            }
            if keyword.lowercased() == "note" {
                // Note over A,B: text / Note right of A: text
                guard let colon = line.firstIndex(of: ":") else { continue }
                let text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                let targets = String(line[..<colon]).components(separatedBy: " ").last?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
                targets.forEach(ensure)
                diagram.items.append(.note(over: targets, text: text))
                continue
            }
            let ns = line as NSString
            if let match = message?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let from = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let to = ns.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces)
                ensure(from)
                ensure(to)
                diagram.items.append(.message(from: from, to: to, text: ns.substring(with: match.range(at: 5)),
                                              dashed: ns.substring(with: match.range(at: 2)) == "--",
                                              // `->` is a plain line; `->>`, `-x` and `-)` end in a marker.
                                              arrow: ns.substring(with: match.range(at: 3)) != ">"))
            }
        }
        return diagram
    }
}

// MARK: Entity relationship

public struct ERDiagram: Equatable, Sendable {
    public struct Attribute: Equatable, Sendable {
        public var type: String
        public var name: String
        public var keys: [String]
    }

    public struct Entity: Equatable, Sendable, Identifiable {
        public var name: String
        public var attributes: [Attribute]
        public var id: String { name }
    }

    public struct Relationship: Equatable, Sendable {
        public var from: String
        public var to: String
        /// Readable cardinalities: "1", "0..1", "0..N" or "1..N".
        public var fromCardinality: String
        public var toCardinality: String
        public var label: String
    }

    public var entities: [Entity]
    public var relationships: [Relationship]

    /// Entities in layers, like a left-to-right flowchart of the relationships.
    public var layers: [[Entity]] {
        let chart = Flowchart(direction: .right, nodes: entities.map { Flowchart.Node(id: $0.name, label: $0.name, shape: .box) },
                              edges: relationships.map { Flowchart.Edge(from: $0.from, to: $0.to, label: nil, style: .solid, arrow: false) }, groups: [])
        return chart.layers.map { layer in layer.compactMap { node in entities.first { $0.name == node.id } } }
    }

    static func parse(_ lines: [String]) -> ERDiagram {
        var diagram = ERDiagram(entities: [], relationships: [])
        func ensure(_ name: String) {
            if !diagram.entities.contains(where: { $0.name == name }) { diagram.entities.append(Entity(name: name, attributes: [])) }
        }
        let relation = try? NSRegularExpression(pattern: #"^(\S+)\s+([|}o][|o]|[|}][|o])(--|\.\.)([|o][|{o]|[|o][|{])\s+(\S+)\s*:\s*(.*)$"#)
        var current: String?
        for line in lines {
            if let name = current {
                if line == "}" { current = nil; continue }
                let parts = line.split(separator: " ").map(String.init)
                guard parts.count >= 2, let index = diagram.entities.firstIndex(where: { $0.name == name }) else { continue }
                let keys = parts.dropFirst(2).filter { ["PK", "FK", "UK"].contains($0.trimmingCharacters(in: CharacterSet(charactersIn: ","))) }
                diagram.entities[index].attributes.append(Attribute(type: parts[0], name: parts[1], keys: keys.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",")) }))
                continue
            }
            if line.hasSuffix("{") {
                let name = line.dropLast().trimmingCharacters(in: .whitespaces)
                ensure(name)
                current = name
                continue
            }
            let ns = line as NSString
            guard let match = relation?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let from = ns.substring(with: match.range(at: 1)), to = ns.substring(with: match.range(at: 5))
            ensure(from)
            ensure(to)
            diagram.relationships.append(Relationship(
                from: from, to: to,
                fromCardinality: cardinality(ns.substring(with: match.range(at: 2))),
                toCardinality: cardinality(ns.substring(with: match.range(at: 4))),
                label: Mermaid.unquote(ns.substring(with: match.range(at: 6)))
            ))
        }
        return diagram
    }

    /// Crow's-foot markers, read from either side: `||` one, `o|`/`|o` zero or one,
    /// `}o`/`o{` zero or more, `}|`/`|{` one or more.
    static func cardinality(_ marker: String) -> String {
        let many = marker.contains("{") || marker.contains("}")
        let optional = marker.contains("o")
        switch (many, optional) {
        case (true, true): return "0..N"
        case (true, false): return "1..N"
        case (false, true): return "0..1"
        case (false, false): return "1"
        }
    }
}
