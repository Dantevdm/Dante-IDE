import Foundation

/// The story behind the Agents area's numbers: what you asked for and who led it, who
/// checked whose work and why, what each model did, and what failed. Built from the
/// `AgentLedger` alone, so it says only what happened.
public struct AgentDigest: Equatable, Sendable {
    /// What a job was, from the point of view of the work.
    public enum Role: String, Sendable {
        /// One of your requests, led by Claude or Codex.
        case led
        /// A second opinion on the work: Claude or Codex on the other's, or Grok.
        case checked
        /// A small job handed to a local model.
        case delegated
        /// A quick decision from Jev.
        case decided
        /// One of Claude's own sub-agents.
        case helped
        /// Dante's own jobs, such as commit messages.
        case dante
    }

    public struct Step: Equatable, Sendable, Identifiable {
        public var job: AgentJob
        public var role: Role
        /// Who did it: "Codex", "Reader", "Claude".
        public var agent: String
        /// Who asked: "You", "Codex", "Dante".
        public var asker: String
        public var id: UUID { job.id }
    }

    /// One request and everything done for it, or a job on its own.
    public struct Thread: Equatable, Sendable, Identifiable {
        public var lead: Step
        public var helpers: [Step]
        public var id: UUID { lead.id }
    }

    /// One model and everything it did.
    public struct ModelLine: Equatable, Sendable, Identifiable {
        public var name: String
        public var provider: AgentJob.Provider
        public var agents: [String]
        public var work: [String]
        public var jobs: Int
        public var failed: Int
        public var tokens: Int
        public var id: String { "\(provider.rawValue):\(name)" }
    }

    public var sentences: [String]
    public var threads: [Thread]
    public var models: [ModelLine]
    /// Second opinions, newest first.
    public var checks: [Step]

    public init(_ jobs: [AgentJob]) {
        let steps = jobs.sorted { $0.date < $1.date }.map(Self.step)
        threads = Self.threads(steps)
        checks = steps.filter { $0.role == .checked }.reversed()
        models = Self.models(steps)
        sentences = Self.sentences(steps, threads: threads)
    }

    // MARK: Steps

    static func step(_ job: AgentJob) -> Step {
        Step(job: job, role: role(of: job), agent: AgentStats.agent(of: job), asker: name(job.requestedBy))
    }

    static func role(of job: AgentJob) -> Role {
        switch job.kind {
        case "turn": return .led
        case "opinion", "audit": return .checked
        case "decision": return .decided
        case "subagent": return .helped
        default: return job.requestedBy == "claude" || job.requestedBy == "codex" ? .delegated : .dante
        }
    }

    /// "claude" → "Claude", "you" → "You".
    static func name(_ requester: String) -> String {
        switch requester {
        case "you": "You"
        case "claude": "Claude"
        case "codex": "Codex"
        case "dante": "Dante"
        default: requester.prefix(1).uppercased() + requester.dropFirst()
        }
    }

    // MARK: Threads

    /// Each request with the jobs its lead started while it ran (same project, within the
    /// turn's time), newest first. Jobs that belong to no request stand alone.
    static func threads(_ steps: [Step]) -> [Thread] {
        var threads: [Thread] = []
        var claimed = Set<UUID>()
        let helpers = steps.filter { $0.role != .led && $0.role != .dante }
        for lead in steps where lead.role == .led {
            let end = lead.job.date.addingTimeInterval(5)
            let start = lead.job.date.addingTimeInterval(-max(lead.job.seconds, 0) - 5)
            let mine = helpers.filter {
                !claimed.contains($0.id) && $0.job.project == lead.job.project && $0.job.date >= start && $0.job.date <= end
            }
            mine.forEach { claimed.insert($0.id) }
            threads.append(Thread(lead: lead, helpers: mine))
        }
        for step in steps where step.role != .led && !claimed.contains(step.id) {
            threads.append(Thread(lead: step, helpers: []))
        }
        return threads.sorted { $0.lead.job.date > $1.lead.job.date }
    }

    // MARK: Models

    static func models(_ steps: [Step]) -> [ModelLine] {
        var lines: [String: ModelLine] = [:]
        var order: [String] = []
        for step in steps {
            let name = modelName(step.job)
            let key = "\(step.job.provider.rawValue):\(name)"
            if lines[key] == nil {
                lines[key] = ModelLine(name: name, provider: step.job.provider, agents: [], work: [], jobs: 0, failed: 0, tokens: 0)
                order.append(key)
            }
            lines[key]?.jobs += 1
            lines[key]?.tokens += step.job.tokens
            if step.job.outcome == .failed { lines[key]?.failed += 1 }
            if !(lines[key]?.agents.contains(step.agent) ?? true) { lines[key]?.agents.append(step.agent) }
            let work = self.work(step)
            if !(lines[key]?.work.contains(work) ?? true) { lines[key]?.work.append(work) }
        }
        return order.compactMap { lines[$0] }.sorted { $0.jobs != $1.jobs ? $0.jobs > $1.jobs : $0.name < $1.name }
    }

