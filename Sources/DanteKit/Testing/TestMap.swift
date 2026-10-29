import Foundation

/// Every test written in the code as a tile, coloured by what the runs on this Mac last said
/// about it: passed, failed, flaky, skipped or never run, and marked stale when its file
/// changed after that run. Built from `TestInventory` and `TestRunLog`, so it shows the
/// project's tests whoever ran them.
public struct TestMap: Equatable, Sendable {
    public enum State: String, Equatable, Sendable, CaseIterable {
        case failed, flaky, passed, skipped, notRun
    }

    public struct Tile: Equatable, Sendable, Identifiable {
        public var test: WrittenTest
        public var state: State
        /// The result that set the state, when a run had one.
        public var result: TestResult?
        /// When that run was, and who ran it.
        public var ranAt: Date?
        public var ranBy: TestRunner?
        /// The test's file changed after that run, so the result may be out of date.
        public var stale: Bool
        /// In the run going now, and not reported yet.
        public var waiting: Bool
        /// Passed and failed in recent runs. A flaky test whose last result passed shows as
        /// `.flaky`; one that last failed stays `.failed` with this set.
        public var flaky = false
        public var id: String { test.id }
    }

    public struct Group: Equatable, Sendable, Identifiable {
        /// The folder or package (`WrittenTest.area`).
        public var name: String
        public var category: String
        public var tiles: [Tile]
        public var id: String { name }
        public func count(_ state: State) -> Int { tiles.count { $0.state == state } }
    }

    /// One kind of test (`TestInventory` categories: Front-end, Back-end, Integration…) with
    /// its folders inside.
    public struct Kind: Equatable, Sendable, Identifiable {
        public var name: String
        public var areas: [Group]
        public var id: String { name }
        public var tiles: [Tile] { areas.flatMap(\.tiles) }
        public func count(_ state: State) -> Int { areas.reduce(0) { $0 + $1.count(state) } }
    }

    /// The tests by kind, in `order` (kinds it doesn't name come after), each kind's folders
    /// with failures first.
    public func kinds(order: [String]) -> [Kind] {
        var byKind: [String: [String: Group]] = [:]
        for tile in tiles {
            byKind[tile.test.category, default: [:]][tile.test.area, default: Group(name: tile.test.area, category: tile.test.category, tiles: [])].tiles.append(tile)
        }
        let rank: (Group) -> (Int, Int, String) = { group in (-group.count(.failed), -group.count(.flaky), group.name) }
        let names = order.filter { byKind[$0] != nil } + byKind.keys.filter { !order.contains($0) }.sorted()
        return names.map { name in Kind(name: name, areas: (byKind[name] ?? [:]).values.sorted { rank($0) < rank($1) }) }
    }

    public var groups: [Group]
    /// Results the runs reported that no written test matched (parameterised and display-named tests, other folders).
    public var unmatched: [TestResult]

    public var tiles: [Tile] { groups.flatMap(\.tiles) }
    public func count(_ state: State) -> Int { groups.reduce(0) { $0 + $1.count(state) } }
    public var staleCount: Int { tiles.count { $0.stale && $0.state != .notRun } }
    /// Keys (`key(_:)`) of the tests that are flaky, for marking failures.
    public var flakyKeys: Set<String> { Set(tiles.filter(\.flaky).map { Self.key($0.test.name) }) }

