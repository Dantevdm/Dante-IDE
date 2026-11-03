import DanteKit
import SwiftUI

/// Quality › Review: which code files people have read and understood as they are now, who
/// read them, what's been asked of whom, and marking files from here or the editor.
struct ReviewView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, notReviewed, changed, partly, concern, reviewed, askedOfMe
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .notReviewed: "Not yet"
            case .changed: "Changed since"
            case .partly: "Needs another"
            case .concern: "Concerns"
            case .reviewed: "Reviewed"
            case .askedOfMe: "Asked of you"
            }
        }

        var state: CodeReview.State? {
            switch self {
            case .notReviewed: .notReviewed
            case .changed: .changed
            case .partly: .partly
            case .concern: .concern
            case .reviewed: .reviewed
            case .all, .askedOfMe: nil
            }
        }
    }

    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var open: Set<String> = []
    @State private var asking = false
    @State private var concernPath: String?
    @State private var limit = 200

    private var model: ReviewModel { session.review }

    var body: some View {
        AreaPage(eyebrow: nil, title: "Review",
                 subtitle: "Which code files someone has read and understood, as they are now. A mark goes stale when the file changes.") {
            Button("Ask for a review…") { asking = true }
                .buttonStyle(DanteButtonStyle(primary: true))
                .disabled(model.coverage == nil)
                .help("Ask someone to read files, a folder or everything not yet reviewed")
        } content: {
            if let message = model.errorMessage {
                Text(message).font(.dante(size: 12.5)).foregroundStyle(theme.red.color)
            }
            if let coverage = model.coverage {
                if coverage.files.isEmpty {
                    EmptyState(symbol: "eye", title: "No code files to review",
                               message: "Review counts the code files git tracks. Add `review: include:` to .dante/project.yaml for other files.") { EmptyView() }
                } else {
                    overview(coverage)
                    asked(coverage)
                    files(coverage)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task(id: workspace.revision) { await model.load(root: workspace.url, revision: workspace.revision) }
        .sheet(isPresented: $asking) {
            AskForReviewSheet(model: model, folders: model.coverage?.folders().map(\.path).filter { $0 != "." } ?? [],
                              openFile: openPath, root: workspace.url)
        }
    }

    private var openPath: String? {
        workspace.activeDocument.flatMap { ReviewView.relative($0.url, to: workspace.url) }
    }

    static func relative(_ url: URL, to root: URL) -> String? {
        let base = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
    }

    // MARK: Overview

    private func overview(_ coverage: CodeReview.Coverage) -> some View {
        CardGrid(minimum: 320) {
            Card(nil) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(coverage.reviewed)")
                            .font(.dante(size: 34, weight: .semibold).monospacedDigit())
                        Text("of \(coverage.files.count) code files reviewed")
                            .font(.dante(size: 14)).foregroundStyle(theme.text2.color)
                    }
                    ReviewBar(coverage: coverage)
                    FlowChips(items: CodeReview.State.allCases.reversed().filter { coverage.count($0) > 0 }) { state in
                        Button { filter = Filter.allCases.first { $0.state == state } ?? .all } label: {
                            Chip(text: "\(coverage.count(state)) \(Self.label(state))", color: color(state), selected: filter.state == state)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(coverage.required == 1
                         ? "Each file needs one person's eyes. Set `review: required: 2` in .dante/project.yaml for two."
                         : "Each file needs \(coverage.required) people (review: required in .dante/project.yaml).")
                        .font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                }
            }
            Card("People") {
                let people = coverage.people
                if people.isEmpty {
                    Text(coverage.files.contains { !$0.stale.isEmpty }
                         ? "Nobody has read the current version of any file: everything marked has changed since."
                         : "Nobody has marked a file yet. Open a file and press Mark reviewed in the status bar, or mark one below.")
                        .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    RowList(data: people.prefix(6).map { $0 }) { person in
                        HStack(spacing: 10) {
                            ReviewerBadge(name: person.name, current: true)
                            Text(person.name + (person.name == model.reviewer ? " (you)" : ""))
                                .font(.dante(size: 13, weight: .medium))
                            Spacer()
                            if person.concerns > 0 {
                                Text("\(person.concerns) raised").font(.dante(size: 12)).foregroundStyle(theme.red.color)
                            }
                            Text("\(person.current) \(person.current == 1 ? "file" : "files") · \(person.last.formatted(.relative(presentation: .named)))")
                                .font(.dante(size: 12).monospacedDigit()).foregroundStyle(theme.text3.color)
                        }
                    }
                }
                Text("Marks live in \(CodeReview.file), so they travel with git to GitHub, Bitbucket or Azure DevOps and show in pull requests.")
                    .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func asked(_ coverage: CodeReview.Coverage) -> some View {
        let requests = coverage.openRequests
        if !requests.isEmpty {
            Card("Asked for") {
                RowList(data: requests.reversed()) { request in
                    let waiting = coverage.askedOf(request.reviewer).filter { request.covers($0.path) }.count
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        ReviewerBadge(name: request.reviewer, current: false)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(request.by) asked \(request.reviewer == model.reviewer ? "you" : request.reviewer) to read \(Self.scope(request.paths))")
                                .font(.dante(size: 13))
                            if let note = request.note {
                                Text(note).font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                            }
                        }
                        Spacer()
                        Text("\(waiting) to go · \(request.at.formatted(.relative(presentation: .named)))")
                            .font(.dante(size: 12).monospacedDigit()).foregroundStyle(theme.text3.color)
                        if request.reviewer == model.reviewer {
                            LinkButton("Show") { filter = .askedOfMe }
                        }
                    }
                }
            }
        }
    }

    static func scope(_ paths: [String]) -> String {
        if paths.contains("") { return "every code file" }
        if paths.count == 1 { return paths[0] }
        return "\(paths.count) places"
    }

    // MARK: Files

    private func files(_ coverage: CodeReview.Coverage) -> some View {
        let shown = shownFiles(coverage)
        let folders = coverage.folders(shown)
        let expanded = filter != .all || !query.isEmpty
        return Card("Files") {
            HStack(spacing: 8) {
                TextField("Filter", text: $query).textFieldStyle(.roundedBorder).frame(width: 220)
                Text("\(shown.count) \(shown.count == 1 ? "file" : "files")").font(.dante(size: 12).monospacedDigit()).foregroundStyle(theme.text3.color)
            }
        } content: {
            FlowChips(items: Filter.allCases.filter { $0 != .askedOfMe || !(model.reviewer.map(coverage.askedOf) ?? []).isEmpty }) { item in
                Button { filter = item } label: { Chip(text: item.title, selected: filter == item) }.buttonStyle(.plain)
            }
            if shown.isEmpty {
                Text(filter == .all ? "No files match." : "Nothing here: \(filter.title.lowercased()).")
                    .font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(folders.prefix(limit)) { folder in
                    let isOpen = expanded || open.contains(folder.path)
                    folderRow(folder, isOpen: isOpen)
                    if isOpen {
                        ForEach(folder.files) { file in fileRow(file) }
                    }
                }
                if folders.count > limit {
                    LinkButton("Show more folders") { limit += 200 }.padding(.top, 8)
                }
            }
        }
    }

    private func shownFiles(_ coverage: CodeReview.Coverage) -> [CodeReview.FileReview] {
        var files = coverage.files
        if filter == .askedOfMe, let me = model.reviewer {
            files = coverage.askedOf(me)
        } else if let state = filter.state {
            files = files.filter { $0.state == state }
        }
        if !query.isEmpty { files = files.filter { $0.path.localizedCaseInsensitiveContains(query) } }
        return files
    }

    private func folderRow(_ folder: CodeReview.Coverage.Folder, isOpen: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                if open.contains(folder.path) { open.remove(folder.path) } else { open.insert(folder.path) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.dante(size: 10, weight: .semibold)).foregroundStyle(theme.text3.color).frame(width: 12)
                    Image(systemName: "folder").foregroundStyle(theme.text3.color)
                    Text(folder.path).font(.dante(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ProgressBar(fraction: Double(folder.reviewed) / Double(max(1, folder.files.count)), color: theme.green.color)
                .frame(width: 90)
            Text("\(folder.reviewed)/\(folder.files.count)")
                .font(.dante(size: 12).monospacedDigit()).foregroundStyle(theme.text3.color).frame(width: 56, alignment: .trailing)
            Menu {
                Button("Ask someone to read this folder…") { asking = true }
                Button("Mark all \(folder.files.count) as reviewed") {
                    Task { await model.mark(folder.files.map(\.path), .reviewed, root: workspace.url) }
                }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Folder actions")
        }
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Rectangle().fill(theme.line.color).frame(height: 1) }
    }

    private func fileRow(_ file: CodeReview.FileReview) -> some View {
        let mine = model.reviewer.map(file.reviewed(by:)) ?? false
        return HStack(spacing: 10) {
            StatusDot(color: color(file.state))
                .help(Self.label(file.state))
            Button { session.open(file: workspace.url.appending(path: file.path)) } label: {
                Text((file.path as NSString).lastPathComponent)
                    .font(.dante(size: 12.5, design: .monospaced))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Open \(file.path)")
            if let concern = file.current.first(where: { $0.verdict == .concern }) {
                Text(concern.note ?? "Concern raised").font(.dante(size: 12)).foregroundStyle(theme.red.color).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: -4) {
                ForEach(file.current, id: \.by) { mark in ReviewerBadge(name: mark.by, current: true, concern: mark.verdict == .concern) }
                ForEach(file.stale, id: \.by) { mark in ReviewerBadge(name: mark.by, current: false) }
            }
            .help(Self.who(file))
            Button(mine ? "✓ Reviewed" : "Mark reviewed") {
                Task { await model.mark([file.path], mine ? .cleared : .reviewed, root: workspace.url) }
            }
            .buttonStyle(DanteButtonStyle())
            .help(mine ? "You've marked this version. Press to take your mark back." : "You've read and understood this file as it is now")
            Menu {
                Button("Raise a concern…") { concernPath = file.path }
                Button("Walk me through it") { explain(file.path) }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .popover(isPresented: Binding(get: { concernPath == file.path }, set: { if !$0 { concernPath = nil } })) {
                ConcernPopover(path: file.path) { note in
                    concernPath = nil
                    Task { await model.mark([file.path], .concern, note: note, root: workspace.url) }
                }
            }
        }
        .padding(.leading, 28)
        .padding(.vertical, 5)
    }

    private func explain(_ path: String) {
        session.askClaude("""
        Walk me through \(path) so I can review it: what it's for, how it works step by step, what it depends on and \
        what depends on it, and anything a reviewer should look at closely (risky logic, error handling, security). \
        Don't change anything.
        """)
    }

    static func who(_ file: CodeReview.FileReview) -> String {
        var parts = file.current.map { "\($0.by) read this version \($0.at.formatted(.relative(presentation: .named)))" }
        parts += file.stale.map { "\($0.by) read an earlier version" }
        parts += file.askedOf.map { "\($0) has been asked" }
        return parts.isEmpty ? "Nobody has read it yet" : parts.joined(separator: "\n")
    }

    static func label(_ state: CodeReview.State) -> String {
        switch state {
        case .notReviewed: "not yet"
        case .changed: "changed since"
        case .partly: "need another"
        case .reviewed: "reviewed"
        case .concern: "with concerns"
        }
    }

    private func color(_ state: CodeReview.State) -> Color { Self.color(state, theme) }

    static func color(_ state: CodeReview.State, _ theme: Theme) -> Color {
        switch state {
        case .notReviewed: theme.text3.color
        case .changed: theme.amber.color
        case .partly: theme.accent.color
        case .reviewed: theme.green.color
        case .concern: theme.red.color
        }
    }
}

/// The coverage as one bar: reviewed, needing another, with concerns, changed since.
private struct ReviewBar: View {
    @Environment(\.theme) private var theme
    let coverage: CodeReview.Coverage

    var body: some View {
        GeometryReader { proxy in
            let total = CGFloat(max(1, coverage.files.count))
            HStack(spacing: 0) {
                ForEach([CodeReview.State.reviewed, .partly, .concern, .changed], id: \.self) { state in
                    Rectangle().fill(ReviewView.color(state, theme))
                        .frame(width: proxy.size.width * CGFloat(coverage.count(state)) / total)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10)
        .background(theme.track.color)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .animation(.easeOut(duration: 0.4), value: coverage.reviewed)
    }
}

private struct ProgressBar: View {
    @Environment(\.theme) private var theme
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 3).fill(color)
                .frame(width: proxy.size.width * min(1, max(0, fraction)))
        }
        .frame(height: 6)
        .background(RoundedRectangle(cornerRadius: 3).fill(theme.track.color))
    }
}

/// A reviewer's initials: filled for this version, outlined for an earlier one.
struct ReviewerBadge: View {
    @Environment(\.theme) private var theme
    let name: String
    let current: Bool
    var concern = false

    var body: some View {
        let color = concern ? theme.red.color : current ? theme.green.color : theme.text3.color
        Text(CodeReview.initials(name))
            .font(.dante(size: 9.5, weight: .semibold))
            .foregroundStyle(current ? theme.onAccent.color : color)
            .frame(width: 22, height: 22)
            .background(Circle().fill(current ? color : theme.card.color))
            .overlay(Circle().strokeBorder(current ? theme.card.color : color, lineWidth: 1.5))
            .accessibilityLabel(name)
    }
}

/// Chips that wrap onto as many lines as they need.
private struct FlowChips<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}

private struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

private struct ConcernPopover: View {
    @Environment(\.theme) private var theme
    let path: String
    let raise: (String) -> Void
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What should be looked at?").font(.dante(size: 13, weight: .semibold))
            Text((path as NSString).lastPathComponent).font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text3.color)
            TextField("Retries forever when the queue is down", text: $note, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder).frame(width: 320)
            HStack {
                Spacer()
                Button("Raise it") { raise(note) }
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

/// Asks a person to read the open file, a folder, or everything not yet reviewed.
private struct AskForReviewSheet: View {
    enum Scope: Hashable { case everything, folder(String), file(String) }

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let model: ReviewModel
    let folders: [String]
    let openFile: String?
    let root: URL
    @State private var person = ""
    @State private var scope: Scope = .everything
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask for a review").font(.dante(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("Who")
                TextField("Their git name", text: $person).textFieldStyle(.roundedBorder)
                let others = model.people.filter { $0 != model.reviewer }.prefix(8)
                if !others.isEmpty {
                    FlowChips(items: Array(others)) { name in
                        Button { person = name } label: { Chip(text: name, selected: person == name) }.buttonStyle(.plain)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("What")
                Picker("What", selection: $scope) {
                    Text("Every code file").tag(Scope.everything)
                    if let openFile { Text(openFile).tag(Scope.file(openFile)) }
                    ForEach(folders, id: \.self) { Text("\($0)/").tag(Scope.folder($0)) }
                }
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("Note")
                TextField("What to look for (optional)", text: $note, axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.roundedBorder)
            }
            Text("The request is a line in \(CodeReview.file): it reaches them when you push, and they see it here under Asked for.")
                .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(DanteButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Ask") {
                    let paths: [String] = switch scope {
                    case .everything: [""]
                    case .folder(let folder): [folder == "." ? "" : folder]
                    case .file(let file): [file]
                    }
                    Task { await model.request(paths, of: person, note: note.isEmpty ? nil : note, root: root) }
                    dismiss()
                }
                .buttonStyle(DanteButtonStyle(primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(person.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
        .onAppear { if let openFile { scope = .file(openFile) } }
    }
}
