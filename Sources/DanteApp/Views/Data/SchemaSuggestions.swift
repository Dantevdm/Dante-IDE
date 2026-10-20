import DanteKit
import SwiftUI

/// What could be better about a database, from its SQL and the code that queries it: each
/// suggestion with why, where, the SQL that fixes it, and asking the agent to make the change.
struct SchemaSuggestions: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let advice: [SchemaAdvice]
    /// Rows shown before "Show all".
    var limit = 6
    @State private var showsAll = false
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if advice.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal").foregroundStyle(theme.green.color)
                    Text("Nothing to suggest: keys are indexed and the queries Dante can read look fine.")
                        .font(.dante(size: 11.5)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(Array((showsAll ? advice : Array(advice.prefix(limit))).enumerated()), id: \.element.id) { index, item in
                    SuggestionRow(item: item, copied: copied == item.id) {
                        if let fix = item.fix { copy(fix, item.id) }
                    } open: {
                        if let file = item.file { session.open(file: workspace.url.appending(path: file), line: item.line ?? 1) }
                    }
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
                    .animation(.snappy.delay(Double(index) * 0.03), value: showsAll)
                }
                if advice.count > limit {
                    Button(showsAll ? "Show fewer" : "Show all \(advice.count)") { withAnimation(.snappy) { showsAll.toggle() } }
                        .buttonStyle(.plain)
                        .font(.dante(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.accent.color)
                }
                Button {
                    session.askClaude(Self.prompt(for: advice))
                } label: {
                    ClaudeLabel("Ask \(session.agentName) to make these changes").frame(maxWidth: .infinity)
                }
                .buttonStyle(DanteButtonStyle())
                .help("Schema changes go in a new migration in the project's own tool; code changes are proposed as edits for you to approve")
            }
        }
    }

    /// For the agent: every suggestion with its place and SQL, and how to go about it.
    static func prompt(for advice: [SchemaAdvice]) -> String {
        let list = advice.map { item in
            var line = "- \(item.title): \(item.detail)"
            if let file = item.file { line += " (\(file)\(item.line.map { ":\($0)" } ?? ""))" }
            if let fix = item.fix { line += "\n  SQL: \(fix)" }
            return line
        }.joined(separator: "\n")
        return """
        Dante found these possible improvements to the database, from the repo's SQL and the code that queries it. \
        Check each against the code first (Dante can't see table sizes or every query), skip any that don't hold, and say why. \
        Write the schema changes as one new migration in the project's migration tool (never edit applied migrations), \
        and fix the code ones in place. Ask before changing a column's type on a table that may hold data.

        \(list)
        """
    }

    private func copy(_ text: String, _ id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.snappy) { copied = id }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if copied == id { withAnimation(.snappy) { copied = nil } }
        }
    }
}

private struct SuggestionRow: View {
    @Environment(\.theme) private var theme
    let item: SchemaAdvice
    let copied: Bool
    let copy: () -> Void
    let open: () -> Void
    @State private var hovering = false

    private var tint: Color {
        switch item.weight {
        case .warning: theme.amber.color
        case .suggestion: theme.accent.color
        case .note: theme.text3.color
        }
    }

    private var symbol: String {
        switch item.kind {
        case .foreignKeyIndex, .filterIndex: "bolt.horizontal"
        case .primaryKey: "key"
        case .money: "dollarsign.circle"
        case .timeZone: "clock"
        case .selectStar: "asterisk"
        case .queryInLoop: "arrow.triangle.2.circlepath"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.dante(size: 10.5)).foregroundStyle(tint).frame(width: 14)
                Text(item.title).font(.dante(size: 12, weight: .medium)).foregroundStyle(theme.text.color).lineLimit(2)
                Spacer(minLength: 4)
                if item.fix != nil {
                    Button(action: copy) {
                        Label(copied ? "Copied" : "SQL", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.dante(size: 10.5))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copied ? theme.green.color : theme.text3.color)
                    .help(item.fix ?? "")
                }
            }
            Text(item.detail).font(.dante(size: 11)).foregroundStyle(theme.text2.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
            if let file = item.file {
                Button(action: open) {
                    Text("\((file as NSString).lastPathComponent)\(item.line.map { ":\($0)" } ?? "")")
                        .font(.dante(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.text3.color)
                }
                .buttonStyle(.plain)
                .padding(.leading, 20)
                .help("Open \(file)")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? theme.raised.color : theme.raised.color.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5).fill(tint.opacity(item.weight == .note ? 0.4 : 0.85)).frame(width: 3).padding(.vertical, 8)
        }
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.18), value: hovering)
    }
}
