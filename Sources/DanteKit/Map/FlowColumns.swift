import Foundation

/// Columns for a small flow picture: what something leads to goes to its right, so a chain
/// reads left to right (a web app, the API it calls, the database). Each node's column is the
/// longest chain of links leading into it; a cycle is cut where it closes.
public enum FlowColumns {
    public static func columns(nodes: [String], links: [(from: String, to: String)]) -> [String: Int] {
        let known = Set(nodes)
        var incoming: [String: [String]] = [:]
        for link in links where known.contains(link.from) && known.contains(link.to) && link.from != link.to {
            incoming[link.to, default: []].append(link.from)
        }
        var column: [String: Int] = [:]
        var visiting: Set<String> = []
        func depth(_ node: String) -> Int {
            if let known = column[node] { return known }
            guard !visiting.contains(node) else { return 0 }
            visiting.insert(node)
            let value = (incoming[node] ?? []).map { depth($0) + 1 }.max() ?? 0
            visiting.remove(node)
            column[node] = value
            return value
        }
        for node in nodes { _ = depth(node) }
        return column
    }
}
