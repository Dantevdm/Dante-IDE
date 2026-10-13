import Foundation

/// Line coverage per file, read from a report the project's tests already wrote: lcov
/// (`lcov.info`), a Go cover profile (`coverage.out`) or Cobertura XML (`coverage.xml`).
public struct CoverageReport: Equatable, Sendable {
    public struct Lines: Equatable, Sendable {
        public var covered: Int
        public var total: Int
        public var fraction: Double { total == 0 ? 0 : Double(covered) / Double(total) }
    }

    /// By project-relative path.
    public var files: [String: Lines]
    /// The report it came from, relative to the root.
    public var source: String
    public var date: Date?

    public static let candidates = [
        "coverage/lcov.info", "lcov.info", "coverage.lcov",
        "coverage.out", "cover.out", "coverage.txt", "c.out",
        "coverage.xml", "coverage/cobertura-coverage.xml", "cobertura.xml",
    ]

    /// The newest report in the project, matched to `files` (the project's paths).
    public static func load(root: URL, files: [String]) -> CoverageReport? {
        let found = candidates.compactMap { name -> (String, Date)? in
            let url = root.appending(path: name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let date = attributes[.modificationDate] as? Date else { return nil }
            return (name, date)
        }
        guard let (name, date) = found.max(by: { $0.1 < $1.1 }),
              let text = try? String(contentsOf: root.appending(path: name), encoding: .utf8) else { return nil }
        var report = parse(text, files: files, root: root.path)
        report.source = name
        report.date = date
        return report.files.isEmpty ? nil : report
    }

    public static func parse(_ text: String, files: [String], root: String = "") -> CoverageReport {
        let raw: [String: Lines]
        if text.hasPrefix("mode:") { raw = goProfile(text) }
        else if text.contains("<coverage") { raw = cobertura(text) }
        else { raw = lcov(text) }
        // Reports name files absolutely, by Go module path or from the root; match each to a
        // project file by the longest shared tail.
        var byName: [String: [String]] = [:]
        for file in files { byName[(file as NSString).lastPathComponent, default: []].append(file) }
        var result: [String: Lines] = [:]
        for (path, lines) in raw {
            var path = path
            if !root.isEmpty, path.hasPrefix(root + "/") { path = String(path.dropFirst(root.count + 1)) }
            let match = files.contains(path) ? path : bestMatch(path, among: byName[(path as NSString).lastPathComponent] ?? [])
            guard let match else { continue }
            var total = result[match] ?? Lines(covered: 0, total: 0)
            total.covered += lines.covered
            total.total += lines.total
            result[match] = total
        }
        return CoverageReport(files: result, source: "", date: nil)
    }

    /// The candidate sharing the most trailing folders with `path`. A module path
    /// (`example.com/shop/internal/api/x.go`) and a repo path (`backend/internal/api/x.go`)
    /// share `internal/api/x.go`. A bare file name only counts when it's the only one.
    static func bestMatch(_ path: String, among candidates: [String]) -> String? {
        let parts = path.split(separator: "/")
        func shared(_ candidate: String) -> Int {
            zip(parts.reversed(), candidate.split(separator: "/").reversed()).prefix { $0 == $1 }.count
        }
        let scored = candidates.map { ($0, shared($0)) }.sorted { $0.1 > $1.1 }
        guard let best = scored.first else { return nil }
        if best.1 < 2, candidates.count > 1 { return nil }
        if scored.count > 1, scored[1].1 == best.1 { return nil }
        return best.0
    }

    static func lcov(_ text: String) -> [String: Lines] {
        var result: [String: Lines] = [:]
        var file: String?
        var found = 0, hit = 0
        for line in text.split(separator: "\n") {
            if line.hasPrefix("SF:") { file = String(line.dropFirst(3)); found = 0; hit = 0 }
            else if line.hasPrefix("LF:") { found = Int(line.dropFirst(3)) ?? 0 }
            else if line.hasPrefix("LH:") { hit = Int(line.dropFirst(3)) ?? 0 }
            else if line == "end_of_record", let current = file {
                result[current] = Lines(covered: hit, total: found)
                file = nil
            }
        }
        return result
    }

    /// `path/file.go:12.30,14.2 3 1`: statements, and how often they ran.
    static func goProfile(_ text: String) -> [String: Lines] {
        var blocks: [String: [String: (Int, Bool)]] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ")
            guard fields.count == 3, let colon = fields[0].lastIndex(of: ":"),
                  let statements = Int(fields[1]), let count = Int(fields[2]) else { continue }
            let file = String(fields[0][..<colon])
            let block = String(fields[0][fields[0].index(after: colon)...])
            // The same block appears once per test binary; it's covered if any run hit it.
            let previous = blocks[file]?[block]
            blocks[file, default: [:]][block] = (statements, (previous?.1 ?? false) || count > 0)
        }
        return blocks.mapValues { blocks in
            Lines(covered: blocks.values.filter(\.1).reduce(0) { $0 + $1.0 }, total: blocks.values.reduce(0) { $0 + $1.0 })
        }
    }

    /// `<class filename="…" line-rate="…">` with its `<line hits="…">` children.
    static func cobertura(_ text: String) -> [String: Lines] {
        var result: [String: Lines] = [:]
        var current: String?
        for raw in text.components(separatedBy: "<").dropFirst() {
            if raw.hasPrefix("class "), let file = attribute("filename", in: raw) {
                current = file
            } else if raw.hasPrefix("line "), let file = current, let hits = attribute("hits", in: raw).flatMap(Int.init) {
                var lines = result[file] ?? Lines(covered: 0, total: 0)
                lines.total += 1
                if hits > 0 { lines.covered += 1 }
                result[file] = lines
            } else if raw.hasPrefix("/class") {
                current = nil
            }
        }
        return result
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let start = tag.range(of: name + "=\"") else { return nil }
        let rest = tag[start.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }
}
