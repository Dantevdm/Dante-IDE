import DanteKit
import SwiftUI

/// The message box under the conversation. Return sends; ⌥Return adds a line.
struct Composer: View {
    @Environment(\.theme) private var theme
    let session: Session
    let claude: ClaudeSession
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.text.color)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit(send)
                    .disabled(isUnavailable)
                    .padding(.vertical, 2)

                if claude.state == .working {
                    Button(action: claude.interrupt) {
                        Image(systemName: "stop.fill").font(.system(size: 9))
                            .frame(width: 24, height: 24)
                            .foregroundStyle(theme.text.color)
                            .background(Circle().fill(theme.raised.color))
                            .overlay(Circle().strokeBorder(theme.line2.color))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop (⌘.)")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                            .frame(width: 24, height: 24)
                            .foregroundStyle(canSend ? theme.onAccent.color : theme.text3.color)
                            .background(Circle().fill(canSend ? theme.accent.color : theme.raised.color))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send (↩)")
                }
            }
            .padding(.leading, 11)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.card.color))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(focused ? theme.accentLine.color : theme.line2.color)
            )

            HStack(spacing: 6) {
                Image(systemName: "hand.raised").font(.system(size: 9.5))
                Text("Claude asks before every edit and command.")
                Spacer(minLength: 0)
                if claude.totalCostUSD > 0 {
                    Text(claude.totalCostUSD, format: .currency(code: "USD").precision(.fractionLength(2)))
                        .help("Cost of this conversation")
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(theme.text3.color)
        }
        .padding(12)
        .onChange(of: session.claudeFocusRequest) { focused = true }
    }

    private var isUnavailable: Bool {
        if case .unavailable = claude.state { true } else { false }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && claude.state == .idle
    }

    private var placeholder: String {
        claude.items.isEmpty ? "Ask Claude…" : "Reply to Claude…"
    }

    private func send() {
        guard canSend else { return }
        session.askClaude(draft)
        draft = ""
    }
}
