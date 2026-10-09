import DanteKit
import SwiftUI

/// Env: the project's Docker Compose services. Start, stop and restart them, follow a
/// service's logs, open a shell in it, and have Claude write the Docker files it's missing.
struct EnvironmentView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    @State private var compose: ComposeFile?
    @State private var containers: Result<[ContainerState], DockerUnavailable>?
    @State private var busy: String?
    @State private var logService: String?
    /// Why services aren't up, by service name.
    @State private var notes: [String: String] = [:]
    /// The last start, stop or rebuild: its output as it runs, kept when it fails.
    @State private var command: ComposeRun?

    struct ComposeRun: Equatable {
        var title: String
        var lines: [String] = []
        var status: Int32?
    }

    private var running: [ContainerState] {
        if case .success(let list) = containers { list } else { [] }
    }

    private var dockerfiles: [String] {
        workspace.files.filter {
            let name = ($0 as NSString).lastPathComponent.lowercased()
            return name == "dockerfile" || name.hasPrefix("dockerfile.") || name.hasSuffix(".dockerfile")
        }
    }

    var body: some View {
        AreaPage(
            eyebrow: "Environments",
            title: "Local",
            subtitle: compose.map { "Runs \($0.url.lastPathComponent) with Docker. Start, stop and rebuild services, read their logs, or let Claude write the Docker files the project is missing." }
                ?? "Run the project’s services in Docker: databases, queues and the app itself, the same way every time."
        ) {
            if compose != nil {
                IconButton(symbol: "arrow.clockwise", label: "Refresh") { Task { await refresh() } }
                Button { act("stop", ["stop"]) } label: { Label("Stop all", systemImage: "stop.fill") }
                    .buttonStyle(DanteButtonStyle())
                    .disabled(busy != nil || running.allSatisfy { $0.state != "running" })
                Button { act("build", ["up", "-d", "--build"]) } label: { Label("Rebuild", systemImage: "hammer") }
                    .buttonStyle(DanteButtonStyle())
                    .disabled(busy != nil || !dockerReady)
                Button { act("up", ["up", "-d"]) } label: { Label(busy == "up" ? "Starting…" : "Start all", systemImage: "play.fill") }
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .disabled(busy != nil || !dockerReady)
            }
        } content: {
            if let compose {
                facts(compose)
                if case .failure(let reason) = containers {
                    Banner(symbol: "exclamationmark.triangle.fill", color: theme.amber.color, text: reason.message)
                }
                if let error = compose.parseError {
                    Banner(symbol: "xmark.octagon.fill", color: theme.red.color, text: error)
                }
                if let command {
                    CommandOutputCard(run: command) { self.command = nil }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(compose.services) { service in
                        ServiceCard(
                            service: service,
                            state: running.first { $0.service == service.name },
                            note: notes[service.name],
                            isShowingLogs: logService == service.name,
                            busy: busy != nil,
                            logs: { logService = service.name },
                            shell: { session.runInTerminal("docker compose exec \(service.name) sh") },
                            restart: { act("restart:\(service.name)", ["restart", service.name]) },
                            start: { act("start:\(service.name)", ["up", "-d", service.name]) }
                        )
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    if let service = logService ?? compose.services.first?.name, dockerReady {
                        let state = running.first { $0.service == service }
                        LogsCard(session: session, root: workspace.url, service: service,
                                 waiting: state?.state == "running" ? nil : notes[service] ?? (state == nil ? "\(service) hasn’t been created yet. Start it to see its output." : nil))
                            .id(service)
                    }
                    VStack(spacing: 16) {
                        if let failing = failing {
                            DiagnoseCard(session: session, service: failing.service, problem: failing.problem, note: notes[failing.service])
                        }
                        DockerfilesCard(session: session, compose: compose, dockerfiles: dockerfiles)
                    }
                    .frame(width: 340)
                }
            } else {
                EmptyState(
                    symbol: "shippingbox",
                    title: "No docker-compose.yml",
                    message: dockerfiles.isEmpty
                        ? "A compose file lists the services this project needs to run locally: the app, its database, cache and queues. Claude can write one from the code."
                        : "Found \(dockerfiles.count == 1 ? "a Dockerfile" : "\(dockerfiles.count) Dockerfiles") but no compose file to run them together. Claude can write one."
                ) {
                    Button("Ask Claude to write it") {
                        session.askClaude("Write a docker-compose.yml for running this project locally: the app and every service the code connects to (databases, caches, queues), with ports, health checks and volumes. Add Dockerfiles where a service builds from this repo. Explain each service briefly.")
                    }
                    .buttonStyle(DanteButtonStyle(primary: true))
                }
            }
        }
        .task(id: workspace.revision) {
            compose = ComposeFile.load(projectRoot: workspace.url)
            await refresh()
            // Keep states current while the area is open.
            while !Task.isCancelled, compose != nil {
                try? await Task.sleep(for: .seconds(5))
                await refresh()
            }
        }
    }

    /// The service most worth explaining: one with a note (a blocked dependency's own
    /// problem first), else one restarting or exited with an error.
    private var failing: (service: String, problem: String)? {
        let order = compose?.services.map(\.name) ?? []
        let noted = order.filter { notes[$0] != nil }
        if let root = noted.first(where: { name in running.first { $0.service == name }?.health == "unhealthy" }) ?? noted.first {
            let state = running.first { $0.service == root }
            return (root, state.map { "\($0.label) (\($0.status))" } ?? "not created")
        }
        if let broken = running.first(where: { $0.state == "restarting" || ($0.state == "exited" && !$0.status.contains("(0)")) }) {
            return (broken.service, "\(broken.label) (\(broken.status))")
        }
        return nil
    }

    private var dockerReady: Bool {
        if case .failure = containers { false } else { true }
    }

    private func facts(_ compose: ComposeFile) -> some View {
        let up = running.filter(\.isUp).count
        return HStack(spacing: 8) {
            Chip(text: "compose: \(compose.url.lastPathComponent)", symbol: "shippingbox", mono: true)
            let profiles = Set(compose.services.flatMap(\.profiles)).sorted()
            if !profiles.isEmpty { Chip(text: "profiles: \(profiles.joined(separator: ", "))") }
            Spacer()
            if dockerReady {
                Text("\(up) of \(compose.services.count) services up")
                    .font(.dante(size: 12))
                    .foregroundStyle(theme.text3.color)
            }
        }
    }

    private func refresh() async {
        guard compose != nil else { containers = nil; return }
        let next = await ContainerState.load(projectRoot: workspace.url)
        if next != containers { containers = next }
        await diagnose()
    }

    private func diagnose() async {
        guard let compose, case .success(let list) = containers else {
            if !notes.isEmpty { notes = [:] }
            return
        }
        let stopped = compose.services.contains { service in list.first { $0.service == service.name }?.state != "running" }
        let listening = stopped ? await ListeningPort.load() : []
        var health: [String: String] = [:]
        for container in list where container.health == "unhealthy" && !container.name.isEmpty {
            health[container.service] = await ComposeDiagnosis.lastHealthFailure(container: container.name, in: workspace.url)
        }
        let next = ComposeDiagnosis.notes(services: compose.services, containers: list, listening: listening, healthOutput: health)
        if next != notes { notes = next }
    }

    /// Runs a compose command, showing its output as it goes: `up` waits for health
    /// checks and can take a minute before it says anything went wrong.
    private func act(_ id: String, _ arguments: [String]) {
        busy = id
        command = ComposeRun(title: (["docker", "compose"] + arguments).joined(separator: " "))
        Task {
            defer { busy = nil }
            guard let process = try? Shell.stream(["docker", "compose", "--progress", "plain"] + arguments, in: workspace.url) else {
                command?.lines.append("Couldn’t run docker.")
                command?.status = 1
                return
            }
            let refreshing = Task {
                // States change while `up` waits on health checks.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    await refresh()
                }
            }
            for await line in process.lines {
                command?.lines.append(line)
                if (command?.lines.count ?? 0) > 1000 { command?.lines.removeFirst() }
            }
            refreshing.cancel()
            let status = await process.exitStatus()
            command?.status = status
            await refresh()
            // Keep the output only when something went wrong.
            if status == 0 {
                try? await Task.sleep(for: .seconds(3))
                if command?.status == 0 { command = nil }
            }
        }
    }
}

