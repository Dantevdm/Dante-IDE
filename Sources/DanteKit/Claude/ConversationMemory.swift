import Foundation

/// The conversation each project had open, per Mac, so reopening the project (after a quit,
/// a restart or a crash) continues it instead of starting a stranger: the transcript comes
/// back and the next message resumes the same Claude Code session or Codex thread.
public struct ConversationMemory: Codable, Equatable, Sendable {
    public var id: String
    public var engine: AgentEngine
    public var savedAt: Date

    public init(id: String, engine: AgentEngine, savedAt: Date = Date()) {
        self.id = id
        self.engine = engine
        self.savedAt = savedAt
    }

    /// Older than this, a reopened project starts fresh; the conversation is still in Earlier.
    public static let keepsFor: TimeInterval = 7 * 24 * 3600

    public func isFresh(now: Date = Date()) -> Bool { now.timeIntervalSince(savedAt) < Self.keepsFor }

    static func key(for root: URL) -> String { "conversation:" + root.standardizedFileURL.path }

    public static func load(for root: URL, defaults: UserDefaults = .standard) -> ConversationMemory? {
        guard let data = defaults.data(forKey: key(for: root)) else { return nil }
        return try? JSONDecoder().decode(ConversationMemory.self, from: data)
    }

    public static func save(_ memory: ConversationMemory, for root: URL, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(memory) { defaults.set(data, forKey: key(for: root)) }
    }

    public static func forget(for root: URL, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: root))
    }

    /// Whether a transcript stops mid-turn: the last thing in it is the person's message or a
    /// step, not the agent's reply. After a crash that means it was still working.
    public static func stoppedMidTurn(_ items: [TranscriptItem]) -> Bool {
        guard let last = items.last(where: { if case .notice = $0.content { return false }; return true }) else { return false }
        if case .assistant = last.content { return false }
        return true
    }
}

/// Whether the last run of Dante ended without quitting: set on launch, cleared on quit.
public enum CleanExit {
    static let key = "dante.running"

    /// Call once at launch: true when the previous run never reached `quitting()`.
    public static func launching(defaults: UserDefaults = .standard) -> Bool {
        let crashed = defaults.bool(forKey: key)
        defaults.set(true, forKey: key)
        return crashed
    }

    public static func quitting(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: key)
    }
}
