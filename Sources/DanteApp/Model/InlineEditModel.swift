import DanteKit
import Foundation
import Observation

/// One ⌘I request: the lines being rewritten, what was asked, and Claude's proposal,
/// which changes nothing until accepted.
@MainActor
@Observable
final class InlineEditModel {
    enum Phase: Equatable {
        case asking
        case working
        case proposed(String)
        case failed(String)
    }

    let document: EditorDocument
    let root: URL
    /// Where the edit goes, and the text there when it started.
    let range: NSRange
    let original: String
    var instruction = ""
    private(set) var phase: Phase = .asking
    /// Bumped to put the cursor in the instruction field.
    private(set) var focusRequest = 0
    private var task: Task<Void, Never>?

    init(document: EditorDocument, root: URL, selection: NSRange) {
        self.document = document
        self.root = root
        let text = document.text as NSString
        let clamped = NSRange(location: min(selection.location, text.length), length: min(selection.length, text.length - min(selection.location, text.length)))
        range = InlineEdit.lineRange(for: clamped, in: text)
        original = text.substring(with: range)
    }

    var proposal: String? {
        if case .proposed(let code) = phase { return code }
        return nil
    }

    var lineSpan: String {
        let text = document.text as NSString
        let first = text.substring(to: min(range.location, text.length)).components(separatedBy: "\n").count
        let last = first + max(original.components(separatedBy: "\n").count - (original.hasSuffix("\n") ? 2 : 1), 0)
        return range.length == 0 ? "line \(first)" : (first == last ? "line \(first)" : "lines \(first)–\(last)")
    }

    func submit() {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, phase != .working else { return }
        let previous = proposal
        let prompt = InlineEdit.prompt(
            instruction: instruction,
            path: ProposedChange.relativePath(of: document.url, in: root),
            language: document.language,
            text: document.text as NSString,
            range: range,
            previous: previous
        )
        phase = .working
        task = Task {
            do {
                let answer = try await ClaudeQuick.text(prompt, system: InlineEdit.system, in: root)
                guard !Task.isCancelled else { return }
                phase = .proposed(InlineEdit.clean(answer, replacing: original))
                self.instruction = ""
                focusRequest += 1
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase == .working { phase = .asking }
    }

    /// Puts the proposal in the document as one undoable change and selects it. Refuses if
    /// the lines changed in the meantime.
    func accept() -> Bool {
        guard let proposal else { return false }
        let text = document.text as NSString
        guard NSMaxRange(range) <= text.length, text.substring(with: range) == original else {
            phase = .failed("The code changed while Claude was working, so the proposal no longer fits. Ask again.")
            return false
        }
        document.text = text.replacingCharacters(in: range, with: proposal)
        document.revealRange = NSRange(location: range.location, length: (proposal as NSString).length)
        return true
    }
}