private struct Banner: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.3)))
    }
}

private struct ServiceCard: View {
    @Environment(\.theme) private var theme
    let service: ComposeFile.Service
    let state: ContainerState?
    let note: String?
    let isShowingLogs: Bool
    let busy: Bool
    let logs: () -> Void
    let shell: () -> Void
    let restart: () -> Void
    let start: () -> Void

    private var color: Color {
        guard let state else { return note == nil ? theme.text3.color : theme.amber.color }
        if state.state == "restarting" || state.health == "unhealthy" || state.health == "starting" { return theme.amber.color }
        if state.state == "running" { return theme.green.color }
        if state.state == "exited", !state.status.contains("(0)") { return theme.red.color }
        return note == nil ? theme.text3.color : theme.amber.color
    }

    private var isWarning: Bool { color == theme.amber.color || color == theme.red.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                StatusDot(color: color, size: 8)
                Text(service.name).font(.dante(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(theme.text.color).lineLimit(1)
                Spacer()
                Text(state?.label ?? "not created").font(.dante(size: 12)).foregroundStyle(color)
            }
            Text(service.source).font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color).lineLimit(1)
            if let note {
                Text(note)
                    .font(.dante(size: 12))
                    .foregroundStyle(theme.text2.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(alignment: .top, spacing: 8) {
                fact("Port", state?.ports.joined(separator: " ").nonEmpty ?? service.ports.first ?? "—")
                fact("Status", state?.status.nonEmpty ?? "—")
            }
            HStack(spacing: 6) {
                Button(action: logs) { Label("Logs", systemImage: "text.alignleft") }
                    .buttonStyle(DanteButtonStyle(primary: isShowingLogs))
                if state?.state == "running" {
                    Button(action: shell) { Label("Shell", systemImage: "terminal") }
                        .buttonStyle(DanteButtonStyle())
                    Button(action: restart) { Label("Restart", systemImage: "arrow.clockwise") }
                        .buttonStyle(DanteButtonStyle())
                        .disabled(busy)
                } else {
                    Button(action: start) { Label("Start", systemImage: "play.fill") }
                        .buttonStyle(DanteButtonStyle())
                        .disabled(busy)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isWarning ? color.opacity(0.6) : theme.line.color, lineWidth: isWarning ? 1.5 : 1))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            Text(value).font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text.color).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Follows `docker compose logs -f` for one service.
private struct LogsCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let root: URL
    let service: String
    /// Why there's no output: the container isn't running.
    let waiting: String?

    @State private var lines: [String] = []
    @State private var paused = false
    @State private var process: Shell.Running?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "text.alignleft").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                Text(service).font(.dante(size: 12.5, design: .monospaced)).foregroundStyle(theme.text.color)
                Text(paused ? "paused" : "following").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                Spacer()
                Button(paused ? "Resume" : "Pause") { paused.toggle() }.buttonStyle(DanteButtonStyle())
                Button("Clear") { lines.removeAll() }.buttonStyle(DanteButtonStyle())
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(theme.panel.color)
            Rectangle().fill(theme.line.color).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if lines.isEmpty {
                            Text(waiting ?? "No output yet.")
                                .foregroundStyle(waiting == nil ? theme.text3.color : theme.amber.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line.isEmpty ? " " : line)
                                .foregroundStyle(color(for: line))
                                .fixedSize()
                                .id(index)
                        }
                    }
                    .font(.dante(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                }
                .onChange(of: lines.count) { _, count in
                    if !paused, count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
            .frame(height: 300)
        }
        .background(theme.codeBackground.color)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line.color))
        .task {
            guard let running = try? Shell.stream(["docker", "compose", "logs", "-f", "--no-color", "--tail", "200", service], in: root) else { return }
            process = running
            for await line in running.lines where !paused {
                // Compose prefixes each line with "service  | ".
                let trimmed = line.range(of: " | ").map { String(line[$0.upperBound...]) } ?? line
                lines.append(trimmed)
                if lines.count > 2000 { lines.removeFirst(lines.count - 2000) }
            }
        }
        .onDisappear { process?.terminate() }
    }

    private func color(for line: String) -> Color {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("fatal") || lower.contains("panic") { return theme.red.color }
        if lower.contains("warn") { return theme.amber.color }
        return theme.text2.color
    }
}

