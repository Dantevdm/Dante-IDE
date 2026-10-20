import Foundation

/// The infrastructure in a few plain sentences: how a change is delivered, how a request
/// reaches the app, and what holds it together. Pure.
public struct InfraStory: Equatable, Sendable {
    public struct Line: Equatable, Sendable, Hashable {
        public var symbol: String
        public var title: String
        public var text: String
    }

    public var lines: [Line]

    public init(_ infra: Infrastructure) {
        var lines: [Line] = []
        // Delivery: one sentence per pipeline, its stages in order.
        for pipeline in infra.pipelines {
            let trigger = pipeline.branches.isEmpty ? "when it's run" : "on every push to \(Self.list(pipeline.branches))"
            let stages = pipeline.stages.map { $0.name.lowercased() }
            var text = "\(pipeline.system) runs \(pipeline.name) \(trigger)"
            if !stages.isEmpty { text += ": " + stages.joined(separator: " → ") }
            text += "."
            let actions = Self.actions(of: pipeline, in: infra)
            if !actions.isEmpty { text += " It " + Self.list(actions) + "." }
            lines.append(Line(symbol: "arrow.triangle.branch", title: "Delivery" + (pipeline.environment.map { " · \($0)" } ?? ""), text: text))
        }
        // Traffic: from the first edge resource along the links, one per tier.
        if let path = Self.trafficPath(infra), path.count >= 2 {
            let names = path.map { Self.label($0) }
            lines.append(Line(symbol: "point.topleft.down.to.point.bottomright.curvepath", title: "A request",
                              text: "Reaches the app through " + names.joined(separator: " → ") + "."))
        }
        // Around it: images, logs, security.
        var around: [String] = []
        if infra.resources.contains(where: { $0.tier == .registry }) { around.append("images are kept in \(Self.label(infra.resources.first { $0.tier == .registry }!))") }
        if infra.resources.contains(where: { $0.tier == .observability }) { around.append("logs go to \(Self.label(infra.resources.first { $0.tier == .observability }!))") }
        let security = infra.resources.filter { $0.tier == .security }
        if !security.isEmpty { around.append("access is controlled by \(Self.list(Array(Set(security.map { Self.lowerFirst($0.service) + "s" })).sorted()))") }
        if !around.isEmpty {
            lines.append(Line(symbol: "square.grid.3x3.topleft.filled", title: "Around it", text: Self.list(around).prefix(1).uppercased() + Self.list(around).dropFirst() + "."))
        }
        if !infra.stacks.isEmpty {
            let stacks = infra.stacks.map { stack in "\(stack.name) (\(stack.tool), \(Self.count(infra.resources.filter { $0.stack == stack.id }.count, "resource")))" }
            var text = "\(infra.stacks.count == 1 ? "One stack" : "\(infra.stacks.count) stacks") on \(infra.provider.rawValue): " + stacks.joined(separator: ", ") + "."
            if !infra.environments.isEmpty { text += " Environments: " + infra.environments.joined(separator: ", ") + "." }
            lines.append(Line(symbol: "square.stack.3d.up", title: "Defined in", text: text))
        }
        self.lines = lines
    }

    /// What a pipeline's stages do, in order, without repeats.
    static func actions(of pipeline: Infrastructure.Pipeline, in infra: Infrastructure) -> [String] {
        var found: [String] = []
        func add(_ text: String) { if !found.contains(text) { found.append(text) } }
        for stage in pipeline.stages {
            for step in stage.steps {
                let targets = infra.deploys.filter { $0.from == pipeline.id + "#" + stage.id }.compactMap { infra.resource($0.to) }
                func target(_ tier: Infrastructure.Tier? = nil, _ service: String? = nil) -> String? {
                    targets.first { (tier == nil || $0.tier == tier) && (service == nil || $0.service == service) }.map(label)
                }
                switch step.kind {
                case .build: add("builds the code")
                case .test: add("runs the tests")
                case .scan: add("scans it")
                case .image: add("builds the container image")
                case .push: add("pushes the image to " + (target(.registry) ?? "the registry"))
                case .migrate:
                    let flyway = [step.detail, step.title, stage.name].contains { $0.lowercased().contains("flyway") }
                    let text = "migrates " + (target(.data) ?? "the database") + (flyway ? " with Flyway" : "")
                    // Once: the Flyway wording wins over a plain mention.
                    if let index = found.firstIndex(where: { $0.hasPrefix("migrates ") }) {
                        if flyway { found[index] = text }
                    } else {
                        add(text)
                    }
                case .stack: add("deploys the infrastructure")
                case .deploy: add("rolls out " + (target(.compute) ?? "the new version"))
                case .approval: add("waits for an approval")
                case .script: break
                }
            }
        }
        return found
    }

    /// Edge to data along the drawn links, choosing the first link out of each step.
    static func trafficPath(_ infra: Infrastructure) -> [Infrastructure.Resource]? {
        let starts = infra.resources.filter { $0.tier == .edge }
        guard let start = starts.first(where: { r in !infra.links.contains { $0.to == r.id && infra.resource($0.from)?.tier == .edge } }) ?? starts.first else { return nil }
        var path = [start]
        var seen: Set<String> = [start.id]
        while let next = infra.links.filter({ $0.from == path.last!.id }).compactMap({ infra.resource($0.to) })
            .filter({ $0.tier.isMain && !seen.contains($0.id) && $0.service != "Task definition" && $0.service != "ECS cluster" })
            .min(by: { $0.tier < $1.tier }) {
            path.append(next)
            seen.insert(next.id)
        }
        return path
    }

    static func label(_ resource: Infrastructure.Resource) -> String {
        switch resource.service {
        case "Database" where resource.isOutside: "the database"
        case "DNS record": "a DNS record (\(resource.name))"
        default: "the \(lowerFirst(resource.service)) \(resource.name)"
        }
    }

    /// "Listener rule" → "listener rule", but "ECS service" stays.
    static func lowerFirst(_ text: String) -> String {
        let second = text.dropFirst().first
        return second?.isUppercase == true ? text : text.prefix(1).lowercased() + text.dropFirst()
    }

    static func count(_ number: Int, _ word: String) -> String { "\(number) \(word)\(number == 1 ? "" : "s")" }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}
