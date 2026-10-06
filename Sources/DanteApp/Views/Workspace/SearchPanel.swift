import DanteKit
import SwiftUI

/// Find in Project, in the sidebar where the explorer sits.
struct SearchPanel: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    @FocusState private var fieldFocused: Bool

    private var search: SearchState { session.search }

    var body: some View {
        @Bindable var search = search
        let shown = search.references?.result ?? search.result
        VStack(alignment: .leading, spacing: 0) {
            if let references = search.references {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("References to \(references.symbol)")
                            .font(.dante(size: 12.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.text.color)
                            .lineLimit(1)
                        Text("\(references.result.matchCount) in \(references.result.files.count) file\(references.result.files.count == 1 ? "" : "s")")
                            .font(.dante(size: 11.5))
                            .foregroundStyle(theme.text3.color)
                    }
                    Spacer()
                    IconButton(symbol: "xmark", label: "Back to search", size: 10) { search.references = nil }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 2) {
                        replaceToggle
                        VStack(spacing: 6) {
                            searchField
                            if search.showsReplace { replaceField }
                        }
                    }
                    summary
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let replacing = search.showsReplace && search.references == nil
                    ForEach(shown.files) { file in
                        FileHeader(file: file, isCollapsed: search.collapsed.contains(file.path),
                                   replace: replacing ? { session.replaceMatches(in: file) } : nil) {
                            if search.collapsed.contains(file.path) { search.collapsed.remove(file.path) } else { search.collapsed.insert(file.path) }
                        }
                        if !search.collapsed.contains(file.path) {
                            ForEach(file.matches.filter { !replacing || !search.isDismissed($0, in: file.path) }) { match in
                                MatchRow(
                                    match: match,
                                    replacement: replacing ? ProjectReplace.preview(of: match.matched, query: search.query, replacement: search.replacement) : nil,
                                    open: { session.open(match, in: file.path) },
                                    replace: { session.replaceMatch(match, in: file.path) },
                                    dismiss: { search.dismissed.insert("\(file.path)#\(match.id)") }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
        }
        .onChange(of: search.query) {
            search.replaceNotice = nil
            search.run(in: workspace)
        }
        .onChange(of: search.replacement) { search.replaceNotice = nil }
        .onChange(of: session.searchFocusRequest, initial: true) { fieldFocused = true }
    }

    private var replaceToggle: some View {
        Button { search.showsReplace.toggle() } label: {
            Image(systemName: search.showsReplace ? "chevron.down" : "chevron.right")
                .font(.dante(size: 9, weight: .semibold))
                .foregroundStyle(theme.text3.color)
                .frame(width: 16, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(search.showsReplace ? "Hide Replace" : "Replace")
        .accessibilityLabel(search.showsReplace ? "Hide Replace" : "Show Replace")
    }

    private var searchField: some View {
        @Bindable var search = search
        return HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
            TextField("Search files", text: $search.query.text)
                .textFieldStyle(.plain)
                .font(.dante(size: 12.5))
                .focused($fieldFocused)
                .onSubmit { search.run(in: workspace, delay: .zero) }
            toggle("textformat", "Match case", $search.query.caseSensitive)
            toggle("character.cursor.ibeam", "Whole word", $search.query.wholeWord)
            toggle("asterisk", "Regular expression", $search.query.isRegex)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(search.isInvalid ? theme.red.color : (fieldFocused ? theme.accentLine.color : theme.line.color)))
    }

    private var replaceField: some View {
        @Bindable var search = search
        let count = search.replaceable.reduce(0) { $0 + $1.ids.count }
        return HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.turn.down.right").font(.dante(size: 10.5)).foregroundStyle(theme.text3.color)
                TextField("Replace", text: $search.replacement)
                    .textFieldStyle(.plain)
                    .font(.dante(size: 12.5))
                    .onSubmit { session.replaceAllInProject() }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line.color))
            Button("Replace All") { session.replaceAllInProject() }
                .buttonStyle(.plain)
                .font(.dante(size: 11.5, weight: .medium))
                .foregroundStyle(count > 0 ? theme.onAccent.color : theme.text3.color)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(count > 0 ? theme.accent.color : theme.raised.color, in: RoundedRectangle(cornerRadius: 6))
                .disabled(count == 0)
                .help("Replace every match shown (⌥⌘↩)")
                .keyboardShortcut(.return, modifiers: [.command, .option])
        }
    }

    @ViewBuilder
    private var summary: some View {
        let result = search.result
        Group {
            if let notice = search.replaceNotice {
                Text(notice).foregroundStyle(theme.green.color)
            } else if search.isInvalid {
                Text("That regular expression doesn’t compile.").foregroundStyle(theme.red.color)
            } else if search.query.text.isEmpty {
                Text("Searches every file in the project except ignored ones.")
            } else if search.isSearching {
                Text("Searching…")
            } else if result.matchCount == 0 {
                Text("No results.")
            } else {
                let files = result.files.count
                Text("\(result.truncated ? "First " : "")\(result.matchCount) result\(result.matchCount == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s")")
            }
        }
        .font(.dante(size: 11.5))
        .foregroundStyle(theme.text3.color)
        .padding(.horizontal, 2)
    }

    private func toggle(_ symbol: String, _ label: String, _ isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Image(systemName: symbol)
                .font(.dante(size: 10.5, weight: .medium))
                .frame(width: 20, height: 20)
                .foregroundStyle(isOn.wrappedValue ? theme.accent.color : theme.text3.color)
                .background(isOn.wrappedValue ? theme.accent.opacity(0.14).color : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }
}

private struct FileHeader: View {
    @Environment(\.theme) private var theme
    let file: ProjectSearch.FileMatches
    let isCollapsed: Bool
    var replace: (() -> Void)?
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        header
            .overlay(alignment: .trailing) {
                if let replace {
                    IconButton(symbol: "arrow.turn.down.right", label: "Replace in \((file.path as NSString).lastPathComponent)", size: 10, action: replace)
                        .background(theme.panel.color, in: RoundedRectangle(cornerRadius: 6))
                        .opacity(hovering ? 1 : 0)
                }
            }
            .onHover { hovering = $0 }
    }

    private var header: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.dante(size: 8.5, weight: .semibold))
                    .foregroundStyle(theme.text3.color)
                    .frame(width: 10)
                Text((file.path as NSString).lastPathComponent)
                    .font(.dante(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.text.color)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text((file.path as NSString).deletingLastPathComponent)
                    .font(.dante(size: 11))
                    .foregroundStyle(theme.text3.color)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 4)
                Text("\(file.matches.count)")
                    .font(.dante(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.text2.color)
                    .padding(.horizontal, 5)
                    .background(theme.raised.color, in: Capsule())
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(file.path)
    }
}