private struct DiagnoseCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let service: String
    let problem: String
    let note: String?

    var body: some View {
        Card(accent: true) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle").foregroundStyle(theme.accent.color)
                Text("\(service) is \(problem)").font(.dante(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
            }
            if let note {
                Text(note).font(.dante(size: 12)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
            }
            Text("Claude can read its logs, the compose file and the code it runs, then propose a fix as a diff.")
                .font(.dante(size: 12.5))
                .foregroundStyle(theme.text2.color)
                .fixedSize(horizontal: false, vertical: true)
            Button("Find the cause") {
                session.askClaude("The \(service) service is \(problem).\(note.map { " \($0)" } ?? "") Read its logs with `docker compose logs --tail 100 \(service)`, check docker-compose.yml and the code it runs, and tell me why. Propose a fix as a diff.")
            }
            .buttonStyle(DanteButtonStyle(primary: true))
        }
    }
}

private struct DockerfilesCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let compose: ComposeFile
    let dockerfiles: [String]

    private struct Row: Identifiable {
        let path: String
        let note: String
        let missing: Bool
        var id: String { path }
    }

    var body: some View {
        let rows = self.rows
        Card("Docker files") {
            Text("Claude writes, you review").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
        } content: {
            RowList(data: rows, padding: 6) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.missing ? "exclamationmark.triangle.fill" : "checkmark")
                        .font(.dante(size: 11, weight: .semibold))
                        .foregroundStyle(row.missing ? theme.amber.color : theme.green.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.path).font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text.color).lineLimit(1).truncationMode(.head)
                        if !row.note.isEmpty {
                            Text(row.note).font(.dante(size: 11.5)).foregroundStyle(row.missing ? theme.amber.color : theme.text3.color).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if row.missing {
                        Button("Generate") {
                            session.askClaude("docker-compose.yml builds a service from \(row.path.replacingOccurrences(of: "/Dockerfile", with: "")), but there's no Dockerfile there. Write one: multi-stage, small runtime image, non-root user.")
                        }
                        .buttonStyle(DanteButtonStyle())
                    }
                }
            }
        }
    }

    private var rows: [Row] {
        var rows = [Row(path: compose.url.lastPathComponent, note: "\(compose.services.count) services", missing: false)]
        for service in compose.services {
            guard let context = service.build else { continue }
            var folder = context.hasPrefix("./") ? String(context.dropFirst(2)) : context
            if folder == "." { folder = "" }
            let path = folder.isEmpty ? "Dockerfile" : "\(folder)/Dockerfile"
            if dockerfiles.contains(path) {
                if !rows.contains(where: { $0.path == path }) { rows.append(Row(path: path, note: "builds \(service.name)", missing: false)) }
            } else {
                rows.append(Row(path: path, note: "missing for \(service.name)", missing: true))
            }
        }
        for file in dockerfiles where !rows.contains(where: { $0.path == file }) {
            rows.append(Row(path: file, note: "", missing: false))
        }
        return rows
    }
}

