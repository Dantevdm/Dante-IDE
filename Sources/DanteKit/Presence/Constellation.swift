import Foundation

/// A helper working beside Claude, drawn as a small orb circling the big one: a sub-agent
/// (Task/Agent), a job Claude handed to a local model (`mcp__dante__delegate`), or a question
/// for a cloud agent (`decide`, `ask_grok`).
public struct OrbSatellite: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case subagent(String)
        case local(String)
        case cloud(CloudAgent)
        case codex
        case claude
    }

    public var id: String
    public var kind: Kind
    public var color: RGBA
    /// What it's doing, for the panel.
    public var title: String
    /// Who handed the work over ("Claude", "Codex").
    public var lead: String
    /// Who took it: the sub-agent's type, the local model's role, the other agent.
    public var agent: String
    /// What was handed over, in a few words; empty when the call didn't say.
    public var task: String

    public init(id: String, kind: Kind, color: RGBA, title: String, lead: String = "Claude", agent: String? = nil, task: String = "") {
        self.id = id
        self.kind = kind
        self.color = color
        self.title = title
        self.lead = lead
        self.agent = agent ?? title
        self.task = task
    }

    /// One satellite per running sub-agent and delegated job, oldest first. `lead` is the
    /// agent in charge of the conversation the calls are in.
    public static func running(in tools: [ToolActivity], lead: String = "Claude") -> [OrbSatellite] {
        tools.compactMap { tool in
            guard tool.status == .running else { return nil }
            // Every Dante tool says why it's asking; otherwise the question's first sentence.
            let why = tool.input["why"]?.string.flatMap(short)
            let asked = why ?? (tool.input["prompt"]?.string ?? tool.input["question"]?.string).flatMap { AgentJob.gist(of: $0, limit: 90) }.flatMap(short) ?? ""
            switch tool.name {
            case "Task", "Agent":
                let type = tool.input["subagent_type"]?.string ?? "general-purpose"
                let description = tool.input["description"]?.string
                return OrbSatellite(id: tool.id, kind: .subagent(type), color: color(subagent: type),
                                    title: description ?? "Sub-agent", lead: lead, agent: agentName(subagent: type),
                                    task: description.flatMap(short) ?? asked)
            case "mcp__dante__delegate":
                let kind = tool.input["kind"]?.string ?? "draft"
                let agent = DelegateKind(rawValue: kind)?.agent ?? "Local model"
                return OrbSatellite(id: tool.id, kind: .local(kind), color: color(local: kind), title: agent, lead: lead, task: asked)
            case "mcp__dante__look":
                return OrbSatellite(id: tool.id, kind: .local(Looker.kind), color: RGBA(0xFFD740), title: Looker.agent, lead: lead, task: asked)
            case "mcp__dante__ask_grok":
                return OrbSatellite(id: tool.id, kind: .cloud(.grok), color: color(cloud: .grok), title: "Grok", lead: lead, task: asked)
            case "mcp__dante__ask_codex":
                return OrbSatellite(id: tool.id, kind: .codex, color: RGBA(0x8C9EFF), title: "Codex", lead: lead, task: asked)
            case "mcp__dante__ask_claude":
                return OrbSatellite(id: tool.id, kind: .claude, color: RGBA(0xD97757), title: "Claude", lead: lead, task: asked)
            case "mcp__dante__decide":
                return OrbSatellite(id: tool.id, kind: .cloud(.jev), color: color(cloud: .jev), title: "Jev", lead: lead, task: why ?? "a decision")
            default:
                return nil
            }
        }
    }

    /// Made-up agents coming and going on a 30-second loop, for seeing the Stage without
    /// spending a turn (`DANTE_STAGE_DEMO=1`).
    public static func demo(at t: TimeInterval) -> [OrbSatellite] {
        let cycle = t.truncatingRemainder(dividingBy: 30)
        let loop = Int(t / 30)
        let cast: [(start: Double, end: Double, satellite: OrbSatellite)] = [
            (0, 14, OrbSatellite(id: "demo-explore-\(loop)", kind: .subagent("Explore"), color: color(subagent: "explore"),
                                 title: "Find where the parser builds the tree", agent: "Explore", task: "Find where the parser builds the tree")),
            (3, 10, OrbSatellite(id: "demo-summary-\(loop)", kind: .local("summary"), color: color(local: "summary"),
                                 title: "Researcher", task: "Summarise the failing test log")),
            (6, 20, OrbSatellite(id: "demo-codex-\(loop)", kind: .codex, color: RGBA(0x8C9EFF),
                                 title: "Codex", task: "Check the migration can't lock the table")),
            (12, 24, OrbSatellite(id: "demo-look-\(loop)", kind: .local(Looker.kind), color: RGBA(0xFFD740),
                                  title: Looker.agent, task: "Read the error in the screenshot")),
        ]
        return cast.filter { cycle >= $0.start && cycle < $0.end }.map(\.satellite)
    }

    /// "Explore", "Plan", "code-reviewer" → "Code reviewer"; the default type is just a sub-agent.
    static func agentName(subagent type: String) -> String {
        if type == "general-purpose" || type.isEmpty { return "Sub-agent" }
        if let role = TeamRole(agentID: type) { return role.title }
        let words = type.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// One line, at most about 64 characters, cut at a word.
    static func short(_ text: String) -> String? {
        var line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        while line.hasSuffix(".") { line.removeLast() }
        guard !line.isEmpty else { return nil }
        guard line.count > 64 else { return line }
        let cut = line.prefix(64)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-")) + "…"
    }

    /// Sub-agents in cool colours by type; local models in greens, so you can tell at a glance
    /// what's running on this Mac.
    static func color(subagent type: String) -> RGBA {
        switch type.lowercased() {
        case "explore": RGBA(0x40C4FF)
        case "plan": RGBA(0xB388FF)
        case "general-purpose", "claude": RGBA(0xD97757)
        default: [RGBA(0x82B1FF), RGBA(0xEA80FC), RGBA(0xFF8A80), RGBA(0x84FFFF)][stableIndex(type, count: 4)]
        }
    }

    static func color(local kind: String) -> RGBA {
        switch kind {
        case "summary": RGBA(0x1DE9B6)
        case "triage": RGBA(0xC6FF00)
        case "commitMessage": RGBA(0x69F0AE)
        default: RGBA(0x64FFDA)
        }
    }

    /// Cloud agents in their own colours: Grok a cold silver, Jev a hot pink.
    static func color(cloud agent: CloudAgent) -> RGBA {
        switch agent {
        case .grok: RGBA(0xCFD8DC)
        case .jev: RGBA(0xFF4081)
        }
    }

    /// The same small number for the same text on every run (Swift's `hashValue` isn't).
    static func stableIndex(_ text: String, count: Int) -> Int {
        Int(text.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 } % UInt32(count))
    }
}

