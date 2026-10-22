import Charts
import DanteKit
import SwiftUI

/// Agents: who did the work. Claude or Codex is in charge and the other reviews; local models in Ollama take the jobs it
/// (and Dante) hands them, and Grok and Jev answer when the user has added their keys. Live numbers from the `AgentLedger`, which the `dante mcp` server
/// Claude Code runs writes to as well.
struct AgentsView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    @State private var jobs: [AgentJob] = []
    @State private var models: [OllamaModel]?
    @State private var range: Range = .week
    /// Cloud agents with a key in the Keychain.
    @State private var cloud: Set<CloudAgent> = []

    enum Range: String, CaseIterable, Identifiable {
        case today = "Today", week = "7 days", month = "30 days"
        var id: Self { self }
        var days: Int {
            switch self {
            case .today: 1
            case .week: 7
            case .month: 30
            }
        }
    }

    private var since: Date {
        Calendar.current.date(byAdding: .day, value: -(range.days - 1), to: Calendar.current.startOfDay(for: .now)) ?? .distantPast
    }

    private var shown: [AgentJob] { jobs.filter { $0.date >= since } }

    var body: some View {
        let stats = AgentStats(shown)
        AreaPage(eyebrow: nil, title: "Activity", subtitle: nil) {
            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } content: {
            hero(stats)
            flowCard(agents(stats))
            AgentStoryCard(digest: AgentDigest(shown))
            CardGrid(minimum: 220) {
                ForEach(agents(stats)) { agent in AgentCard(agent: agent) }
            }
            CardGrid(minimum: 420) {
                Card("Who did the work") {
                    DailyChart(days: AgentStats.daily(jobs, days: max(range.days, 7)))
                }
                Card("When") {
                    HourStrip(byHour: stats.byHour)
                }
            }
            CardGrid(minimum: 420) {
                AgentThreadsCard(threads: AgentDigest(shown).threads)
                modelsCard
            }
        }
        .task {
            // The ledger is written by other processes too, so look again every few seconds.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    // MARK: Hero

    private func hero(_ stats: AgentStats) -> some View {
        HStack(alignment: .center, spacing: 24) {
            OrbRepresentable(size: .large)
                .frame(width: 210, height: 180)
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 28) {
                    BigNumber(value: "\(stats.localJobs + stats.claudeJobs + stats.cloudJobs)", label: "Jobs")
                    BigNumber(value: ClaudeUsage.short(stats.tokensKeptLocal), label: "Tokens kept local", color: theme.green.color)
                    BigNumber(value: "\(stats.delegatedByClaude)", label: "Delegated", color: theme.claude.color)
                    BigNumber(value: stats.localJobs + stats.claudeJobs == 0 ? "–" : "\(Int((stats.delegationShare * 100).rounded()))%",
                              label: "Done locally", color: theme.accent.color)
                }
                ShareBar(local: stats.localJobs, claude: stats.claudeJobs)
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(get: { Preferences.shared.delegatesToLocalModels },
                                         set: { Preferences.shared.delegatesToLocalModels = $0; session.applyClaudePreferences() })) {
                        Text("Let Claude and Codex delegate to local models").font(.dante(size: 12.5))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    if models == nil {
                        Chip(text: "Ollama isn’t running", symbol: "exclamationmark.triangle", color: theme.amber.color)
                    } else if Session.danteCommand == nil {
                        Chip(text: "Delegation needs the app bundle", symbol: "info.circle")
                    }
                    if stats.cloudJobs > 0 {
                        Chip(text: "\(stats.cloudJobs) cloud job\(stats.cloudJobs == 1 ? "" : "s")\(stats.costUSD > 0 ? String(format: " · $%.4f", stats.costUSD) : "")",
                             symbol: "cloud", color: theme.syntax.type.color)
                            .help("Codex on your ChatGPT plan, and Grok and Jev with your keys. Cost is what Jev reports.")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [theme.accentTint.color, theme.card.color], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.accentLine.color))
    }

    // MARK: Agents

    /// Who hands work to whom: you to the agent in charge, and it to the others, each link
    /// labelled with the jobs in this range and moving while that agent is at work.
    @ViewBuilder
    private func flowCard(_ agents: [AgentSummary]) -> some View {
        if agents.count >= 2, let lead = agents.first {
            let recent = Date().addingTimeInterval(-120)
            // The five who did most (or are at work now); the rest share one node.
            let others = agents.dropFirst().sorted { ($0.jobs.contains { $0.date > recent } ? 1 : 0, $0.jobs.count) > ($1.jobs.contains { $0.date > recent } ? 1 : 0, $1.jobs.count) }
            let shownAgents = Array(others.prefix(others.count > 6 ? 5 : 6))
            let rest = others.dropFirst(shownAgents.count)
            let leadWorking = session.claude?.state == .working || session.jobs.open.contains { session.jobs.phase(of: $0.id).isActive }
            let nodes = [FlowGraph.Node(id: "you", title: "You", detail: "\(lead.jobs.filter { $0.kind == "turn" }.count) requests", symbol: "person.fill", state: .idle, column: 0),
                         FlowGraph.Node(id: lead.name, title: lead.name, detail: lead.role.components(separatedBy: ":").first ?? lead.model,
                                        symbol: lead.isCodex ? "chevron.left.forwardslash.chevron.right" : "sparkle", state: leadWorking ? .live : .idle, tint: lead.color, column: 1)]
                + shownAgents.map { agent in
                    FlowGraph.Node(id: agent.name, title: agent.name, detail: agent.model, symbol: agent.isClaude || agent.isCodex ? "person.2" : "cpu",
                                   state: agent.jobs.contains { $0.date > recent } ? .live : agent.availability == nil ? .idle : .off, tint: agent.color, column: 2)
                }
            let links = [FlowGraph.Link(from: "you", to: lead.name, label: "\(lead.jobs.count)", state: leadWorking ? .live : .idle)]
                + shownAgents.map { agent in
                    FlowGraph.Link(from: lead.name, to: agent.name, label: agent.jobs.isEmpty ? "" : "\(agent.jobs.count)",
                                   state: agent.jobs.contains { $0.date > recent } ? .live : agent.failed > 0 && agent.failed == agent.jobs.count ? .bad : .idle)
                }
            let restJobs = rest.reduce(0) { $0 + $1.jobs.count }
            let restNodes = rest.isEmpty ? [] : [FlowGraph.Node(id: "rest", title: "\(rest.count) more", detail: rest.prefix(3).map(\.name).joined(separator: ", "),
                                                                symbol: "ellipsis", state: .idle, column: 2)]
            let restLinks = rest.isEmpty ? [] : [FlowGraph.Link(from: lead.name, to: "rest", label: restJobs == 0 ? "" : "\(restJobs)")]
            Card("How the work flows") {
                FlowGraph(nodes: nodes + restNodes, links: links + restLinks)
            }
        }
    }

    private func agents(_ stats: AgentStats) -> [AgentSummary] {
        var byAgent: [String: [AgentJob]] = [:]
        for job in shown { byAgent[AgentStats.agent(of: job), default: []].append(job) }
        let installed = models ?? []
        let lead = session.claude?.engine ?? .claude
        let claudeRole = lead == .claude ? "In charge: writes, decides, checks" : "Reviews Codex’s work · Anthropic"
        var result: [AgentSummary] = [AgentSummary(name: "Claude", role: claudeRole, model: Preferences.shared.claudeModel.argument ?? "Claude",
                                                   jobs: byAgent["Claude"] ?? [], color: theme.claude.color, isClaude: true,
                                                   availability: session.claude?.executable == nil ? "Unavailable · install Claude Code" : nil)]
        let codexJobs = byAgent["Codex"] ?? []
        if Preferences.shared.asksCodex || lead == .codex || !codexJobs.isEmpty {
            let codex = AgentSummary(name: "Codex", role: lead == .codex ? "In charge: writes, decides, checks" : "Reviews Claude’s work · OpenAI",
                                     model: Preferences.shared.codexModel.isEmpty ? codexJobs.last(where: { $0.kind == "turn" })?.model ?? "Codex default" : Preferences.shared.codexModel,
                                     jobs: codexJobs, color: theme.syntax.function.color, isClaude: false, isCodex: true,
                                     availability: Session.codexPath == nil ? "Unavailable · install Codex CLI or ChatGPT" : nil)
            if lead == .codex { result.insert(codex, at: 0) } else { result.append(codex) }
        }
        if let sub = byAgent["Sub-agents"], !sub.isEmpty {
            result.append(AgentSummary(name: "Sub-agents", role: "Claude’s own helpers", model: "Claude", jobs: sub, color: theme.syntax.keyword.color, isClaude: true))
        }
        let palette = [theme.accent.color, theme.green.color, theme.amber.color, theme.syntax.type.color, theme.syntax.string.color]
        for (index, kind) in DelegateKind.allCases.enumerated() {
            result.append(AgentSummary(name: kind.agent, role: kind.title, model: ModelRouting.model(for: kind, installed: installed) ?? "No model",
                                       jobs: byAgent[kind.agent] ?? [], color: palette[index % palette.count], isClaude: false))
        }
        result.append(AgentSummary(name: Looker.agent, role: "Reads screenshots and images", model: Looker.model(installed: installed) ?? "No model",
                                   jobs: byAgent[Looker.agent] ?? [], color: theme.amber.color, isClaude: false))
        for agent in CloudAgent.allCases {
            let jobs = byAgent[agent.title] ?? []
            let hasKey = cloud.contains(agent)
            let model = agent == .grok ? (Preferences.shared.grokModel.isEmpty ? jobs.last?.model ?? "Best available" : Preferences.shared.grokModel)
                                       : jobs.last?.model ?? Jev.defaultModel
            result.append(AgentSummary(name: agent.title, role: "\(agent.role) · \(agent.company)", model: hasKey ? model : "No key",
                                       jobs: jobs, color: agent == .grok ? theme.text2.color : theme.syntax.type.color, isClaude: false,
                                       availability: hasKey ? nil : "Unavailable · add API key in Settings"))
        }
        return result
    }

    // MARK: Models

    private var modelsCard: some View {
        Card("Models on this Mac") {
            if let models {
                let usable = models.filter { !$0.isCloud }
                if usable.isEmpty {
                    Text("No local models yet.").font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
                }
                VStack(spacing: 0) {
                    ForEach(usable) { model in
                        let roles = DelegateKind.allCases.filter { ModelRouting.model(for: $0, installed: models) == model.name }.map(\.agent)
                            + (Looker.model(installed: models) == model.name ? [Looker.agent] : [])
                            + (ModelRouting.embeddingModel(installed: models) == model.name ? ["Search by meaning"] : [])
                        HStack(spacing: 10) {
                            Circle().fill(roles.isEmpty ? theme.track.color : theme.green.color).frame(width: 7, height: 7)
                            Text(model.name).font(.dante(size: 12.5, design: .monospaced)).foregroundStyle(theme.text.color)
                            Text(model.parameterSize).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                            Spacer(minLength: 8)
                            Text(roles.isEmpty ? (model.isVision ? "images, not used" : "spare") : roles.joined(separator: ", "))
                                .font(.dante(size: 11.5))
                                .foregroundStyle(roles.isEmpty ? theme.text3.color : theme.text2.color)
                                .lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file))
                                .font(.dante(size: 11.5, design: .monospaced))
                                .foregroundStyle(theme.text3.color)
                                .frame(width: 64, alignment: .trailing)
                        }
                        .padding(.vertical, 6)
                    }
                }
                if Looker.model(installed: models) == nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Looker.missingReason(installed: models))
                            .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                            .fixedSize(horizontal: false, vertical: true)
                        LinkButton("Type the command in the terminal") {
                            session.showsTerminal = true
                            session.typeInTerminal("ollama pull \(Looker.suggestedModel)")
                        }
                        .help("Types it for you to run. Dante never downloads models itself.")
                    }
                    .padding(.top, 8)
                }
            } else {
                Text("Ollama isn’t running. Start it to give Claude local helpers.")
                    .font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
            }
        }
    }

    private func load() async {
        let ledger = AgentLedger.standard
        let loaded = await Task.detached(priority: .utility) {
            ledger.jobs(since: Calendar.current.date(byAdding: .day, value: -31, to: .now) ?? .distantPast)
        }.value
        if loaded != jobs { jobs = loaded }
        let found = await Ollama().models()
        if found != models { models = found }
        let keyed = Set(CloudAgent.allCases.filter { AgentKeys.key(for: $0) != nil })
        if keyed != cloud { cloud = keyed }
    }
}

