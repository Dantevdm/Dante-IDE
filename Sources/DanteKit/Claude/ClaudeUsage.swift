import CryptoKit
import Foundation

/// How much Claude has been used lately, worked out from Claude Code's own transcripts on
/// this Mac (every project, not just this one). Plans count usage in five-hour windows that
/// start with the first message after the last window ended; this finds the current one
/// and when it resets. It's an estimate: the exact allowance isn't published, and usage
/// from other machines or claude.ai doesn't appear here.
public struct ClaudeUsage: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var date: Date
        public var usage: TokenUsage
        public var model: String
    }

    public struct Window: Equatable, Sendable {
        public var start: Date
        public var resets: Date
        public var usage: TokenUsage
        public var messages: Int
    }

    /// The five-hour window running now, if any message fell in one.
    public var current: Window?
    /// The last seven days.
    public var week: TokenUsage
    public var weekMessages: Int
    /// The busiest earlier window this week, for a sense of scale.
    public var busiestWindow: TokenUsage?

    public static let windowLength: TimeInterval = 5 * 3600

    public init(current: Window?, week: TokenUsage, weekMessages: Int, busiestWindow: TokenUsage?) {
        self.current = current
        self.week = week
        self.weekMessages = weekMessages
        self.busiestWindow = busiestWindow
    }

    /// Reads transcripts changed in the last week from `~/.claude/projects`, and remote
    /// projects' copies from their hosts (the same account's limits).
    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = .now, remote: [URL]? = nil) -> ClaudeUsage {
        let since = now.addingTimeInterval(-7 * 86_400)
        let projects = home.appending(path: ".claude/projects")
        var entries: [Entry] = []
        let folders = ((try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [])
            + (remote ?? RemoteProject.transcriptFolders())
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified >= since,
                      let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                entries += self.entries(fromTranscript: text).filter { $0.date >= since }
            }
        }
        return summarise(entries, now: now)
    }

    /// Each model call once: Claude Code writes a line per content block, all carrying the
    /// same message id and usage.
    public static func entries(fromTranscript text: String) -> [Entry] {
        let assistant = Array(#""type":"assistant""#.utf8), usageKey = Array(#""usage":{"#.utf8)
        var seen: Set<String> = []
        var entries: [Entry] = []
        // Byte-level, since a long session's transcript is hundreds of megabytes: only the
        // `usage` object is parsed.
        TranscriptScan.lines(text) { line in
            guard TranscriptScan.has(line, usageKey), TranscriptScan.has(line, assistant),
                  TranscriptScan.topLevelType(line) == "assistant",
                  let stamp = TranscriptScan.string("timestamp", in: line), let date = TranscriptScan.date(stamp),
                  let usage = TranscriptScan.usage(in: line) else { return }
            let id = TranscriptScan.string("id", in: line, startingWith: "msg_") ?? ""
            let key = id + ":" + (TranscriptScan.string("requestId", in: line) ?? stamp)
            guard seen.insert(key).inserted else { return }
            entries.append(Entry(date: date, usage: usage, model: TranscriptScan.string("model", in: line) ?? ""))
        }
        return entries
    }

    /// Pure: windows from entries, and the one `now` falls in.
    public static func summarise(_ entries: [Entry], now: Date) -> ClaudeUsage {
        let sorted = entries.filter { $0.model != "<synthetic>" }.sorted { $0.date < $1.date }
        var windows: [Window] = []
        for entry in sorted {
            if var last = windows.last, entry.date < last.resets {
                last.usage = last.usage + entry.usage
                last.messages += 1
                windows[windows.count - 1] = last
            } else {
                // A window starts on the hour of its first message.
                let start = Calendar(identifier: .gregorian).dateInterval(of: .hour, for: entry.date)?.start ?? entry.date
                windows.append(Window(start: start, resets: start.addingTimeInterval(windowLength), usage: entry.usage, messages: 1))
            }
        }
        let current = windows.last.flatMap { $0.resets > now ? $0 : nil }
        let earlier = current == nil ? windows : Array(windows.dropLast())
        let week = sorted.reduce(TokenUsage()) { $0 + $1.usage }
        return ClaudeUsage(current: current, week: week, weekMessages: sorted.count,
                           busiestWindow: earlier.map(\.usage).max { $0.weighted < $1.weighted })
    }

    /// "1.2M", "86k", "512".
    public static func short(_ tokens: Int) -> String {
        switch tokens {
        case 1_000_000...: String(format: "%.1fM", Double(tokens) / 1_000_000)
        case 10_000...: "\(tokens / 1000)k"
        case 1000...: String(format: "%.1fk", Double(tokens) / 1000)
        default: "\(tokens)"
        }
    }
}

/// The plan Claude Code is signed in with, from `claude auth status`.
public struct ClaudeAccount: Equatable, Sendable {
    public var loggedIn: Bool
    /// "pro", "max", "team", "enterprise", or nil when it's an API key.
    public var plan: String?
    public var method: String?
    /// A fingerprint of the address and organisation, so a different sign-in is noticed
    /// without keeping either.
    public var identity: String?

    public init(loggedIn: Bool, plan: String?, method: String?, identity: String? = nil) {
        self.loggedIn = loggedIn
        self.plan = plan
        self.method = method
        self.identity = identity
    }

    /// Only the plan, the sign-in method and a fingerprint are kept, never the address or organisation.
    public static func parse(_ output: String) -> ClaudeAccount? {
        guard let json = JSONValue(line: output.trimmingCharacters(in: .whitespacesAndNewlines)), json["loggedIn"] != nil else { return nil }
        let who = [json["email"]?.string, json["orgId"]?.string].compactMap { $0 }
        let identity = who.isEmpty ? nil
            : SHA256.hash(data: Data(who.joined(separator: "\n").utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return ClaudeAccount(loggedIn: json["loggedIn"]?.bool ?? false, plan: json["subscriptionType"]?.string,
                             method: json["authMethod"]?.string, identity: identity)
    }

    public var planName: String {
        guard loggedIn else { return "Not signed in" }
        guard let plan else { return method == "claude.ai" ? "Claude plan" : "API key" }
        return switch plan {
        case "pro": "Pro plan"
        case "max": "Max plan"
        case "team": "Team plan"
        case "enterprise": "Enterprise plan"
        default: plan.capitalized + " plan"
        }
    }

    public static func load(executable: String) async -> ClaudeAccount? {
        let output = await Shell.run([executable, "auth", "status"], in: FileManager.default.homeDirectoryForCurrentUser)
        return parse(output.stdout)
    }
}
