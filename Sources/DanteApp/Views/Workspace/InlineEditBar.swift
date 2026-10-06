import DanteKit
import SwiftUI

/// ⌘I in the editor: say what to change, see Claude's proposal as a diff, accept or refine it.
struct InlineEditBar: View {
    @Environment(\.theme) private var theme
    let session: Session
    @Bindable var model: InlineEditModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.accent.color)
                Text(model.range.length == 0 ? "Claude writes code at \(model.lineSpan)" : "Claude edits \(model.lineSpan)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.text2.color)
                Spacer()
                IconButton(symbol: "xmark", label: "Close (Esc)", size: 9.5) { close() }
            }

            if let proposal = model.proposal {
                let lines = LineDiff.lines(old: model.original, new: proposal, context: 2)
                GeometryReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                DiffLineRow(line: line)
                            }
                        }
                        .padding(.vertical, 4)
                        // Short lines sit at the left, not centred in the box.
                        .frame(minWidth: proxy.size.width, alignment: .leading)
                    }
                }
                // Tall enough for the lines (and a horizontal scroller), up to a dozen.
                .frame(height: CGFloat(min(lines.count, 12)) * 19 + 22)
                .background(theme.codeBackground.color, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line.color))
            }

            HStack(spacing: 8) {
                TextField(model.proposal == nil ? "Describe the change…" : "Ask for changes, or press ⌘↩ to accept",
                          text: $model.instruction, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .lineLimit(1...4)
                    .focused($fieldFocused)
                    .disabled(model.phase == .working)
                    .onSubmit(submit)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(fieldFocused ? theme.accentLine.color : theme.line.color))
                switch model.phase {
                case .working:
                    ProgressView().controlSize(.small)
                    Text("Claude is writing…").font(.system(size: 11.5)).foregroundStyle(theme.text3.color)
                    Button("Stop") { model.cancel() }.buttonStyle(DanteButtonStyle())
                case .proposed:
                    Button("Reject") { close() }.buttonStyle(DanteButtonStyle())
                    Button("Accept") { accept() }
                        .buttonStyle(DanteButtonStyle(primary: true))
                        .keyboardShortcut(.return, modifiers: .command)
                case .asking, .failed:
                    Button("Ask") { model.submit() }
                        .buttonStyle(DanteButtonStyle(primary: true))
                        .disabled(model.instruction.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if case .failed(let message) = model.phase {
                Text(message).font(.system(size: 11.5)).foregroundStyle(theme.red.color).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(theme.panel.color)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line.color).frame(height: 1) }
        .onExitCommand { close() }
        .onAppear { fieldFocused = true }
        .onChange(of: model.focusRequest) { fieldFocused = true }
    }

    /// Return sends the instruction; with nothing typed under a proposal, it accepts.
    private func submit() {
        if model.proposal != nil, model.instruction.trimmingCharacters(in: .whitespaces).isEmpty {
            accept()
        } else {
            model.submit()
        }
    }

    private func accept() {
        if model.accept() { session.inlineEdit = nil }
    }

    private func close() {
        model.cancel()
        session.inlineEdit = nil
    }
}
