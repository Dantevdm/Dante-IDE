import Foundation
import Security

/// A job handed to Dante from outside, by `dante job "…"`: what to do, in which project, and
/// whether it may go ahead without asking. Sent as a `dante://job` URL.
public struct JobRequest: Equatable, Sendable {
    /// The project folder, absolute.
    public var folder: String
    public var brief: String
    /// Away mode for this many minutes; nil asks as the window's approval level says.
    public var awayMinutes: Int?
    /// "claude" or "codex"; nil for the one in charge by default.
    public var agent: String?
    /// A job type's id (`.dante/jobs/<id>.md` or a built-in one).
    public var kind: String?
    /// The local key (`JobRequest.localKey`), which proves the request came from the `dante`
    /// command on this Mac rather than a link in a web page or another app.
    public var key: String?

    public init(folder: String, brief: String, awayMinutes: Int? = nil, agent: String? = nil, kind: String? = nil, key: String? = nil) {
        self.folder = folder
        self.brief = brief
        self.awayMinutes = awayMinutes
        self.agent = agent
        self.kind = kind
        self.key = key
    }

    /// Whether the request carries this Mac's key.
    public func isTrusted(by localKey: String?) -> Bool {
        guard let key, let localKey, !localKey.isEmpty else { return false }
        return key == localKey
    }

    /// The key shared by the `dante` command and the app: random, in a file only this user
    /// can read. Made on first use.
    public static func localKey(in folder: URL = URL.applicationSupportDirectory.appending(path: "Dante", directoryHint: .isDirectory),
                                create: Bool = true) -> String? {
        let url = folder.appending(path: "cli-key")
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.count >= 32 { return key }
        }
        guard create else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let key = bytes.map { String(format: "%02x", $0) }.joined()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600]) else { return nil }
        } catch {
            return nil
        }
        return key
    }

    /// `dante://job?path=/a&brief=…&away=30&agent=codex`.
    public var url: URL {
        var components = URLComponents()
        components.scheme = OpenRequest.scheme
        components.host = "job"
        var query = [URLQueryItem(name: "path", value: folder), URLQueryItem(name: "brief", value: brief)]
        if let awayMinutes { query.append(URLQueryItem(name: "away", value: String(awayMinutes))) }
        if let agent { query.append(URLQueryItem(name: "agent", value: agent)) }
        if let kind { query.append(URLQueryItem(name: "type", value: kind)) }
        if let key { query.append(URLQueryItem(name: "key", value: key)) }
        components.queryItems = query
        return components.url!
    }

    public init?(url: URL) {
        guard url.scheme == OpenRequest.scheme, url.host == "job",
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        guard let folder = value("path"), folder.hasPrefix("/"),
              let brief = value("brief")?.trimmingCharacters(in: .whitespacesAndNewlines), !brief.isEmpty else { return nil }
        let away = value("away").flatMap(Int.init).flatMap { $0 > 0 ? min($0, 24 * 60) : nil }
        let agent = value("agent").flatMap { ["claude", "codex"].contains($0) ? $0 : nil }
        let kind = value("type").flatMap { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } && !$0.isEmpty ? $0 : nil }
        self.init(folder: folder, brief: brief, awayMinutes: away, agent: agent, kind: kind, key: value("key"))
    }

    /// Reads `dante job <brief…> [--in folder] [--away minutes] [--codex|--claude]`. The
    /// folder defaults to `directory`; words of the brief may be given unquoted.
    public static func parse(arguments: [String], in directory: String, isDirectory: (String) -> Bool) throws -> JobRequest {
        var words: [String] = []
        var folder = directory
        var away: Int?
        var agent: String?
        var kind: String?
        var index = 0
        func next(_ option: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw OpenRequest.ArgumentError(description: "\(option) needs a value. Try dante job --help.") }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--in": folder = OpenRequest.absolute(try next(argument), in: directory)
            case "--away":
                let text = try next(argument)
                guard let minutes = Int(text), minutes > 0 else {
                    throw OpenRequest.ArgumentError(description: "--away takes a number of minutes, such as --away 30.")
                }
                away = minutes
            case "--type": kind = try next(argument).lowercased()
            case "--codex": agent = "codex"
            case "--claude": agent = "claude"
            case "-h", "--help": throw OpenRequest.ArgumentError(description: usage)
            default:
                if argument.hasPrefix("--") { throw OpenRequest.ArgumentError(description: "Unknown option \(argument). Try dante job --help.") }
                words.append(argument)
            }
            index += 1
        }
        let brief = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else { throw OpenRequest.ArgumentError(description: "Say what the job should do: dante job \"Fix the login redirect\"") }
        guard isDirectory(folder) else { throw OpenRequest.ArgumentError(description: "\(folder): no such folder") }
        // From a subfolder, the job is the repository's: its nearest .git or .dante folder.
        folder = OpenTarget.projectRoot(of: folder + "/.")
        return JobRequest(folder: folder, brief: brief, awayMinutes: away, agent: agent, kind: kind)
    }

    public static let usage = """
        Usage: dante job <what to do> [--type name] [--in folder] [--away minutes] [--codex|--claude]

        Hands a job to an agent in Dante: it works on its own branch in its own
        worktree of the project (the current folder unless --in says otherwise),
        while you carry on. Look over its changes and merge it from the Jobs area.

          --type name       a job type from .dante/jobs/ (or builder); for the
                            builder, say which task: dante job DI-12 --type builder
          --in folder       the project to work on
          --away minutes    go ahead without asking for this long, within the
                            project's rules (never pushing, merging or deploying)
          --codex, --claude who does the job (default: the one in charge)
        """
}
