import DanteKit
import SwiftUI

/// One tool call: a one-line summary, plus the diff or command to approve when Claude asks.
struct ToolRow: View {
    @Environment(\.theme) private var theme
    let tool: ToolActivity
    let claude: ClaudeSession
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if tool.change != nil, !tool.isAwaitingApproval { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    statusIcon.frame(width: 14)
                    Text(verb).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text2.color)
                    Text(target)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(theme.text3.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let change = tool.change {
                        DiffStat(added: change.added, removed: change.removed)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tool.change != nil && !tool.isAwaitingApproval ? (expanded ? "Hide changes" : "Show changes") : "")

            if let change = tool.change, tool.isAwaitingApproval || expanded {
                DiffCard(change: change)
            } else if tool.isAwaitingApproval, let command = tool.input["command"]?.string {
                CodeBlock(text: command, language: "shell")
            } else if tool.isAwaitingApproval {
                CodeBlock(text: tool.input.jsonLine, language: nil)
            }

            if case .failed(let message) = tool.status, !message.isEmpty {
                Text(message.prefix(400))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.red.color)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .padding(.leading, 21)
            }

            if tool.isAwaitingApproval {
                ApprovalBar(tool: tool, claude: claude)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch tool.status {
        case .running:
            ProgressView().controlSize(.mini)
        case .awaitingApproval:
            Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(theme.amber.color)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.green.color)
        case .declined:
            Image(systemName: "nosign").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.text3.color)
        case .failed:
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.red.color)
        }
    }

    private var verb: String {
        let resolved = !tool.isAwaitingApproval && tool.status != .running
        switch tool.name {
        case "Read": return "Read"
        case "Edit", "MultiEdit": return tool.status == .declined ? "Declined edit" : (resolved ? "Edited" : "Edit")
        case "Write": return tool.status == .declined ? "Declined" : (tool.change?.isNewFile == true ? (resolved ? "Created" : "Create") : (resolved ? "Wrote" : "Write"))
        case "Bash": return tool.status == .declined ? "Didn’t run" : (resolved ? "Ran" : "Run")
        case "Grep": return "Searched for"
        case "Glob": return "Listed"
        case "WebFetch": return "Fetched"
        case "WebSearch": return "Searched the web for"
        case "TodoWrite": return "Updated its to-do list"
        case "Task", "Agent": return "Delegated"
        default: return tool.name
        }
    }

    private var target: String {
        let input = tool.input
        if let path = input["file_path"]?.string ?? input["notebook_path"]?.string {
            return ProposedChange.relativePath(of: URL(filePath: path), in: claude.root)
        }
        if let command = input["command"]?.string {
            return command.split(separator: "\n").first.map(String.init) ?? command
        }
        return input["pattern"]?.string ?? input["url"]?.string ?? input["query"]?.string ?? input["description"]?.string ?? ""
    }
}

private struct ApprovalBar: View {
    @Environment(\.theme) private var theme
    let tool: ToolActivity
    let claude: ClaudeSession

    var body: some View {
        HStack(spacing: 8) {
            Button(approveTitle) { claude.approve(tool.id) }
                .buttonStyle(DanteButtonStyle(primary: true))
                .keyboardShortcut(isFirst ? KeyboardShortcut(.return, modifiers: .command) : nil)
                .disabled(tool.change?.applies == false)
            Button(declineTitle) { claude.decline(tool.id) }
                .buttonStyle(DanteButtonStyle())
            Spacer(minLength: 0)
            if tool.change?.applies == false {
                Text("No longer matches the file").font(.system(size: 11)).foregroundStyle(theme.amber.color)
            } else if isFirst {
                Text("⌘↩").font(.system(size: 11)).foregroundStyle(theme.text3.color)
            }
        }
    }

    /// Only the oldest pending request answers to ⌘↩.
    private var isFirst: Bool { claude.pendingApprovals.first?.id == tool.id }

    private var approveTitle: String {
        switch tool.name {
        case "Bash": "Run"
        case "Edit", "MultiEdit", "Write": "Apply"
        default: "Allow"
        }
    }

    private var declineTitle: String {
        tool.name == "Bash" ? "Don’t run" : "Decline"
    }
}

struct DiffStat: View {
    @Environment(\.theme) private var theme
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 5) {
            Text("+\(added)").foregroundStyle(theme.green.color)
            Text("−\(removed)").foregroundStyle(theme.red.color)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
    }
}

/// A proposed change as a diff: file path, then numbered lines tinted by kind.
struct DiffCard: View {
    @Environment(\.theme) private var theme
    let change: ProposedChange

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: change.isNewFile ? "doc.badge.plus" : "doc.text")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.text3.color)
                Text(change.displayPath)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.text.color)
                    .lineLimit(1)
                    .truncationMode(.head)
                if change.isNewFile {
                    Text("new file").font(.system(size: 10.5)).foregroundStyle(theme.green.color)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Rectangle().fill(theme.line.color).frame(height: 1)

            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(change.lines.enumerated()), id: \.offset) { _, line in
                        DiffLineRow(line: line)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.codeBackground.color))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.line.color))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct DiffLineRow: View {
    @Environment(\.theme) private var theme
    let line: DiffLine

    var body: some View {
        if line.kind == .gap {
            Text("⋯")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.text3.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 44)
                .padding(.vertical, 2)
        } else {
            HStack(spacing: 0) {
                Text(number)
                    .frame(width: 30, alignment: .trailing)
                    .foregroundStyle(theme.lineNumber.color)
                Text(marker)
                    .frame(width: 16)
                    .foregroundStyle(markerColor)
                Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(theme.text.color)
                    .fixedSize()
                    .padding(.trailing, 10)
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
        }
    }

    private var number: String {
        (line.kind == .removed ? line.oldNumber : line.newNumber).map(String.init) ?? ""
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        default: ""
        }
    }

    private var markerColor: Color {
        line.kind == .added ? theme.green.color : theme.red.color
    }

    private var background: Color {
        switch line.kind {
        case .added: theme.green.opacity(0.1).color
        case .removed: theme.red.opacity(0.09).color
        default: .clear
        }
    }
}

struct CodeBlock: View {
    @Environment(\.theme) private var theme
    let text: String
    let language: String?

    var body: some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(theme.text.color)
                .textSelection(.enabled)
                .fixedSize()
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.codeBackground.color))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.line.color))
        .overlay(alignment: .topTrailing) {
            if let language {
                Text(language).font(.system(size: 9.5)).foregroundStyle(theme.text3.color).padding(6)
            }
        }
    }
}
