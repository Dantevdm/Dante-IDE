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
            Section(title: "How Dante works", source: "built in", text: [
                "You are working inside Dante, a macOS IDE organised around the software lifecycle: Discover, Define, Design, Build, Test, Release, Operate.",
                "The project's plan lives in `.dante/` at the repository root: `project.yaml` (name, `lifecycle.current`, optional `lifecycle.phases`), `tasks.yaml`, and markdown specs and decisions. Read them when they're relevant, and keep them current when your work changes what they describe.",
            ].joined(separator: "\n\n")),
            Section(title: "Pair mode", source: "built in", text: [
                "You are a pair, not an autopilot. The user reviews every file change as a diff and every command before it runs. Make focused edits with the Edit tool, and say briefly what each change does and why.",
                "Phases are guidance, not gates: favour work that fits the current phase, but don't refuse other work.",
            ].joined(separator: "\n\n")),
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
        let lifecycle = workspace.lifecycle
        if let current = lifecycle.currentIndex {
            let phase = lifecycle.phases[current]
            sections.append(Section(
                title: "Current phase: \(phase)",
                source: "project.yaml › lifecycle",
                text: "The project is in the \(phase) phase (\(current + 1) of \(lifecycle.phases.count): \(lifecycle.phases.joined(separator: ", ")))."
            ))
        } else if !lifecycle.hasSpec {
            sections.append(Section(
                title: "Setting up",
                source: "no project.yaml",
                text: "This project has no `.dante/project.yaml` yet. If the user asks you to set the project up, draft one from the README, docs, code and git history, and let them review it."
            ))
        }
        return sections
    }

    /// Hidden context sent with a message: the open file and cursor line.
    public static func context(workspace: Workspace, line: Int?, diagnostics: [LSPDiagnostic] = []) -> String? {
        guard let document = workspace.activeDocument else { return nil }
        let path = ProposedChange.relativePath(of: document.url, in: workspace.url)
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
