import DanteKit
import SwiftUI

/// The Claude pair panel: the conversation, proposed changes to approve, and the composer.
struct ClaudePanel: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let claude: ClaudeSession

    var body: some View {
        VStack(spacing: 0) {
            header
            ContextChips(session: session, workspace: workspace)
            Rectangle().fill(theme.line.color).frame(height: 1)
            Transcript(session: session, claude: claude)
            if claude.needsLogin {
                SignInBanner(session: session)
            }
            ApplyAllBar(claude: claude)
            Composer(session: session, claude: claude)
        }
        .background(theme.panel.color)
        .modifier(AcceptsAttachments(session: session))
    }

    private var header: some View {
        HStack(spacing: 8) {
            ClaudeMark(isWorking: claude.state == .working)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude").font(.dante(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
                Text(subtitle).font(.dante(size: 11)).foregroundStyle(theme.text3.color)
            }
            Spacer()
            Button {
                Preferences.shared.claudeAsksFirst.toggle()
            } label: {
                Label("Ask first", systemImage: Preferences.shared.claudeAsksFirst ? "questionmark.bubble.fill" : "questionmark.bubble")
                    .font(.dante(size: 11, weight: .medium))
                    .foregroundStyle(Preferences.shared.claudeAsksFirst ? theme.accent.color : theme.text3.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Preferences.shared.claudeAsksFirst ? theme.accentTint.color : .clear))
                    .overlay(Capsule().strokeBorder(Preferences.shared.claudeAsksFirst ? theme.accentLine.color : theme.line2.color))
            }
            .buttonStyle(.plain)
            .help(Preferences.shared.claudeAsksFirst
                  ? "On: Claude asks clarifying questions before starting anything ambiguous. Click to let it go straight ahead."
                  : "Off: Claude goes straight ahead. Click to have it ask clarifying questions first.")
            IconButton(symbol: "clock.arrow.circlepath", label: "Earlier conversations") { session.claudeShowsHistory.toggle() }
                .popover(isPresented: Bindable(session).claudeShowsHistory, arrowEdge: .bottom) {
                    ConversationHistory(session: session) { session.claudeShowsHistory = false }
                }
            IconButton(symbol: "square.and.pencil", label: "New conversation (the current one stays in Earlier conversations)") { claude.reset() }
                .disabled(claude.items.isEmpty)
            IconButton(symbol: "sidebar.right", label: "Hide Claude (⌥⌘L)") {
                withAnimation(.snappy(duration: 0.22)) { session.showsClaude = false }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    private var subtitle: String {
        switch claude.state {
        case .unavailable: "Not available"
        case .working where !claude.pendingApprovals.isEmpty: "Waiting for you"
        case .working: "Working…"
        case .idle: "Proposes, you apply"
        }
    }
}

/// Over the composer while file edits wait: which files, Apply all, and the option to apply
/// the rest of the turn's edits as they come (Undo this turn still puts them back).
private struct ApplyAllBar: View {
    @Environment(\.theme) private var theme
    let claude: ClaudeSession

    var body: some View {
        let edits = claude.pendingApprovals.filter { $0.change != nil }
        if claude.appliesRestOfTurn, claude.state == .working {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle").foregroundStyle(theme.green.color)
                Text("Applying this turn’s edits as they come").foregroundStyle(theme.text2.color)
                Spacer()
                Button("Stop") { claude.stopApplyingRestOfTurn() }.buttonStyle(.plain).foregroundStyle(theme.accent.color)
            }
            .font(.dante(size: 11.5))
            .padding(.horizontal, 14)
            .padding(.top, 8)
        } else if !edits.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(edits.count == 1 ? "1 edit waiting" : "\(edits.count) edits waiting")
                        .font(.dante(size: 11.5, weight: .semibold)).foregroundStyle(theme.text.color)
                    Text(files(edits)).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                }
                HStack(spacing: 6) {
                    Button(edits.count == 1 ? "Apply" : "Apply all") { claude.applyAll() }
                        .buttonStyle(DanteButtonStyle(primary: true))
                    Button("Apply the rest of this turn") { claude.applyAll(restOfTurn: true) }
                        .buttonStyle(DanteButtonStyle())
                        .help("Applies these and every edit Claude makes until the turn ends. Undo this turn puts them all back.")
                    Spacer()
                    Button("Decline all") { for edit in edits { claude.decline(edit.id) } }
                        .buttonStyle(.plain).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card.color))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.accentLine.color))
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    private func files(_ edits: [ToolActivity]) -> String {
        var names: [String] = []
        for edit in edits { if let name = edit.change?.url.lastPathComponent, !names.contains(name) { names.append(name) } }
        return names.joined(separator: ", ")
    }
}

