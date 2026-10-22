import CoreGraphics
import Foundation

// MARK: Icons the Map and diagrams share

extension Infrastructure.Tier {
    public var symbol: String {
        switch self {
        case .edge: "globe"
        case .compute: "cpu"
        case .data: "cylinder.split.1x2"
        case .messaging: "tray.2"
        case .registry: "archivebox"
        case .security: "lock.shield"
        case .network: "network"
        case .observability: "waveform.path.ecg"
        case .other: "cube"
        }
    }
}

extension Infrastructure.Provider {
    public var symbol: String { self == .azure ? "cloud.fill" : "cloud" }

    /// "AWS cloud", or "Cloud".
    public var cloudTitle: String { self == .other ? "Cloud" : rawValue + " cloud" }
}

extension SystemMap.Kind {
    public var symbol: String {
        switch self {
        case .web: "macwindow"
        case .mobile: "iphone"
        case .routes: "arrow.left.arrow.right"
        case .app: "terminal"
        case .package: "shippingbox"
        case .structure: "curlybraces.square"
        case .function: "function"
        case .database: "cylinder.split.1x2"
        case .table: "tablecells"
        case .cache: "bolt.horizontal"
        case .container: "cube"
        case .email: "envelope"
        case .messaging: "bubble.left.and.bubble.right"
        case .ai: "sparkles"
        case .payments: "creditcard"
        case .storage: "externaldrive"
        case .monitoring: "waveform.path.ecg"
        case .service: "globe"
        }
    }
}

extension SystemMap.Lane {
    public var symbol: String {
        switch self {
        case .clients: "macwindow"
        case .api: "arrow.left.arrow.right"
        case .backend: "shippingbox"
        case .data: "cylinder.split.1x2"
        case .outside: "globe"
        }
    }
}

// MARK: From the Map

/// Turns what a Map view shows into a diagram to edit. `frames` are the boxes where the view
/// drew them (by the view's ids, see each function); without them the picture is laid out
/// the way the view lays it out.
extension Diagram {
    /// The Infra view. Frame ids: each resource's id, "users", "source:<pipeline>",
    /// "<pipeline>#<stage>", "tier:<tier number>", "cloud" (the dashed panel) and "band:delivery".
    public static func infrastructure(_ infra: Infrastructure, title: String, frames given: [String: CGRect] = [:]) -> Diagram {
        let frames = given.isEmpty ? InfraPlacement(infra).frames : given
        var diagram = Diagram(title: title, note: infra.stacks.isEmpty ? "" : "From " + infra.stacks.map(\.name).joined(separator: ", "))
        var ids: [String: String] = [:]
        func add(_ key: String, _ node: Node) {
            var node = node
            node.id = diagram.uniqueID(for: node.title.isEmpty ? key : node.title)
            node.frame = frames[key].map(Rect.init)
            ids[key] = node.id
            diagram.nodes.append(node)
        }

        // Delivery: each pipeline's source, then its stages.
        if !infra.pipelines.isEmpty {
            add("band:delivery", Node(id: "", kind: .title, title: "Delivery", subtitle: Set(infra.pipelines.map(\.system)).sorted().joined(separator: " · "),
                                      icon: "arrow.triangle.branch", hue: .gray))
        }
        for pipeline in infra.pipelines {
            add("source:" + pipeline.id, Node(id: "", kind: .source, title: pipeline.name, subtitle: pipeline.system, detail: pipeline.file,
                                               hue: .blue, chips: Array(pipeline.branches.prefix(3)), tag: pipeline.environment ?? ""))
            for stage in pipeline.stages {
                add(pipeline.id + "#" + stage.id, Node(id: "", kind: .stage, title: stage.name, subtitle: stage.environment ?? "", icon: stage.kind.symbol,
                                                       hue: .blue, icons: stage.steps.prefix(8).map(\.kind.symbol)))
            }
        }

        // The cloud: a dashed boundary, users, and a group per tier.
        let mainTiers = Infrastructure.Tier.allCases.filter { tier in infra.resources.contains { $0.tier == tier } }
        if !infra.resources.isEmpty {
            var cloud = Node(id: "", kind: .boundary, title: infra.provider.cloudTitle, subtitle: infra.stacks.map(\.name).joined(separator: " · "),
                             icon: infra.provider.symbol, hue: .gray, dashed: true)
            cloud.id = diagram.uniqueID(for: cloud.title)
            if let panel = frames["cloud"] {
                cloud.frame = Rect(CGRect(x: panel.minX, y: panel.minY - Self.boundaryTitleRoom, width: panel.width, height: panel.height + Self.boundaryTitleRoom))
            }
            ids["cloud"] = cloud.id
            diagram.nodes.append(cloud)
            if frames["users"] != nil || given.isEmpty, !InfraPlacement.entrances(infra).isEmpty {
                add("users", Node(id: "", kind: .person, title: "Users", hue: .gray, parent: cloud.id))
            }
            for tier in mainTiers {
                add("tier:\(tier.rawValue)", Node(id: "", kind: .group, title: tier.title, icon: tier.symbol, hue: Hue(tier: tier), parent: cloud.id))
                for resource in infra.resources where resource.tier == tier {
                    add(resource.id, Node(id: "", kind: .card, title: resource.name, subtitle: resource.service,
                                          detail: resource.stack.isEmpty ? (resource.isOutside ? "outside the templates" : "") : resource.stack,
                                          icon: resource.symbol, hue: Hue(tier: tier), parent: ids["tier:\(tier.rawValue)"], dashed: resource.isOutside))
                }
            }
        }

        // Links, as the view draws them at rest.
        for pipeline in infra.pipelines {
            for (index, stage) in pipeline.stages.enumerated() {
                let to = pipeline.id + "#" + stage.id
                let froms = stage.dependsOn.isEmpty ? [index == 0 ? "source:" + pipeline.id : pipeline.id + "#" + pipeline.stages[index - 1].id]
                    : stage.dependsOn.map { pipeline.id + "#" + $0 }
                for from in froms {
                    guard let a = ids[from], let b = ids[to] else { continue }
                    diagram.links.append(Link(id: diagram.uniqueID(for: "\(a) to \(b)"), from: a, to: b, line: .flowing, arrow: false, hue: .blue, width: 1.6))
                }
            }
        }
        if let users = ids["users"] {
            for entrance in InfraPlacement.entrances(infra) {
                guard let b = ids[entrance.id] else { continue }
                diagram.links.append(Link(id: diagram.uniqueID(for: "users to \(b)"), from: users, to: b, line: .flowing, pulse: true, arrow: false, width: 1.4))
            }
        }
        for link in infra.links {
            guard let from = infra.resource(link.from), let to = infra.resource(link.to), let a = ids[link.from], let b = ids[link.to] else { continue }
            let traffic = from.tier.isMain && to.tier.isMain
            diagram.links.append(Link(id: diagram.uniqueID(for: "\(a) to \(b)"), from: a, to: b, label: traffic ? link.label : "",
                                      line: link.declared ? .solid : .dashed, pulse: traffic, hue: traffic ? Hue(tier: to.tier) : nil, width: traffic ? 1.7 : 1.2))
        }
        diagram.settle()
        return diagram
    }

