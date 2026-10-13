import DanteKit
import Foundation

/// Working on a task with Claude: each task gets its own branch and its own conversation,
/// both remembered on the task in tasks.yaml (`branch:` and `conversation:`).
extension Session {
    func workOn(_ task: PlanTask) async {
        guard let workspace, let claude else { return }
        do {
            try workspace.tasks.setWorkingWithClaude(task.id, true)
            if task.state == .ready { try workspace.tasks.move(task.id, to: .inProgress) }
        } catch {
            errorMessage = "Couldn’t update tasks.yaml: \(error.localizedDescription)"
        }
        area = .code
        showsClaude = true

        if git.isRepository, !(git.status?.isNewRepository ?? true) {
            let branch = task.extra["branch"] ?? TaskBranch.name(for: task)
            if git.status?.branch != branch {
                await git.loadBranches()
                if let existing = git.branches.first(where: { !$0.isRemote && $0.name == branch }) {
                    await git.checkout(existing)
                } else {
                    await git.createBranch(branch)
                }
            }
            if git.error == nil, task.extra["branch"] == nil { try? workspace.tasks.setField(task.id, "branch", branch) }
        }

        if let conversation = task.extra["conversation"], conversation != claude.conversationID {
            if await resumeConversation(id: conversation) { focusClaude(); return }
        } else if task.extra["conversation"] != nil {
            focusClaude()
            return
        }
        claude.reset()
        claudeTaskLink = task.id
        var message = "Let's work on \(task.id): \(task.title)."
        if let spec = task.spec { message += " The spec is .dante/\(spec); read it first." }
        if let note = task.note { message += " Note: \(note)" }
        message += " Propose a short plan before changing any files."
        askClaude(message)
    }

    func linkConversation(_ id: String) {
        guard let task = claudeTaskLink, let workspace else { return }
        claudeTaskLink = nil
        try? workspace.tasks.setField(task, "conversation", id)
    }
}
