import Foundation

/// A crash report macOS wrote for Dante (`~/Library/Logs/DiagnosticReports/Dante-*.ips`):
/// a JSON header line, then the report as one JSON object. Only what helps fixing it is kept:
/// the exception, the crashed thread's top frames and whether Dante's own code is among them.
public struct AppCrash: Equatable, Sendable, Identifiable {
    public struct Frame: Equatable, Sendable {
        public var image: String
        public var symbol: String
        public var file: String?
        public var line: Int?
        /// The frame is in Dante's own binary rather than a system library.
        public var isDante: Bool

        public var text: String {
            var text = "\(image)  \(symbol)"
            if let file, let line { text += "  (\((file as NSString).lastPathComponent):\(line))" }
            return text
        }
    }

    public var file: URL
    public var date: Date
    public var version: String
    public var build: String
    public var os: String
    public var exception: String
    /// "Segmentation fault: 11", "Abort trap: 6"…
    public var termination: String
    /// What the runtime said before it stopped (fatalError messages, an assertion).
    public var message: String?
    public var queue: String?
    public var frames: [Frame]

    public var id: URL { file }

    /// The first frame in Dante's own code, which is usually where to start.
    public var danteFrame: Frame? { frames.first(where: \.isDante) }

    /// One line for a list: where it stopped.
    public var headline: String {
        if let frame = danteFrame { return frame.symbol }
        return frames.first.map { "\($0.image): \($0.symbol)" } ?? exception
    }

    /// The report as text to copy or hand to an agent.
    public var summary: String {
        var lines = [
            "Dante \(version) (\(build)) crashed on macOS \(os), \(Self.stamp.string(from: date))",
            "\(exception) — \(termination)",
        ]
        if let message { lines.append("Message: \(message)") }
        if let queue { lines.append("Thread: \(queue)") }
        lines.append("Crashed thread, top frames:")
        lines += frames.map { "  " + $0.text }
        return lines.joined(separator: "\n")
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    // MARK: Reading (pure)

    /// Reads an .ips file's text; nil when it isn't a crash report Dante can read.
    public static func parse(_ text: String, file: URL, frameLimit: Int = 16) -> AppCrash? {
        guard let newline = text.firstIndex(of: "\n"),
              let header = json(text[..<newline]),
              let body = json(text[text.index(after: newline)...]) else { return nil }
        let app = header["app_name"] as? String ?? "Dante"
        let images = body["usedImages"] as? [[String: Any]] ?? []
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = body["faultingThread"] as? Int ?? threads.firstIndex { $0["triggered"] as? Bool == true } ?? 0
        let thread = threads.indices.contains(faulting) ? threads[faulting] : [:]
        let frames = (thread["frames"] as? [[String: Any]] ?? []).prefix(frameLimit).map { frame -> Frame in
            let index = frame["imageIndex"] as? Int ?? -1
            let image = images.indices.contains(index) ? images[index] : [:]
            let name = image["name"] as? String ?? "?"
            return Frame(image: name,
                         symbol: frame["symbol"] as? String ?? "0x" + String(frame["imageOffset"] as? Int ?? 0, radix: 16),
                         file: frame["sourceFile"] as? String,
                         line: frame["sourceLine"] as? Int,
                         isDante: name == app)
        }
        let exception = body["exception"] as? [String: Any] ?? [:]
        let termination = body["termination"] as? [String: Any] ?? [:]
        let os = body["osVersion"] as? [String: Any]
        let messages = (body["asi"] as? [String: [String]])?.values.flatMap { $0 } ?? []
        return AppCrash(
            file: file,
            date: date(header["timestamp"] as? String) ?? date(body["captureTime"] as? String) ?? .distantPast,
            version: header["app_version"] as? String ?? "?",
            build: header["build_version"] as? String ?? "",
            os: [os?["train"] as? String, (os?["build"] as? String).map { "(\($0))" }].compactMap { $0 }.joined(separator: " "),
            exception: [exception["type"] as? String, exception["signal"] as? String].compactMap { $0 }.joined(separator: " "),
            termination: termination["indicator"] as? String ?? "",
            message: messages.first.map { String($0.prefix(400)) },
            queue: thread["queue"] as? String,
            frames: Array(frames))
    }

    private static func json(_ text: Substring) -> [String: Any]? {
        guard let data = String(text).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// "2026-11-03 13:37:17.00 +0200"
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss.SSSS Z", "yyyy-MM-dd HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    // MARK: Finding them

    public static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports")
    }

    /// Dante's reports, newest first: the folder and the Retired folder macOS moves old ones to.
    public static func list(in folder: URL = folder, bundleID: String = Bundle.main.bundleIdentifier ?? "dev.dante.ide",
                            limit: Int = 20) -> [AppCrash] {
        let folders = [folder, folder.appending(path: "Retired")]
        let files = folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "ips" && $0.lastPathComponent.hasPrefix("Dante") }
        }
        return files.compactMap { file -> AppCrash? in
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  text.prefix(2000).contains("\"bundleID\":\"\(bundleID)\"") else { return nil }
            return parse(text, file: file)
        }
        .sorted { $0.date > $1.date }
        .prefix(limit)
        .map { $0 }
    }
}
