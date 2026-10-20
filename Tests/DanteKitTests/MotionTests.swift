import Foundation
import Testing
@testable import DanteKit

@Suite("Motion pieces")
struct MotionPieceTests {
    @Test func aManifestIsReadLeniently() {
        let piece = MotionPiece.parse("""
        title: Anatomy of the shop
        kind: Deck
        duration: "1:30"
        fps: 30
        size: 1280x720
        stops: [6, "12s", 200]
        data: [System, stats]
        brief: |
          For new engineers.
        narration:
          - {at: 1.5, text: "Every order starts here."}
          - 8: Then the API takes over.
          - {at: oops, text: "skipped"}
        """)
        #expect(piece.title == "Anatomy of the shop")
        #expect(piece.kind == .deck)
        #expect(piece.duration == 90)
        #expect(piece.fps == 30)
        #expect(piece.width == 1280 && piece.height == 720)
        #expect(piece.stops == [6, 12])
        #expect(piece.data == ["system", "stats"])
        #expect(piece.brief == "For new engineers.")
        #expect(piece.narration == [.init(at: 1.5, text: "Every order starts here."), .init(at: 8, text: "Then the API takes over.")])
    }

    @Test func oddValuesFallBackToDefaults() {
        let piece = MotionPiece.parse("fps: 7\nsize: huge\nscene: ../../secrets.html\nduration: -3", fallbackTitle: "spin")
        #expect(piece.title == "spin")
        #expect(piece.fps == 60)
        #expect(piece.width == 1920)
        #expect(piece.scene == "index.html")
        #expect(piece.duration == 30)
        #expect(MotionPiece.parse("not: [yaml").title == "Untitled")
    }

    @Test func theManifestRoundTrips() {
        var piece = MotionPiece(title: "Ship \"it\"", kind: .deck, duration: 42.5, brief: "Two lines\nof brief", data: ["system"])
        piece.stops = [6, 12.25]
        piece.narration = [.init(at: 0.5, text: "Hello: world")]
        #expect(MotionPiece.parse(piece.yaml) == piece)
    }

    @Test func foldersAreNamedFromTheTitle() {
        #expect(MotionPiece.slug("Anatomy of the API — v2!") == "anatomy-of-the-api-v2")
        #expect(MotionPiece.slug("???") == "piece")
        let taken: Set<String> = ["docs/motion/launch/motion.yaml", "docs/motion/launch-2/index.html"]
        #expect(MotionPiece.newFolder(for: "Launch", existing: taken) == "docs/motion/launch-3")
        #expect(MotionPiece.newFolder(for: "Pitch", existing: taken) == "docs/motion/pitch")
    }

    @Test func timing() {
        let piece = MotionPiece(title: "t", kind: .deck, duration: 2, fps: 30, stops: [0.5, 1.5],
                                narration: [.init(at: 0, text: "one"), .init(at: 1, text: "two")])
        #expect(piece.frameTimes.count == 60)
        #expect(piece.frameTimes[30] == 1)
        #expect(piece.line(at: 0.5, lengths: [0.8, 0.5])?.text == "one")
        #expect(piece.line(at: 0.9, lengths: [0.8, 0.5]) == nil)
        #expect(piece.line(at: 1.2, lengths: [0.8, 0.5])?.text == "two")
        #expect(piece.overlaps(lengths: [1.4, 0.5]).first?.by ?? 0 > 0.39)
        #expect(piece.overlaps(lengths: [0.8, 0.5]).isEmpty)
        #expect(piece.nextStop(after: 0.5) == 1.5)
        #expect(piece.nextStop(after: 1.6) == 2)
        #expect(piece.previousStop(before: 1.5) == 0.5)
        #expect(piece.previousStop(before: 0.4) == 0)
    }

    @Test func piecesAreDocs() {
        let library = DocLibrary(paths: ["README.md", "docs/motion/launch/motion.yaml", "docs/motion/launch/index.html", "motion.yaml", "docs/guide.md"])
        let motion = library.groups.first { $0.title == "Motion" }
        #expect(motion?.docs.map(\.path) == ["docs/motion/launch/motion.yaml"])
        #expect(motion?.docs.first?.kind == .motion)
        #expect(motion?.docs.first?.title == "Launch")
        #expect(library.groups.map(\.title).prefix(2) == ["Project", "Motion"])
        #expect(!library.all.contains { $0.path == "motion.yaml" })
    }
}

