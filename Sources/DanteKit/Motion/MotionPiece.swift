import Foundation
import Yams

/// A piece of motion design in the repo: a folder (`docs/motion/<slug>/`) holding
/// `motion.yaml` (this), the scene the agent writes (`index.html`, drawn by its own code for
/// any moment in time) and the project data it shows. Dante plays it, presents it on the
/// Stage, and renders it frame by frame into an MP4 with the narration mixed in.
public struct MotionPiece: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        /// A film: plays straight through.
        case video
        /// Slides that hold at each `stops` time until the presenter moves on.
        case deck
        /// A short loop or explainer for a doc.
        case explainer

        public var id: Self { self }
        public var title: String {
            switch self {
            case .video: "Video"
            case .deck: "Slide deck"
            case .explainer: "Animated explainer"
            }
        }
    }

    /// A line of narration, spoken from `at` seconds.
    public struct Line: Equatable, Sendable, Hashable {
        public var at: Double
        public var text: String

        public init(at: Double, text: String) {
            self.at = at
            self.text = text
        }
    }

    public var title: String
    public var kind: Kind
    /// Seconds.
    public var duration: Double
    public var fps: Int
    /// The design size in CSS pixels; renders scale it (4K is 2×).
    public var width: Int
    public var height: Int
    /// The page that draws it, relative to the folder.
    public var scene: String
    /// For a deck: where each slide holds, in seconds.
    public var stops: [Double]
    public var narration: [Line]
    /// What it's for and who it's for, in the author's words: the brief it was made from.
    public var brief: String
    /// The project data it shows: "system", "infra", "stats" (written to `data.json`).
    public var data: [String]
    /// The agent that made it ("Claude", "Codex"), so two versions can be told apart.
    public var maker = ""

    public init(title: String, kind: Kind = .video, duration: Double = 30, fps: Int = 60, width: Int = 1920, height: Int = 1080,
                scene: String = "index.html", stops: [Double] = [], narration: [Line] = [], brief: String = "", data: [String] = []) {
        self.title = title
        self.kind = kind
        self.duration = duration
        self.fps = fps
        self.width = width
        self.height = height
        self.scene = scene
        self.stops = stops
        self.narration = narration
        self.brief = brief
        self.data = data
    }

    public static let manifestName = "motion.yaml"
    /// Where new pieces go.
    public static let folder = "docs/motion"

    /// Whether a project path is a piece's manifest.
    /// Whether `path` is the manifest of another agent's version of a piece in `paths`:
    /// `launch-codex/motion.yaml` beside `launch/motion.yaml`.
    public static func isOtherVersion(_ path: String, among paths: Set<String>) -> Bool {
        guard isManifest(path) else { return false }
        let folder = (path as NSString).deletingLastPathComponent
        for suffix in ["-claude", "-codex"] where folder.hasSuffix(suffix) {
            if paths.contains(String(folder.dropLast(suffix.count)) + "/" + manifestName) { return true }
        }
        return false
    }

    public static func isManifest(_ path: String) -> Bool {
        (path as NSString).lastPathComponent == manifestName
    }

    /// Read leniently: missing or odd values fall back to the defaults, `duration` may be
    /// "1:30" or "90s", narration lines may be `- 2.5: text` or `{at, text}`.
    public static func parse(_ text: String, fallbackTitle: String = "Untitled") -> MotionPiece {
        let meta = ((try? Yams.load(yaml: text)) as? [String: Any]) ?? [:]
        var piece = MotionPiece(title: (meta["title"] as? String)?.nonEmptyTrimmed ?? fallbackTitle)
        if let kind = (meta["kind"] as? String).flatMap({ Kind(rawValue: $0.lowercased()) }) { piece.kind = kind }
        if let duration = seconds(meta["duration"]), duration > 0 { piece.duration = min(duration, 3600) }
        if let fps = meta["fps"] as? Int, [24, 25, 30, 48, 50, 60].contains(fps) { piece.fps = fps }
        if let size = meta["size"] as? String {
            let parts = size.lowercased().split(separator: "x").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2, parts.allSatisfy({ (320...7680).contains($0) }) { (piece.width, piece.height) = (parts[0], parts[1]) }
        }
        if let width = meta["width"] as? Int, (320...7680).contains(width) { piece.width = width }
        if let height = meta["height"] as? Int, (320...7680).contains(height) { piece.height = height }
        if let scene = (meta["scene"] as? String)?.nonEmptyTrimmed, !scene.contains(".."), !scene.hasPrefix("/") { piece.scene = scene }
        piece.stops = ((meta["stops"] as? [Any]) ?? []).compactMap(seconds).filter { $0 >= 0 && $0 <= piece.duration }.sorted()
        piece.brief = (meta["brief"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        piece.data = ((meta["data"] as? [Any]) ?? []).compactMap { ($0 as? String)?.lowercased() }
        piece.maker = (meta["maker"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        piece.narration = ((meta["narration"] as? [Any]) ?? []).compactMap { entry -> Line? in
            if let object = entry as? [String: Any] {
                if let text = (object["text"] as? String)?.nonEmptyTrimmed, let at = seconds(object["at"]) { return Line(at: at, text: text) }
                // `- 2.5: text`
                if object.count == 1, let (key, value) = object.first, let text = (value as? String)?.nonEmptyTrimmed, let at = seconds(key) {
                    return Line(at: at, text: text)
                }
                if object.count == 1, let (key, value) = object.first as? (Double, Any), let text = (value as? String)?.nonEmptyTrimmed {
                    return Line(at: key, text: text)
                }
            }
            return nil
        }
        .sorted { $0.at < $1.at }
        return piece
    }

    /// Seconds from 12, 12.5, "12", "12s", "1:30" or "1:02.5".
    static func seconds(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: return number
        case let number as Int: return Double(number)
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.contains(":") {
                let parts = trimmed.split(separator: ":").map { Double($0) }
                guard parts.count == 2, let minutes = parts[0], let seconds = parts[1] else { return nil }
                return minutes * 60 + seconds
            }
            return Double(trimmed.hasSuffix("s") ? String(trimmed.dropLast()) : trimmed)
        default: return nil
        }
    }

    /// The manifest as YAML, comments included, for a new piece.
    public var yaml: String {
        var lines = [
            "# A motion piece: Dante plays index.html, presents it on the Stage and renders it to MP4.",
            "title: \(Self.quoted(title))",
            "kind: \(kind.rawValue)          # video, deck or explainer",
            "duration: \(Self.format(duration))        # seconds",
            "fps: \(fps)",
            "size: \(width)x\(height)       # design size; 4K renders at 2x",
            "scene: \(scene)",
        ]
        if !maker.isEmpty { lines.append("maker: \(maker)        # who made this version") }
        if !data.isEmpty { lines.append("data: [\(data.joined(separator: ", "))]   # project data in data.json") }
        if !stops.isEmpty { lines.append("stops: [\(stops.map(Self.format).joined(separator: ", "))]   # where each slide holds") }
        if !brief.isEmpty {
            lines.append("brief: |")
            lines += brief.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }
        }
        if narration.isEmpty {
            lines.append("narration: []   # - {at: 1.5, text: \"Spoken in Dante's voice from 1.5 s\"}")
        } else {
            lines.append("narration:")
            lines += narration.map { "  - {at: \(Self.format($0.at)), text: \(Self.quoted($0.text))}" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func format(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.2f", seconds).replacing(/0+$/, with: "")
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ") + "\""
    }

    /// A folder name for a title: "Anatomy of the API" → "anatomy-of-the-api".
    public static func slug(_ title: String) -> String {
        let words = title.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let slug = words.prefix(6).joined(separator: "-")
        return slug.isEmpty ? "piece" : slug
    }

    /// Where a new piece with this title goes: `docs/motion/<slug>`, numbered if taken.
    public static func newFolder(for title: String, existing: Set<String>) -> String {
        let base = "\(folder)/\(slug(title))"
        var candidate = base
        var number = 2
        while existing.contains(where: { $0 == candidate || $0.hasPrefix(candidate + "/") }) {
            candidate = "\(base)-\(number)"
            number += 1
        }
        return candidate
    }

    // MARK: Timing

    /// The time of each frame to render.
    public var frameTimes: [Double] {
        let count = max(1, Int((duration * Double(fps)).rounded()))
        return (0..<count).map { Double($0) / Double(fps) }
    }

    /// The narration line being spoken at `time`, given how long each one runs.
    public func line(at time: Double, lengths: [Double]) -> Line? {
        for (index, line) in narration.enumerated().reversed() where line.at <= time {
            let length = index < lengths.count ? lengths[index] : 4
            return time < line.at + length ? line : nil
        }
        return nil
    }

    /// Lines that start before the one before them has finished, with the overlap in seconds.
    public func overlaps(lengths: [Double]) -> [(line: Line, by: Double)] {
        zip(narration, narration.dropFirst()).enumerated().compactMap { index, pair in
            guard index < lengths.count else { return nil }
            let end = pair.0.at + lengths[index]
            return end > pair.1.at + 0.05 ? (pair.1, end - pair.1.at) : nil
        }
    }

    /// For a deck: the stop after `time`, or the end.
    public func nextStop(after time: Double) -> Double {
        stops.first { $0 > time + 0.01 } ?? duration
    }

    /// For a deck: the stop before `time`, or the start.
    public func previousStop(before time: Double) -> Double {
        stops.last { $0 < time - 0.01 } ?? 0
    }
}