/// The satellites around the orb over time: each buds off the orb when its work starts,
/// circles it on a tilted orbit (passing behind and in front), and merges back when done.
/// Times are seconds on the caller's clock; distances are in the shader's units, where the
/// orb's radius is `mainRadius`.
public struct Constellation: Sendable {
    public static let limit = 6
    /// How long splitting off and merging back take.
    public static let birth = 1.4
    public static let merge = 1.5

    /// One satellite as the shader draws it this frame.
    public struct Frame: Sendable, Equatable {
        public var x, y, radius: Double
        /// -1 behind the orb … 1 in front of it.
        public var depth: Double
        /// 0 still inside the orb … 1 free of it (the neck between them fades out on the way).
        public var out: Double
        public var color: RGBA
        /// Which satellite this is, for labels drawn beside it.
        public var satellite: OrbSatellite
        /// Its orbit, 0..<limit; kept while it's out, so labels can keep their place.
        public var slot: Int = 0
        /// Done and merging back: its work is flowing home to the lead.
        public var returning = false
    }

    struct Member: Sendable {
        var satellite: OrbSatellite
        var slot: Int
        var born: Double
        var ended: Double?
    }

    private(set) var members: [Member] = []

    public init() {}

    public var isEmpty: Bool { members.isEmpty }