private struct MatchRow: View {
    @Environment(\.theme) private var theme
    let match: ProjectSearch.Match
    /// What the match becomes, while Replace is open.
    var replacement: String?
    let open: () -> Void
    let replace: () -> Void
    let dismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(match.line + 1)")
                        .font(.dante(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.text3.color)
                        .frame(width: 30, alignment: .trailing)
                    Text(highlighted)
                        .font(.dante(size: 11.5, design: .monospaced))
                        .lineLimit(1)
                }
                .padding(.leading, 6)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(hovering ? theme.raised.color : .clear, in: RoundedRectangle(cornerRadius: 4))
        // Over the end of the preview rather than beside it, so previews keep the width.
        .overlay(alignment: .trailing) {
            if replacement != nil {
                HStack(spacing: 0) {
                    IconButton(symbol: "arrow.turn.down.right", label: "Replace this match", size: 9.5, action: replace)
                    IconButton(symbol: "xmark", label: "Leave this match out", size: 9.5, action: dismiss)
                }
                .frame(height: 20)
                .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 4))
                .opacity(hovering ? 1 : 0)
            }
        }
        .onHover { hovering = $0 }
    }

    private var highlighted: AttributedString {
        var text = AttributedString(match.preview)
        text.foregroundColor = theme.text2.color
        guard let range = Range(match.previewRange, in: match.preview), let target = Range(range, in: text) else { return text }
        guard let replacement else {
            text[target].foregroundColor = theme.text.color
            text[target].backgroundColor = theme.accent.opacity(0.22).color
            return text
        }
        // Old text struck through, the new text after it.
        text[target].foregroundColor = theme.red.color
        text[target].strikethroughStyle = .single
        text[target].backgroundColor = theme.red.opacity(0.12).color
        var added = AttributedString(replacement)
        added.foregroundColor = theme.text.color
        added.backgroundColor = theme.greenTint.color
        text.insert(added, at: target.upperBound)
        return text
    }
}
