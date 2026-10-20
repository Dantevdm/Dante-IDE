import DanteSpec
import Foundation
import Yams

/// Reads `spec/`: a page per markdown file (front matter, a spoken summary, then sections)
/// and the rail's places. Pure apart from `load`, which reads the bundled folder.
public enum PageSpec {
    /// One `## Heading` of a page and its lines, bullets without their marks.
    public struct Section: Equatable, Sendable {
        public var title: String
        public var lines: [String]
    }

    struct Front: Decodable {
        var id: String
        var title: String
        var area: String?
        var phrases: [String]?
    }

    /// A page's file: nil when its front matter has no id or title.
    public static func feature(from text: String) -> DanteFeature? {
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalised.hasPrefix("---\n"), let close = normalised.range(of: "\n---\n", range: normalised.index(normalised.startIndex, offsetBy: 4)..<normalised.endIndex),
              let front = try? YAMLDecoder().decode(Front.self, from: String(normalised[normalised.index(normalised.startIndex, offsetBy: 4)..<close.lowerBound])) else { return nil }
        let body = String(normalised[close.upperBound...])
        var summary: [String] = []
        var sections: [Section] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("## ") {
                sections.append(Section(title: String(line.dropFirst(3)), lines: []))
            } else if line.hasPrefix("# ") || line.isEmpty {
                if sections.isEmpty, !summary.isEmpty, line.isEmpty { summary.append("") }
            } else if sections.isEmpty {
                summary.append(line)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                sections[sections.count - 1].lines.append(String(line.dropFirst(2)))
            } else if var last = sections[sections.count - 1].lines.popLast() {
                // A bullet carried on to the next line.
                last += " " + line
                sections[sections.count - 1].lines.append(last)
            } else {
                sections[sections.count - 1].lines.append(line)
            }
        }
        // The first paragraph is the spoken summary.
        let paragraph = summary.split(separator: "").first.map { $0.joined(separator: " ") } ?? ""
        var feature = DanteFeature(front.id, area: front.area, title: front.title, summary: paragraph,
                                   details: sections.first { $0.title == "Highlights" }?.lines ?? [],
                                   phrases: (front.phrases ?? []).map { $0.lowercased() })
        feature.sections = sections
        feature.markdown = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return feature
    }

    struct PlacesFile: Decodable {
        struct Entry: Decodable {
            var id: String
            var title: String
            var pages: [String]
            var footer: Bool?
        }
        var places: [Entry]
    }

    public static func places(from text: String) -> [FeatureGuide.Place] {
        guard let file = try? YAMLDecoder().decode(PlacesFile.self, from: text) else { return [] }
        return file.places.map { FeatureGuide.Place(id: $0.id, title: $0.title, pages: $0.pages, footer: $0.footer ?? false) }
    }

    /// Pages in rail order, each followed by its views; pages outside the rail (Settings,
    /// the Stage) last.
    public static func ordered(_ features: [DanteFeature], places: [FeatureGuide.Place]) -> [DanteFeature] {
        let rank = Dictionary(places.flatMap(\.pages).enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return features.sorted { a, b in
            let ra = rank[a.area] ?? Int.max, rb = rank[b.area] ?? Int.max
            if ra != rb { return ra < rb }
            if a.area != b.area { return a.area < b.area }
            if (a.view == nil) != (b.view == nil) { return a.view == nil }
            return a.id < b.id
        }
    }

    static func load() -> (features: [DanteFeature], places: [FeatureGuide.Place]) {
        guard let folder = DanteSpec.folder else { return ([], []) }
        let places = (try? String(contentsOf: folder.appending(path: "places.yaml"), encoding: .utf8)).map(Self.places(from:)) ?? []
        let files = (try? FileManager.default.contentsOfDirectory(at: folder.appending(path: "pages"), includingPropertiesForKeys: nil)) ?? []
        let features = files.filter { $0.pathExtension == "md" }.compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).flatMap(feature(from:))
        }
        return (ordered(features, places: places), places)
    }
}
