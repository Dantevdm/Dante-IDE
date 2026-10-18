import DanteKit
import SwiftUI

/// Under the composer: the model, how full the conversation's context is (with Compact),
/// and how much of the plan's current five-hour window has gone.
struct ClaudeFooter: View {
    @Environment(\.theme) private var theme
    let session: Session
    let claude: ClaudeSession

    var body: some View {
        HStack(spacing: 8) {
            modelMenu
            if let context = claude.context {
                ContextMeter(used: context.context, window: claude.contextWindow)
                if fraction(context) >= 0.4, claude.state == .idle {
                    Button("Compact") { claude.compact() }
                        .buttonStyle(.plain)
                        .font(.dante(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.accent.color)
                        .help("Have Claude summarise the conversation so far. Every message re-reads the whole conversation, so a shorter one uses less of your plan.")
                }
            }
            Spacer(minLength: 4)
            Button { session.claudeShowsUsage.toggle() } label: { usageLabel }
                .buttonStyle(.plain)
                .help("Your Claude usage on this Mac")
                .popover(isPresented: Bindable(session).claudeShowsUsage, arrowEdge: .top) {
                    UsagePopover(session: session, claude: claude)
                }
        }
        .font(.dante(size: 10.5))
        .foregroundStyle(theme.text3.color)
        .frame(height: 16)
        .task {
            while !Task.isCancelled {
                await session.refreshClaudeUsage()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: claude.state) { _, state in
            if state == .idle { Task { await session.refreshClaudeUsage() } }
        }
    }

    private func fraction(_ usage: TokenUsage) -> Double {
        Double(usage.context) / Double(max(claude.contextWindow, 1))
    }

    private var modelMenu: some View {
        Menu {
            ForEach(Preferences.ClaudeModel.allCases, id: \.self) { model in
                Button {
                    Preferences.shared.claudeModel = model
                    session.applyClaudePreferences()
                } label: {
                    if model == Preferences.shared.claudeModel { Label(model.label, systemImage: "checkmark") } else { Text(model.label) }
                }
            }
            Divider()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "cpu").font(.dante(size: 9.5))
                Text(modelName)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The model for the next message")
    }

    private var modelName: String {
        if Preferences.shared.claudeModel != .default { return Preferences.shared.claudeModel.label }
        guard let model = claude.model?.lowercased() else { return "Default model" }
        for name in ["opus", "sonnet", "haiku"] where model.contains(name) { return name.capitalized }
        return "Default model"
    }

    @ViewBuilder
    private var usageLabel: some View {
        if let window = session.claudeUsage?.current {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.dante(size: 9.5))
                Text("\(ClaudeUsage.short(window.usage.weighted)) · resets \(window.resets.formatted(date: .omitted, time: .shortened))")
                    .monospacedDigit()
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.0percent").font(.dante(size: 9.5))
                Text(session.claudeUsage == nil ? "Usage" : "Fresh window")
            }
        }
    }
}

/// A small ring and percentage for the context window.
struct ContextMeter: View {
    @Environment(\.theme) private var theme
    let used: Int
    let window: Int

    var body: some View {
        let fraction = min(Double(used) / Double(max(window, 1)), 1)
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(theme.line2.color, lineWidth: 2)
                Circle().trim(from: 0, to: fraction)
                    .stroke(color(fraction), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 11, height: 11)
            Text("\(Int((fraction * 100).rounded()))% context").monospacedDigit()
        }
        .help("The conversation fills \(ClaudeUsage.short(used)) of the model’s \(ClaudeUsage.short(window))-token context. Claude Code compacts it on its own when it runs out; compacting sooner or starting a new conversation for a new topic uses less of your plan.")
    }

    private func color(_ fraction: Double) -> Color {
        fraction > 0.75 ? theme.red.color : fraction > 0.5 ? theme.amber.color : theme.accent.color
    }
}

