import Foundation

/// Work Claude, or Dante itself, can hand to a local model. Claude stays the one that
/// decides and checks; these are the parts where a smaller model is good enough.
public enum DelegateKind: String, Sendable, CaseIterable, Codable, Identifiable {
    /// Boil down a long file, log or diff.
    case summary
    /// Sort failures, errors or issues and say which matter.
    case triage
    /// A first draft of code, tests or fixtures for Claude to review.
    case draft
    /// A git commit message for a diff.
    case commitMessage
    /// Plain text work: rewording, docs, release notes.
    case writing

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .summary: "Summaries"
        case .triage: "Triage"
        case .draft: "Code drafts"
        case .commitMessage: "Commit messages"
        case .writing: "Writing"
        }
    }

    /// The agent's name in stats and on the orbs.
    public var agent: String {
        switch self {
        case .summary: "Reader"
        case .triage: "Triage"
        case .draft: "Drafter"
        case .commitMessage: "Scribe"
        case .writing: "Writer"
        }
    }

    /// Model families that suit the job, best first. Matched against the start of a model's name.
    var preferred: [String] {
        switch self {
        case .draft: ["devstral", "qwen3-coder", "qwen2.5-coder", "deepseek-coder", "codestral", "qwen3", "gpt-oss", "llama3"]
        default: ["qwen3", "gpt-oss", "gemma3", "mistral-small", "llama3.3", "llama3.1", "llama3", "mistral"]
        }
    }

    /// For the `delegate` tool's description.
    var guidance: String {
        switch self {
        case .summary: "condense a long file, log, diff or transcript into the points that matter"
        case .triage: "sort test failures, errors or issues by likely cause and importance"
        case .draft: "write a first draft of boilerplate code, tests or fixtures for you to review and fix"
        case .commitMessage: "write a commit message for a diff"
        case .writing: "reword or draft prose: docs, release notes, descriptions"
        }
    }
}

/// Which local model does which job.
public enum ModelRouting {
    /// The model for a job: the one chosen in Settings if it's here, else the best installed
    /// match. Nil when nothing local suits it (cloud, vision and embedding models never do).
    public static func model(for kind: DelegateKind, installed: [OllamaModel], chosen: String? = nil) -> String? {
        let usable = installed.filter { !$0.isCloud && !$0.isVision && !$0.isEmbedding }
        if let chosen, usable.contains(where: { $0.name == chosen }) { return chosen }
        for family in kind.preferred {
            let matches = usable.filter { $0.name.lowercased().hasPrefix(family) }
            // The biggest of a family that fits comfortably is the most capable.
            if let best = matches.max(by: { $0.size < $1.size }) { return best.name }
        }
        return usable.max(by: { $0.size < $1.size })?.name
    }
}

/// One job an agent did: a local model's delegated task or a Claude turn, for the stats.
public struct AgentJob: Codable, Equatable, Sendable, Identifiable {
    public enum Provider: String, Codable, Sendable { case local, claude }
    public enum Outcome: String, Codable, Sendable { case done, failed }

    public var id: UUID
    public var date: Date
    public var kind: String
    public var provider: Provider
    public var model: String
    public var project: String
    public var promptTokens: Int
    public var outputTokens: Int
    public var seconds: Double
    public var outcome: Outcome
    /// Who asked: "claude" when Claude delegated it, "dante" for Dante's own jobs.
    public var requestedBy: String
    /// A few words about the job.
    public var title: String

    public init(id: UUID = UUID(), date: Date = Date(), kind: String, provider: Provider, model: String, project: String,
                promptTokens: Int = 0, outputTokens: Int = 0, seconds: Double = 0, outcome: Outcome = .done,
                requestedBy: String = "dante", title: String = "") {
        self.id = id
        self.date = date
        self.kind = kind
        self.provider = provider
        self.model = model
        self.project = project
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.seconds = seconds
        self.outcome = outcome
        self.requestedBy = requestedBy
        self.title = title
    }

    public var tokens: Int { promptTokens + outputTokens }
}

/// Every agent job on this Mac, one JSON line each, in Application Support. Shared by the
/// app and the `dante mcp` server Claude Code runs, so appends are whole lines.
public struct AgentLedger: Sendable {
    public var url: URL

    public static var standard: AgentLedger {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AgentLedger(url: support.appending(path: "Dante/agents.jsonl"))
    }

    public init(url: URL) { self.url = url }

    public func append(_ job: AgentJob) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(job) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    /// Jobs since a date, oldest first. Lines that don't parse are skipped.
    public func jobs(since: Date = .distantPast) -> [AgentJob] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return Self.parse(data).filter { $0.date >= since }
    }

    static func parse(_ data: Data) -> [AgentJob] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(AgentJob.self, from: Data($0)) }
    }
}

