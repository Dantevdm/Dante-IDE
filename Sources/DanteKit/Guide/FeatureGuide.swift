import Foundation

/// A page or view in Dante, described for voice and the agents: what it is, what it shows,
/// what you can do there, and the words people use for it.
public struct DanteFeature: Identifiable, Equatable, Sendable {
    /// "map", or "map.infra" for a view inside a page.
    public var id: String
    /// The `Session.Area` it lives in ("settings" for the Settings window, "stage" for the Stage).
    public var area: String
    /// The view inside the area, when it has several ("infra" on the Map).
    public var view: String?
    public var title: String
    /// One spoken sentence: what it's for.
    public var summary: String
    /// What it shows and what you can do there, a sentence each.
    public var details: [String]
    /// Words that name it, lowercased: "pipelines", "cloud".
    public var phrases: [String]
    /// The spec's sections: Highlights, Shows, Actions, States, Edge cases, Acceptance.
    public var sections: [PageSpec.Section] = []
    /// The spec file's body, for `dante_pages`.
    public var markdown = ""

    public init(_ id: String, area: String? = nil, view: String? = nil, title: String, summary: String, details: [String] = [], phrases: [String] = []) {
        self.id = id
        self.area = area ?? String(id.split(separator: ".").first ?? "")
        self.view = view ?? (id.contains(".") ? id.split(separator: ".").last.map(String.init) : nil)
        self.title = title
        self.summary = summary
        self.details = details
        self.phrases = phrases
    }
}

/// Every page and view in Dante, read from `spec/pages` (see spec/README.md). Voice opens and
/// explains them from here and the agents get them in their brief and through `dante mcp`, so
/// each new page or view gets a spec file as it's added (`FeatureGuideTests` fails when an
/// area has none).
public enum FeatureGuide {
    private static let spec = PageSpec.load()
    public static var features: [DanteFeature] { spec.features }

    /// The rail's places, in order, each with its pages as tabs (the first is where it opens).
    /// The app's rail is built from this list.
    public struct Place: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var pages: [String]
        /// At the foot of the rail.
        public var footer = false
    }

    public static var places: [Place] { spec.places }

    /// The place a page is in.
    public static func place(of page: String) -> Place? { places.first { $0.pages.contains(page) } }

    public static func feature(_ id: String) -> DanteFeature? { features.first { $0.id == id } }

    /// A page as an agent or a person names it: its id, "local.services", "Local › Services",
    /// "Map/Infra", or a spoken name.
    public static func resolve(_ name: String) -> DanteFeature? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let exact = feature(trimmed.lowercased()) { return exact }
        let parts = trimmed.lowercased().split(whereSeparator: { ".›>/".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.count == 2 {
            // A place and its tab, or a page and its view, by id or title.
            if let place = places.first(where: { $0.id == parts[0] || $0.title.lowercased() == parts[0] }),
               let page = place.pages.compactMap(feature).first(where: { $0.id == parts[1] || $0.title.lowercased() == parts[1] }) { return page }
            if let page = features.first(where: { $0.view == nil && ($0.id == parts[0] || $0.title.lowercased() == parts[0]) }),
               let view = features.first(where: { $0.area == page.area && $0.view != nil && ($0.view == parts[1] || $0.title.lowercased() == parts[1]) }) { return view }
        }
        if parts.count == 1, let place = places.first(where: { $0.id == parts[0] || $0.title.lowercased() == parts[0] }) {
            return feature(place.pages[0])
        }
        return match(trimmed)
    }

    /// The page a request names, when that's all it names: "the infrastructure", "data page",
    /// "the map view". Nil for anything longer ("where the data is saved"), which is a
    /// question for the agent.
    public static func match(_ spoken: String) -> DanteFeature? {
        var words = spoken.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "'" }.split(separator: " ").map(String.init)
        while let first = words.first, ["the", "my", "our", "this", "a"].contains(first) { words.removeFirst() }
        while let last = words.last, ["page", "view", "tab", "screen", "area", "section", "for", "do", "please", "now", "then", "again"].contains(last) { words.removeLast() }
        // "infra on the map": the view's name is enough.
        if let on = words.lastIndex(where: { $0 == "on" || $0 == "in" }), on > 0, words[(on + 1)...].filter({ $0 != "the" }) == ["map"] {
            words = Array(words[..<on])
        }
        let name = words.joined(separator: " ")
        guard !name.isEmpty else { return nil }
        // A page's own title first ("services" is the Services tab, not the Map's view), then
        // a view's words over a page's ("pipelines" is the Infra view).
        if let page = features.first(where: { $0.view == nil && $0.title.lowercased() == name }) { return page }
        let found = features.filter { $0.title.lowercased() == name || $0.phrases.contains(name) }
        return found.first { $0.view != nil } ?? found.first
    }

    /// Spoken: what it is and the first things to know.
    public static func explanation(of feature: DanteFeature) -> String {
        ([feature.summary] + feature.details.prefix(2)).joined(separator: " ")
    }

    /// Spoken: the places in a breath, with the pages inside each.
    public static var overview: String {
        let spoken = places.map { place -> String in
            let pages = place.pages.compactMap { feature($0)?.title }
            return pages == [place.title] ? place.title : "\(place.title), with \(list(pages))"
        }
        return "Dante has \(spoken.count) places: " + spoken.joined(separator: "; ") + ". Say open and a page's name, or ask what one does."
    }

    private static func list(_ items: [String]) -> String {
        items.count < 2 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    /// Where it is, as the user finds it: "Map › Infrastructure", "Quality › Security", "Home".
    public static func place(_ feature: DanteFeature) -> String {
        if feature.view != nil {
            return "\(self.feature(feature.area)?.title ?? feature.area.capitalized) › \(feature.title)"
        } else if let group = place(of: feature.id), group.pages.count > 1 {
            return "\(group.title) › \(feature.title)"
        }
        return feature.title
    }

    /// For the agents' brief: every page and view in a line, so they can send the user there.
    public static var brief: String {
        let lines = features.map { "- \(place($0)): \($0.summary)" }
        return "Dante (the IDE the user is in) has these pages; point the user to one when it shows what they ask about. With Dante's tools, show_page opens one for them and dante_pages gives a page's full spec.\n" + lines.joined(separator: "\n")
    }
}
