import AppKit
import DanteEditor
import DanteKit
import PDFKit

/// The terminal panel's tabs.
extension Session {
    /// The tab in front; the first one until another is picked.
    var selectedTerminal: UUID {
        get { terminalTabs.first { $0.id == selectedTerminalID }?.id ?? terminalTabs[0].id }
        set { selectedTerminalID = newValue }
    }

    func newTerminal() {
        let tab = TerminalTab()
        terminalTabs.append(tab)
        selectedTerminal = tab.id
        showsTerminal = true
    }

    /// Closes a shell. Closing the last one hides the panel and leaves a fresh shell for next time.
    func closeTerminal(_ id: UUID) {
        guard let index = terminalTabs.firstIndex(where: { $0.id == id }) else { return }
        terminalTabs.remove(at: index)
        if terminalTabs.isEmpty {
            terminalTabs = [TerminalTab()]
            showsTerminal = false
        }
        if !terminalTabs.contains(where: { $0.id == selectedTerminalID }) {
            selectedTerminal = terminalTabs[min(index, terminalTabs.count - 1)].id
        }
    }

    func selectTerminal(offset: Int) {
        guard let index = terminalTabs.firstIndex(where: { $0.id == selectedTerminal }) else { return }
        selectedTerminal = terminalTabs[(index + offset + terminalTabs.count) % terminalTabs.count].id
    }

    /// Starts Claude Code's sign-in in the terminal; the next message starts a fresh session.
    func signInToClaude() {
        guard let claude, let executable = claude.executable else { return }
        claude.reset()
        runInTerminal("'\(executable.replacingOccurrences(of: "'", with: "'\\''"))' auth login")
    }

    func focusClaude() {
        showsClaude = true
        claudeFocusRequest += 1
    }

    /// Sends a message to Claude with what's on screen as context, and any attached files.
    /// `instructions` go with the message but aren't shown in the transcript, for long prompts
    /// Dante writes on the user's behalf.
    func askClaude(_ text: String, instructions: String? = nil, attachments extra: [Attachment] = []) {
        guard let claude, let workspace else { return }
        showsClaude = true
        let diagnostics = workspace.activeDocument.flatMap { languages?.diagnostics(for: $0) } ?? []
        let brief = ClaudeBrief.context(workspace: workspace, line: cursor.line, diagnostics: diagnostics)
        applyClaudePreferences(to: claude)
        claude.send(text, context: [instructions, brief].compactMap { $0 }.joined(separator: "\n\n"),
                    attachments: claudeAttachments + extra)
        claudeAttachments = []
    }

    /// Reads files for the next message to Claude. Files that can't be read are reported.
    func attach(_ urls: [URL]) async {
        let fresh = urls.filter { url in !claudeAttachments.contains { $0.url == url } }
        guard !fresh.isEmpty else { return }
        showsClaude = true
        attachmentsLoading += fresh.count
        defer { attachmentsLoading -= fresh.count }
        for url in fresh {
            do {
                claudeAttachments.append(try await Attachment.load(url))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        claudeFocusRequest += 1
    }

    /// An image from the pasteboard or a drag, saved outside the project.
    func attachImage(_ data: Data) {
        do {
            let folder = FileManager.default.temporaryDirectory.appending(path: "Dante attachments")
            claudeAttachments.append(try Attachment.image(data: data, savingIn: folder))
            showsClaude = true
            claudeFocusRequest += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Asks Claude to work on a file: attached, with an instruction.
    func askClaude(_ text: String, about url: URL) {
        Task {
            do {
                askClaude(text, attachments: [try await Attachment.load(url)])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
