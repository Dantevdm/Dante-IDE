import DanteKit
import Foundation

/// Usage and history for the Claude panel.
extension Session {
    /// Re-reads usage from Claude Code's transcripts, and the account, which can change when
    /// the user signs Claude Code in to another one.
    func refreshClaudeUsage() async {
        let usage = await Task.detached(priority: .utility) { ClaudeUsage.load() }.value
        claudeUsage = usage
        await refreshClaudeAccount()
    }

    /// The next message to a conversation started under another account goes to a new process.
    func refreshClaudeAccount() async {
        guard let path = claude?.executable else { return }
        guard let account = await ClaudeAccount.load(executable: path) else { return }
        claudeAccount = account
        claude?.account = account.identity
    }

    func claudeConversations() async -> [ClaudeHistory.Conversation] {
        guard let root = workspace?.url else { return [] }
        return await Task.detached(priority: .userInitiated) { ClaudeHistory.conversations(for: root) }.value
    }

    /// Shows an earlier conversation in the panel; the next message continues it.
    func resumeConversation(_ conversation: ClaudeHistory.Conversation) async {
        _ = await resumeConversation(id: conversation.id)
    }

    /// False when Claude Code no longer has the transcript.
    func resumeConversation(id: String) async -> Bool {
        guard let root = workspace?.url, let claude else { return false }
        let url = ClaudeHistory.transcriptURL(for: id, root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let items = await Task.detached(priority: .userInitiated) {
            (try? String(contentsOf: url, encoding: .utf8)).map(ClaudeHistory.items(fromTranscript:)) ?? []
        }.value
        claude.resume(conversation: id, items: items)
        showsClaude = true
        return true
    }
}
