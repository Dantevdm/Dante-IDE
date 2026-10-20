import CryptoKit
import Foundation

/// `motion_frames`: the agent asks to see frames of a piece it's making. Dante's MCP server
/// can't draw a scene (WebKit lives in the app), so the app, seeing the call go by, renders
/// the frames into the piece's `renders/frames/` and writes `result.json`; the server waits
/// for the result with this request's key and answers with the PNG paths to read.
public enum MotionFrames {
    public struct Result: Codable, Equatable, Sendable {
        public var key: String
        /// Project-relative PNG paths, in the order asked.
        public var files: [String]
        public var errors: [String]
        /// All the frames in one image, with their times: the quickest way to review them.
        public var contactSheet: String?
        /// Dante's lint of the scene's code.
        public var lint: [String]?

        public init(key: String, files: [String], errors: [String], contactSheet: String? = nil, lint: [String]? = nil) {
            self.key = key
            self.files = files
            self.errors = errors
            self.contactSheet = contactSheet
            self.lint = lint
        }
    }

    /// At most this many frames a call.
    public static let limit = 12
    /// The width frames are rendered at: enough to read type, small enough to look at quickly.
    public static let width = 1280

    /// The piece's folder from the tool's input, project-relative and safe; nil when it isn't one.
    public static func folder(_ input: String?) -> String? {
        guard var path = input?.trimmingCharacters(in: .whitespaces), !path.isEmpty, let safe = MotionRuntime.safe(path) else { return nil }
        path = safe
        if MotionPiece.isManifest(path) || path.hasSuffix(".html") { path = (path as NSString).deletingLastPathComponent }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// The times asked for, in order, without repeats, at most `limit`.
    public static func times(_ values: [Double]) -> [Double] {
        var seen: Set<Int> = []
        return values.filter { $0.isFinite && $0 >= 0 }
            .map { ($0 * 1000).rounded() / 1000 }
            .filter { seen.insert(Int($0 * 1000)).inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// The same for the server and the app.
    public static func key(folder: String, times: [Double]) -> String {
        let text = folder + "|" + times.map { String(format: "%.3f", $0) }.joined(separator: ",")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    public static func framesFolder(_ folder: String) -> String { folder + "/renders/frames" }
    public static func resultPath(_ folder: String) -> String { framesFolder(folder) + "/result.json" }

    /// Waits for the app's result (up to `timeout`), then answers in words for the agent.
    public static func await(root: URL, folder: String, times: [Double], timeout: Double = 150) async -> (text: String, isError: Bool) {
        let key = key(folder: folder, times: times)
        let url = root.appending(path: resultPath(folder))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url), let result = try? JSONDecoder().decode(Result.self, from: data), result.key == key {
                return answer(result, times: times)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return ("Dante didn't render the frames in time. Is the piece open in Dante's Docs, and does \(folder)/index.html call dante.scene()?", true)
    }

    static func answer(_ result: Result, times: [Double]) -> (text: String, isError: Bool) {
        var lines: [String] = []
        if result.files.isEmpty {
            lines.append("No frames could be drawn.")
        } else {
            lines.append("Rendered \(result.files.count) frame\(result.files.count == 1 ? "" : "s") at \(width) px wide. Read each image and check it: type clipped or overlapping, unreadable contrast, empty or broken frames, anything off-brand.")
            if let sheet = result.contactSheet { lines.append("Contact sheet (every frame with its time, read this first): \(sheet)") }
            for (index, file) in result.files.enumerated() {
                let time = index < times.count ? String(format: "%.2f s", times[index]) : ""
                lines.append("- \(time): \(file)")
            }
        }
        if let lint = result.lint, !lint.isEmpty {
            lines.append("Dante's lint of the scene (fix these; the timing ones break renders silently):\n" + lint.prefix(12).map { "- " + $0 }.joined(separator: "\n"))
        }
        if !result.errors.isEmpty {
            lines.append("Script errors:\n" + result.errors.prefix(8).map { "- " + $0 }.joined(separator: "\n"))
        }
        return (lines.joined(separator: "\n"), result.files.isEmpty)
    }
}