/// A small mark that breathes while Claude works.
private struct ClaudeMark: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isWorking: Bool
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(theme.accentTint.color)
            .overlay(
                Image(systemName: "sparkle")
                    .font(.dante(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent.color)
                    .scaleEffect(isWorking && pulse && !reduceMotion ? 1.18 : 1)
                    .rotationEffect(.degrees(isWorking && pulse && !reduceMotion ? 20 : 0))
            )
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(theme.accentLine.color))
            .frame(width: 26, height: 26)
            .onChange(of: isWorking, initial: true) { _, working in
                if working {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { pulse = false }
                }
            }
            .accessibilityHidden(true)
    }
}

/// What Claude can see: the phase and the open file.
private struct ContextChips: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 6) {
            if let current = workspace.lifecycle.currentIndex {
                chip("\(workspace.lifecycle.phases[current]) phase", symbol: "circle.circle")
            }
            if let document = workspace.activeDocument {
                chip(document.name, symbol: "doc.text")
                    .help("Claude sees which file is open and where the cursor is")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func chip(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.dante(size: 11))
            .foregroundStyle(theme.text2.color)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.card.color))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.line.color))
    }
}

private struct Transcript: View {
    @Environment(\.theme) private var theme
    let session: Session
    let claude: ClaudeSession

    var body: some View {
        if claude.items.isEmpty {
            EmptyConversation(session: session, claude: claude)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                // Not lazy: a lazy stack re-estimates row heights as text streams in, which
                // makes the conversation jump up and down.
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Self.segments(claude.items)) { segment in
                        switch segment {
                        case .item(let item):
                            TranscriptRow(item: item, claude: claude)
                        case .tools(let tools):
                            ToolGroup(tools: tools, claude: claude)
                        }
                    }
                    if claude.state == .working, claude.pendingApprovals.isEmpty {
                        ThinkingDots().padding(.leading, 2)
                    }
                    ForEach(claude.queued) { message in
                        QueuedRow(message: message) { claude.cancelQueued(message.id) }
                    }
                }
                .padding(14)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
        }
    }
}

extension Transcript {
    enum Segment: Identifiable {
        case item(TranscriptItem)
        /// Three or more finished tool calls in a row with nothing to review, shown as one line.
        case tools([ToolActivity])

        var id: String {
            switch self {
            case .item(let item): item.id
            case .tools(let tools): "group-" + (tools.first?.id ?? "")
            }
        }
    }

    static func segments(_ items: [TranscriptItem]) -> [Segment] {
        var segments: [Segment] = []
        var run: [TranscriptItem] = []
        func flush() {
            if run.count >= 3 {
                segments.append(.tools(run.compactMap { if case .tool(let tool) = $0.content { tool } else { nil } }))
            } else {
                segments += run.map(Segment.item)
            }
            run = []
        }
        for item in items {
            if case .tool(let tool) = item.content, tool.status == .done, tool.change == nil, tool.ruleNote == nil, tool.name != "AskUserQuestion" {
                run.append(item)
            } else {
                flush()
                segments.append(.item(item))
            }
        }
        flush()
        return segments
    }
}

/// Finished tool calls folded into one line: "Read 4 files, ran 2 commands". Click to list them.
private struct ToolGroup: View {
    @Environment(\.theme) private var theme
    let tools: [ToolActivity]
    let claude: ClaudeSession
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark").font(.dante(size: 10, weight: .bold)).foregroundStyle(theme.green.color).frame(width: 14)
                    Text(summary).font(.dante(size: 12, weight: .medium)).foregroundStyle(theme.text2.color).lineLimit(1)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.dante(size: 9, weight: .semibold)).foregroundStyle(theme.text3.color)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tools, id: \.id) { tool in
                        ToolRow(tool: tool, claude: claude)
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(theme.line.color).frame(width: 1) }
            }
        }
    }

    private var summary: String {
        var counts: [(String, Int)] = []
        func add(_ label: String) {
            if let index = counts.firstIndex(where: { $0.0 == label }) { counts[index].1 += 1 } else { counts.append((label, 1)) }
        }
        for tool in tools {
            switch tool.name {
            case "Read": add("file read")
            case "Bash": add("command")
            case "Grep", "Glob": add("search")
            case "WebFetch", "WebSearch": add("web lookup")
            default: add("tool call")
            }
        }
        return counts.prefix(3).map { "\($0.1) \($0.0)\($0.1 == 1 ? "" : "s")" }.joined(separator: ", ")
            .replacingOccurrences(of: "searchs", with: "searches")
    }
}

private struct EmptyConversation: View {
    @Environment(\.theme) private var theme
    let session: Session
    let claude: ClaudeSession