    /// The project's Infra or System view as a diagram, read straight from its files (for when
    /// the Map hasn't been built in this window). Nil when the project has nothing to show.
    public static func fromProject(_ root: URL, system: Bool, title: String) -> Diagram? {
        let files = FileIndex.scan(root)
        let read: @Sendable (String) -> String? = { path in
            let url = root.appending(path: path)
            guard ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < 2_000_000 else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        if system {
            let map = SystemMap.build(files: files, read: { SystemMap.isReadable($0) ? read($0) : nil }, compose: ComposeFile.load(projectRoot: root), modules: nil)
            return map.isUseful ? Diagram.system(map, title: title) : nil
        }
        let infra = Infrastructure.detect(files: files.filter(Infrastructure.isCandidate), read: read)
        return infra.isEmpty ? nil : Diagram.infrastructure(infra, title: title)
    }

    /// The System map, or an opened part's inside. Frame ids: each part's id. Each lane
    /// becomes a group around its parts, in the lane's colour.
    public static func system(_ map: SystemMap, title: String, frames given: [String: CGRect] = [:]) -> Diagram {
        let frames = given.isEmpty ? SystemPlacement(map).frames : given
        var diagram = Diagram(title: title)
        var ids: [String: String] = [:]
        for (lane, parts) in map.lanes {
            let laneFrames = parts.compactMap { frames[$0.id] }
            let groupID = diagram.uniqueID(for: map.title(of: lane))
            var group = Node(id: groupID, kind: .group, title: map.title(of: lane), icon: lane.symbol, hue: Hue(lane: lane))
            if !laneFrames.isEmpty {
                let union = laneFrames.reduce(CGRect.null) { $0.union($1) }
                let header = headerHeight(.group)
                group.frame = Rect(CGRect(x: union.minX - inset, y: union.minY - header, width: union.width + inset * 2, height: union.height + header + inset))
            }
            diagram.nodes.append(group)
            for part in parts {
                let screens = part.lane == .clients && part.id.hasPrefix("client:") ? part.items.prefix(8).map(\.text).joined(separator: " · ") : ""
                var node = Node(id: diagram.uniqueID(for: part.name), kind: .box, title: part.name, subtitle: part.detail, text: screens,
                                icon: part.kind.symbol, hue: Hue(lane: lane), parent: groupID, dashed: lane == .outside,
                                chips: part.container.map { [$0] } ?? [])
                node.frame = frames[part.id].map(Rect.init)
                ids[part.id] = node.id
                diagram.nodes.append(node)
            }
        }
        let heaviest = max(map.links.map(\.weight).max() ?? 1, 1)
        for link in map.links {
            guard let a = ids[link.from], let b = ids[link.to] else { continue }
            diagram.links.append(Link(id: diagram.uniqueID(for: "\(a) to \(b)"), from: a, to: b, pulse: link.weight * 3 >= heaviest,
                                      width: 1.1 + 1.6 * Double(link.weight) / Double(heaviest), route: .loop))
        }
        diagram.settle()
        return diagram
    }

    /// The room above a boundary's dashed frame for its title.
    public static let boundaryTitleRoom: CGFloat = 30

    /// Places anything still without a frame, grows containers round their contents and
    /// moves the picture clear of the top and left.
    public mutating func settle() {
        if nodes.contains(where: { $0.frame == nil }) { self = laidOut() }
        // Inner containers first, so an outer one grows round the inner one's new size.
        for node in drawingOrder.reversed() where node.kind.isContainer {
            if let index = nodes.firstIndex(where: { $0.id == node.id }), let needed = contentsFrame(of: node.id), !nodes[index].rect.contains(needed) {
                nodes[index].frame = Rect(nodes[index].rect.union(needed))
            }
        }
        normalise(margin: 24)
    }
}

/// Where the Infra view puts things, for a picture made without the view on screen (an
/// agent's request): the pipelines in rows, then the cloud with users and a column per tier.
struct InfraPlacement {
    var frames: [String: CGRect] = [:]

