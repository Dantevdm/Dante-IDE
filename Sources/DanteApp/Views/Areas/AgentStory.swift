import DanteKit
import SwiftUI

/// The Agents area's summary: what happened in a few sentences, what each model did, and
/// who checked whose work and why.
struct AgentStoryCard: View {
    @Environment(\.theme) private var theme
    let digest: AgentDigest

    var body: some View {
        Card("What happened", accent: true) {
            if digest.sentences.isEmpty {
                Text("Nothing yet. Ask Claude or Codex for something and the story starts here.")
                    .font(.dante(size: 13)).foregroundStyle(theme.text3.color)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(digest.sentences.enumerated()), id: \.offset) { index, sentence in
                        Text(sentence)
                            .font(.dante(size: index == 0 ? 15 : 13.5, weight: index == 0 ? .semibold : .regular))
                            .foregroundStyle(index == 0 ? theme.text.color : theme.text2.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
                .animation(.snappy(duration: 0.3), value: digest.sentences)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) { modelsColumn.frame(maxWidth: .infinity); checksColumn.frame(maxWidth: .infinity) }
                    VStack(alignment: .leading, spacing: 18) { modelsColumn; checksColumn }
                }
                .padding(.top, 6)
            }
        }
    }

    private var modelsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Who did what", symbol: "person.2")
            ForEach(digest.models) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(AgentColor.color(for: line.provider, theme: theme)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(line.name).font(.dante(size: 12.5, weight: .medium, design: line.provider == .local ? .monospaced : .default))
                                .foregroundStyle(theme.text.color)
                            if line.agents.count > 1 || line.agents.first != line.name {
                                Text(line.agents.joined(separator: ", ")).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                            }
                        }
                        Text(line.work.joined(separator: " · ")).font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                    }
                    Spacer(minLength: 6)
                    Text(line.failed > 0 ? "\(line.jobs) · \(line.failed) failed" : "\(line.jobs)")
                        .font(.dante(size: 11.5, design: .monospaced))
                        .foregroundStyle(line.failed > 0 ? theme.red.color : theme.text3.color)
                }
                .help("\(line.jobs) job\(line.jobs == 1 ? "" : "s"), \(ClaudeUsage.short(line.tokens)) tokens")
            }
        }
    }

    private var checksColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Who checked what", symbol: "checkmark.seal")
            if digest.checks.isEmpty {
                Text("No second opinions yet. Turn on Codex in Settings › Claude, or ask the agent in charge to have the other review its work.")
                    .font(.dante(size: 12)).foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(digest.checks.prefix(5)) { check in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(check.agent).font(.dante(size: 12.5, weight: .semibold)).foregroundStyle(AgentColor.color(for: check.job.provider, theme: theme))
                        Image(systemName: "arrow.right").font(.dante(size: 9)).foregroundStyle(theme.text3.color)
                        Text(check.asker == "You" || check.asker == "Dante" ? "for you" : "\(check.asker)’s work")
                            .font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                        Spacer(minLength: 4)
                        Text(check.job.date.relative).font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                    }
                    Text(check.job.title).font(.dante(size: 12)).foregroundStyle(theme.text.color).lineLimit(1)
                    if let why = check.job.why {
                        Label { Text(why) } icon: { Image(systemName: "questionmark.circle") }
                            .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(2)
                    }
                    if let gist = check.job.gist {
                        Label { Text(gist) } icon: { Image(systemName: check.job.outcome == .failed ? "xmark.circle" : "text.bubble") }
                            .font(.dante(size: 11.5))
                            .foregroundStyle(check.job.outcome == .failed ? theme.red.color : theme.text2.color)
                            .lineLimit(2)
                    }
                }
                .padding(.leading, 9)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(AgentColor.color(for: check.job.provider, theme: theme).opacity(0.6)).frame(width: 2)
                }
            }
        }
    }

    private func heading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.dante(size: 11.5, weight: .semibold))
            .foregroundStyle(theme.text3.color)
            .textCase(.uppercase)
    }
}

