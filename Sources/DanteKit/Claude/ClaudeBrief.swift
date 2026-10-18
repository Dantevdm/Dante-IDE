import Foundation

/// What Dante tells Claude about the project: a system prompt describing the `.dante`
/// format and the current phase, and per-message context about what's on screen.
@MainActor
public enum ClaudeBrief {
    /// One part of the system prompt, with where it comes from, for the Spec area's
    /// "What Claude gets" list.
    public struct Section: Equatable, Sendable, Identifiable {
        public var title: String
        public var source: String
        public var text: String
        public var id: String { title }

        /// A rough token count: about four characters per token for English prose.
        public var estimatedTokens: Int { max(1, text.count / 4) }
    }

    /// Always added: choices go through AskUserQuestion, which Dante shows as options to click.
    public static let offeringChoices = """
    # Offering choices
    When you end a turn by asking the user to pick between options (which skills to write, which fix to apply, which approach to take), ask with the AskUserQuestion tool instead of a numbered list in prose: Dante shows its options as buttons, so the user doesn't have to type. Use multiSelect when several can be picked, keep labels short and put the detail in each option's description. Up to four options per question; split longer lists into two questions or keep only the strongest four.
    """

    /// Added when local models are on: Claude orchestrates, delegates and checks.
    public static let delegation = """
    # Delegating to local models
    You're the orchestrator. The `delegate` tool (from the dante MCP server) hands a self-contained job to a model running on the user's Mac, which saves their Claude usage. Use it for work a smaller model does well: condensing long logs, diffs or files you only need the gist of (summary), sorting many failures or errors (triage), first drafts of boilerplate, fixtures or repetitive tests (draft), and prose (writing). Put everything the job needs in the prompt; the local model can't read files or run tools. Always check what comes back, fix it or redo it yourself if it's wrong, and say briefly when you delegated. Don't delegate design decisions, subtle bugs, security-sensitive code or anything needing the whole codebase in mind.
    """

    /// Added to the system prompt while "Ask questions first" is on.
    public static let clarifyingQuestions = """
    # Clarifying questions
    Get it right the first time. Before starting a request that is ambiguous, underspecified, or has several reasonable readings, ask the user with the AskUserQuestion tool and wait for the answers. Ask everything you need in one go (up to four questions), give 2–4 concrete options each with the one you recommend first, and say briefly what each option means for the result. Don't ask what you can find out from the code, the .dante folder or git history; look first. For small, clear requests, just do them.
    """

    public static func systemPrompt(for workspace: Workspace?) -> String {
        sections(for: workspace).map(\.text).joined(separator: "\n\n")
    }

    public static func sections(for workspace: Workspace?) -> [Section] {
        var sections = [
            Section(title: "How Dante works", source: "built in", text:
                "You are working inside Dante, a native macOS IDE. The user sees your conversation in a panel beside the code."),
            Section(title: "Pair mode", source: "built in", text:
                "You are a pair, not an autopilot. The user reviews every file change as a diff and every command before it runs. Make focused edits with the Edit tool, and say briefly what each change does and why."),
        ]
        guard let workspace else { return sections }
        let rules = workspace.claudeRules
        if !rules.isEmpty {
            var parts: [String] = []
            if !rules.propose.isEmpty { parts.append("propose changes in \(rules.propose.joined(separator: ", "))") }
            if !rules.flag.isEmpty { parts.append("call out any change to \(rules.flag.joined(separator: ", ")) and explain why it's needed") }
            if !rules.never.isEmpty { parts.append("never read or change \(rules.never.joined(separator: ", "))") }
            sections.append(Section(title: "Rules for Claude", source: "project.yaml › claude", text: "This project's rules for you (.dante/project.yaml): " + parts.joined(separator: "; ") + "."))
        }
        return sections
    }

    /// Hidden context sent with a message: the open file and cursor line.
    public static func context(workspace: Workspace, line: Int?, diagnostics: [LSPDiagnostic] = []) -> String? {
        guard let document = workspace.activeDocument else { return nil }
        let path = ProposedChange.relativePath(of: document.url, in: workspace.url)
        guard document.kind.opensAsText else {
            return "The user is looking at \(path) (\(document.kind.title.lowercased())) in a viewer tab."
        }
        let position = line.map { ", cursor on line \($0)" } ?? ""
        let unsaved = document.isDirty ? " It has unsaved edits, so the file on disk may differ from what the user sees." : ""
        var text = "The user has \(path) open in the editor\(position).\(unsaved)"
        let problems = diagnostics.filter { $0.severity <= .warning }
        if !problems.isEmpty {
            let shown = problems.prefix(10).map { "- line \($0.range.start.line + 1), \($0.severity == .error ? "error" : "warning"): \($0.message)" }
            let more = problems.count > 10 ? "\n- and \(problems.count - 10) more" : ""
            text += "\nThe language server reports these problems in it:\n" + shown.joined(separator: "\n") + more
        }
        return text
    }
}
