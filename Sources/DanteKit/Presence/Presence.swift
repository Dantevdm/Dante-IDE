import Foundation

/// How Claude is, across every open window: what the menu bar orb shows.
public enum PresenceMood: String, Sendable, CaseIterable {
    /// No Claude session anywhere.
    case asleep
    /// A session is open and waiting for a message.
    case idle
    /// A turn is running and no tool is.
    case thinking
    /// A tool is running: reading, editing, running a command.
    case acting
    /// An edit, command or question is waiting for you.
    case needsYou
    /// A turn just finished (shown for a moment by `PresenceTracker`).
    case done
    /// Claude Code can't start or stopped with an error.
    case trouble
    /// Hearing you speak (set by the voice controller, not by sessions).
    case listening

    public var title: String {
        switch self {
        case .asleep: "Asleep"
        case .idle: "Ready"
        case .thinking: "Thinking"
        case .acting: "Working"
        case .needsYou: "Waiting for you"
        case .done: "Done"
        case .trouble: "Something’s wrong"
        case .listening: "Listening"
        }
    }
}

/// One window's Claude session, as the orb sees it.
public struct PresenceSource: Sendable, Equatable, Identifiable {
    public enum Claude: Sendable, Equatable {
        case off
        case idle
        case working
        case unavailable(String)
    }

    public var id: String
    public var project: String
    public var claude: Claude
    /// Edits, commands and questions waiting for an answer.
    public var waiting: Int
    /// The tool running now, as the panel words it ("Edit SystemMap.swift").
    public var running: String?
    /// The last thing Claude did or asked.
    public var last: String?

    public init(id: String, project: String, claude: Claude, waiting: Int = 0, running: String? = nil, last: String? = nil) {
        self.id = id
        self.project = project
        self.claude = claude
        self.waiting = waiting
        self.running = running
        self.last = last
    }

    public var mood: PresenceMood {
        if waiting > 0 { return .needsYou }
        switch claude {
        case .off: return .asleep
        case .idle: return .idle
        case .working: return running == nil ? .thinking : .acting
        case .unavailable: return .trouble
        }
    }

    /// One line for this window: what it's doing or waiting on.
    public var status: String {
        switch mood {
        case .needsYou: return waiting == 1 ? (last ?? "1 thing waiting") : "\(waiting) things waiting"
        case .acting: return running ?? "Working"
        case .thinking: return "Thinking"
        case .trouble: if case .unavailable(let reason) = claude { return reason }; return "Stopped"
        case .idle: return last.map { "Last: \($0)" } ?? "Ready"
        case .asleep, .done, .listening: return "Claude not started"
        }
    }
}

/// Every window's sessions combined into the one mood the orb shows. The most urgent wins:
/// something waiting for you, then work in progress, then trouble, then rest.
public struct Presence: Sendable, Equatable {
    public var mood: PresenceMood
    public var line: String
    public var sources: [PresenceSource]

    public init(mood: PresenceMood, line: String, sources: [PresenceSource]) {
        self.mood = mood
        self.line = line
        self.sources = sources
    }

    static let priority: [PresenceMood] = [.needsYou, .acting, .thinking, .trouble, .idle, .asleep]

    public static func combine(_ sources: [PresenceSource]) -> Presence {
        guard !sources.isEmpty else { return Presence(mood: .asleep, line: "No project open", sources: []) }
        let mood = priority.first { mood in sources.contains { $0.mood == mood } } ?? .asleep
        let matching = sources.filter { $0.mood == mood }
        let line: String
        switch mood {
        case .needsYou:
            let total = matching.reduce(0) { $0 + $1.waiting }
            if matching.count == 1, total == 1 {
                line = "\(matching[0].project): \(matching[0].last ?? "an answer")"
            } else {
                line = "\(total) things waiting in \(names(matching))"
            }
        case .acting, .thinking, .trouble:
            line = matching.count == 1 ? "\(matching[0].project): \(matching[0].status)" : "\(names(matching))"
        case .idle:
            line = sources.count == 1 ? sources[0].project : "\(sources.count) projects open"
        case .asleep, .done, .listening:
            line = sources.count == 1 ? sources[0].project : "\(sources.count) projects open"
        }
        return Presence(mood: mood, line: line, sources: sources)
    }

    private static func names(_ sources: [PresenceSource]) -> String {
        let names = sources.map(\.project)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }
}

/// Shows `done` for a moment after a turn ends, so finishing reads as an event rather than
/// just going quiet.
public struct PresenceTracker: Sendable {
    public static let doneDuration: TimeInterval = 3
    private var previous: PresenceMood?
    private var doneUntil: Date?

    public init() {}

    /// The mood to show now, and when to ask again (when a `done` runs out).
    public mutating func mood(for presence: Presence, at now: Date) -> (mood: PresenceMood, recheck: Date?) {
        let mood = presence.mood
        defer { previous = mood }
        if mood == .idle, previous == .thinking || previous == .acting {
            doneUntil = now.addingTimeInterval(Self.doneDuration)
        }
        if mood != .idle { doneUntil = nil }
        if let until = doneUntil, now < until { return (.done, until) }
        doneUntil = nil
        return (mood, nil)
    }
}

