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
            Composer(session: session, claude: claude)
        }
        .background(theme.panel.color)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ClaudeMark(isWorking: claude.state == .working)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(theme.text3.color)
            }
            Spacer()
            IconButton(symbol: "square.and.pencil", label: "New conversation") { claude.reset() }
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
                    .font(.system(size: 12, weight: .semibold))
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
            .font(.system(size: 11))
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
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(claude.items) { item in
                        TranscriptRow(item: item, claude: claude)
                    }
                    if claude.state == .working, claude.pendingApprovals.isEmpty {
                        ThinkingDots().padding(.leading, 2)
                    }
                }
                .padding(14)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
        }
    }
}

private struct EmptyConversation: View {
    @Environment(\.theme) private var theme
    let session: Session
    let claude: ClaudeSession

    var body: some View {
        VStack(spacing: 14) {
            if case .unavailable(let reason) = claude.state {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 20)).foregroundStyle(theme.amber.color)
                Text(reason).font(.system(size: 12)).foregroundStyle(theme.text2.color).multilineTextAlignment(.center)
            } else {
                Text("Ask about the code, or hand Claude a task. You review every change before it lands.")
                    .font(.system(size: 12))
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
                list.append("Write tests for \(document.name)")
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
            .font(.system(size: 12))
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

    var body: some View {
        switch item.content {
        case .user(let text):
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.text.color)
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.raised.color))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.line.color))
        case .assistant(let text):
            if !text.isEmpty { MarkdownText(text: text) }
        case .tool(let tool):
            ToolRow(tool: tool, claude: claude)
        case .notice(let text, let isError):
            Label(text, systemImage: isError ? "exclamationmark.circle" : "info.circle")
                .font(.system(size: 11.5))
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
                .font(.system(size: 15))
                .foregroundStyle(theme.amber.color)
            VStack(alignment: .leading, spacing: 8) {
                Text("Claude Code isn’t signed in")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.text.color)
                Text("Sign in once in the terminal below, then ask again.")
                    .font(.system(size: 11.5))
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
