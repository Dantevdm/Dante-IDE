import AppKit
import DanteKit
import SwiftUI

/// Claude: how it works on this project. Usage, the skills it can use (and ones worth
/// adding), the memory it reads every message, connectors, permissions and conversations.
struct ClaudeAreaView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    @State private var skills: [ClaudeSkill] = []
    @State private var memory: [ClaudeMemoryFile] = []
    @State private var permissions = ClaudePermissions()
    @State private var conversations: [ClaudeHistory.Conversation] = []
    @State private var servers: [MCPServer]?
    @State private var checkingServers = false
    @State private var plugins: [ClaudePlugin]?
    @State private var available: [ClaudePlugin]?
    @State private var browsing = false
    @State private var removing: ClaudeSkill?
    @State private var lastReview: Date?

    private var suggestions: [SkillSuggestion] {
        ClaudeSkills.suggestions(files: workspace.files, stack: languages, hasDante: FileManager.default.fileExists(atPath: workspace.danteFolder.path), existing: skills)
    }

    private var languages: [String] {
        let names: [String: String] = ["go": "Go", "js": "JavaScript", "ts": "TypeScript", "py": "Python", "rs": "Rust", "swift": "Swift"]
        return Array(Set(workspace.files.compactMap { names[($0 as NSString).pathExtension.lowercased()] })).sorted()
    }

    private var reviewKey: String { "skillsReview." + workspace.url.path }

    var body: some View {
        AreaPage(
            eyebrow: nil,
            title: "Setup",
            subtitle: nil
        ) {
            Button {
                session.showsClaude = true
            } label: {
                Label("Open the panel", systemImage: "sidebar.right")
            }
            .buttonStyle(DanteButtonStyle())
        } content: {
            usageRow
            skillsCard
            HStack(alignment: .top, spacing: 16) {
                memoryCard
                permissionsCard
            }
            HStack(alignment: .top, spacing: 16) {
                connectorsCard
                pluginsCard
            }
            conversationsCard
        }
        .task(id: workspace.revision) { await load() }
        .confirmationDialog("Move \(removing?.name ?? "this skill") to the Trash?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let skill = removing {
                    try? FileManager.default.trashItem(at: skill.file.deletingLastPathComponent(), resultingItemURL: nil)
                    Task { await load() }
                }
            }
        } message: {
            Text("Claude stops using it from the next conversation.")
        }
    }

    private func load() async {
        let root = workspace.url
        let loaded = await Task.detached(priority: .userInitiated) {
            (ClaudeSkills.load(root: root), ClaudeMemoryFile.load(root: root), ClaudePermissions.load(root: root))
        }.value
        (skills, memory, permissions) = loaded
        lastReview = UserDefaults.standard.object(forKey: reviewKey) as? Date
        conversations = Array(await session.claudeConversations().prefix(6))
        if session.claudeUsage == nil { await session.refreshClaudeUsage() }
    }

    // MARK: Usage

    private var usageRow: some View {
        let usage = session.claudeUsage
        let context = session.claude?.context
        let window = session.claude?.contextWindow ?? 200_000
        return HStack(spacing: 12) {
            stat(session.claudeAccount?.planName ?? "Plan", value: usage?.current.map { ClaudeUsage.short($0.usage.weighted) } ?? "0",
                 note: usage?.current.map { "this 5-hour window · resets \($0.resets.formatted(date: .omitted, time: .shortened))" } ?? "no use in the last five hours")
            stat("Last 7 days", value: usage.map { ClaudeUsage.short($0.week.weighted) } ?? "…", note: usage.map { "\($0.weekMessages) replies across all projects" } ?? "reading logs")
            stat("Current conversation", value: context.map { "\(Int((Double($0.context) / Double(window) * 100).rounded()))%" } ?? "—",
                 note: context.map { "of the context window · \(ClaudeUsage.short($0.context)) tokens" } ?? "nothing sent yet")
            stat("Memory per message", value: memory.contains(where: \.exists) ? "~" + ClaudeUsage.short(memory.reduce(0) { $0 + $1.tokens }) : "None",
                 note: "tokens of CLAUDE.md read every turn")
        }
    }

    private func stat(_ label: String, value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            Text(value).font(.dante(size: 22, weight: .semibold)).foregroundStyle(theme.text.color).monospacedDigit()
            Text(note).font(.dante(size: 11)).foregroundStyle(theme.text3.color).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(theme.card.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.line.color))
    }

    // MARK: Skills

    private var skillsCard: some View {
        let due = ClaudeSkills.reviewDue(lastReview: lastReview)
        return Card("Skills") {
            HStack(spacing: 10) {
                if let lastReview {
                    Text("Reviewed \(lastReview.formatted(.relative(presentation: .named)))").font(.dante(size: 11.5)).foregroundStyle(due ? theme.amber.color : theme.text3.color)
                }
                Button {
                    UserDefaults.standard.set(Date.now, forKey: reviewKey)
                    lastReview = .now
                    session.askClaude(ClaudeSkills.reviewPrompt(existing: skills))
                } label: {
                    ClaudeLabel("Review with Claude")
                }
                .buttonStyle(DanteButtonStyle(primary: due))
                .help("Claude looks at how the project works now and suggests skills to add, update or drop.")
            }
        } content: {
            if skills.isEmpty {
                Text("No skills yet").font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
            }
            RowList(data: skills, padding: 9) { skill in
                HStack(spacing: 10) {
                    Image(systemName: "book.pages").font(.dante(size: 13)).foregroundStyle(theme.accent.color).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(skill.name).font(.dante(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(theme.text.color)
                            Chip(text: skill.scope == .project ? "this project" : "all projects")
                        }
                        if !skill.description.isEmpty {
                            Text(skill.description).font(.dante(size: 12)).foregroundStyle(theme.text3.color).lineLimit(2)
                        }
                    }
                    Spacer()
                    Button("Open") { session.open(file: skill.file) }.buttonStyle(DanteButtonStyle())
                    if skill.scope == .project {
                        IconButton(symbol: "trash", label: "Remove") { removing = skill }
                    }
                }
            }
            let suggested = suggestions
            if !suggested.isEmpty {
                Eyebrow("Worth adding for this project").padding(.top, 6)
                RowList(data: suggested, padding: 9) { suggestion in
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle").font(.dante(size: 13)).foregroundStyle(theme.text3.color).frame(width: 18)
                        Text(suggestion.title).font(.dante(size: 13, weight: .medium)).foregroundStyle(theme.text.color)
                            .help(suggestion.reason)
                        Spacer()
                        Button("Draft with Claude") { session.askClaude(suggestion.prompt) }
                            .buttonStyle(DanteButtonStyle())
                            .help("Claude reads how the project does it and writes .claude/skills/\(suggestion.id)/SKILL.md for you to approve.")
                    }
                }
            }
        }
    }

    // MARK: Memory

    private var memoryCard: some View {
        Card("Memory") {
            EmptyView()
        } content: {
            RowList(data: memory, padding: 9) { file in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.title).font(.dante(size: 12.5, weight: .medium, design: .monospaced)).foregroundStyle(theme.text.color)
                        Text(file.exists ? "\(file.note) · ~\(ClaudeUsage.short(file.tokens)) tokens" : "Not written yet").font(.dante(size: 11.5))
                            .foregroundStyle(file.tokens > 4000 ? theme.amber.color : theme.text3.color)
                    }
                    Spacer()
                    if file.exists {
                        if file.tokens > 4000 {
                            Button("Tighten") {
                                session.askClaude("\(file.title) is about \(ClaudeUsage.short(file.tokens)) tokens and Claude reads it with every message. Propose a shorter version that keeps every rule and fact Claude needs, drops what the code already says, and moves rarely needed detail into skills.")
                            }
                            .buttonStyle(DanteButtonStyle())
                        }
                        Button("Open") { session.open(file: file.url) }.buttonStyle(DanteButtonStyle())
                    } else {
                        Button("Write with Claude") {
                            session.askClaude("Write CLAUDE.md for this project: how to build, test and run it, the layout of the code, conventions to follow, and anything surprising. Keep it under 80 lines; Claude reads it with every message.")
                        }
                        .buttonStyle(DanteButtonStyle())
                    }
                }
            }
        }
    }

    // MARK: Permissions

    private var permissionsCard: some View {
        Card("Permissions") {
            if FileManager.default.fileExists(atPath: workspace.url.appending(path: ".claude/settings.json").path) {
                LinkButton("settings.json") { session.open(file: workspace.url.appending(path: ".claude/settings.json")) }
            }
        } content: {
            let never = workspace.claudeRules.never
            if !never.isEmpty {
                ruleList("Never (from .dante/project.yaml)", never, color: theme.red.color, symbol: "lock.fill")
            }
            if !permissions.deny.isEmpty { ruleList("Denied", permissions.deny, color: theme.red.color, symbol: "nosign") }
            if !permissions.ask.isEmpty { ruleList("Always ask", permissions.ask, color: theme.amber.color, symbol: "hand.raised") }
            if !permissions.allow.isEmpty { ruleList("Allowed without asking", permissions.allow, color: theme.green.color, symbol: "checkmark") }
            if never.isEmpty, permissions.isEmpty {
                Text("No rules yet").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
            }
        }
    }

    private func ruleList(_ title: String, _ rules: [String], color: Color, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.dante(size: 11.5, weight: .semibold)).foregroundStyle(theme.text2.color)
            ForEach(rules.prefix(8), id: \.self) { rule in
                Label {
                    Text(rule).font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text.color).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: symbol).font(.dante(size: 9.5)).foregroundStyle(color)
                }
            }
            if rules.count > 8 {
                Text("+\(rules.count - 8) more").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
            }
        }
    }

    // MARK: Connectors

    private var connectorsCard: some View {
        Card("Connectors") {
            Button {
                Task { await checkServers() }
            } label: {
                if checkingServers { ProgressView().controlSize(.mini) } else { Text(servers == nil ? "Check" : "Check again") }
            }
            .buttonStyle(DanteButtonStyle())
            .disabled(checkingServers || session.claude?.executable == nil)
        } content: {
            if let servers {
                if servers.isEmpty {
                    Text("None set up").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                }
                RowList(data: servers, padding: 8) { server in
                    HStack(spacing: 8) {
                        Circle().fill(server.connected ? theme.green.color : theme.red.color).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.name).font(.dante(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color)
                            Text(server.connected ? "Connected" : server.status).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private func checkServers() async {
        guard let executable = session.claude?.executable else { return }
        checkingServers = true
        let output = await Shell.run([executable, "mcp", "list"], in: workspace.url)
        servers = MCPServer.parse(output.stdout)
        checkingServers = false
    }

    // MARK: Plugins

    private var pluginsCard: some View {
        Card("Plugins") {
            Button {
                Task { await loadPlugins(available: true) }
            } label: {
                if browsing { ProgressView().controlSize(.mini) } else { Text(available == nil ? "Browse" : "Refresh") }
            }
            .buttonStyle(DanteButtonStyle())
            .disabled(browsing || session.claude?.executable == nil)
        } content: {
            if let plugins {
                if plugins.isEmpty {
                    Text("None installed.").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                }
                RowList(data: plugins, padding: 8) { plugin in
                    HStack(spacing: 8) {
                        Circle().fill(plugin.enabled ? theme.green.color : theme.text3.color).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(plugin.name + (plugin.version.map { " " + $0 } ?? "")).font(.dante(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color)
                            Text(plugin.description.isEmpty ? (plugin.marketplace ?? "") : plugin.description).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                        }
                        Spacer()
                        LinkButton(plugin.enabled ? "Disable" : "Enable") {
                            session.typeInTerminal("claude plugin \(plugin.enabled ? "disable" : "enable") \(Shell.quote(plugin.id))")
                        }
                    }
                }
            }
            if let available {
                let fresh = available.filter { candidate in !(plugins ?? []).contains { $0.id == candidate.id } }
                Eyebrow("Available")
                if fresh.isEmpty {
                    Text("Nothing more in your marketplaces").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                }
                RowList(data: Array(fresh.prefix(12)), padding: 8) { plugin in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(plugin.name).font(.dante(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color)
                            Text(plugin.description).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(2)
                        }
                        Spacer()
                        LinkButton("Install…") { session.typeInTerminal("claude plugin install \(Shell.quote(plugin.id))") }
                    }
                }
            }
        }
        .task(id: workspace.revision) { if plugins == nil { await loadPlugins(available: false) } }
    }

    private func loadPlugins(available withAvailable: Bool) async {
        guard let executable = session.claude?.executable else { return }
        if withAvailable { browsing = true }
        let output = await Shell.run([executable, "plugin", "list", "--json"] + (withAvailable ? ["--available"] : []), in: workspace.url)
        let parsed = ClaudePlugin.parse(output.stdout)
        plugins = parsed.installed
        if withAvailable { available = parsed.available }
        browsing = false
    }

    // MARK: Conversations

    private var conversationsCard: some View {
        Card("Recent conversations") {
            EmptyView()
        } content: {
            if conversations.isEmpty {
                Text("None in this project yet.").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
            }
            RowList(data: conversations, padding: 8) { conversation in
                Button {
                    Task { await session.resumeConversation(conversation) }
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(conversation.title).font(.dante(size: 12.5)).foregroundStyle(theme.text.color).lineLimit(1)
                            Text(conversation.date.formatted(.relative(presentation: .named))).font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                        }
                        Spacer()
                        Image(systemName: "arrow.uturn.forward").font(.dante(size: 10)).foregroundStyle(theme.text3.color)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show it in the panel and continue it")
            }
        }
    }
}
