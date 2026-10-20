import Foundation

/// Checks a scene's code for what breaks frame-accurate rendering or the brand, before a
/// render shows it: timers and animation loops, wall-clock time, CSS transitions and keyframes
/// (they run on their own clock, so rendered frames come out empty or early), loading from the
/// network, and colours written in by hand instead of the brand's tokens. These fail silently,
/// which is why they're checked rather than left to the frames.
public enum MotionLint {
    public struct Finding: Equatable, Sendable, Hashable {
        public enum Kind: String, Sendable {
            case timer, wallClock, cssAnimation, network, rawColor, noScene
        }

        public var kind: Kind
        public var file: String
        public var line: Int
        public var text: String

        public var message: String {
            switch kind {
            case .timer: "\(file):\(line): \(text) runs on its own clock; derive it from seek(t)."
            case .wallClock: "\(file):\(line): \(text) reads the wall clock; use t from seek(t)."
            case .cssAnimation: "\(file):\(line): \(text) animates outside seek(t), so renders miss it; set the style from t instead."
            case .network: "\(file):\(line): loads \(text) from the network; put it beside the scene."
            case .rawColor: "\(file):\(line): \(text) isn't a brand colour; use var(--brand-…) or dante.brand.colors."
            case .noScene: "\(file): never calls dante.scene({ setup, seek })."
            }
        }

        /// Whether it breaks renders (the rest are taste).
        public var breaksRender: Bool { kind != .rawColor }
    }

    /// Lints the scene's files: `files` maps names (index.html, scene.js…) to their text.
    public static func check(_ files: [String: String], brand: BrandKit) -> [Finding] {
        var findings: [Finding] = []
        let allowed = Set(brand.colors.all.map { $0.1.lowercased() } + ["#000000", "#ffffff", "#000", "#fff"])
        var callsScene = false
        for (name, text) in files.sorted(by: { $0.key < $1.key }) {
            if text.contains("dante.scene(") { callsScene = true }
            var inStyle = !name.lowercased().hasSuffix(".js")
            var inScript = name.lowercased().hasSuffix(".js")
            for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(raw)
                let lower = line.lowercased()
                let number = index + 1
                if name.hasSuffix(".html") {
                    if lower.contains("<script") { inScript = true; inStyle = false }
                    if lower.contains("</script") { inScript = false }
                    if lower.contains("<style") { inStyle = true }
                    if lower.contains("</style") { inStyle = false }
                }
                let code = stripComments(line)
                if inScript {
                    for (pattern, label) in timerPatterns where code.contains(pattern) {
                        findings.append(Finding(kind: .timer, file: name, line: number, text: label))
                    }
                    for pattern in ["Date.now(", "new Date(", "performance.now(", "document.timeline"] where code.contains(pattern) {
                        findings.append(Finding(kind: .wallClock, file: name, line: number, text: pattern.replacingOccurrences(of: "(", with: "()")))
                    }
                    if code.contains(".animate(") && !code.contains("dante.") {
                        findings.append(Finding(kind: .cssAnimation, file: name, line: number, text: "element.animate()"))
                    }
                }
                if inStyle || code.contains("style") {
                    if let match = code.firstMatch(of: /(?:^|[\s;{"'])(transition|animation)\s*:\s*(?!none)/) {
                        findings.append(Finding(kind: .cssAnimation, file: name, line: number, text: "CSS \(match.1)"))
                    }
                    if code.contains("@keyframes") { findings.append(Finding(kind: .cssAnimation, file: name, line: number, text: "@keyframes")) }
                }
                for match in code.matches(of: /(?:src|href|import|from|url\(|fetch\()\s*=?\s*["'(]?\s*(https?:\/\/[^"')\s]+)/) {
                    findings.append(Finding(kind: .network, file: name, line: number, text: String(match.1)))
                }
                for match in code.matches(of: /#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{3}\b/) {
                    let color = String(match.0).lowercased()
                    let full = BrandKit.cssColor(color) ?? color
                    if !allowed.contains(color), !allowed.contains(full), !code.contains("--brand-") {
                        findings.append(Finding(kind: .rawColor, file: name, line: number, text: color))
                    }
                }
            }
        }
        if !callsScene, !files.isEmpty { findings.insert(Finding(kind: .noScene, file: files.keys.contains("index.html") ? "index.html" : files.keys.sorted()[0], line: 0, text: ""), at: 0) }
        // One finding per kind and line.
        var seen: Set<String> = []
        return findings.filter { seen.insert("\($0.kind)|\($0.file)|\($0.line)|\($0.text)").inserted }
    }

    static let timerPatterns: [(String, String)] = [
        ("setTimeout(", "setTimeout"), ("setInterval(", "setInterval"), ("requestAnimationFrame(", "requestAnimationFrame"),
        ("new THREE.Clock", "THREE.Clock"), ("clock.getElapsedTime", "clock.getElapsedTime()"), ("clock.getDelta", "clock.getDelta()"),
        ("gsap.ticker", "gsap.ticker"), ("setAnimationLoop(", "renderer.setAnimationLoop"),
    ]

    /// The line without `//` comments (outside strings, roughly) and `/* */` on one line.
    static func stripComments(_ line: String) -> String {
        var text = line.replacing(/\/\*.*?\*\//, with: "")
        if let range = text.range(of: "//"), !text[..<range.lowerBound].hasSuffix(":") {
            text = String(text[..<range.lowerBound])
        }
        return text
    }

    /// Reads the scene's text files (HTML, JS, CSS) from its folder, skipping renders.
    public static func sceneFiles(in folder: URL) -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return [:] }
        var files: [String: String] = [:]
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(folder.path.count + 1))
            // Only folders are skipped: skipDescendants on a file skips the rest of its folder.
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if ["renders", "lib", "node_modules"].contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard ["html", "js", "mjs", "css"].contains(url.pathExtension.lowercased()), !relative.hasSuffix(".min.js"),
                  let text = try? String(contentsOf: url, encoding: .utf8), text.count < 600_000 else { continue }
            files[relative] = text
        }
        return files
    }
}