    /// The model as people say it: "Claude Opus", "gpt-6.1-sol", "qwen3:14b".
    public static func modelName(_ job: AgentJob) -> String {
        let model = job.model.lowercased()
        switch job.provider {
        case .claude:
            for family in ["opus", "sonnet", "haiku"] where model.contains(family) { return "Claude \(family.capitalized)" }
            return "Claude"
        case .codex:
            return model.isEmpty || model == "codex" ? "Codex" : job.model
        case .grok:
            return model.isEmpty || model == "grok" ? "Grok" : job.model
        case .jev:
            return model.isEmpty || model == "jev" ? "Jev" : job.model
        case .local:
            return job.model
        }
    }

    /// What a job was, in a few words: "led 2 requests" is counted elsewhere.
    static func work(_ step: Step) -> String {
        switch step.role {
        case .led: return "led your requests"
        case .checked:
            if step.job.kind == "audit" { return "security audits" }
            return step.asker == "You" || step.asker == "Dante" ? "second opinions" : "checked \(step.asker)’s work"
        case .decided: return "decisions"
        case .helped: return "sub-agent work"
        case .delegated, .dante:
            if step.job.kind == Looker.kind { return "reading screenshots" }
            return DelegateKind(rawValue: step.job.kind)?.title.lowercased() ?? step.job.kind
        }
    }

    // MARK: Sentences

    static func sentences(_ steps: [Step], threads: [Thread]) -> [String] {
        var sentences: [String] = []
        let leads = steps.filter { $0.role == .led }
        if !leads.isEmpty {
            let byLead = counted(leads.map(\.agent))
            let things = leads.count == 1 ? "1 thing" : "\(leads.count) things"
            if byLead.count == 1, let only = byLead.first {
                sentences.append("You asked for \(things), \(leads.count == 1 ? "" : leads.count == 2 ? "both " : "all ")led by \(only.name).")
            } else {
                sentences.append("You asked for \(things): " + list(byLead.map { "\($0.name) led \($0.count)" }) + ".")
            }
            let files = Set(leads.flatMap { $0.job.files ?? [] })
            if !files.isEmpty {
                let names = files.sorted().prefix(3).map { ($0 as NSString).lastPathComponent }
                let more = files.count > 3 ? " and \(files.count - 3) more" : ""
                sentences.append("Together they changed \(files.count == 1 ? "1 file" : "\(files.count) files") (\(names.joined(separator: ", "))\(more)).")
            }
        }

        let checks = steps.filter { $0.role == .checked }
        if !checks.isEmpty {
            let pairs = counted(checks.map { $0.asker == "You" || $0.asker == "Dante" ? "\($0.agent)|" : "\($0.agent)|\($0.asker)" })
            sentences.append(list(pairs.map { pair in
                let parts = pair.name.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                return parts[1].isEmpty ? "\(parts[0]) gave \(times(pair.count, "second opinion"))"
                                        : "\(parts[0]) checked \(parts[1])’s work \(often(pair.count))"
            }).capitalisedFirst + ".")
        } else if leads.count >= 2 {
            sentences.append("Nothing was cross-checked: ask the other agent to review before you ship.")
        }

        let delegated = steps.filter { $0.role == .delegated || $0.role == .dante }
        if !delegated.isEmpty {
            let kinds = Array(NSOrderedSet(array: delegated.map(work))) as? [String] ?? []
            let kept = delegated.filter { $0.job.provider == .local && $0.job.outcome == .done }.reduce(0) { $0 + $1.job.tokens }
            var sentence = "Local models took \(times(delegated.count, "job")) (\(list(kinds)))"
            if kept > 0 { sentence += ", keeping \(ClaudeUsage.short(kept)) tokens off your plans" }
            sentences.append(sentence + ".")
        }

        let decisions = steps.filter { $0.role == .decided }
        if !decisions.isEmpty { sentences.append("Jev made \(times(decisions.count, "decision")).") }
        let helpers = steps.filter { $0.role == .helped }
        if !helpers.isEmpty { sentences.append("Claude started \(times(helpers.count, "sub-agent")).") }

        let failed = steps.filter { $0.job.outcome == .failed }
        if !failed.isEmpty {
            let named = failed.suffix(2).reversed().map { "\($0.agent) on “\($0.job.title.isEmpty ? $0.job.kind : $0.job.title)”" }
            sentences.append("\(times(failed.count, "job")) failed: \(list(Array(named)))\(failed.count > 2 ? " and others" : "").")
        }
        return sentences
    }

    private static func counted(_ names: [String]) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for name in names {
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }

    static func times(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }

    static func often(_ count: Int) -> String {
        switch count {
        case 1: "once"
        case 2: "twice"
        default: "\(count) times"
        }
    }
}

private extension String {
    var capitalisedFirst: String { prefix(1).uppercased() + dropFirst() }
}
