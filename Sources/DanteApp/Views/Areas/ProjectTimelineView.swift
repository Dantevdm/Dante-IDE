import DanteKit
import SwiftUI

/// Timeline: commits, tags, Claude Code sessions, test runs and CI runs in one stream,
/// grouped by day. Each row opens what it's about.
struct ProjectTimelineView: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    let session: Session
    let workspace: Workspace

    @State private var events: [TimelineEvent] = []
    @State private var loading = true
    @State private var kind: TimelineEvent.Kind?
    @AppStorage("timelineShowsQuickClaude") private var showsQuick = false
    @State private var limit = 150

    private var shown: [TimelineEvent] {
        events.filter { (kind == nil || $0.kind == kind) && (showsQuick || !$0.isQuick) }
    }

    var body: some View {
        AreaPage(
            eyebrow: "History",
            title: "Timeline",
            subtitle: "What happened to the project, newest first: commits and tags, Claude Code sessions, test runs and CI."
        ) {
            IconButton(symbol: "arrow.clockwise", label: "Reload") { Task { await load() } }
        } content: {
            HStack(spacing: 14) {
                Picker("Show", selection: $kind) {
                    Text("Everything").tag(TimelineEvent.Kind?.none)
                    ForEach(TimelineEvent.Kind.allCases, id: \.self) { kind in
                        Text(label(kind)).tag(Optional(kind))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Toggle("Quick Claude runs", isOn: $showsQuick)
                    .toggleStyle(.checkbox)
                    .font(.dante(size: 12))
                    .fixedSize()
                    .help("One-prompt sessions, such as commit messages and inline edits")
                Spacer()
            }
            if loading, events.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the history…").font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
                }
            } else if shown.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath", title: "Nothing here yet",
                           message: "Commits, Claude Code sessions in this folder, test runs from Tests and CI runs from GitHub show up here.") {}
            } else {
                let visible = Array(shown.prefix(limit))
                ForEach(days(visible), id: \.day) { group in
                    Card(dayTitle(group.day)) {
                        RowList(data: group.events, padding: 7) { event in
                            row(event)
                        }
                    }
                }
                if shown.count > limit {
                    Button("Show \(min(150, shown.count - limit)) more") { limit += 150 }
                        .buttonStyle(DanteButtonStyle())
                }
            }
        }
        .task(id: workspace.url) { await load() }
    }

    private func load() async {
        loading = true
        let root = workspace.url
        let ci: [CIRun] = if case .success(let runs) = await CIRun.load(projectRoot: root, limit: 30) { runs } else { [] }
        events = await Timeline.load(root: root, tests: TestRecord.load(for: root), ci: ci)
        loading = false
    }

    private func row(_ event: TimelineEvent) -> some View {
        Button { open(event) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(event.date.formatted(date: .omitted, time: .shortened))
                    .font(.dante(size: 11, design: .monospaced))
                    .foregroundStyle(theme.text3.color)
                    .frame(width: 64, alignment: .leading)
                Image(systemName: symbol(event))
                    .font(.dante(size: 11))
                    .foregroundStyle(color(event))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.dante(size: 12.5, weight: event.kind == .release ? .semibold : .regular))
                        .foregroundStyle(theme.text.color)
                        .lineLimit(2)
                    if let detail = event.detail {
                        Text(detail).font(.dante(size: 11)).foregroundStyle(theme.text3.color).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(label(event.kind)).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help(event))
    }

    private func open(_ event: TimelineEvent) {
        guard let reference = event.reference else { return }
        switch event.kind {
        case .commit, .release: session.runInTerminal("git show --stat \(reference)")
        case .claude: session.runInTerminal("claude --resume \(reference)")
        case .ci: if let url = URL(string: reference) { openURL(url) }
        case .tests: session.area = .tests
        }
    }

    private func help(_ event: TimelineEvent) -> String {
        switch event.kind {
        case .commit, .release: "Show it in the terminal"
        case .claude: "Resume this session in the terminal"
        case .ci: "Open the run on GitHub"
        case .tests: "Open Tests"
        }
    }

    private func label(_ kind: TimelineEvent.Kind) -> String {
        switch kind {
        case .commit: "Commits"
        case .release: "Releases"
        case .claude: "Claude"
        case .tests: "Tests"
        case .ci: "CI"
        }
    }

    private func symbol(_ event: TimelineEvent) -> String {
        switch event.kind {
        case .commit: "smallcircle.filled.circle"
        case .release: "tag.fill"
        case .claude: "sparkles"
        case .tests: event.outcome == .bad ? "xmark.circle.fill" : "checkmark.circle.fill"
        case .ci: event.outcome == .running ? "circle.dotted" : event.outcome == .bad ? "xmark.octagon.fill" : "checkmark.seal.fill"
        }
    }

    private func color(_ event: TimelineEvent) -> Color {
        switch event.outcome {
        case .good: theme.green.color
        case .bad: theme.red.color
        case .running: theme.amber.color
        case .neutral: event.kind == .claude ? theme.accent.color : theme.text3.color
        }
    }

    private func days(_ events: [TimelineEvent]) -> [(day: Date, events: [TimelineEvent])] {
        let calendar = Calendar.current
        var groups: [(day: Date, events: [TimelineEvent])] = []
        for event in events {
            let day = calendar.startOfDay(for: event.date)
            if groups.last?.day == day { groups[groups.count - 1].events.append(event) } else { groups.append((day, [event])) }
        }
        return groups
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).year(calendar.isDate(day, equalTo: .now, toGranularity: .year) ? .omitted : .defaultDigits))
    }
}
