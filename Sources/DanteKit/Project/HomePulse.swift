import Foundation

/// What Home draws: the system map cut down to fit a glance, a grid of commit days and the
/// languages' shares. Pure, so Home stays quick and it's all tested.
public enum HomePulse {
    /// The system map with at most `perLane` parts in each lane: the ones with the most links,
    /// in their lane's order, and how many more each lane has.
    public struct Sketch: Equatable, Sendable {
        public var lanes: [(lane: SystemMap.Lane, parts: [SystemMap.Part], more: Int)]
        public var links: [SystemMap.Link]

        public static func == (a: Sketch, b: Sketch) -> Bool {
            a.links == b.links && a.lanes.map(\.lane) == b.lanes.map(\.lane)
                && a.lanes.map { $0.parts.map(\.id) } == b.lanes.map { $0.parts.map(\.id) } && a.lanes.map(\.more) == b.lanes.map(\.more)
        }
    }

    public static func sketch(_ map: SystemMap, perLane: Int = 4) -> Sketch {
        var weight: [String: Int] = [:]
        for link in map.links where link.from != link.to {
            weight[link.from, default: 0] += link.weight
            weight[link.to, default: 0] += link.weight
        }
        var lanes: [(lane: SystemMap.Lane, parts: [SystemMap.Part], more: Int)] = []
        var shown = Set<String>()
        for (lane, parts) in map.lanes {
            let picked = Set(parts.enumerated()
                .sorted { (weight[$0.element.id] ?? 0, -$0.offset) > (weight[$1.element.id] ?? 0, -$1.offset) }
                .prefix(perLane).map(\.element.id))
            let kept = parts.filter { picked.contains($0.id) }
            shown.formUnion(picked)
            lanes.append((lane, kept, parts.count - kept.count))
        }
        let links = map.links.filter { shown.contains($0.from) && shown.contains($0.to) && $0.from != $0.to }
        return Sketch(lanes: lanes, links: links)
    }

    /// Commits per day for the last `weeks` weeks, a column per week (Monday first), the
    /// current week last; days after today are -1.
    public static func commitGrid(_ dates: [Date], weeks: Int = 12, now: Date = Date(), calendar: Calendar = .current) -> [[Int]] {
        var calendar = calendar
        calendar.firstWeekday = 2
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              let first = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) else { return [] }
        let today = calendar.startOfDay(for: now)
        var grid = (0..<weeks).map { week in
            (0..<7).map { day -> Int in
                let date = calendar.date(byAdding: .day, value: week * 7 + day, to: first)!
                return date > today ? -1 : 0
            }
        }
        for date in dates where date >= first && date <= now {
            let days = calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: date)).day ?? -1
            guard days >= 0, days / 7 < weeks else { continue }
            grid[days / 7][days % 7] += 1
        }
        return grid
    }

    /// The languages that make up the code, largest first, the rest as "Other".
    public static func languages(_ paths: [String], limit: Int = 4) -> [(name: String, share: Double)] {
        let all = LanguageStats.top(paths, limit: .max)
        let total = all.reduce(0) { $0 + $1.files }
        guard total > 0 else { return [] }
        var shares = all.prefix(limit).map { (name: $0.language.displayName, share: Double($0.files) / Double(total)) }
        let rest = all.dropFirst(limit).reduce(0) { $0 + $1.files }
        if rest > 0 { shares.append((name: "Other", share: Double(rest) / Double(total))) }
        return shares
    }
}
