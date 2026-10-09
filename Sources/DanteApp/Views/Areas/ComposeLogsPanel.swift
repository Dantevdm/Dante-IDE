import AppKit
import DanteKit
import SwiftUI

/// Follows `docker compose logs -f` for every service or one, with search, a level filter,
/// and the app's own timestamps set apart from the message.
struct ComposeLogsPanel: View {
    @Environment(\.theme) private var theme
    let root: URL
    let services: [String]
    /// Nil follows every service.
    @Binding var service: String?
    /// Why a service has no output, when it isn't running.
    let waiting: (String) -> String?

    @State private var lines: [LogLine] = []
    @State private var filter = LogFilter()
    @State private var follows = true
    @State private var process: Shell.Running?
    @FocusState private var searchFocused: Bool

    private static let limit = 5000

    var body: some View {
        let shown = filter.apply(lines)
        VStack(spacing: 0) {
            toolbar(shown: shown)
            Rectangle().fill(theme.line.color).frame(height: 1)
            content(shown)
        }
        .background(theme.codeBackground.color)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line.color))
        .task(id: service) { await follow() }
        .onDisappear { process?.terminate() }
    }

    // MARK: Toolbar

    private func toolbar(shown: [LogLine]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Logs").font(.dante(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
                HStack(spacing: 2) {
                    tab("All services", selected: service == nil) { service = nil }
                    ForEach(services, id: \.self) { name in
                        tab(name, selected: service == name, mono: true) { service = name }
                    }
                }
                .padding(2)
                .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 7))
                Spacer(minLength: 8)
                Button { follows.toggle() } label: {
                    Label(follows ? "Following" : "Paused", systemImage: follows ? "arrow.down.to.line" : "pause.fill")
                }
                .buttonStyle(DanteButtonStyle(primary: follows))
                .help(follows ? "Stop scrolling to new lines" : "Scroll to new lines as they arrive")
                IconButton(symbol: "doc.on.doc", label: "Copy the lines shown", size: 11) { copy(shown) }
                IconButton(symbol: "trash", label: "Clear", size: 11) { lines.removeAll() }
            }
            HStack(spacing: 8) {
                searchField
                Toggle("Only matching", isOn: $filter.onlyMatches)
                    .toggleStyle(.checkbox)
                    .font(.dante(size: 12))
                    .foregroundStyle(theme.text2.color)
                    .disabled(!filter.isSearching)
                Picker("Level", selection: $filter.minimum) {
                    Text("All levels").tag(LogLine.Level.debug)
                    Text("Info and up").tag(LogLine.Level.info)
                    Text("Warnings and errors").tag(LogLine.Level.warning)
                    Text("Errors").tag(LogLine.Level.error)
                }
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 4)
                Text(countText(shown))
                    .font(.dante(size: 11.5))
                    .foregroundStyle(theme.text3.color)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.panel.color)
    }

    private func tab(_ title: String, selected: Bool, mono: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.dante(size: 12, weight: selected ? .medium : .regular, design: mono ? .monospaced : .default))
                .foregroundStyle(selected ? theme.text.color : theme.text2.color)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(selected ? theme.card.color : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
            TextField("Search logs", text: $filter.query)
                .textFieldStyle(.plain)
                .font(.dante(size: 12.5))
                .focused($searchFocused)
                .onExitCommand { filter.query = "" }
            if filter.isSearching {
                Button { filter.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 280, height: 28)
        .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(searchFocused ? theme.accentLine.color : theme.line.color))
    }

    private func countText(_ shown: [LogLine]) -> String {
        if filter.isSearching {
            let matches = lines.filter { $0.level >= filter.minimum && filter.matches($0) }.count
            return "\(matches) matching line\(matches == 1 ? "" : "s") of \(lines.count)"
        }
        return shown.count == lines.count ? "\(lines.count) line\(lines.count == 1 ? "" : "s")" : "\(shown.count) of \(lines.count) lines"
    }

    // MARK: Lines

    @ViewBuilder
    private func content(_ shown: [LogLine]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if shown.isEmpty {
                        placeholder
                    }
                    ForEach(shown) { line in
                        LogRow(line: line, query: filter.query, showsService: service == nil, serviceColor: color(forService: line.service))
                            .id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.vertical, 6)
            }
            .frame(height: 440)
            .onChange(of: lines.last?.id) { _, last in
                if follows, let last = shown.last?.id ?? last { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onChange(of: follows) { _, follows in
                if follows, let last = shown.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    private var placeholder: some View {
        let note = service.flatMap(waiting)
        let text = filter.isSearching && !lines.isEmpty ? "No lines match “\(filter.query)”."
            : note ?? (lines.isEmpty ? "No output yet." : "No lines at this level.")
        return Text(text)
            .font(.dante(size: 12.5))
            .foregroundStyle(note != nil && !filter.isSearching ? theme.amber.color : theme.text3.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
    }

    /// A stable colour per service, from the theme's status colours.
    private func color(forService name: String) -> Color {
        let palette = [theme.accent.color, theme.green.color, theme.amber.color, theme.text2.color]
        let index = services.firstIndex(of: name) ?? abs(name.hashValue)
        return palette[index % palette.count]
    }

    private func follow() async {
        process?.terminate()
        lines.removeAll()
        var arguments = ["docker", "compose", "logs", "-f", "--no-color", "--tail", "500"]
        if let service { arguments.append(service) }
        guard let running = try? Shell.stream(arguments, in: root) else { return }
        process = running
        var next = 0
        let fallback = service ?? ""
        for await raw in running.lines {
            lines.append(LogLine.parse(raw, id: next, service: fallback))
            next += 1
            if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
        }
    }

    private func copy(_ shown: [LogLine]) {
        let text = shown.map { line in
            [service == nil ? line.service : nil, line.timestamp, line.message].compactMap { $0 }.joined(separator: "  ")
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct LogRow: View {
    @Environment(\.theme) private var theme
    let line: LogLine
    let query: String
    let showsService: Bool
    let serviceColor: Color
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Rectangle()
                .fill(levelColor ?? .clear)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
            if showsService {
                Text(line.service)
                    .foregroundStyle(serviceColor)
                    .frame(width: 70, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let timestamp = line.timestamp {
                Text(highlighted(timestamp))
                    .foregroundStyle(theme.text3.color)
                    .fixedSize()
            }
            Text(highlighted(line.message.isEmpty ? " " : line.message))
                .foregroundStyle(levelColor ?? (line.level == .debug ? theme.text3.color : theme.text.color))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.dante(size: 12, design: .monospaced))
        .textSelection(.enabled)
        .padding(.trailing, 14)
        .padding(.vertical, 2)
        .background(background)
        .onHover { hovering = $0 }
    }

    private var levelColor: Color? {
        switch line.level {
        case .error: theme.red.color
        case .warning: theme.amber.color
        case .info, .debug: nil
        }
    }

    private var background: Color {
        if hovering { return theme.raised.color }
        switch line.level {
        case .error: return theme.red.color.opacity(0.07)
        case .warning: return theme.amber.color.opacity(0.06)
        case .info, .debug: return .clear
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        for range in LogFilter.ranges(of: query, in: text) {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].backgroundColor = theme.amber.color.opacity(0.35)
            attributed[lower..<upper].foregroundColor = theme.text.color
        }
        return attributed
    }
}
