import Foundation
import Testing
@testable import DanteKit

/// The guide voice and the agents use to find their way around Dante.
struct FeatureGuideTests {
    /// The app's areas, read from its source: a new area without a guide entry fails here.
    @Test func everyAreaHasAnEntry() throws {
        let session = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/DanteApp/Model/Session.swift")
        let text = try String(contentsOf: session, encoding: .utf8)
        let declaration = try #require(text.firstMatch(of: /enum Area: String[^{]*\{\s*case ([\w, ]+)/))
        let areas = declaration.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(areas.count >= 14)
        for area in areas {
            let entry = FeatureGuide.feature(area)
            #expect(entry != nil, "Add \(area) to FeatureGuide.features")
            #expect(entry?.area == area && entry?.view == nil)
        }
        // Views inside a page belong to one.
        for feature in FeatureGuide.features where feature.view != nil { #expect(areas.contains(feature.area)) }
        #expect(Set(FeatureGuide.features.map(\.id)).count == FeatureGuide.features.count)
    }

    @Test func pagesAreNamedTheWayPeopleSayThem() {
        #expect(FeatureGuide.match("the infrastructure")?.id == "map.infra")
        #expect(FeatureGuide.match("pipelines")?.id == "map.infra")
        #expect(FeatureGuide.match("infra on the map")?.id == "map.infra")
        #expect(FeatureGuide.match("the data page")?.id == "data")
        #expect(FeatureGuide.match("map")?.id == "map")
        #expect(FeatureGuide.match("docker")?.id == "environments")
        #expect(FeatureGuide.match("where the data is saved") == nil)
    }

    @Test func voiceNavigatesAndExplains() {
        func parse(_ text: String) -> VoiceCommand { VoiceCommand.parse(text, projects: ["Shop Portal", "Dante IDE"]) }
        #expect(parse("Show me the infrastructure") == .navigate("map.infra"))
        #expect(parse("Hey Dante, take me to security") == .navigate("security"))
        #expect(parse("go to the data page") == .navigate("data"))
        #expect(parse("Open settings") == .navigate("settings"))
        #expect(parse("tests") == .navigate("tests"))
        // A project's name still wins.
        #expect(parse("open shop portal") == .show(project: "Shop Portal"))
        #expect(parse("What's on this page?") == .explain(nil))
        #expect(parse("What does the infra view do?") == .explain("map.infra"))
        #expect(parse("Explain the map") == .explain("map"))
        #expect(parse("What can you do?") == .overview)
        // Anything more is a question for the agent.
        #expect(parse("show me where the orders table is written") == .ask("show me where the orders table is written"))
        #expect(parse("explain how the data is saved") == .ask("explain how the data is saved"))
    }

    @Test func theAgentsBriefNamesEveryPage() {
        let brief = FeatureGuide.brief
        for feature in FeatureGuide.features { #expect(brief.contains(feature.summary)) }
        #expect(brief.contains("- Map › Infrastructure:"))
        #expect(FeatureGuide.overview.hasPrefix("Dante's pages are Home, Map, Code"))
    }
}