/// One agent's numbers for its card.
struct AgentSummary: Identifiable {
    var name: String
    var role: String
    var model: String
    var jobs: [AgentJob]
    var color: Color
    var isClaude: Bool
    var isCodex = false
    var availability: String? = nil
    var id: String { name }

    var failed: Int { jobs.filter { $0.outcome == .failed }.count }
    var tokens: Int { jobs.reduce(0) { $0 + $1.tokens } }
    var averageSeconds: Double { jobs.isEmpty ? 0 : jobs.reduce(0) { $0 + $1.seconds } / Double(jobs.count) }
    var successRate: Double { jobs.isEmpty ? 0 : Double(jobs.count - failed) / Double(jobs.count) }
}

private struct AgentCard: View {
    @Environment(\.theme) private var theme
    let agent: AgentSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AgentAvatar(color: agent.color, busy: agent.jobs.last.map { Date().timeIntervalSince($0.date) < 60 } ?? false, isClaude: agent.isClaude, isCodex: agent.isCodex)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name).font(.dante(size: 13.5, weight: .semibold)).foregroundStyle(theme.text.color)
                    Text(agent.role).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                stat("\(agent.jobs.count)", "jobs")
                stat(agent.jobs.isEmpty ? "–" : "\(Int((agent.successRate * 100).rounded()))%", "ok")
                stat(agent.jobs.isEmpty ? "–" : String(format: "%.1fs", agent.averageSeconds), "avg")
                stat(ClaudeUsage.short(agent.tokens), "tokens")
            }
            if let availability = agent.availability {
                Label(availability, systemImage: "exclamationmark.triangle.fill")
                    .font(.dante(size: 11)).foregroundStyle(theme.amber.color)
                    .lineLimit(1).help(availability)
            }
            Text(agent.model)
                .font(.dante(size: 11, design: .monospaced))
                .foregroundStyle(theme.text3.color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
        .overlay(alignment: .top) {
            // The agent's colour as a thin top edge.
            UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous)
                .fill(agent.color.opacity(agent.jobs.isEmpty ? 0.25 : 0.9))
                .frame(height: 3)
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line.color))
        .opacity(agent.jobs.isEmpty ? 0.7 : 1)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.dante(size: 16, weight: .semibold)).foregroundStyle(theme.text.color).monospacedDigit()
            Text(label).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color)
        }
    }
}