/// The numbers behind the Agents view.
public struct AgentStats: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var model: String
        public var provider: AgentJob.Provider
        public var jobs: Int
        public var failed: Int
        public var tokens: Int
        public var seconds: Double
        public var kinds: [String: Int]
        public var id: String { "\(provider.rawValue):\(model)" }

        public var successRate: Double { jobs == 0 ? 0 : Double(jobs - failed) / Double(jobs) }
        public var averageSeconds: Double { jobs == 0 ? 0 : seconds / Double(jobs) }
    }

    public var rows: [Row]
    public var localJobs: Int
    public var claudeJobs: Int
    /// Tokens local models handled instead of Claude.
    public var tokensKeptLocal: Int
    /// Of the jobs Claude could have delegated, the share it did.
    public var delegatedByClaude: Int
    /// Jobs per hour of the day (0–23), for the activity strip.
    public var byHour: [Int]

    public var delegationShare: Double {
        let total = localJobs + claudeJobs
        return total == 0 ? 0 : Double(localJobs) / Double(total)
    }

    public init(_ jobs: [AgentJob], calendar: Calendar = .current) {
        var rows: [String: Row] = [:]
        var byHour = Array(repeating: 0, count: 24)
        for job in jobs {
            let key = "\(job.provider.rawValue):\(job.model)"
            var row = rows[key] ?? Row(model: job.model, provider: job.provider, jobs: 0, failed: 0, tokens: 0, seconds: 0, kinds: [:])
            row.jobs += 1
            if job.outcome == .failed { row.failed += 1 }
            row.tokens += job.tokens
            row.seconds += job.seconds
            row.kinds[job.kind, default: 0] += 1
            rows[key] = row
            byHour[calendar.component(.hour, from: job.date)] += 1
        }
        self.rows = rows.values.sorted { $0.jobs != $1.jobs ? $0.jobs > $1.jobs : $0.model < $1.model }
        localJobs = jobs.filter { $0.provider == .local }.count
        claudeJobs = jobs.filter { $0.provider == .claude }.count
        tokensKeptLocal = jobs.filter { $0.provider == .local && $0.outcome == .done }.reduce(0) { $0 + $1.tokens }
        delegatedByClaude = jobs.filter { $0.provider == .local && $0.requestedBy == "claude" }.count
        self.byHour = byHour
    }
}

/// Dante's own small jobs (commit messages, PR descriptions): a local model when one suits
/// the job and delegation is on, else `ClaudeQuick`. Either way the job is recorded.
public enum QuickModel {
    public static func text(_ prompt: String, system: String?, kind: DelegateKind, in root: URL,
                            local: Bool, chosen: String? = nil, ledger: AgentLedger? = .standard) async throws -> String {
        let project = root.lastPathComponent
        let started = Date()
        if local, let installed = await Ollama().models(),
           let model = ModelRouting.model(for: kind, installed: installed, chosen: chosen) {
            do {
                let reply = try await Ollama().chat(model: model, system: system, prompt: prompt)
                if !reply.text.isEmpty {
                    ledger?.append(AgentJob(kind: kind.rawValue, provider: .local, model: model, project: project,
                                            promptTokens: reply.promptTokens, outputTokens: reply.outputTokens,
                                            seconds: reply.seconds, title: kind.title))
                    return reply.text
                }
            } catch {
                ledger?.append(AgentJob(kind: kind.rawValue, provider: .local, model: model, project: project,
                                        seconds: Date().timeIntervalSince(started), outcome: .failed, title: kind.title))
            }
        }
        let claudeStarted = Date()
        do {
            let text = try await ClaudeQuick.text(prompt, system: system, in: root)
            ledger?.append(AgentJob(kind: kind.rawValue, provider: .claude, model: "claude", project: project,
                                    promptTokens: prompt.count / 4, outputTokens: text.count / 4,
                                    seconds: Date().timeIntervalSince(claudeStarted), title: kind.title))
            return text
        } catch {
            ledger?.append(AgentJob(kind: kind.rawValue, provider: .claude, model: "claude", project: project,
                                    seconds: Date().timeIntervalSince(claudeStarted), outcome: .failed, title: kind.title))
            throw error
        }
    }
}

extension AgentStats {
    public struct Day: Equatable, Sendable, Identifiable {
        public var date: Date
        public var local: Int
        public var claude: Int
        public var id: Date { date }
    }

    /// Jobs per day for the last `days` days, oldest first, empty days included.
    public static func daily(_ jobs: [AgentJob], days: Int, now: Date = Date(), calendar: Calendar = .current) -> [Day] {
        let today = calendar.startOfDay(for: now)
        var result = (0..<days).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { Day(date: $0, local: 0, claude: 0) }
        }
        for job in jobs {
            let day = calendar.startOfDay(for: job.date)
            guard let index = result.firstIndex(where: { $0.date == day }) else { continue }
            if job.provider == .local { result[index].local += 1 } else { result[index].claude += 1 }
        }
        return result
    }

    /// The agent a job belongs to, by name: the local agents by kind, else Claude or a sub-agent.
    public static func agent(of job: AgentJob) -> String {
        if let kind = DelegateKind(rawValue: job.kind), job.provider == .local { return kind.agent }
        return job.kind == "subagent" ? "Sub-agents" : "Claude"
    }
}
