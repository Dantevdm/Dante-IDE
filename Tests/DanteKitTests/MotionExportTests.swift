import Foundation
import Testing
@testable import DanteKit

@Suite("Motion export, critique and handouts")
struct MotionExportTests {
    @Test func specifiersResolveToKeys() {
        #expect(MotionExport.resolve("three", from: "piece:index.html") == "lib:three/three.module.js")
        #expect(MotionExport.resolve("three/addons/postprocessing/EffectComposer.js", from: "piece:index.html") == "lib:three/addons/postprocessing/EffectComposer.js")
        #expect(MotionExport.resolve("../shaders/CopyShader.js", from: "lib:three/addons/postprocessing/Pass.js") == "lib:three/addons/shaders/CopyShader.js")
        #expect(MotionExport.resolve("./scene.js", from: "piece:index.html") == "piece:scene.js")
        #expect(MotionExport.resolve("art/logo.svg?v=2", from: "piece:js/scene.js") == "piece:js/art/logo.svg")
        #expect(MotionExport.resolve("/_dante/project/assets/logo.png", from: "piece:index.html") == "project:assets/logo.png")
        #expect(MotionExport.resolve("_dante/fonts/Geist.ttf", from: "piece:index.html") == "fonts:Geist.ttf")
        #expect(MotionExport.resolve("/textures/sky.hdr", from: "piece:js/scene.js") == "piece:textures/sky.hdr")
        #expect(MotionExport.resolve("https://cdn.example.com/x.js", from: "piece:index.html") == nil)
        #expect(MotionExport.resolve("../../secrets.png", from: "piece:index.html") == nil)
        #expect(MotionExport.resolve("data:image/png;base64,AAAA", from: "piece:index.html") == nil)
    }

    @Test func importsAreFoundOutsideComments() {
        let code = """
        /**
         * import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
         */
        import * as THREE from "three";
        import { a as b,
          c } from './c.js';
        // import x from "nope.js";
        export * from './d.js';
        import './side.js';
        const later = () => import("./lazy.js");
        export const name = 'not-an-import.js';
        """
        #expect(MotionExport.imports(in: code).map(\.specifier) == ["three", "./c.js", "./d.js", "./side.js", "./lazy.js"])
    }

    @Test func aPageCarriesItsModulesInOrder() throws {
        let files: [String: String] = [
            "piece:scene.js": "import * as THREE from \"three\";\nimport { glow } from './glow.js';\nexport const scene = 1;",
            "piece:glow.js": "import * as THREE from 'three';\nexport const glow = 'logo.svg';",
            "piece:logo.svg": "<svg/>",
            "lib:three/three.module.js": "import { A } from './three.core.js';\nexport * from './three.core.js';",
            "lib:three/three.core.js": "export const A = 1;",
            "fonts:Geist.ttf": "font",
        ]
        let html = """
        <!doctype html><html><head><script type="importmap">{"imports":{}}</script><link rel="stylesheet" href="look.css"></head>
        <body><img src="logo.svg"><script type="module" src="./scene.js"></script>
        <script type="module">import "./glow.js"; dante.scene({ seek() {} });</script></body></html>
        """
        let result = MotionExport.page(scene: "index.html", html: html, runtime: "window.dante = {}; // </script> inside", fonts: ["Geist.ttf"]) { key in
            files[key].map { Data($0.utf8) }
        }
        #expect(result.cycle == nil)
        #expect(result.missing == ["look.css"])
        #expect(!result.html.contains("importmap"))
        #expect(!result.html.contains("type=\"module\""))
        #expect(result.html.contains("<\\/script> inside"))
        #expect(result.html.contains("src=\"data:image/svg+xml;base64,"))
        #expect(result.html.contains("font/ttf;base64,"))
        // The modules, each after what it imports, with placeholders for their imports.
        let json = try #require(result.html.firstMatch(of: /id="dante-modules">(.*?)<\/script>/)?.1)
        let sources = try #require(try JSONSerialization.jsonObject(with: Data(String(json).replacingOccurrences(of: "<\\/", with: "</").utf8)) as? [String])
        #expect(sources.count == 5)
        #expect(sources[0] == "export const A = 1;")
        #expect(sources[1].contains("from '__DANTE_MODULE_0__'"))
        #expect(sources.contains { $0.contains("export const glow = 'data:image/svg+xml;base64,") })
        #expect(result.html.contains("for (const entry of [3, 4])"))
    }

