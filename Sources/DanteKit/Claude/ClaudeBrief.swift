import Foundation

/// What Dante tells Claude about the project: a system prompt describing the `.dante`
/// format and the current phase, and per-message context about what's on screen.
@MainActor
public enum ClaudeBrief {
    public static func systemPrompt(for workspace: Workspace?) -> String {
        var lines = [
            "You are working inside Dante, a macOS IDE organised around the software lifecycle: Discover, Define, Design, Build, Test, Release, Operate.",
            "The project's plan lives in `.dante/` at the repository root: `project.yaml` (name, `lifecycle.current`, optional `lifecycle.phases`), `tasks.yaml`, and markdown specs and decisions. Read them when they're relevant, and keep them current when your work changes what they describe.",
            "You are a pair, not an autopilot. The user reviews every file change as a diff and every command before it runs. Make focused edits with the Edit tool, and say briefly what each change does and why.",
            "Phases are guidance, not gates: favour work that fits the current phase, but don't refuse other work.",
        ]
        if let workspace {
            let lifecycle = workspace.lifecycle
            if let current = lifecycle.currentIndex {
                lines.append("The project is in the \(lifecycle.phases[current]) phase (\(current + 1) of \(lifecycle.phases.count): \(lifecycle.phases.joined(separator: ", "))).")
            } else if !lifecycle.hasSpec {
                lines.append("This project has no `.dante/project.yaml` yet. If the user asks you to set the project up, draft one from the README, docs, code and git history, and let them review it.")
            }
        }
        return lines.joined(separator: "\n\n")
    }

    /// Hidden context sent with a message: the open file and cursor line.
    public static func context(workspace: Workspace, line: Int?) -> String? {
        guard let document = workspace.activeDocument else { return nil }
        let path = ProposedChange.relativePath(of: document.url, in: workspace.url)
        let position = line.map { ", cursor on line \($0)" } ?? ""
        let unsaved = document.isDirty ? " It has unsaved edits, so the file on disk may differ from what the user sees." : ""
        return "The user has \(path) open in the editor\(position).\(unsaved)"
    }
}