/// A small glowing bead in the agent's colour that pulses while it's working.
private struct AgentAvatar: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color
    let busy: Bool
    let isClaude: Bool
    var isCodex = false

    var body: some View {
        TimelineView(.animation(paused: !busy || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = busy && !reduceMotion ? 0.5 + 0.5 * sin(t * 4) : 0
            ZStack {
                Circle().fill(color.opacity(0.18 + 0.2 * pulse)).frame(width: 30 + 6 * pulse, height: 30 + 6 * pulse).blur(radius: 4)
                Circle().fill(RadialGradient(colors: [color.opacity(0.45), color], center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: 14))
                    .frame(width: 22, height: 22)
                if isClaude {
                    Image.symbol("sparkle", side: 11).foregroundStyle(theme.onAccent.color)
                } else if isCodex {
                    CodexGlyph().fill(theme.onAccent.color).frame(width: 11, height: 11)
                }
            }
            .frame(width: 34, height: 34)
        }
    }
}

private struct BigNumber: View {
    @Environment(\.theme) private var theme
    let value: String
    let label: String
    var color: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.dante(size: 30, weight: .semibold))
                .foregroundStyle(color ?? theme.text.color)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
        }
    }
}

/// Local versus Claude, as one bar.
private struct ShareBar: View {
    @Environment(\.theme) private var theme
    let local: Int
    let claude: Int

