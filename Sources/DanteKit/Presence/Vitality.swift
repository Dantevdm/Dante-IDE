import Foundation

/// How hard Claude is working and how much it has left, for the orb: busy work makes it
/// blaze, a nearly spent usage window makes it tired, and a hit limit puts it to sleep.
public struct Vitality: Equatable, Sendable {
    /// 0 when nothing is running, 1 at full tilt.
    public var intensity: Double
    /// 0 fresh, 1 about to run out.
    public var fatigue: Double
    /// When a usage limit was hit: the orb sleeps until then (or until the next good turn).
    public var exhaustedUntil: Date?

    public init(intensity: Double = 0, fatigue: Double = 0, exhaustedUntil: Date? = nil) {
        self.intensity = intensity
        self.fatigue = fatigue
        self.exhaustedUntil = exhaustedUntil
    }

    public func isExhausted(at now: Date) -> Bool { exhaustedUntil.map { now < $0 } ?? false }

    /// Tiredness from the five-hour window: none until it's past `onset` of the busiest window
    /// seen, then rising to 1 as it reaches it. Without a busiest window there's no measure.
    public static func fatigue(current: Int, busiest: Int?, onset: Double = 0.55) -> Double {
        guard let busiest, busiest > 0 else { return 0 }
        let used = Double(current) / Double(busiest)
        return min(1, max(0, (used - onset) / (1 - onset)))
    }

    /// Whether Claude Code's message says a usage limit was hit, as opposed to another error.
    public static func isLimitMessage(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("usage limit") || lower.contains("limit reached") || lower.contains("hit your limit")
            || lower.contains("rate limit") && lower.contains("claude")
    }
}

/// Tool calls per minute, from how many tool calls the sessions have made so far. Fed the
/// running total at each update; keeps the last minute of starts.
public struct WorkRate: Sendable {
    public static let window: TimeInterval = 60
    /// Calls per minute that count as flat out.
    public static let flatOut = 24.0
    private var starts: [Date] = []
    private var lastTotal: Int?

    public init() {}

    public mutating func record(total: Int, at now: Date) {
        if let lastTotal, total > lastTotal {
            starts.append(contentsOf: Array(repeating: now, count: min(total - lastTotal, 50)))
        }
        lastTotal = total
        starts.removeAll { now.timeIntervalSince($0) > Self.window }
    }

    public func perMinute(at now: Date) -> Double {
        Double(starts.filter { now.timeIntervalSince($0) <= Self.window }.count) * 60 / Self.window
    }

    /// 0…1: the rate against `flatOut`, plus a floor for each thing running right now
    /// (tools and sub-agents), so a long build still reads as work.
    public func intensity(at now: Date, running: Int) -> Double {
        min(1, perMinute(at: now) / Self.flatOut + Double(running) * 0.2)
    }
}

extension OrbStyle {
    /// The mood's style pushed by the work and worn down by fatigue.
    public func adjusted(for vitality: Vitality) -> OrbStyle {
        var style = self
        let i = vitality.intensity, f = vitality.fatigue
        // Work makes it blaze.
        style.energy = min(1.3, energy * (0.75 + 0.55 * i))
        style.pulseRate = pulseRate * (0.85 + 0.6 * i)
        style.aura = min(1.2, aura * (0.7 + 0.6 * i))
        style.lightning = min(1.2, lightning * (0.5 + 0.9 * i))
        style.ring = min(1, ring * (0.8 + 0.4 * i))
        // Fatigue wears it down.
        style.energy *= 1 - 0.6 * f
        style.pulseRate *= 1 - 0.5 * f
        style.glow *= 1 - 0.45 * f
        style.aura *= 1 - 0.55 * f
        style.lightning *= 1 - 0.75 * f
        style.drowse = max(drowse, 0.5 * f)
        return style
    }
}
