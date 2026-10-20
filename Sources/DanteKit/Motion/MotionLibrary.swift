import Foundation

/// The libraries bundled with Dante for motion scenes (Resources/MotionLib in the app), served
/// under `_dante/lib/` and named by an import map Dante adds to the scene's page, so a scene
/// writes `import * as THREE from "three"` and nothing comes from the network. GSAP isn't
/// here: its licence rules out tools that make animations, and scenes draw from `seek(t)` anyway.
public struct MotionLibrary: Sendable, Equatable {
    public let name: String
    public let version: String
    public let licence: String
    /// What a scene imports, and the file (or folder, ending in /) it maps to under `_dante/lib/`.
    public let imports: [(specifier: String, path: String)]
    /// One line for the agent's brief: what it's for and how to use it within the contract.
    public let use: String

    public static func == (a: MotionLibrary, b: MotionLibrary) -> Bool { a.name == b.name && a.version == b.version }

    public static let path = "_dante/lib/"

    public static let all: [MotionLibrary] = [
        MotionLibrary(name: "three.js", version: "0.186.1", licence: "MIT",
                      imports: [("three", "three/three.module.js"), ("three/addons/", "three/addons/")],
                      use: "`import * as THREE from \"three\"`; addons from \"three/addons/…\" (postprocessing with UnrealBloomPass, shaders, geometries, lines, environments, objects, curves, math, utils, and loaders/GLTFLoader, FontLoader, SVGLoader, HDRLoader, OBJLoader). Render with renderer.render inside seek(t); never setAnimationLoop or THREE.Clock."),
        MotionLibrary(name: "hairline", version: "0.3.0", licence: "MIT",
                      imports: [("@lucasmarkes/hairline", "hairline/index.js")],
                      use: "`import { terrain, branches, cabinet, … } from \"@lucasmarkes/hairline\"`: 27 isometric line figures (riffle, terrain, exploded, phosphor, slow, turntable, keyboard, elevator, phone, laptop, terminal, cabinet, branches, vault, lockers, padlock, patch, dish, router, loupe, sieve, rail, plug, query, drawer, basket, plot), each `figure(element, { intensity, theme })` at 5:4, coloured by --hairline-plate/-hi/-edge/-mid/-lo. They answer the pointer on their own clock, which Dante steps frame by frame in renders: move them by dispatching pointermove events at positions computed from t in seek(t)."),
        MotionLibrary(name: "DiceBear Open Peeps", version: "core 9.4.3, open-peeps 9.4.2", licence: "MIT code, CC0 drawings",
                      imports: [("@dicebear/core", "dicebear/core/index.js"), ("@dicebear/open-peeps", "dicebear/open-peeps/index.js")],
                      use: "`import { createAvatar } from \"@dicebear/core\"; import * as openPeeps from \"@dicebear/open-peeps\"`, then `createAvatar(openPeeps, { seed, size }).toString()` gives hand-drawn people as SVG for stories with people in them (the same seed gives the same person)."),
    ]

    /// The import map every scene page gets.
    public static var importMap: String {
        let entries = all.flatMap(\.imports).map { "\"\($0.specifier)\": \"/\(path)\($0.path)\"" }
        return "<script type=\"importmap\">{\"imports\": {\(entries.joined(separator: ", "))}}</script>"
    }

    /// The page with the import map added at the top of its head, unless it brings its own.
    public static func addingImportMap(to html: String) -> String {
        if html.range(of: "type=\"importmap\"", options: .caseInsensitive) != nil
            || html.range(of: "type='importmap'", options: .caseInsensitive) != nil { return html }
        for tag in ["<head", "<html"] {
            if let open = html.range(of: tag, options: .caseInsensitive),
               let close = html.range(of: ">", range: open.upperBound..<html.endIndex) {
                return html.replacingCharacters(in: close.upperBound..<close.upperBound, with: "\n" + importMap)
            }
        }
        return importMap + "\n" + html
    }

    /// Its line in the scene contract.
    public var briefLine: String { "  - \(name) \(version): \(use)" }
}