@Suite("Brand kit")
struct BrandKitTests {
    @Test func aSavedKitIsRead() {
        let kit = BrandKit.parse("""
        name: Shop
        colors:
          background: "#000"
          primary: rgb(37, 99, 235)
          text: not-a-colour
        fonts:
          heading: Fraunces
        logo: docs/brand/logo.svg
        motion: {pace: Lively, ease: power3.out}
        3d: {bloom: false}
        voice: {tone: Warm and direct., narrator: bf_emma}
        """, name: "fallback")
        #expect(kit.isSaved)
        #expect(kit.name == "Shop")
        #expect(kit.colors.background == "#000000")
        #expect(kit.colors.accent == "#2563eb")
        #expect(kit.colors.text == BrandKit.Colors().text)
        #expect(kit.display == "Fraunces" && kit.body == "Geist")
        #expect(kit.logo == "docs/brand/logo.svg")
        #expect(kit.pace == .lively && kit.ease == "power3.out")
        #expect(!kit.bloom && kit.grain)
        #expect(kit.tone == "Warm and direct." && kit.voice == "bf_emma")
        #expect(BrandKit.parse(kit.yaml, name: "x") == kit)
    }

    @Test func aKitIsGuessedFromTheProject() {
        let files = ["web/src/styles/app.css", "web/tailwind.config.ts", "web/public/logo.svg", "web/node_modules/x/logo.svg", "web/src/assets/logo-big.png"]
        let texts = [
            "web/src/styles/app.css": ":root {\n  --background: #ffffff;\n  --accent: #ff5a1f;\n}\nbody { font-family: 'Inter', sans-serif; }",
            "web/tailwind.config.ts": "export default { theme: { extend: { colors: { primary: { DEFAULT: '#2563eb', 50: '#eff6ff' }, secondary: '#14b8a6' } } } }",
        ]
        let kit = BrandKit.detect(name: "shop", files: files) { texts[$0] }
        #expect(!kit.isSaved)
        #expect(kit.colors.accent == "#ff5a1f")
        #expect(kit.colors.accent2 == "#14b8a6")
        // A light site still gets a dark stage.
        #expect(kit.colors.background == BrandKit.Colors().background)
        #expect(kit.display == "Inter")
        #expect(kit.logo == "web/public/logo.svg")
    }

    @Test func colours() {
        #expect(BrandKit.cssColor("#ABC") == "#aabbcc")
        #expect(BrandKit.cssColor("#11223344") == "#112233")
        #expect(BrandKit.cssColor("rgba(255, 0, 10, .5)") == "#ff000a")
        #expect(BrandKit.cssColor("red") == nil)
        #expect(BrandKit.luminance("#ffffff") > 0.99)
        #expect(BrandKit.luminance("#000000") < 0.01)
        #expect(BrandKit().css.contains("--brand-accent: #7c8cff;"))
    }
}

private extension BrandKit {
    init() { self.init(name: "t") }
}

@Suite("Motion runtime")
struct MotionRuntimeTests {
    @Test func pathsStayInTheirFolder() {
        #expect(MotionRuntime.safe("/index.html") == "index.html")
        #expect(MotionRuntime.safe("/scenes/a%20b.js") == "scenes/a b.js")
        #expect(MotionRuntime.safe("/../secret") == nil)
        #expect(MotionRuntime.safe("/a/%2E%2E/b") == nil)
        #expect(MotionRuntime.mimeType(for: "x.glb") == "model/gltf-binary")
    }

    @Test func theScriptCarriesThePiece() {
        let piece = MotionPiece(title: "Launch", duration: 12, narration: [.init(at: 1, text: "Hi")])
        let script = MotionRuntime.script(piece: piece, brand: BrandKit(name: "Shop"), data: ["system": ["lanes": []]], mode: .render, pixelRatio: 2)
        #expect(script.contains("\"mode\":\"render\""))
        #expect(script.contains("\"duration\":12"))
        #expect(script.contains("\"pixelRatio\":2"))
        #expect(script.contains("window.dante = dante"))
        #expect(script.contains("Geist.ttf"))
        let exported = MotionRuntime.script(piece: piece, brand: BrandKit(name: "Shop"), data: nil, mode: .browser, pixelRatio: 1)
        #expect(!exported.contains("Geist.ttf"))
    }