    /// `runs` oldest first; `live` is a run going now (its results win, and with `liveCoversAll`
    /// every test it hasn't reported yet is waiting); `modified` gives each test file's last change.
    public static func build(inventory: TestInventory, runs: [SavedTestRun], live: [TestResult]? = nil, liveCoversAll: Bool = false,
                             modified: [String: Date] = [:]) -> TestMap {
        // The newest result for each test, by name, with the run it came from.
        var latest: [String: [(result: TestResult, run: SavedTestRun?)]] = [:]
        for run in runs {
            for result in run.results { latest[key(result.name), default: []].append((result, run)) }
        }
        let flaky = Set(flakyKeys(runs))
        var liveByKey: [String: [TestResult]] = [:]
        for result in live ?? [] { liveByKey[key(result.name), default: []].append(result) }
        var matchedIDs = Set<String>()

        func pick(_ candidates: [(result: TestResult, run: SavedTestRun?)], for test: WrittenTest) -> (result: TestResult, run: SavedTestRun?)? {
            // Several tests can share a name in different files: prefer the result whose suite names this file.
            let stem = ((test.file as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
            let fitting = candidates.filter { c in
                let suite = c.result.suite.lowercased()
                return suite.isEmpty || suite.contains(stem) || stem.contains(suite) || test.file.lowercased().contains(suite)
            }
            return (fitting.isEmpty ? candidates : fitting).last
        }

        var groups: [String: Group] = [:]
        for test in inventory.tests {
            let k = key(test.name)
            var tile = Tile(test: test, state: .notRun, result: nil, ranAt: nil, ranBy: nil, stale: false, waiting: false)
            if let found = liveByKey[k].flatMap({ results in pick(results.map { (result: $0, run: SavedTestRun?.none) }, for: test) }) {
                tile.result = found.result
                tile.state = state(of: found.result.status)
                tile.ranAt = .now
                tile.ranBy = .you
                matchedIDs.insert(found.result.id)
            } else if let found = latest[k].flatMap({ pick($0, for: test) }) {
                tile.result = found.result
                tile.state = state(of: found.result.status)
                tile.ranAt = found.run?.date
                tile.ranBy = found.run?.by
                matchedIDs.insert(found.result.id)
                if let ranAt = tile.ranAt, let changed = modified[test.file], changed > ranAt { tile.stale = true }
                if live != nil, liveCoversAll { tile.waiting = true }
            } else if live != nil, liveCoversAll {
                tile.waiting = true
            }
            if flaky.contains(k) {
                tile.flaky = true
                if tile.state == .passed { tile.state = .flaky }
            }
            groups[test.area, default: Group(name: test.area, category: test.category, tiles: [])].tiles.append(tile)
        }
        let unmatched = (runs.last?.results ?? []).filter { !matchedIDs.contains($0.id) }
        let order: (Group) -> (Int, Int, String) = { group in (-group.count(.failed), -group.count(.flaky), group.name) }
        return TestMap(groups: groups.values.sorted { order($0) < order($1) }, unmatched: unmatched)
    }

    static func state(of status: TestResult.Status) -> State {
        switch status {
        case .passed: .passed
        case .failed: .failed
        case .skipped: .skipped
        }
    }

    /// Tests that both passed and failed in the last twenty runs that included them.
    static func flakyKeys(_ runs: [SavedTestRun], window: Int = 20) -> [String] {
        var outcomes: [String: (passed: Int, failed: Int)] = [:]
        for run in runs.suffix(window) where !run.brokeOutsideTests {
            for result in run.results {
                let k = key(result.name)
                if result.status == .passed { outcomes[k, default: (0, 0)].passed += 1 }
                if result.status == .failed { outcomes[k, default: (0, 0)].failed += 1 }
            }
        }
        // Failing in the newest run that had it after passing earlier is a break, not flakiness:
        // flaky needs a failure followed by a pass, or a pass between failures.
        return outcomes.filter { $0.value.passed > 0 && $0.value.failed > 0 }.keys.filter { k in
            let statuses = runs.suffix(window).compactMap { run in run.results.first { key($0.name) == k }?.status }.filter { $0 != .skipped }
            guard let firstFailure = statuses.firstIndex(of: .failed) else { return false }
            return statuses[firstFailure...].contains(.passed)
        }.sorted()
    }

    /// The name a runner prints and the name in the code, made comparable: `passes()` and
    /// `passes`, `TestLimit/zero` and `TestLimit`, `` `adds up` `` and `adds up`.
    public static func key(_ name: String) -> String {
        var key = name.components(separatedBy: "/")[0]
        if key.hasSuffix("()") { key = String(key.dropLast(2)) }
        if let paren = key.firstIndex(of: "("), key.hasSuffix(")") { key = String(key[..<paren]) }
        return key.trimmingCharacters(in: CharacterSet(charactersIn: "`\" "))
    }
}