    static func entrances(_ infra: Infrastructure) -> [Infrastructure.Resource] {
        infra.resources.filter { r in r.tier == .edge && !infra.links.contains { $0.to == r.id && infra.resource($0.from)?.tier == .edge } }
    }

    init(_ infra: Infrastructure) {
        var y: CGFloat = 24
        if !infra.pipelines.isEmpty {
            frames["band:delivery"] = CGRect(x: 24, y: y, width: 260, height: 16)
            y += 28
            for pipeline in infra.pipelines {
                frames["source:" + pipeline.id] = CGRect(x: 24, y: y + 4, width: 190, height: 70)
                for (index, stage) in pipeline.stages.enumerated() {
                    frames[pipeline.id + "#" + stage.id] = CGRect(x: 24 + 230 + CGFloat(index) * 236, y: y, width: 196, height: 78)
                }
                y += 90
            }
            y += 14
        }
        guard !infra.resources.isEmpty else { return }
        let panelTop = y + Diagram.boundaryTitleRoom
        var x: CGFloat = 44
        let top = panelTop + 20
        var bottom = top
        if !Self.entrances(infra).isEmpty {
            frames["users"] = CGRect(x: x, y: top + 60, width: 50, height: 66)
            x += 50 + 46
        }
        func column(_ tier: Infrastructure.Tier, at x: CGFloat, top: CGFloat) -> CGRect {
            let members = infra.resources.filter { $0.tier == tier }
            var cardY = top + 36
            for resource in members {
                frames[resource.id] = CGRect(x: x + 12, y: cardY, width: 196, height: 64)
                cardY += 74
            }
            let rect = CGRect(x: x, y: top, width: 220, height: cardY - top + 2)
            frames["tier:\(tier.rawValue)"] = rect
            return rect
        }
        for tier in Infrastructure.Tier.allCases where tier.isMain && infra.resources.contains(where: { $0.tier == tier }) {
            bottom = max(bottom, column(tier, at: x, top: top).maxY)
            x += 220 + 46
        }
        var right = x - 46
        let supportTop = bottom + 22
        x = 44
        for tier in Infrastructure.Tier.allCases where !tier.isMain && infra.resources.contains(where: { $0.tier == tier }) {
            bottom = max(bottom, column(tier, at: x, top: supportTop).maxY)
            x += 220 + 18
            right = max(right, x - 18)
        }
        frames["cloud"] = CGRect(x: 24, y: panelTop, width: right - 24 + 20, height: bottom - panelTop + 20)
    }
}

/// Where the System map puts things: a column per lane, data and outside services sharing the last.
struct SystemPlacement {
    var frames: [String: CGRect] = [:]