    @Test func theStarterFollowsTheContract() {
        let html = MotionStarter.html(title: "A <b> & c")
        #expect(html.contains("dante.scene({"))
        #expect(html.contains("A &lt;b&gt; &amp; c"))
        #expect(!html.contains("requestAnimationFrame"))
    }
}

@Suite("Motion frames and briefs")
struct MotionFramesTests {
    @Test func requests() {
        #expect(MotionFrames.folder("docs/motion/a/motion.yaml") == "docs/motion/a")
        #expect(MotionFrames.folder("docs/motion/a/") == "docs/motion/a")
        #expect(MotionFrames.folder("../etc") == nil)
        #expect(MotionFrames.times([3, 1.0004, 1, -2, .nan] + Array(repeating: 9, count: 20)) == [3, 1, 9])
        #expect(MotionFrames.key(folder: "a", times: [1, 2]) == MotionFrames.key(folder: "a", times: [1, 2.0]))
        #expect(MotionFrames.key(folder: "a", times: [1, 2]) != MotionFrames.key(folder: "a", times: [2, 1]))
    }

    @Test func theServerWaitsForTheApp() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "motion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = "docs/motion/a"
        try FileManager.default.createDirectory(at: root.appending(path: MotionFrames.framesFolder(folder)), withIntermediateDirectories: true)
        // A stale result for other times is ignored.
        try JSONEncoder().encode(MotionFrames.Result(key: "old", files: ["x.png"], errors: [])).write(to: root.appending(path: MotionFrames.resultPath(folder)))
        let waiting = Task { await MotionFrames.await(root: root, folder: folder, times: [1, 2], timeout: 5) }
        try await Task.sleep(for: .milliseconds(400))
        let result = MotionFrames.Result(key: MotionFrames.key(folder: folder, times: [1, 2]), files: ["\(folder)/renders/frames/a.png"], errors: ["index.html:3: boom"])
        try JSONEncoder().encode(result).write(to: root.appending(path: MotionFrames.resultPath(folder)))
        let answer = await waiting.value
        #expect(!answer.isError)
        #expect(answer.text.contains("1.00 s: docs/motion/a/renders/frames/a.png"))
        #expect(answer.text.contains("boom"))
    }

    @Test func theBriefCarriesTheContractAndTheData() {
        let map = SystemMap(parts: [.init(id: "client:web", name: "web", lane: .clients, kind: .web), .init(id: "api:/orders", name: "/orders", lane: .api, kind: .routes)],
                            links: [.init(from: "client:web", to: "api:/orders")])
        let data = MotionData.json(project: "shop", system: map, infra: nil, stats: ["files": 12])
        let piece = MotionPiece(title: "Anatomy", kind: .deck, duration: 60, stops: [6])
        let brief = MotionBrief.create(ask: "show how an order travels", folder: "docs/motion/anatomy", piece: piece, brand: BrandKit(name: "Shop"), data: data, libraries: [])
        #expect(brief.contains("dante.scene({"))
        #expect(brief.contains("motion_frames"))
        #expect(brief.contains("storyboard.md"))
        #expect(brief.contains("Clients (1): web"))
        #expect(brief.contains("dante.data.stats: files 12"))
        #expect(brief.contains("holds at its stop"))
        #expect(MotionData.describe([:]).contains("null"))
    }
}

@Suite("Motion libraries")
struct MotionLibraryTests {
    @Test func importMapGoesAtTheTopOfTheHead() {
        let page = MotionLibrary.addingImportMap(to: "<!doctype html>\n<HTML lang=\"en\"><Head><title>x</title></head><body></body></html>")
        #expect(page.contains("<Head>\n<script type=\"importmap\">"))
        #expect(page.contains("\"three\": \"/_dante/lib/three/three.module.js\""))
        #expect(page.contains("\"three/addons/\": \"/_dante/lib/three/addons/\""))
        #expect(page.contains("\"@dicebear/open-peeps\": \"/_dante/lib/dicebear/open-peeps/index.js\""))
        #expect(MotionLibrary.addingImportMap(to: "<html><body></body></html>").hasPrefix("<html>\n<script type=\"importmap\">"))
        #expect(MotionLibrary.addingImportMap(to: "<p>bare</p>").hasPrefix("<script type=\"importmap\">"))
    }