    var body: some View {
        GeometryReader { geometry in
            let total = max(1, local + claude)
            HStack(spacing: 2) {
                Capsule().fill(theme.green.color).frame(width: max(local > 0 ? 6 : 0, geometry.size.width * CGFloat(local) / CGFloat(total)))
                Capsule().fill(theme.claude.color).frame(maxWidth: .infinity)
            }
        }
        .frame(height: 6)
        .frame(maxWidth: 520)
        .animation(.snappy, value: local)
        .help("Green: local models. Clay: Claude.")
    }
}

private struct DailyChart: View {
    @Environment(\.theme) private var theme
    let days: [AgentStats.Day]

    var body: some View {
        Chart {
            ForEach(days) { day in
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Jobs", day.local))
                    .foregroundStyle(by: .value("Who", "Local"))
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Jobs", day.claude))
                    .foregroundStyle(by: .value("Who", "Claude"))
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Jobs", day.codex))
                    .foregroundStyle(by: .value("Who", "Codex"))
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Jobs", day.cloud))
                    .foregroundStyle(by: .value("Who", "Grok and Jev"))
            }
        }
        .chartForegroundStyleScale(["Local": theme.green.color, "Claude": theme.claude.color, "Codex": theme.syntax.function.color,
                                    "Grok and Jev": theme.syntax.type.color])
        .chartLegend(position: .top, alignment: .leading)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: days.count > 10 ? 5 : 1)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.dante(size: 10))
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(theme.line.color)
                AxisValueLabel().font(.dante(size: 10))
            }
        }
        .frame(height: 180)
    }
}

/// Jobs by hour of day, as a row of cells that glow with use.
private struct HourStrip: View {
    @Environment(\.theme) private var theme
    let byHour: [Int]

    var body: some View {
        let peak = max(1, byHour.max() ?? 1)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(byHour[hour] == 0 ? theme.track.color : theme.accent.color.opacity(0.25 + 0.75 * Double(byHour[hour]) / Double(peak)))
                        .frame(height: 44)
                        .help("\(hour):00 · \(byHour[hour]) job\(byHour[hour] == 1 ? "" : "s")")
                }
            }
            HStack {
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(String(format: "%02d:00", hour)).font(.dante(size: 10)).foregroundStyle(theme.text3.color)
                    if hour != 18 { Spacer() }
                }
            }
        }
    }
}