    /// Takes the satellites that should be showing: new ones start splitting off, missing ones
    /// start merging back. A satellite that returns while merging splits off again.
    public mutating func update(_ satellites: [OrbSatellite], at t: Double) {
        let wanted = Set(satellites.map(\.id))
        for index in members.indices where members[index].ended == nil && !wanted.contains(members[index].satellite.id) {
            members[index].ended = t
        }
        for satellite in satellites {
            if let index = members.firstIndex(where: { $0.satellite.id == satellite.id }) {
                members[index].satellite = satellite
                if members[index].ended != nil {
                    members[index].ended = nil
                    members[index].born = t - Self.birth * 0.5
                }
                continue
            }
            let taken = Set(members.map(\.slot))
            guard let slot = (0..<Self.limit).first(where: { !taken.contains($0) }) else { break }
            members.append(Member(satellite: satellite, slot: slot, born: t, ended: nil))
        }
    }

    /// Where each satellite is at `t`, and how many finished merging since the last call
    /// (the orb gives a little pulse for each). Merged satellites are dropped.
    public mutating func frames(at t: Double, mainRadius: Double, satelliteRadius: Double) -> (frames: [Frame], merged: Int) {
        let before = members.count
        members.removeAll { member in member.ended.map { t - $0 >= Self.merge } ?? false }
        let merged = before - members.count
        let frames = members.map { member in
            Self.frame(of: member, at: t, mainRadius: mainRadius, satelliteRadius: satelliteRadius)
        }
        return (frames, merged)
    }

    /// How far out a member is: rising with a little overshoot as it splits, falling as it merges.
    static func out(born: Double, ended: Double?, at t: Double) -> Double {
        if let ended {
            let p = min(1, max(0, (t - ended) / merge))
            let start = min(1, max(0, (ended - born) / birth))
            return start * (1 - p * p)
        }
        let p = min(1, max(0, (t - born) / birth))
        return p
    }

    static func frame(of member: Member, at t: Double, mainRadius: Double, satelliteRadius: Double) -> Frame {
        let slot = Double(member.slot)
        // Each slot has its own orbit: tilted towards the viewer, turned a little, at its own pace.
        // Alternate slots circle the other way, so neighbours bud off on opposite sides.
        let period = 9 + slot * 1.7
        let direction: Double = member.slot % 2 == 0 ? 1 : -1
        let tilt = 1.15 + 0.12 * sin(slot * 1.3)
        let turn = -0.35 + 0.7 * (slot.truncatingRemainder(dividingBy: 3) / 2)
        // It comes free at the front of its orbit, nearest you, and carries on round.
        let spin = 2 * .pi / period
        let theta = -.pi / 2 + direction * spin * (t - member.born - birth * 0.8)

        let out = out(born: member.born, ended: member.ended, at: t)
        let free = ease(out)
        let orbit = mainRadius * (1.48 + 0.05 * slot.truncatingRemainder(dividingBy: 2))

        // A point on the tilted ring, seen from a little above: the far half sits higher and behind.
        let ringX = cos(theta) * orbit, ringY = sin(theta) * cos(tilt) * orbit
        let orbitX = ringX * cos(turn) - ringY * sin(turn)
        let orbitY = ringX * sin(turn) + ringY * cos(turn)
        let orbitDepth = -sin(theta)
        // While budding it sits in the orb's surface on our side, so the split is seen.
        let length = max(0.0001, (orbitX * orbitX + orbitY * orbitY).squareRoot())
        let budX = orbitX / length * mainRadius * 0.62, budY = orbitY / length * mainRadius * 0.62
        let x = budX + (orbitX - budX) * free
        let y = budY + (orbitY - budY) * free
        // It stays in front for most of a split and swings round to the front to merge, so
        // neither happens out of sight behind the orb.
        let swing = member.ended == nil ? out * out : pow(out, 4)
        let depth = min(1, max(-1, 1 + (orbitDepth - 1) * swing))
        let radius = satelliteRadius * (1 + 0.18 * depth) * (0.3 + 0.7 * min(1, free))
        return Frame(x: x, y: y, radius: radius, depth: depth, out: out, color: member.satellite.color, satellite: member.satellite,
                     slot: member.slot, returning: member.ended != nil)
    }

    /// Ease out with a slight overshoot, so a satellite springs free.
    static func ease(_ p: Double) -> Double {
        let p = min(1, max(0, p))
        let c = 1.4
        return 1 + (c + 1) * pow(p - 1, 3) + c * pow(p - 1, 2)
    }
}