/// The details behind the footer's usage figure, and ways to use less.
struct UsagePopover: View {
    @Environment(\.theme) private var theme
    let session: Session
    let claude: ClaudeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Claude usage").font(.dante(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
                Spacer()
                if let account = session.claudeAccount {
                    Text(account.planName).font(.dante(size: 11.5, weight: .medium)).foregroundStyle(theme.accent.color)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(theme.accentTint.color))
                }
            }
            if let usage = session.claudeUsage {
                windowSection(usage)
                Rectangle().fill(theme.line.color).frame(height: 1)
                fact("Last 7 days", "\(ClaudeUsage.short(usage.week.weighted)) tokens across \(usage.weekMessages) replies")
            } else {
                Text("Reading Claude Code’s logs…").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
            }
            if claude.totalCostUSD > 0 {
                fact("This conversation", claude.totalCostUSD.formatted(.currency(code: "USD").precision(.fractionLength(2))) + " at API prices")
                Text(session.claudeAccount?.plan != nil
                     ? "On a \(session.claudeAccount?.planName ?? "plan") this isn’t charged; it shows how heavy the conversation has been."
                     : "With an API key, this is what the conversation has been billed.")
                    .font(.dante(size: 11)).foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(theme.line.color).frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                Text("Using less").font(.dante(size: 11.5, weight: .semibold)).foregroundStyle(theme.text2.color)
                tip("arrow.down.right.and.arrow.up.left", "Compact long conversations: every message re-reads all of it.")
                tip("square.and.pencil", "Start a new conversation for a new topic.")
                tip("hare", "Pick Haiku for small jobs like renames and explanations.")
                tip("doc.text.magnifyingglass", "Point Claude at the file, so it doesn’t search the project.")
            }
            Text("Estimated from this Mac’s Claude Code logs.")
                .font(.dante(size: 10.5)).foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
    }

    @ViewBuilder
    private func windowSection(_ usage: ClaudeUsage) -> some View {
        if let window = usage.current {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("This 5-hour window").font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                    Spacer()
                    Text("resets \(window.resets.formatted(date: .omitted, time: .shortened))")
                        .font(.dante(size: 12, weight: .medium)).foregroundStyle(theme.text.color)
                }
                Text(ClaudeUsage.short(window.usage.weighted) + " tokens")
                    .font(.dante(size: 22, weight: .semibold)).foregroundStyle(theme.text.color).monospacedDigit()
                if let busiest = usage.busiestWindow, busiest.weighted > 0 {
                    let fraction = min(Double(window.usage.weighted) / Double(busiest.weighted), 1)
                    ProgressView(value: fraction).tint(theme.accent.color)
                    Text(window.usage.weighted >= busiest.weighted ? "Your busiest window this week."
                         : "\(Int((fraction * 100).rounded()))% of your busiest window this week (\(ClaudeUsage.short(busiest.weighted))).")
                        .font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                }
                Text("\(window.messages) replies since \(window.start.formatted(date: .omitted, time: .shortened)), plus \(ClaudeUsage.short(window.usage.cacheRead)) re-read from cache.")
                    .font(.dante(size: 11)).foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("No Claude use in the last five hours: the next message starts a fresh window.")
                .font(.dante(size: 12)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.dante(size: 12)).foregroundStyle(theme.text2.color)
            Spacer()
            Text(value).font(.dante(size: 12)).foregroundStyle(theme.text.color).multilineTextAlignment(.trailing)
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).frame(width: 14)
        }
        .font(.dante(size: 11.5))
        .foregroundStyle(theme.text2.color)
    }
}

/// Earlier conversations in this project, to read again and continue.
struct ConversationHistory: View {
    @Environment(\.theme) private var theme
    let session: Session
    let dismiss: () -> Void
    @State private var conversations: [ClaudeHistory.Conversation]?
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Conversations").font(.dante(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
                Spacer()
                Button {
                    session.claude?.reset()
                    dismiss()
                } label: { Label("New", systemImage: "square.and.pencil") }
                    .buttonStyle(DanteButtonStyle())
            }
            .padding(12)
            TextField("Search conversations", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.dante(size: 12))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Rectangle().fill(theme.line.color).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if let conversations {
                        let shown = filtered(conversations)
                        if shown.isEmpty {
                            Text(conversations.isEmpty ? "No earlier conversations in this project." : "Nothing matches.")
                                .font(.dante(size: 12)).foregroundStyle(theme.text3.color).padding(12)
                        }
                        ForEach(shown) { conversation in
                            row(conversation)
                        }
                    } else {
                        ProgressView().controlSize(.small).padding(16).frame(maxWidth: .infinity)
                    }
                }
                .padding(6)
            }
            .frame(height: 340)
        }
        .frame(width: 340)
        .task { conversations = await session.claudeConversations() }
    }

    private func filtered(_ list: [ClaudeHistory.Conversation]) -> [ClaudeHistory.Conversation] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? list : list.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func row(_ conversation: ClaudeHistory.Conversation) -> some View {
        let current = session.claude?.conversationID == conversation.id
        return Button {
            Task { await session.resumeConversation(conversation) }
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.title.isEmpty ? "Untitled" : conversation.title)
                    .font(.dante(size: 12.5, weight: current ? .semibold : .regular))
                    .foregroundStyle(theme.text.color)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(conversation.date.formatted(.relative(presentation: .named))) · \(conversation.detail)")
                    .font(.dante(size: 11)).foregroundStyle(theme.text3.color).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(current ? theme.accentTint.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(current)
    }
}