    @Test func aPageWithItsOwnMapKeepsIt() {
        let own = "<head><script type=\"importmap\">{\"imports\":{}}</script></head>"
        #expect(MotionLibrary.addingImportMap(to: own) == own)
    }

    @Test func everyImportIsBundledWithItsLicence() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/DanteApp/Resources/MotionLib")
        for library in MotionLibrary.all {
            for entry in library.imports {
                #expect(FileManager.default.fileExists(atPath: folder.appending(path: entry.path).path), "\(entry.specifier)")
                let licenceFolder = folder.appending(path: entry.path.hasSuffix("/") ? entry.path : (entry.path as NSString).deletingLastPathComponent)
                let top = entry.specifier.hasPrefix("three") ? folder.appending(path: "three") : licenceFolder
                #expect(FileManager.default.fileExists(atPath: top.appending(path: "LICENSE").path), "\(entry.specifier)")
            }
        }
    }

    @Test func theContractNamesThemAndRulesOutOtherClocks() {
        let piece = MotionPiece(title: "Demo")
        let brief = MotionBrief.create(ask: "a demo", folder: "docs/motion/demo", piece: piece, brand: BrandKit.load(name: "shop", files: [], read: { _ in nil }),
                                       data: nil, libraries: MotionLibrary.all.map(\.briefLine))
        #expect(brief.contains("import * as THREE from \"three\""))
        #expect(brief.contains("there's no GSAP"))
        #expect(brief.contains("dispatching pointermove"))
        #expect(MotionRuntime.script(piece: piece, brand: BrandKit.load(name: "shop", files: [], read: { _ in nil }), data: nil, mode: .render, pixelRatio: 1).contains("stepClock(t); await draw(t)"))
    }
}

@Suite("Motion looks")
struct MotionLooksTests {
    @Test func picksBecomeRecipesInTheBrief() {
        #expect(MotionLooks.recipes(for: [:]) == nil)
        let answers: [String: MotionQuestions.Answer] = ["look": .init(picked: ["Isometric", "Clay 3D"]), "kit": .init(picked: ["Hairline figures"])]
        let recipes = MotionLooks.recipes(for: answers) ?? ""
        #expect(recipes.contains("one leads and the other accents it"))
        #expect(recipes.contains("- Isometric: An orthographic three.js camera"))
        #expect(recipes.contains("- Hairline figures:"))
        let brief = MotionBrief.create(ask: "a demo", folder: "docs/motion/demo", piece: MotionPiece(title: "Demo"),
                                       brand: BrandKit.load(name: "shop", files: [], read: { _ in nil }), data: nil, libraries: [], answers: answers)
        #expect(brief.contains("## Look recipes"))
        #expect(brief.contains("- Animation style: Isometric; Clay 3D"))
    }

    @Test func thereAreTwentyStylesAndTheQuestionsOfferThem() {
        #expect(MotionLooks.styles.count == 20)
        #expect(Set(MotionLooks.styles.map(\.id)).count == 20)
        let look = MotionQuestions.all.first { $0.id == "look" }
        #expect(look?.options.count == 20)
        #expect(look?.multiple == true)
        #expect(MotionQuestions.all.first { $0.id == "kit" }?.options == MotionLooks.kits.map(\.name))
    }

    @Test func everyLookHasATileInTheGallery() throws {
        let page = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/DanteApp/Resources/MotionLib/gallery/looks.html")
        let html = try String(contentsOf: page, encoding: .utf8)
        for style in MotionLooks.styles { #expect(html.contains("data-kind=\"style\" data-id=\"\(style.id)\""), "\(style.id)") }
        for kit in MotionLooks.kits { #expect(html.contains("data-kind=\"kit\" data-id=\"\(kit.id)\""), "\(kit.id)") }
    }
}
