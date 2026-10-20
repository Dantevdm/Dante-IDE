import Foundation

/// The project as data a scene can draw: the system map's lanes, parts and links, the
/// infrastructure and its pipelines, and a few numbers. Written to the piece's `data.json`
/// and handed to the scene as `dante.data`, so a video of "how a request travels" is drawn
/// from the real code, and drawn again when the code changes.
public enum MotionData {
    public static let fileName = "data.json"

    /// Everything known, keyed "system", "infra" and "stats".
    public static func json(project: String, system: SystemMap?, infra: Infrastructure?, stats: [String: Int] = [:]) -> [String: Any] {
        var object: [String: Any] = ["project": project, "generated": ISO8601DateFormatter().string(from: Date())]
        if let system, !system.parts.isEmpty { object["system"] = Self.system(system) }
        if let infra, !infra.isEmpty { object["infra"] = Self.infra(infra) }
        if !stats.isEmpty { object["stats"] = stats }
        return object
    }

    public static func system(_ map: SystemMap) -> [String: Any] {
        [
            "lanes": map.lanes.map { lane, parts in
                [
                    "id": String(describing: lane), "title": map.title(of: lane),
                    "parts": parts.map { part -> [String: Any] in
                        var object: [String: Any] = ["id": part.id, "name": part.name, "kind": part.kind.rawValue, "detail": part.detail, "items": part.items.count]
                        if part.lane == .api {
                            object["routes"] = part.items.prefix(30).map { item -> [String: Any] in
                                var route: [String: Any] = ["text": item.text]
                                if let access = item.access { route["open"] = access.level == .open; if access.isConcern { route["concern"] = true } }
                                return route
                            }
                        } else if part.lane == .clients || part.kind == .database {
                            object["children"] = part.items.prefix(30).map(\.text)
                        }
                        if let container = part.container { object["container"] = container }
                        return object
                    },
                ] as [String: Any]
            },
            "links": map.links.map { ["from": $0.from, "to": $0.to, "weight": $0.weight] },
        ]
    }

    public static func infra(_ infra: Infrastructure) -> [String: Any] {
        [
            "provider": infra.provider.rawValue,
            "environments": infra.environments,
            "resources": infra.resources.map { ["id": $0.id, "name": $0.name, "service": $0.service, "tier": String(describing: $0.tier), "stack": $0.stack] },
            "links": infra.links.map { ["from": $0.from, "to": $0.to, "label": $0.label] },
            "pipelines": infra.pipelines.map { pipeline in
                [
                    "name": pipeline.name, "system": pipeline.system,
                    "stages": pipeline.stages.map { ["name": $0.name, "kind": $0.kind.rawValue, "environment": $0.environment ?? ""] },
                ] as [String: Any]
            },
        ]
    }

    /// One paragraph per kind of data, for the agent's brief: what `dante.data` holds.
    public static func describe(_ object: [String: Any]) -> String {
        var lines: [String] = []
        if let system = object["system"] as? [String: Any], let lanes = system["lanes"] as? [[String: Any]] {
            let summary = lanes.map { lane -> String in
                let parts = (lane["parts"] as? [[String: Any]]) ?? []
                let names = parts.prefix(6).compactMap { $0["name"] as? String }.joined(separator: ", ")
                return "\(lane["title"] ?? "?") (\(parts.count)): \(names)\(parts.count > 6 ? "…" : "")"
            }
            let links = (system["links"] as? [Any])?.count ?? 0
            lines.append("dante.data.system: the system map. lanes[] {id, title, parts[] {id, name, kind, detail, items, routes[] {text, open, concern} for API groups, children[] for clients and databases}}, links[] {from, to, weight} by part id (\(links) links). " + summary.joined(separator: "; ") + ".")
        }
        if let infra = object["infra"] as? [String: Any] {
            let resources = (infra["resources"] as? [Any])?.count ?? 0
            let pipelines = (infra["pipelines"] as? [[String: Any]]) ?? []
            lines.append("dante.data.infra: \(infra["provider"] ?? "cloud") infrastructure. resources[] {id, name, service, tier, stack} (\(resources)), links[] {from, to, label}, environments[], pipelines[] {name, system, stages[] {name, kind, environment}}: " + pipelines.map { "\($0["name"] ?? "") (\((($0["stages"] as? [Any])?.count ?? 0)) stages)" }.joined(separator: ", ") + ".")
        }
        if let stats = object["stats"] as? [String: Int] {
            lines.append("dante.data.stats: " + stats.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ".")
        }
        return lines.isEmpty ? "dante.data is null: no project data was asked for." : lines.joined(separator: "\n")
    }
}
