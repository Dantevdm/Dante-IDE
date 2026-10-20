import Foundation
import Testing
import Yams
@testable import DanteKit

/// The guide voice and the agents use to find their way around Dante, read from spec/.
struct FeatureGuideTests {
    static let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The app's areas, read from its source: a new area without a spec file fails here.
    @Test func everyAreaHasAPage() throws {
        let text = try String(contentsOf: Self.repo.appending(path: "Sources/DanteApp/Model/Session.swift"), encoding: .utf8)
        let declaration = try #require(text.firstMatch(of: /enum Area: String[^{]*\{\s*case ([\w, ]+)/))
        let areas = declaration.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(areas.count >= 14)
        for area in areas {
            let entry = FeatureGuide.feature(area)
            #expect(entry != nil, "Add spec/pages/\(area).md")
            #expect(entry?.area == area && entry?.view == nil)
        }
        // Views inside a page belong to one.
        for feature in FeatureGuide.features where feature.view != nil { #expect(areas.contains(feature.area)) }
        #expect(Set(FeatureGuide.features.map(\.id)).count == FeatureGuide.features.count)
        // The rail's places hold every area once.
        #expect(FeatureGuide.places.flatMap(\.pages).sorted() == areas.sorted())
        #expect(FeatureGuide.places.filter(\.footer).map(\.id) == ["docs"])
    }

    /// Every page file is complete: a summary, phrases, and what it shows.
    @Test func everyPageIsSpecified() {
        #expect(FeatureGuide.features.count >= 19)
        for feature in FeatureGuide.features {
            #expect(!feature.summary.isEmpty && feature.summary.hasSuffix("."), "\(feature.id) needs a summary")
            #expect(!feature.phrases.isEmpty, "\(feature.id) needs phrases")
            #expect(feature.sections.contains { $0.title == "Shows" && !$0.lines.isEmpty }, "\(feature.id) needs Shows")
            for section in feature.sections {
                #expect(["Highlights", "Shows", "Actions", "States", "Edge cases", "Acceptance"].contains(section.title), "\(feature.id): \(section.title)")
            }
        }
        // Pages in rail order, views after their page.
        #expect(FeatureGuide.features.prefix(5).map(\.id) == ["home", "map", "map.infra", "map.modules", "map.services"])
        #expect(FeatureGuide.features.suffix(2).map(\.id) == ["settings", "stage"])
    }

    @Test func aPageFileIsRead() throws {
        let feature = try #require(PageSpec.feature(from: """
        ---
        id: map.infra
        title: Infrastructure
        phrases: [Infra, cloud]
        ---
        # Infrastructure (Map › Infra)

        Shows how a change ships
        and where it runs.

        Not the summary.

        ## Highlights
        - Reads templates.
        - Select a stage
          to see its steps.

        ## Shows
        - The delivery band.
        """))
        #expect(feature.area == "map" && feature.view == "infra")
        #expect(feature.summary == "Shows how a change ships and where it runs.")
        #expect(feature.details == ["Reads templates.", "Select a stage to see its steps."])
        #expect(feature.phrases == ["infra", "cloud"])
        #expect(feature.sections.map(\.title) == ["Highlights", "Shows"])
        #expect(feature.markdown.hasPrefix("# Infrastructure"))
        #expect(PageSpec.feature(from: "# No front matter") == nil)
    }

    struct VoiceFixture: Decodable {
        struct Case: Decodable {
            var say: String
            var navigate: String?
            var explain: String?
            var overview: Bool?
            var ask: Bool?
            var show: String?
        }
        var projects: [String]
        var cases: [Case]
        var names: [String: String?]
    }

    /// spec/fixtures/voice.yaml, which every build of Dante runs.
    @Test func voiceFixtures() throws {
        let text = try String(contentsOf: Self.repo.appending(path: "spec/fixtures/voice.yaml"), encoding: .utf8)
        let fixture = try YAMLDecoder().decode(VoiceFixture.self, from: text)
        #expect(fixture.cases.count >= 10)
        for item in fixture.cases {
            let expected: VoiceCommand
            if let page = item.navigate { expected = .navigate(page) }
            else if let page = item.explain { expected = .explain(page == "here" ? nil : page) }
            else if item.overview == true { expected = .overview }
            else if let project = item.show { expected = .show(project: project) }
            else { expected = .ask(item.say) }
            #expect(VoiceCommand.parse(item.say, projects: fixture.projects) == expected, "\(item.say)")
        }
        for (said, page) in fixture.names {
            #expect(FeatureGuide.match(said)?.id == page, "\(said)")
        }
    }

    @Test func theAgentsBriefNamesEveryPage() {
        let brief = FeatureGuide.brief
        for feature in FeatureGuide.features { #expect(brief.contains(feature.summary)) }
        #expect(brief.contains("- Map › Infrastructure:"))
        #expect(brief.contains("- Quality › Security:"))
        #expect(FeatureGuide.overview.hasPrefix("Dante has 8 places: Home; Map; Code; Quality, with Tests and Security; Local, with Services, Data and Health;"))
    }
}

/// `dante mcp`'s page tools.
struct PageToolsTests {
    @Test func pagesAreListedAndRead() async throws {
        let list = DelegateServer.pages(nil)
        #expect(list.contains("- map.infra: Map › Infrastructure. The Infra view"))
        let page = DelegateServer.pages("security")
        #expect(page.hasPrefix("Page security, shown as Quality › Security."))
        #expect(page.contains("## Acceptance"))
        // A spoken name works too.
        #expect(DelegateServer.pages("the infrastructure").hasPrefix("Page map.infra"))
        for name in ["local.services", "Local › Services", "map/infra", "Map › Infrastructure", "quality", "environments"] {
            #expect(FeatureGuide.resolve(name) != nil, "\(name)")
        }
        #expect(FeatureGuide.resolve("local.services")?.id == "environments")
        #expect(FeatureGuide.resolve("Map › Infrastructure")?.id == "map.infra")
        #expect(FeatureGuide.resolve("quality")?.id == "tests")
        #expect(DelegateServer.pages("nowhere").hasPrefix("No page nowhere."))
        let names = DelegateServer.pageTools.compactMap { $0["name"]?.string }
        #expect(names == ["dante_pages", "show_page"])
    }
}
