import Foundation

/// The looks a piece can be made in: twenty animation styles, each with the way to build it
/// inside the scene contract, and the illustration kits bundled with Dante. The New piece
/// sheet shows them as live tiles (MotionLib/gallery/looks.html, whose tile ids are these
/// ids) and the picked ones become the brief's look recipes.
public enum MotionLooks {
    public struct Style: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        /// What it looks like, for the tile's tooltip.
        public let summary: String
        /// How to build it within the contract.
        public let recipe: String
    }

    public struct Kit: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let summary: String
        public let recipe: String
    }

    public static let styles: [Style] = [
        Style(id: "particles", name: "Particles", summary: "Thousands of points that gather into shapes and words",
              recipe: "three.js Points with a custom shader: every particle's position is a function of t (seeded start, eased target from sampled text or SVG paths, curl-noise drift from dante.noise), additive blending, UnrealBloomPass kept subtle."),
        Style(id: "liquid", name: "Liquid morph", summary: "Soft blobs that melt from one shape into the next",
              recipe: "SVG paths with the same number of points tweened by t (or a metaball shader in WebGL); a goo filter (blur then alpha threshold) where shapes meet; slow, viscous easing with no overshoot."),
        Style(id: "holographic", name: "Holographic", summary: "Iridescent foil, scanlines and a light that sweeps across",
              recipe: "A fragment shader or layered conic gradients whose hue angle follows a view angle computed from t; thin scanlines, a specular sweep, and the brand accent as the dominant hue so it stays on brand."),
        Style(id: "neon", name: "Neon glow", summary: "Tubes of light that flicker on in the dark",
              recipe: "Stroked SVG or canvas paths drawn by dash offset, a stacked glow (two blurred copies at 30% and 60%), one flicker per line at a set time, a dark wet floor reflection; use the accent, not hue shifts."),
        Style(id: "wireframe", name: "Wireframe 3D", summary: "Lit edges of geometry turning in space",
              recipe: "three.js EdgesGeometry or LineSegments2 (fat lines from three/addons/lines) on the real shapes, depth fade with fog, a slow orbit camera from t; one solid hero face can fill in at the payoff."),
        Style(id: "glass", name: "Glassmorphism", summary: "Frosted panes floating over moving colour",
              recipe: "DOM cards with backdrop-filter blur and a 1px light border over large soft brand-colour shapes moving by t; or three.js MeshPhysicalMaterial with transmission for 3D glass. Keep the text on solid ground."),
        Style(id: "kinetic", name: "Kinetic type", summary: "Words that move with the voice",
              recipe: "Type is the visual: split lines into words and letters, each timed to the narration's beats with staggered dante.progress, scale and weight contrast, words that push each other off; no images unless the story needs one."),
        Style(id: "isometric", name: "Isometric", summary: "A tidy little world seen from 30 degrees",
              recipe: "An orthographic three.js camera at the isometric angle (or CSS 3D rotateX(55deg) rotateZ(-45deg)), extruded blocks for the system's parts, light paths along the grid between them; hairline figures fit this look."),
        Style(id: "clay", name: "Clay 3D", summary: "Soft rounded shapes that squash and settle",
              recipe: "three.js RoundedBoxGeometry, capsules and spheres with MeshStandardMaterial roughness 0.6 to 0.8, a big soft key light, a RoomEnvironment for fill, squash and stretch on landings from dante.ease.spring."),
        Style(id: "ascii", name: "ASCII art", summary: "Pictures made of characters",
              recipe: "Render the scene to a small offscreen canvas, read its luminance and draw a monospaced character ramp (Geist Mono) on a 2D canvas each seek(t); characters change with brightness, never at random."),
        Style(id: "mesh", name: "Gradient mesh", summary: "Slow fields of colour that breathe",
              recipe: "A full-screen fragment shader mixing four brand colours at control points that drift by dante.noise(t); grain on top if the brand allows; type sits on it in large weights."),
        Style(id: "comic", name: "Comic book", summary: "Ink lines, halftone and bold panels",
              recipe: "SVG panels with thick ink strokes, halftone dot fills (an SVG pattern or shader), speech-bubble captions, frames that slam in on the beat; flat brand colours, no gradients."),
        Style(id: "splitflap", name: "Split-flap", summary: "A departures board turning letters",
              recipe: "Each character a two-half flap in CSS 3D (rotateX by t), cycling through the alphabet to its target with a staggered start per column; mono type, a dark board, a click in the sound if narrated."),
        Style(id: "vhs", name: "Retro VHS", summary: "Tracking lines, colour bleed and a little wobble",
              recipe: "A post-processing pass: RGB channel offset, scanlines, a tracking band rolling by t, slight horizontal jitter from dante.noise; the content underneath stays clean and readable."),
        Style(id: "halftone", name: "Halftone", summary: "Images built from dots of different sizes",
              recipe: "Sample the picture's luminance on a grid and draw dots sized by it (canvas or shader), the grid rotated 15 to 45 degrees; dots grow in by t to reveal each beat."),
        Style(id: "bauhaus", name: "Bauhaus", summary: "Circles, squares and triangles in primary order",
              recipe: "SVG primitives on a strict grid, flat primaries mapped to the brand's colours, geometric type, shapes that rotate and slide in quarter turns with crisp outQuart eases."),
        Style(id: "pixel", name: "Pixel art", summary: "Chunky pixels and stepped motion",
              recipe: "Draw at a low resolution on a canvas with imageSmoothingEnabled false and scale it up; animate in steps (positions rounded to the pixel grid, 8 to 12 poses a second from t)."),
        Style(id: "blueprint", name: "Blueprint", summary: "White lines drawing themselves on blue",
              recipe: "A blue grid, SVG line work drawn by dash offset in build order, dimension lines and callouts in mono type, a slow pan across the sheet; the brand accent only for the one thing that matters."),
        Style(id: "artdeco", name: "Art deco", summary: "Gold sunbursts, symmetry and fine lines",
              recipe: "Symmetric SVG ornaments, fan and sunburst line patterns, a gold (or the brand's warmest colour) on black, tall condensed type; reveals open from the centre outwards."),
        Style(id: "brutal", name: "Neo-brutalism", summary: "Thick borders, hard shadows, loud blocks",
              recipe: "DOM blocks with 3px black borders and offset hard shadows, bright flat brand fills, big grotesque type, things that drop in and land with a short hard bounce."),
    ]

    public static let kits: [Kit] = [
        Kit(id: "hairline", name: "Hairline figures", summary: "27 isometric line figures: a commit graph, a server rack, a phone in layers…",
            recipe: "Use hairline figures (bundled as \"@lucasmarkes/hairline\") as the illustrations: pick the figures that mean something here (branches for git, cabinet for servers, phone and laptop for clients, vault and padlock for security, terminal, router, plot), theme them with the --hairline-* properties from the brand, and move them by dispatching pointer events from seek(t)."),
        Kit(id: "peeps", name: "Open Peeps", summary: "Hand-drawn people, the same person for the same seed",
            recipe: "Draw people with Open Peeps (bundled as \"@dicebear/core\" and \"@dicebear/open-peeps\"): one seed per character so they stay the same, clothing in the brand's colours, people only where the story has a person in it (a user, an on-call engineer)."),
        Kit(id: "own", name: "Drawn by the agent", summary: "Its own SVG illustrations in the piece's style",
            recipe: "Draw the illustrations yourself as SVG in the chosen style, a small consistent set (line weight, corner radius, palette) used throughout."),
        Kit(id: "none", name: "No illustrations", summary: "Type, shapes and the real diagrams only",
            recipe: "No illustrations: carry it with type, simple shapes and the project's real diagrams."),
    ]

    public static func style(named name: String) -> Style? { styles.first { $0.name == name } }
    public static func kit(named name: String) -> Kit? { kits.first { $0.name == name } }

    /// The brief's look recipes for the picked styles and kits.
    public static func recipes(for answers: [String: MotionQuestions.Answer]) -> String? {
        let styles = (answers["look"]?.picked ?? []).compactMap(style(named:))
        let kits = (answers["kit"]?.picked ?? []).compactMap(kit(named:))
        guard !styles.isEmpty || !kits.isEmpty else { return nil }
        var lines = ["## Look recipes"]
        if styles.count > 1 { lines.append("Two styles were picked: one leads and the other accents it (say which in the storyboard); don't alternate them beat by beat.") }
        lines += styles.map { "- \($0.name): \($0.recipe)" }
        lines += kits.map { "- \($0.name): \($0.recipe)" }
        return lines.joined(separator: "\n")
    }
}