/// Requests and everything done for them, newest first: the lead's job with the helpers,
/// reviews and decisions it started hanging off it.
struct AgentThreadsCard: View {
    @Environment(\.theme) private var theme
    let threads: [AgentDigest.Thread]
    @State private var expanded: Set<UUID> = []

    var body: some View {
        Card("Requests") {
            if threads.isEmpty {
                Text("Nothing yet.").font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(threads.prefix(10)) { thread in
                    row(thread.lead, isLead: true, count: thread.helpers.count)
                    if !thread.helpers.isEmpty, expanded.contains(thread.id) || thread.id == threads.first?.id {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(thread.helpers) { row($0, isLead: false, count: 0) }
                        }
                        .padding(.leading, 20)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(theme.line2.color).frame(width: 1).padding(.leading, 7).padding(.vertical, 4)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .animation(.snappy(duration: 0.25), value: expanded)
        }
    }

    private func row(_ step: AgentDigest.Step, isLead: Bool, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol(step))
                .font(.dante(size: 10.5))
                .foregroundStyle(step.job.outcome == .failed ? theme.red.color : AgentColor.color(for: step.job.provider, theme: theme))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verb(step)).font(.dante(size: 12, weight: .medium)).foregroundStyle(theme.text.color)
                    Text(step.job.title.isEmpty ? step.job.kind : step.job.title).font(.dante(size: 12)).foregroundStyle(theme.text2.color).lineLimit(1)
                }
                if let files = step.job.files, !files.isEmpty {
                    Text(files.prefix(4).joined(separator: ", ") + (files.count > 4 ? " +\(files.count - 4)" : ""))
                        .font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color).lineLimit(1)
                }
                if !isLead, let why = step.job.why {
                    Text("Why: \(why)").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                }
                if !isLead || step.role != .led, let gist = step.job.gist {
                    Text(gist).font(.dante(size: 11.5)).foregroundStyle(step.job.outcome == .failed ? theme.red.color : theme.text3.color).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if isLead, count > 0 {
                Button {
                    if expanded.contains(step.id) { expanded.remove(step.id) } else { expanded.insert(step.id) }
                } label: {
                    Text("\(count) helper\(count == 1 ? "" : "s")").font(.dante(size: 11)).foregroundStyle(theme.accent.color)
                }
                .buttonStyle(.plain)
            }
            Text(step.job.date.relative).font(.dante(size: 11)).foregroundStyle(theme.text3.color).frame(width: 74, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .help("\(AgentDigest.modelName(step.job)) · \(step.job.project) · \(String(format: "%.1f", step.job.seconds))s · \(ClaudeUsage.short(step.job.tokens)) tokens")
    }

    private func verb(_ step: AgentDigest.Step) -> String {
        switch step.role {
        case .led: "\(step.agent) led"
        case .checked: "\(step.agent) checked"
        case .delegated: "\(step.agent) took"
        case .decided: "Jev decided"
        case .helped: "Sub-agent"
        case .dante: step.agent
        }
    }

    private func symbol(_ step: AgentDigest.Step) -> String {
        if step.job.outcome == .failed { return "xmark.circle.fill" }
        switch step.role {
        case .led: return "person.crop.circle"
        case .checked: return "checkmark.seal"
        case .delegated, .dante: return "cpu"
        case .decided: return "arrow.triangle.branch"
        case .helped: return "square.stack.3d.up"
        }
    }
}

/// One colour per provider, shared by the Agents area's cards and charts.
enum AgentColor {
    static func color(for provider: AgentJob.Provider, theme: Theme) -> Color {
        switch provider {
        case .local: theme.green.color
        case .claude: theme.claude.color
        case .codex: theme.syntax.function.color
        case .grok: theme.text2.color
        case .jev: theme.syntax.type.color
        }
    }
}