    var body: some View {
        VStack(spacing: 14) {
            if case .unavailable(let reason) = claude.state {
                Image(systemName: "exclamationmark.triangle").font(.dante(size: 20)).foregroundStyle(theme.amber.color)
                Text(reason).font(.dante(size: 12)).foregroundStyle(theme.text2.color).multilineTextAlignment(.center)
            } else {
                Text("Ask about the code, or hand Claude a task. You review every change before it lands.")
                    .font(.dante(size: 12))
                    .foregroundStyle(theme.text3.color)
                    .multilineTextAlignment(.center)
                VStack(spacing: 6) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) { session.askClaude(suggestion) }
                            .buttonStyle(SuggestionButtonStyle())
                    }
                }
            }
        }
        .padding(24)
    }

    private var suggestions: [String] {
        var list = ["Explain how this project is put together"]
        if let workspace = session.workspace {
            if !workspace.lifecycle.hasSpec {
                list.append("Draft a .dante/project.yaml for this project")
            } else if let current = workspace.lifecycle.currentIndex {
                list.append("What should I do next in the \(workspace.lifecycle.phases[current]) phase?")
            }
            if let document = workspace.activeDocument {
                list.append(document.kind.opensAsText ? "Write tests for \(document.name)" : "Summarise \(document.name)")
            }
        }
        return list
    }
}

private struct SuggestionButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.dante(size: 12))
            .foregroundStyle(theme.text.color)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? theme.raised.color : theme.card.color))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.line.color))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

private struct ThinkingDots: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(theme.accent.color)
                        .frame(width: 5, height: 5)
                        .opacity(reduceMotion ? 0.6 : 0.3 + 0.7 * max(0, sin(time * 4 - Double(index) * 0.7)))
                }
            }
        }
        .accessibilityLabel("Claude is working")
    }
}

private struct TranscriptRow: View {
    @Environment(\.theme) private var theme
    let item: TranscriptItem
    let claude: ClaudeSession

    /// Under a message whose turn changed files: undo all of them at once.
    @ViewBuilder
    private var undoControl: some View {
        if let checkpoint = claude.checkpoints[item.id], !checkpoint.files.isEmpty {
            let count = checkpoint.files.count
            if checkpoint.undone {
                Label("Changes undone", systemImage: "arrow.uturn.backward")
                    .font(.dante(size: 11)).foregroundStyle(theme.text3.color)
            } else {
                Button {
                    claude.undoTurn(item.id)
                } label: {
                    Label("Undo this turn (\(count) file\(count == 1 ? "" : "s"))", systemImage: "arrow.uturn.backward")
                        .font(.dante(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(claude.state == .working ? theme.text3.color : theme.accent.color)
                .disabled(claude.state == .working)
                .help(checkpoint.files.map { ProposedChange.relativePath(of: URL(filePath: $0), in: claude.root) }.joined(separator: "\n")
                      + (checkpoint.ranCommands ? "\nCommands Claude ran aren’t undone." : ""))
            }
        }
    }

    var body: some View {
        switch item.content {
        case .user(let text, let attachments):
            VStack(alignment: .leading, spacing: 6) {
                if !attachments.isEmpty {
                    FlowLayout(spacing: 5) {
                        ForEach(attachments, id: \.self) { name in
                            Label(name, systemImage: AttachmentChip.symbol(for: name))
                                .font(.dante(size: 11))
                                .foregroundStyle(theme.text2.color)
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(theme.card.color))
                                .overlay(Capsule().strokeBorder(theme.line.color))
                        }
                    }
                }
                if !text.isEmpty {
                    Text(text)
                        .font(.dante(size: 12.5))
                        .foregroundStyle(theme.text.color)
                        .textSelection(.enabled)
                }
            }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.raised.color))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.line.color))
                .overlay(alignment: .bottomTrailing) { undoControl.offset(y: 22) }
                .padding(.bottom, claude.checkpoints[item.id]?.files.isEmpty == false ? 22 : 0)
        case .assistant(let text):
            if !text.isEmpty { MarkdownText(text: text) }
        case .tool(let tool):
            ToolRow(tool: tool, claude: claude)
        case .notice(let text, let isError):
            Label(text, systemImage: isError ? "exclamationmark.circle" : "info.circle")
                .font(.dante(size: 11.5))
                .foregroundStyle(isError ? theme.red.color : theme.text3.color)
                .textSelection(.enabled)
        }
    }
}

/// Shown when Claude Code reports it isn't signed in.
private struct SignInBanner: View {
    @Environment(\.theme) private var theme
    let session: Session

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.dante(size: 15))
                .foregroundStyle(theme.amber.color)
            VStack(alignment: .leading, spacing: 8) {
                Text("Claude Code isn’t signed in")
                    .font(.dante(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.text.color)
                Text("Sign in once in the terminal below, then ask again.")
                    .font(.dante(size: 11.5))
                    .foregroundStyle(theme.text2.color)
                Button("Sign in") { session.signInToClaude() }
                    .buttonStyle(DanteButtonStyle(primary: true))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.line.color))
        .padding(.horizontal, 12)
    }
}

/// A message waiting for Claude to finish the current turn.
private struct QueuedRow: View {
    @Environment(\.theme) private var theme
    let message: ClaudeSession.QueuedMessage
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
            VStack(alignment: .leading, spacing: 3) {
                Text("Queued · sends when Claude finishes").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                Text(message.text).font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).lineLimit(3)
            }
            Spacer(minLength: 4)
            IconButton(symbol: "xmark", label: "Don’t send", size: 9.5, action: cancel)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.line.color, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}
