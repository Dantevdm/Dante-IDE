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
    /// How many lines back `docker compose logs` starts.
    @State private var tail = 500
    @State private var process: Shell.Running?
    @FocusState private var searchFocused: Bool

    /// Lines kept; trimmed a thousand at a time so the text view rarely redraws everything.
    private static let limit = 20_000

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
        .task(id: "\(service ?? "*"):\(tail)") { await follow() }
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
                Menu {
                    ForEach([500, 2000, 10_000], id: \.self) { count in
                        Button("Last \(count.formatted()) lines") { tail = count }
                    }
                    Button("Everything") { tail = 0 }
                } label: {
                    Text(tail == 0 ? "All history" : "Last \(tail.formatted())")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("How far back to read the logs")
                if follows {
                    Label("Following", systemImage: "arrow.down.to.line")
                        .font(.dante(size: 12))
                        .foregroundStyle(theme.text3.color)
                        .help("New lines appear at the bottom. Scroll up to stop.")
                } else {
                    Button { follows = true } label: { Label("Jump to latest", systemImage: "arrow.down") }
                        .buttonStyle(DanteButtonStyle(primary: true))
                        .help("Go back to the newest line and keep following")
                }
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

    private func content(_ shown: [LogLine]) -> some View {
        LogTextView(lines: shown, query: filter.query, showsService: service == nil, services: services, theme: theme, follows: $follows)
            .frame(height: 440)
            .overlay(alignment: .topLeading) {
                if shown.isEmpty { placeholder }
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
        follows = true
        var arguments = ["docker", "compose", "logs", "-f", "--no-color", "--tail", tail == 0 ? "all" : "\(tail)"]
        if let service { arguments.append(service) }
        guard let running = try? Shell.stream(arguments, in: root) else { return }
        process = running
        var next = 0
        let fallback = service ?? ""
        // History arrives in a burst: hand it over in batches rather than line by line.
        var pending: [LogLine] = []
        var lastFlush = ContinuousClock.now
        let flusher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                flush(&pending)
            }
        }
        defer { flusher.cancel() }
        for await raw in running.lines {
            pending.append(LogLine.parse(raw, id: next, service: fallback))
            next += 1
            if pending.count >= 2000 || ContinuousClock.now - lastFlush > .milliseconds(150) {
                flush(&pending)
                lastFlush = .now
            }
        }
        flush(&pending)
    }

    private func flush(_ pending: inout [LogLine]) {
        guard !pending.isEmpty else { return }
        lines.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
        if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit + 1000) }
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