/// How the orb looks in each mood: four colours its plasma cycles through, and how lively it is.
/// The renderer eases between styles, so a change of mood reads as a power-up: the colours
/// shift, the aura flares and, when it's working, lightning crackles through it.
public struct OrbStyle: Sendable, Equatable {
    public var colors: [RGBA]
    /// Swirl speed and turbulence, 0…1.
    public var energy: Double
    /// Pulses per second, and how deep they go (0…1).
    public var pulseRate: Double
    public var pulseDepth: Double
    /// Strength of the halo, 0…1.
    public var glow: Double
    /// Flicker, for trouble.
    public var flicker: Double
    /// The orbital ring of particles, 0…1.
    public var ring: Double
    /// Flames rising off the orb, 0…1.
    public var aura: Double
    /// Bolts crackling through the aura, 0…1.
    public var lightning: Double
    /// Frames per second the menu bar orb needs to look smooth at this pace.
    public var framesPerSecond: Int
    /// How far the eyelids are down, 0 open to 1 shut: asleep, or tired.
    public var lids: Double = 0

    /// The palettes idle cycles through, one every `formDuration` seconds.
    public static let idleForms: [[RGBA]] = [
        [RGBA(0x6D5DFC), RGBA(0x2E9BFF), RGBA(0x19D3C5), RGBA(0xB44CFF)],
        [RGBA(0xE8EAF6), RGBA(0x9FA8DA), RGBA(0xB3E5FC), RGBA(0x7986CB)],
        [RGBA(0x1DE9B6), RGBA(0x00B8D4), RGBA(0x64FFDA), RGBA(0x2962FF)],
        [RGBA(0xAA00FF), RGBA(0xE040FB), RGBA(0x7C4DFF), RGBA(0xFF4081)],
    ]
    public static let formDuration: Double = 9

    public static func of(_ mood: PresenceMood) -> OrbStyle {
        switch mood {
        case .asleep:
            OrbStyle(colors: [RGBA(0x2B2F6B), RGBA(0x1E3A5F), RGBA(0x3B2A6B), RGBA(0x24406E)],
                     energy: 0.05, pulseRate: 0.1, pulseDepth: 0.3, glow: 0.25, flicker: 0, ring: 0, aura: 0, lightning: 0, framesPerSecond: 15, lids: 1)
        case .idle:
            OrbStyle(colors: idleForms[0],
                     energy: 0.25, pulseRate: 0.18, pulseDepth: 0.5, glow: 0.55, flicker: 0, ring: 0.1, aura: 0.25, lightning: 0, framesPerSecond: 24)
        case .thinking:
            OrbStyle(colors: [RGBA(0x00B0FF), RGBA(0x2979FF), RGBA(0x80D8FF), RGBA(0x7C4DFF)],
                     energy: 0.75, pulseRate: 0.6, pulseDepth: 0.6, glow: 0.85, flicker: 0, ring: 0.6, aura: 0.6, lightning: 0.12, framesPerSecond: 30)
        case .acting:
            OrbStyle(colors: [RGBA(0xFFD600), RGBA(0xFFAB00), RGBA(0xFFF176), RGBA(0xFF6D00)],
                     energy: 1, pulseRate: 1.1, pulseDepth: 0.5, glow: 0.95, flicker: 0, ring: 1, aura: 1, lightning: 1, framesPerSecond: 30)
        case .needsYou:
            OrbStyle(colors: [RGBA(0xFF2E88), RGBA(0xF50057), RGBA(0xFF80AB), RGBA(0xD500F9)],
                     energy: 0.55, pulseRate: 1.4, pulseDepth: 1, glow: 1, flicker: 0, ring: 0.3, aura: 0.8, lightning: 0.3, framesPerSecond: 30)
        case .done:
            OrbStyle(colors: [RGBA(0x39FF88), RGBA(0x00E676), RGBA(0xB2FF59), RGBA(0x1DE9B6)],
                     energy: 0.5, pulseRate: 0.8, pulseDepth: 0.7, glow: 0.9, flicker: 0, ring: 0.5, aura: 0.7, lightning: 0.2, framesPerSecond: 30)
        case .listening:
            OrbStyle(colors: [RGBA(0xE0F7FA), RGBA(0x4DD0E1), RGBA(0xFFFFFF), RGBA(0x18FFFF)],
                     energy: 0.45, pulseRate: 0.5, pulseDepth: 0.4, glow: 1, flicker: 0, ring: 0.8, aura: 0.5, lightning: 0, framesPerSecond: 30)
        case .trouble:
            OrbStyle(colors: [RGBA(0xFF1744), RGBA(0xB0002A), RGBA(0xFF5252), RGBA(0x6A0019)],
                     energy: 0.7, pulseRate: 2, pulseDepth: 0.8, glow: 1, flicker: 0.7, ring: 0, aura: 0.5, lightning: 0.6, framesPerSecond: 30)
        }
    }
}
