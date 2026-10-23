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
        case .summary: TeamRole.researcher.title
        case .triage: TeamRole.tester.title
        case .draft: TeamRole.backend.title
        case .commitMessage, .writing: TeamRole.documenter.title
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

/// One job an agent did: a local model's delegated task, a cloud agent's answer or a Claude
/// turn, for the stats.
public struct AgentJob: Codable, Equatable, Sendable, Identifiable {
    public enum Provider: String, Codable, Sendable {
        case local, claude, grok, jev, codex

        /// Another company's agent: Grok and Jev with the user's keys, Codex with their ChatGPT plan.
        public var isCloudAgent: Bool { self == .grok || self == .jev || self == .codex }
    }
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
    /// Who asked: "claude" or "codex" when the agent in charge delegated it, "you" for your own
    /// turns, "dante" for Dante's own jobs.
    public var requestedBy: String
    /// A few words about the job.
    public var title: String
    /// What the provider charged, when it says (Jev does).
    public var costUSD: Double?
    /// Why the agent in charge asked, in its own words (the tools' `why` argument).
    public var why: String?
    /// The answer's first sentence, from `AgentJob.gist(of:)`.
    public var gist: String?
    /// Files a turn changed, relative to the project.
    public var files: [String]?

    public init(id: UUID = UUID(), date: Date = Date(), kind: String, provider: Provider, model: String, project: String,
                promptTokens: Int = 0, outputTokens: Int = 0, seconds: Double = 0, outcome: Outcome = .done,
                requestedBy: String = "dante", title: String = "", costUSD: Double? = nil,
                why: String? = nil, gist: String? = nil, files: [String]? = nil) {
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
        self.costUSD = costUSD
        self.why = why.flatMap { Self.clean($0) }
        self.gist = gist
        self.files = files?.isEmpty == true ? nil : files
    }

    public var tokens: Int { promptTokens + outputTokens }

    /// The first sentence of a reply, as plain text: tool headers, headings, code and markdown
    /// marks left out, at most `limit` characters.
    public static func gist(of text: String, limit: Int = 160) -> String? {
        var inCode = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inCode.toggle(); continue }
            if inCode || line.isEmpty || line.hasPrefix("#") || line.hasPrefix("|") || line.allSatisfy({ "-*_=".contains($0) }) { continue }
            // Dante's own tool headers: "[Codex · 1→2 tokens · 3s] …"
            if line.hasPrefix("["), let close = line.firstIndex(of: "]"), line[line.startIndex..<close].contains("·") {
                let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                if rest.isEmpty || rest.hasPrefix("A second opinion") || rest.hasPrefix("Check this") { continue }
            }
            guard var plain = clean(line) else { continue }
            // A label such as "Summary of changes:" introduces the gist; it isn't one.
            if plain.hasSuffix(":"), plain.count <= 40 { continue }
            if let end = sentenceEnd(plain) { plain = String(plain[..<end]) }
            if plain.count > limit { plain = String(plain.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" }
            return plain
        }
        return nil
    }

    /// Markdown marks and list bullets off; nil when nothing's left.
    static func clean(_ text: String) -> String? {
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for bullet in ["- ", "* ", "> ", "• "] where line.hasPrefix(bullet) { line.removeFirst(bullet.count) }
        if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
           line[line.index(after: dot)...].hasPrefix(" ") {
            line = String(line[line.index(dot, offsetBy: 2)...])
        }
        line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
        line = line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return line.isEmpty ? nil : line
    }

    /// Where the first sentence ends: after ". ", "! " or "? ", but not inside "e.g. " or a file name.
    private static func sentenceEnd(_ text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if ".!?".contains(text[index]), next < text.endIndex, text[next] == " " {
                let before = text[text.startIndex..<index].split(separator: " ").last.map(String.init) ?? ""
                if !["e.g", "i.e", "etc", "vs", "Mr", "Dr"].contains(before) { return next }
            }
            index = next
        }
        return nil
    }
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
    /// Jobs Grok and Jev did.
    public var cloudJobs: Int
    /// What cloud agents charged, as far as they say.
    public var costUSD: Double
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
        cloudJobs = jobs.filter { $0.provider.isCloudAgent }.count
        costUSD = jobs.reduce(0) { $0 + ($1.costUSD ?? 0) }
        tokensKeptLocal = jobs.filter { $0.provider == .local && $0.outcome == .done }.reduce(0) { $0 + $1.tokens }
        delegatedByClaude = jobs.filter { $0.provider == .local && ($0.requestedBy == "claude" || $0.requestedBy == "codex") }.count
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
        /// Grok and Jev.
        public var cloud: Int = 0
        public var codex: Int = 0
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
            switch job.provider {
            case .local: result[index].local += 1
            case .claude: result[index].claude += 1
            case .codex: result[index].codex += 1
            case .grok, .jev: result[index].cloud += 1
            }
        }
        return result
    }

    /// The agent a job belongs to, by name: the local agents by kind, Grok or Jev, else Claude
    /// or a sub-agent.
    public static func agent(of job: AgentJob) -> String {
        if job.provider == .grok { return CloudAgent.grok.title }
        if job.provider == .jev { return CloudAgent.jev.title }
        if job.provider == .codex { return "Codex" }
        if let kind = DelegateKind(rawValue: job.kind), job.provider == .local { return kind.agent }
        if job.kind == Looker.kind { return Looker.agent }
        if job.kind == "subagent", let role = TeamRole(agentID: job.model) { return role.title }
        return job.kind == "subagent" ? "Sub-agents" : "Claude"
    }
}
