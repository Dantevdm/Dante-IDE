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
                    Text(tool.verb).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text2.color)
                    Text(tool.target(in: claude.root))
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

            if let note = tool.ruleNote {
                Label(note, systemImage: tool.blockedByRule ? "lock.fill" : "flag.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(tool.blockedByRule ? theme.red.color : theme.amber.color)
                    .padding(.leading, 21)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if tool.name == "AskUserQuestion" {
                if tool.isAwaitingApproval {
                    QuestionCard(tool: tool, claude: claude)
                } else {
                    AnsweredQuestions(input: tool.input)
                }
            } else if let change = tool.change, tool.isAwaitingApproval || expanded {
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

            if tool.isAwaitingApproval, tool.name != "AskUserQuestion" {
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
    @Environment(\.isExporting) private var isExporting
    let text: String
    let language: String?

    var body: some View {
        let code = Text(HighlightedCode.attributed(text, language: HighlightedCode.language(forTag: language), theme: theme))
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(theme.syntax.plain.color)
        Group {
            if isExporting {
                // Paper doesn't scroll: long lines wrap.
                code.fixedSize(horizontal: false, vertical: true).padding(10).padding(.trailing, language == nil ? 0 : 40)
            } else {
                ScrollView(.horizontal) {
                    code.textSelection(.enabled).fixedSize().padding(10)
                }
            }
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

/// Claude's clarifying questions, answered by picking options or writing your own.
private struct QuestionCard: View {
    @Environment(\.theme) private var theme
    let tool: ToolActivity
    let claude: ClaudeSession
    @State private var picks: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]

    private var questions: [ClarifyingQuestion] { ClarifyingQuestion.parse(tool.input) }

    private func answer(_ question: ClarifyingQuestion) -> String? {
        var parts = question.options.map(\.label).filter { picks[question.id]?.contains($0) == true }
        if let text = other[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { parts.append(text) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var complete: Bool { questions.allSatisfy { answer($0) != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if !question.header.isEmpty {
                            Text(question.header.uppercased())
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(theme.accent.color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(theme.accentTint.color))
                        }
                        if question.multiSelect {
                            Text("pick any").font(.system(size: 10.5)).foregroundStyle(theme.text3.color)
                        }
                    }
                    Text(question.question)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.text.color)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(question.options) { option in
                        optionRow(option, in: question)
                    }
                    TextField("Something else…", text: Binding(
                        get: { other[question.id] ?? "" },
                        set: { text in
                            other[question.id] = text
                            if !question.multiSelect, !text.isEmpty { picks[question.id] = [] }
                        }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.line2.color))
                }
            }
            HStack(spacing: 8) {
                Button("Answer") {
                    var answers: [String: String] = [:]
                    for question in questions { answers[question.question] = answer(question) }
                    claude.answer(tool.id, answers: answers)
                }
                .buttonStyle(DanteButtonStyle(primary: true))
                .disabled(!complete)
                Button("Skip, use your judgement") {
                    claude.decline(tool.id, message: "The user skipped these questions. Go with your best judgement, and say what you assumed.")
                }
                .buttonStyle(DanteButtonStyle())
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.accentLine.color))
    }

    private func optionRow(_ option: ClarifyingQuestion.Option, in question: ClarifyingQuestion) -> some View {
        let selected = picks[question.id]?.contains(option.label) == true
        return Button {
            var set = picks[question.id] ?? []
            if question.multiSelect {
                if selected { set.remove(option.label) } else { set.insert(option.label) }
            } else {
                set = selected ? [] : [option.label]
                other[question.id] = nil
            }
            picks[question.id] = set
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: question.multiSelect ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? theme.accent.color : theme.text3.color)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.system(size: 12.5)).foregroundStyle(theme.text.color)
                    if !option.description.isEmpty {
                        Text(option.description).font(.system(size: 11.5)).foregroundStyle(theme.text3.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? theme.accentTint.color : theme.raised.color))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// What was asked and answered, once it's done.
private struct AnsweredQuestions: View {
    @Environment(\.theme) private var theme
    let input: JSONValue

    var body: some View {
        let answers = ClarifyingQuestion.answers(in: input)
        if !answers.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(ClarifyingQuestion.parse(input)) { question in
                    if let answer = answers[question.question] {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(question.header.isEmpty ? question.question : question.header)
                                .foregroundStyle(theme.text3.color)
                            Text(answer).foregroundStyle(theme.text.color)
                        }
                        .font(.system(size: 11.5))
                    }
                }
            }
            .padding(.leading, 21)
        }
    }
}

extension EnvironmentValues {
    /// True while a view is drawn for a PDF or print, where nothing can scroll.
    @Entry var isExporting = false
    /// The width a diagram has to fit in when exporting.
    @Entry var exportWidth: CGFloat = 480
}