/// The output of the last start, stop or rebuild.
private struct CommandOutputCard: View {
    @Environment(\.theme) private var theme
    let run: EnvironmentView.ComposeRun
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if run.status == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: run.status == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(run.status == 0 ? theme.green.color : theme.red.color)
                }
                Text(run.title).font(.dante(size: 12.5, design: .monospaced)).foregroundStyle(theme.text.color).lineLimit(1)
                Text(run.status.map { $0 == 0 ? "done" : "failed with status \($0)" } ?? "running")
                    .font(.dante(size: 12))
                    .foregroundStyle(run.status.map { $0 == 0 ? theme.text3.color : theme.red.color } ?? theme.text3.color)
                Spacer()
                if run.status != nil {
                    IconButton(symbol: "xmark", label: "Close", size: 10, action: close)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(theme.panel.color)
            Rectangle().fill(theme.line.color).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if run.lines.isEmpty {
                            Text("Waiting for docker compose…").foregroundStyle(theme.text3.color)
                        }
                        ForEach(Array(run.lines.enumerated()), id: \.offset) { index, line in
                            Text(line.isEmpty ? " " : line)
                                .foregroundStyle(line.localizedCaseInsensitiveContains("error") || line.contains("unhealthy") ? theme.red.color : theme.text2.color)
                                .fixedSize()
                                .id(index)
                        }
                    }
                    .font(.dante(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                }
                .onChange(of: run.lines.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
            .frame(height: 160)
        }
        .background(theme.codeBackground.color)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(run.status.map { $0 == 0 ? theme.line.color : theme.red.color.opacity(0.5) } ?? theme.line.color))
    }
}
