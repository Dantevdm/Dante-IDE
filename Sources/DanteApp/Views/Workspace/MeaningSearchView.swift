import DanteKit
import SwiftUI

/// Text or meaning: the switch at the top of the Search panel.
struct SearchModeSwitch: View {
    @Environment(\.theme) private var theme
    @Binding var byMeaning: Bool
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            segment("Text", symbol: "textformat", selected: !byMeaning) { byMeaning = false }
            segment("Meaning", symbol: "sparkle.magnifyingglass", selected: byMeaning) { byMeaning = true }
                .help("Describe what the code does and find it, with an embedding model on this Mac")
        }
        .padding(2)
        .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.line.color))
        .animation(.snappy(duration: 0.25), value: byMeaning)
    }

    private func segment(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.dante(size: 11.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? theme.text.color : theme.text3.color)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 5).fill(theme.card.color)
                            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                            .matchedGeometryEffect(id: "segment", in: namespace)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Search by meaning: a question, the index's state, and the closest pieces of code.
struct MeaningSearchView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    @FocusState private var fieldFocused: Bool

    private var semantic: SemanticState { session.semantic }

    var body: some View {
        @Bindable var semantic = semantic
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle.magnifyingglass").font(.dante(size: 11)).foregroundStyle(theme.accent.color)
                        .symbolEffect(.pulse, isActive: semantic.isSearching)
                    TextField("What does the code do?", text: $semantic.question)
                        .textFieldStyle(.plain)
                        .font(.dante(size: 12.5))
                        .focused($fieldFocused)
                        .onSubmit { semantic.run(delay: .zero) }
                }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(fieldFocused ? theme.accentLine.color : theme.line.color))
                IndexStatusLine(semantic: semantic, session: session)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if semantic.question.isEmpty, semantic.answers.isEmpty, semantic.status == .ready {
                        Examples { semantic.question = $0 }
                    }
                    ForEach(Array(semantic.answers.enumerated()), id: \.element.id) { offset, answer in
                        AnswerRow(answer: answer, best: semantic.answers.first?.hit.score ?? 1, rank: offset) {
                            session.open(file: workspace.url.appending(path: answer.hit.chunk.path), line: answer.hit.chunk.startLine)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
                .opacity(semantic.isSearching || semantic.answered == semantic.question.trimmingCharacters(in: .whitespacesAndNewlines) ? 1 : 0.55)
                .animation(.snappy(duration: 0.3), value: semantic.answers.map(\.id))
            }
        }
        .onChange(of: semantic.question) { semantic.run() }
        .task(id: workspace.revision) {
            // Picks up edits: only changed pieces are embedded again.
            if semantic.status != .unknown { try? await Task.sleep(for: .seconds(2)) }
            guard !Task.isCancelled else { return }
            semantic.refresh(root: workspace.url, files: workspace.files)
        }
        .onAppear { fieldFocused = true }
        .onChange(of: session.searchFocusRequest) { fieldFocused = true }
    }
}

private struct IndexStatusLine: View {
    @Environment(\.theme) private var theme
    let semantic: SemanticState
    let session: Session

    var body: some View {
        Group {
            switch semantic.status {
            case .unknown:
                Text("Opening the index…")
            case .indexing(let done, let total):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .progressViewStyle(.linear)
                        .tint(theme.accent.color)
                        .animation(.smooth, value: done)
                    Text("Reading the code: \(done.formatted()) of \(total.formatted()) pieces, main code first")
                        .monospacedDigit()
                }
                .help("A model on this Mac turns each piece of code into numbers once. Later changes take a moment.")
            case .ready:
                if let index = semantic.index {
                    let shown = semantic.answers.count
                    Text(semantic.answered.isEmpty ? "\(index.chunks.count.formatted()) pieces in \(index.files.formatted()) files · \(index.model)"
                                                   : "\(shown) closest of \(index.chunks.count.formatted()) pieces")
                        .help("Indexed on this Mac with \(index.model). Nothing leaves it.")
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Text(message).foregroundStyle(theme.red.color).fixedSize(horizontal: false, vertical: true)
                    if message.contains("ollama pull") {
                        Button("Type the command in the terminal") {
                            session.showsTerminal = true
                            session.typeInTerminal("ollama pull \(SemanticSearch.suggestedModel)")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.accent.color)
                        .help("Types it for you to run: about 600 MB, once.")
                    }
                }
            }
        }
        .font(.dante(size: 11.5))
        .foregroundStyle(theme.text3.color)
        .padding(.horizontal, 2)
    }
}

/// A few questions to show what kind of search this is.
private struct Examples: View {
    @Environment(\.theme) private var theme
    let pick: (String) -> Void
    private let questions = ["where errors are shown to the user", "how settings are saved", "what happens when the app starts"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask in plain words, like:").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            ForEach(questions, id: \.self) { question in
                Button { pick(question) } label: {
                    Text(question).font(.dante(size: 12)).foregroundStyle(theme.accent.color)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
    }
}

private struct AnswerRow: View {
    @Environment(\.theme) private var theme
    let answer: SemanticState.Answer
    /// The top score, so bars compare within this list.
    let best: Float
    let rank: Int
    let open: () -> Void
    @State private var hovering = false
    @State private var shown = false

    var body: some View {
        let chunk = answer.hit.chunk
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(chunk.symbol ?? (chunk.path as NSString).lastPathComponent)
                        .font(.dante(size: 12.5, weight: .semibold, design: chunk.symbol == nil ? .default : .monospaced))
                        .foregroundStyle(theme.text.color)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Closeness(fraction: CGFloat(max(0, min(1, (answer.hit.score - 0.3) / max(best - 0.3, 0.01)))), shown: shown)
                        .help("How close this is to your question: \(String(format: "%.2f", answer.hit.score))")
                }
                Text("\(chunk.path):\(chunk.startLine)")
                    .font(.dante(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.text3.color)
                    .lineLimit(1)
                    .truncationMode(.head)
                if !answer.preview.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(answer.preview.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line).lineLimit(1).truncationMode(.tail)
                        }
                    }
                        .font(.dante(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.text2.color)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.codeBackground.color, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(8)
            .background(hovering ? theme.raised.color : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open \(chunk.location)")
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 8)
        .onAppear {
            withAnimation(.snappy(duration: 0.35).delay(Double(min(rank, 10)) * 0.035)) { shown = true }
        }
    }
}

/// A short bar that fills to how close a piece is.
private struct Closeness: View {
    @Environment(\.theme) private var theme
    let fraction: CGFloat
    let shown: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(theme.line.color)
            Capsule().fill(theme.accent.color.opacity(0.4 + 0.6 * fraction))
                .frame(width: 34 * (shown ? max(fraction, 0.08) : 0))
        }
        .frame(width: 34, height: 4)
    }
}
