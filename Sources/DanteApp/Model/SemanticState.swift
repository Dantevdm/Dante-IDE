import DanteKit
import Foundation
import Observation

/// Search by meaning in one window: the index (built and kept up to date in the background)
/// and the latest question's answers.
@MainActor
@Observable
final class SemanticState {
    enum IndexStatus: Equatable {
        case unknown
        case indexing(done: Int, total: Int)
        case ready
        case failed(String)
    }

    struct Answer: Identifiable, Equatable {
        var hit: SemanticIndex.Hit
        /// The declaration line and a few after it, as they are on disk.
        var preview: [String]
        var id: String { hit.id }
    }

    var question = ""
    private(set) var answers: [Answer] = []
    private(set) var status: IndexStatus = .unknown
    private(set) var index: SemanticIndex?
    private(set) var isSearching = false
    /// The question the answers are for, so a stale list isn't shown as current.
    private(set) var answered = ""
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var root: URL?

    private let search = SemanticSearch()

    var isIndexing: Bool { if case .indexing = status { true } else { false } }

    /// Builds or refreshes the index; only pieces that changed are embedded again.
    func refresh(root: URL, files: [String]) {
        if self.root != root {
            self.root = root
            index = SemanticIndex.load(for: root)
            if index != nil { status = .ready }
        }
        guard !isIndexing else { return }
        indexTask = Task { [search] in
            let progress: @Sendable (Int, Int) -> Void = { done, total in
                Task { @MainActor [weak self] in
                    // Small updates aren't worth a progress bar.
                    if total > 64 || self?.index == nil { self?.status = .indexing(done: done, total: total) }
                }
            }
            do {
                let updated = try await search.update(root: root, files: files, progress: progress)
                guard !Task.isCancelled else { return }
                index = updated
                status = .ready
                if !question.isEmpty, answered != question { run(delay: .zero) }
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    /// Asks after a pause, so typing doesn't embed every keystroke.
    func run(delay: Duration = .milliseconds(450)) {
        searchTask?.cancel()
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            answers = []
            answered = ""
            isSearching = false
            return
        }
        guard let index, let root else { return }
        isSearching = true
        searchTask = Task { [search] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            do {
                let hits = try await search.search(question, in: index, limit: 24)
                let answers = await Task.detached { hits.map { Answer(hit: $0, preview: Self.preview($0, root: root)) } }.value
                guard !Task.isCancelled else { return }
                self.answers = answers
                answered = question
            } catch {
                status = .failed(error.localizedDescription)
            }
            isSearching = false
        }
    }

    nonisolated static func preview(_ hit: SemanticIndex.Hit, root: URL) -> [String] {
        guard let text = try? String(contentsOf: root.appending(path: hit.chunk.path), encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: "\n")
        let start = max(hit.chunk.startLine - 1, 0)
        let end = min(hit.chunk.endLine, lines.count)
        guard start < end else { return [] }
        // Skip the doc comment to the declaration when there is one.
        let body = lines[start..<end]
        // Otherwise skip closing braces and blank lines left from the piece before.
        let symbolLine = hit.chunk.symbol.flatMap { name in body.firstIndex { $0.contains(name) } }
            ?? body.firstIndex { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.allSatisfy { "{}()[];,".contains($0) }
            } ?? start
        let shown = lines[symbolLine..<min(symbolLine + 3, end)].map { $0.replacingOccurrences(of: "\t", with: "    ") }
        let indent = shown.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " }.count }.min() ?? 0
        return shown.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }
    }
}
