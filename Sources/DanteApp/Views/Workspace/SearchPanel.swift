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
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.text.color)
                            .lineLimit(1)
                        Text("\(references.result.matchCount) in \(references.result.files.count) file\(references.result.files.count == 1 ? "" : "s")")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.text3.color)
                    }
                    Spacer()
                    IconButton(symbol: "xmark", label: "Back to search", size: 10) { search.references = nil }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(theme.text3.color)
                    TextField("Search files", text: $search.query.text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
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
                summary
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown.files) { file in
                        FileHeader(file: file, isCollapsed: search.collapsed.contains(file.path)) {
                            if search.collapsed.contains(file.path) { search.collapsed.remove(file.path) } else { search.collapsed.insert(file.path) }
                        }
                        if !search.collapsed.contains(file.path) {
                            ForEach(file.matches) { match in
                                MatchRow(match: match) { session.open(match, in: file.path) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
        }
        .onChange(of: search.query) { search.run(in: workspace) }
        .onChange(of: session.searchFocusRequest, initial: true) { fieldFocused = true }
    }

    @ViewBuilder
    private var summary: some View {
        let result = search.result
        Group {
            if search.isInvalid {
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
        .font(.system(size: 11.5))
        .foregroundStyle(theme.text3.color)
        .padding(.horizontal, 2)
    }

    private func toggle(_ symbol: String, _ label: String, _ isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
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
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(theme.text3.color)
                    .frame(width: 10)
                Text((file.path as NSString).lastPathComponent)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.text.color)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text((file.path as NSString).deletingLastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text3.color)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 4)
                Text("\(file.matches.count)")
                    .font(.system(size: 10.5, weight: .medium))
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
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(match.line + 1)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.text3.color)
                    .frame(width: 30, alignment: .trailing)
                Text(highlighted)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
            }
            .padding(.leading, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? theme.raised.color : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var highlighted: AttributedString {
        var text = AttributedString(match.preview)
        text.foregroundColor = theme.text2.color
        if let range = Range(match.previewRange, in: match.preview), let target = Range(range, in: text) {
            text[target].foregroundColor = theme.text.color
            text[target].backgroundColor = theme.accent.opacity(0.22).color
        }
        return text
    }
}