    init(_ map: SystemMap) {
        var x: CGFloat = 40
        var previous: SystemMap.Lane?
        var columnBottom: CGFloat = 0
        for (lane, parts) in map.lanes {
            var y: CGFloat = 60
            if lane == .outside, previous == .data {
                x -= 180 + 56
                y = columnBottom + 56
            }
            for part in parts {
                let height: CGFloat = part.lane == .clients && !part.items.isEmpty ? 84 : 56
                frames[part.id] = CGRect(x: x, y: y, width: 180, height: height)
                y += height + 12
            }
            columnBottom = y
            previous = lane
            x += 180 + 56
        }
    }
}

// MARK: Laying out a hand-written diagram

extension Diagram {
    /// Places every node without a frame: top-level things in columns along the links
    /// (what's linked to comes after what links to it), each container's contents stacked
    /// inside it, and containers sized to hold them. Nodes with frames stay put.
    public func laidOut() -> Diagram {
        var copy = self
        let gap: CGFloat = 48
        // Inside out: a container's size depends on what it holds.
        func place(children parent: String?, origin: CGPoint) -> CGSize {
            let members = copy.nodes.filter { $0.parent == parent && $0.frame == nil }
            guard !members.isEmpty else { return .zero }
            let ranks = copy.ranks(of: members.map(\.id))
            let columns = Dictionary(grouping: members) { ranks[$0.id] ?? 0 }.sorted { $0.key < $1.key }.map(\.value)
            var x = origin.x
            var tallest: CGFloat = 0
            let spacing = parent == nil ? gap : 12
            for column in columns {
                var y = origin.y
                var widest: CGFloat = 0
                for member in column {
                    var size = member.kind.defaultSize
                    if member.kind.isContainer {
                        let header = Self.headerHeight(member.kind)
                        let inner = place(children: member.id, origin: CGPoint(x: x + Self.inset, y: y + header))
                        if inner != .zero {
                            size = CGSize(width: max(size.width, inner.width + Self.inset * 2), height: max(Self.minimumSize(member.kind).height, inner.height + header + Self.inset))
                        }
                    }
                    if let index = copy.nodes.firstIndex(where: { $0.id == member.id }) {
                        copy.nodes[index].frame = Rect(CGRect(origin: CGPoint(x: x, y: y), size: size))
                    }
                    y += size.height + spacing
                    widest = max(widest, size.width)
                }
                tallest = max(tallest, y - spacing - origin.y)
                x += widest + (parent == nil ? 72 : 12)
            }
            return CGSize(width: x - (parent == nil ? 72 : 12) - origin.x, height: tallest)
        }
        let placed = copy.bounds
        let start = placed.isNull ? CGPoint(x: 40, y: 40) : CGPoint(x: 40, y: placed.maxY + gap)
        _ = place(children: nil, origin: start)
        // Children of containers that already had frames.
        for container in copy.nodes where container.kind.isContainer && container.frame != nil {
            let unplaced = copy.nodes.filter { $0.parent == container.id && $0.frame == nil }
            guard !unplaced.isEmpty else { continue }
            let inside = copy.children(of: container.id).compactMap { $0.frame?.cg }.reduce(CGRect.null) { $0.union($1) }
            let origin = inside.isNull ? CGPoint(x: container.rect.minX + Self.inset, y: container.rect.minY + Self.headerHeight(container.kind))
                : CGPoint(x: inside.minX, y: inside.maxY + 12)
            _ = place(children: container.id, origin: origin)
            copy.growAncestors(of: unplaced[0].id)
        }
        return copy
    }

    /// For each node, how many links lead to it along the longest path among `ids` (cycles cut).
    func ranks(of ids: [String]) -> [String: Int] {
        let members = Set(ids)
        // A link into a node inside a container counts for the container.
        func outer(_ id: String) -> String? {
            if members.contains(id) { return id }
            return ancestors(of: id).first { members.contains($0.id) }?.id
        }
        var edges: [(String, String)] = []
        for link in links {
            guard let a = outer(link.from), let b = outer(link.to), a != b else { continue }
            edges.append((a, b))
        }
        var rank: [String: Int] = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
        // Longest path by relaxing as many times as there are nodes: cycles stop growing then.
        for _ in 0..<ids.count {
            var changed = false
            for (a, b) in edges where rank[b]! < rank[a]! + 1 && rank[a]! + 1 < ids.count {
                rank[b] = rank[a]! + 1
                changed = true
            }
            if !changed { break }
        }
        return rank
    }
}