    @Test func aCircleIsReported() {
        let files = ["piece:a.js": "import './b.js';", "piece:b.js": "import './a.js';"]
        let result = MotionExport.page(scene: "index.html", html: "<html><body><script type=\"module\" src=\"a.js\"></script></body></html>", runtime: "") {
            files[$0].map { Data($0.utf8) }
        }
        #expect(result.cycle == ["a.js", "b.js", "a.js"])
    }

    @Test func critiquesAreRead() {
        let reply = """
        **Strong opening, but the middle drags.** The type is on brand.

        - [fix] 0:12 — The title clips at the right edge; shrink it to 88px.
        - [polish] 1:02.5 - Hold the map a beat longer.
        * [good] 4s: The logo build.
        - [keep] The palette.
        - The ending cuts abruptly.
        """
        let critique = MotionCritique.parse(reply, critic: "Codex")
        #expect(critique.summary == "Strong opening, but the middle drags. The type is on brand.")
        #expect(critique.notes == [
            .init(kind: .fix, time: 12, text: "The title clips at the right edge; shrink it to 88px."),
            .init(kind: .polish, time: 62.5, text: "Hold the map a beat longer."),
            .init(kind: .good, time: 4, text: "The logo build."),
            .init(kind: .good, text: "The palette."),
            .init(kind: .polish, text: "The ending cuts abruptly."),
        ])
        #expect(MotionCritique.request(Array(critique.notes.prefix(1)), critic: "Codex").hasSuffix("- [fix] 0:12 — The title clips at the right edge; shrink it to 88px."))
    }

    @Test func critiqueTimesCoverThePiece() {
        let piece = MotionPiece(title: "d", kind: .deck, duration: 30, stops: [6, 6.2, 12, 18, 24])
        #expect(MotionCritique.times(for: piece) == [0.4, 6, 12, 15, 18, 24, 29.95])
        let long = MotionPiece(title: "l", duration: 120, narration: (0..<30).map { .init(at: Double($0) * 4, text: "x") })
        #expect(MotionCritique.times(for: long).count == 12)
    }

    @Test func handoutsAreSlidesOrAStoryboard() {
        let deck = MotionPiece(title: "d", kind: .deck, duration: 18, stops: [6, 12],
                               narration: [.init(at: 0.5, text: "One"), .init(at: 6, text: "Two"), .init(at: 13, text: "Three")])
        #expect(deck.handoutPages(lengths: []) == [.init(time: 6, notes: ["One"]), .init(time: 12, notes: ["Two"]), .init(time: 18, notes: ["Three"])])
        let film = MotionPiece(title: "f", duration: 10, narration: [.init(at: 1, text: "Hello there")])
        #expect(film.handoutPages(lengths: [2]) == [.init(time: 2, notes: ["Hello there"])])
        #expect(MotionPiece(title: "q", duration: 8).handoutPages(lengths: []).map(\.time) == [0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5])
    }

    @Test func otherVersionsAreNotListedBesideTheirPiece() {
        let paths: Set<String> = ["docs/motion/tour/motion.yaml", "docs/motion/tour-codex/motion.yaml", "docs/motion/solo-codex/motion.yaml"]
        #expect(MotionPiece.isOtherVersion("docs/motion/tour-codex/motion.yaml", among: paths))
        #expect(!MotionPiece.isOtherVersion("docs/motion/solo-codex/motion.yaml", among: paths))
        #expect(DocLibrary(paths: Array(paths)).groups.first { $0.title == "Motion" }?.docs.count == 2)
        #expect(!DocLibrary.isDoc("docs/motion/tour/renders/critique/contact-sheet.png") && !DocLibrary.isDoc("docs/motion/tour/renders/tour.pdf"))
        #expect(MotionRuntime.isText("index.HTML") && !MotionRuntime.isText("logo.png"))
    }

    @Test func codexAttachesImagesLast() {
        let arguments = Codex.arguments(project: "/home/me/shop", model: nil, images: ["/home/me/shop/sheet.png"])
        #expect(arguments.suffix(3) == ["-", "--image", "/home/me/shop/sheet.png"])
        #expect(Codex.arguments(project: "/home/me/shop", model: nil).last == "-")
    }
}
