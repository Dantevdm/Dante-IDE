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
    /// Processes listening on ports, other than Docker's own.
    @State private var holders: [PortHolder] = []
    /// A start held back because a port it publishes is taken.
    @State private var portPrompt: PortPrompt?
    /// Frontends, APIs and workers in the repo, and whether compose runs them.
    @State private var apps: [RunnableApp] = []
    /// This project's containers started outside compose (`docker run --name sp-pg`).
    @State private var others: [DockerContainer] = []
    /// Values compose needs that neither .env nor the environment has.
    @State private var missing: [ComposeVariables.Missing] = []
    /// A start held back until they're filled in.
    @State private var heldStart: (id: String, arguments: [String])?

    struct PortPrompt: Identifiable {
        var conflicts: [PortConflict]
        var id: String
        var arguments: [String]
    }

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

    private func flowState(_ service: String) -> FlowGraph.State {
        guard let state = running.first(where: { $0.service == service }) else { return .off }
        if state.health == "unhealthy" || (state.state != "running" && state.state != "created") { return state.state == "exited" ? .bad : .off }
        return .live
    }

    private func flowNode(_ service: ComposeFile.Service) -> FlowGraph.Node {
        let state = running.first { $0.service == service.name }
        let symbol = ["postgres", "mysql", "mariadb", "mongo", "redis", "valkey", "sqlserver", "mssql"].contains { (service.image ?? service.name).lowercased().contains($0) }
            ? "cylinder.split.1x2" : service.build != nil ? "shippingbox" : "cube"
        return FlowGraph.Node(id: service.name, title: service.name,
                              detail: state.map { $0.health.isEmpty ? $0.state : "\($0.state) · \($0.health)" } ?? (service.ports.first.map { "port \($0)" } ?? "not running"),
                              symbol: symbol, state: flowState(service.name))
    }

    /// A service links to what it depends on; live while both run, red when it runs and what it needs doesn't.
    private func flowLinks(_ compose: ComposeFile) -> [FlowGraph.Link] {
        compose.services.flatMap { service in
            service.dependsOn.map { dependency in
                let from = flowState(service.name), to = flowState(dependency)
                let state: FlowGraph.State = from == .live && to == .live ? .live : from == .live ? .bad : .off
                return FlowGraph.Link(from: service.name, to: dependency, state: state)
            }
        }
    }

    var body: some View {
        AreaPage(
            eyebrow: nil,
            title: session.remoteSync.map { "Services on \($0.project.host)" } ?? "Services",
            subtitle: nil
        ) {
            if compose != nil {
                if session.remoteSync == nil {
                    Toggle("Keep running", isOn: Bindable(session.serviceKeeper).isOn)
                        .toggleStyle(.switch).controlSize(.mini)
                        .font(.dante(size: 12))
                        .help("While this project is open, Dante restarts a service that crashes or stays unhealthy (three tries in 15 minutes), and applies changes to the compose file to the running services. Services you stop stay stopped.")
                }
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
                if !missing.isEmpty {
                    MissingValuesCard(missing: missing, held: heldStart != nil, gitIgnored: gitIgnoresDotEnv) { typed in
                        fill(typed)
                    } cancel: {
                        heldStart = nil
                    }
                }
                // Compose's own interpolation error says what the card above already does.
                if case .failure(let reason) = containers, missing.isEmpty || ComposeVariables.named(inError: reason.message).isEmpty {
                    Banner(symbol: "exclamationmark.triangle.fill", color: theme.amber.color, text: reason.message)
                }
                if let error = compose.parseError {
                    Banner(symbol: "xmark.octagon.fill", color: theme.red.color, text: error)
                }
                if !session.serviceKeeper.events.isEmpty {
                    KeeperEvents(session: session, events: session.serviceKeeper.events, covered: failing?.service)
                }
                if let command {
                    CommandOutputCard(run: command, services: compose.services.map(\.name)) { self.command = nil }
                }
                if let failing = failing {
                    DiagnoseCard(session: session, service: failing.service, problem: failing.problem, note: notes[failing.service],
                                 crash: session.serviceKeeper.events.last { $0.crash?.service == failing.service }?.crash)
                }
                if compose.services.count >= 2, compose.services.contains(where: { !$0.dependsOn.isEmpty }) {
                    Card("How they connect") {
                        FlowGraph(nodes: compose.services.map(flowNode), links: flowLinks(compose))
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(compose.services) { service in
                        ServiceCard(
                            service: service,
                            state: running.first { $0.service == service.name },
                            checking: containers == nil,
                            note: notes[service.name],
                            isShowingLogs: logService == service.name,
                            busy: busy != nil,
                            logs: { logService = logService == service.name ? nil : service.name },
                            shell: { session.runInTerminal("docker compose exec \(service.name) sh") },
                            restart: { act("restart:\(service.name)", ["restart", service.name]) },
                            open: { target in
                                switch target {
                                case .data: session.showInData(service: service.name)
                                case .browser(let url): NSWorkspace.shared.open(url)
                                }
                            },
                            start: { act("start:\(service.name)", ["up", "-d", service.name]) }
                        )
                    }
                }
                projectCards(compose: compose)
                if dockerReady {
                    ComposeLogsPanel(root: workspace.url, services: compose.services.map(\.name), service: $logService, waiting: waiting)
                }
                HStack(alignment: .top, spacing: 12) {
                    PortsCard(ports: projectPorts(compose), remote: session.remoteSync, stop: stop)
                        .frame(maxWidth: .infinity)
                    DockerfilesCard(session: session, compose: compose, dockerfiles: dockerfiles)
                        .frame(maxWidth: .infinity)
                }
            } else {
                EmptyState(
                    symbol: "shippingbox",
                    title: "No docker-compose.yml",
                    message: dockerfiles.isEmpty ? nil : "\(dockerfiles.count == 1 ? "1 Dockerfile" : "\(dockerfiles.count) Dockerfiles"), no compose file"
                ) {
                    Button("Ask \(session.agentName) to write it") {
                        session.askClaude("Write a docker-compose.yml for running this project locally: the app and every service the code connects to (databases, caches, queues), with ports, health checks and volumes. Add Dockerfiles where a service builds from this repo. Explain each service briefly.")
                    }
                    .buttonStyle(DanteButtonStyle(primary: true))
                }
                projectCards(compose: nil)
            }
        }
        .confirmationDialog(portPromptTitle, isPresented: Binding(get: { portPrompt != nil }, set: { if !$0 { portPrompt = nil } }), titleVisibility: .visible, presenting: portPrompt) { prompt in
            let holders = prompt.conflicts.map(\.holder)
            Button(holders.count == 1 ? "Stop \(holders[0].listening.command) and Start" : "Stop Them and Start") {
                Task {
                    for holder in holders {
                        if let error = await PortCheck.stop(holder) {
                            session.errorMessage = error
                            return
                        }
                    }
                    act(prompt.id, prompt.arguments, checkingPorts: false)
                }
            }
            Button(prompt.conflicts.count == 1 ? "Publish on Port \(freePort(after: prompt.conflicts[0].port)) Instead" : "Publish on Free Ports Instead") {
                if republish(prompt.conflicts) { act(prompt.id, prompt.arguments, checkingPorts: false) }
            }
            Button("Start Anyway") { act(prompt.id, prompt.arguments, checkingPorts: false) }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text(prompt.conflicts.map { conflict in
                "\(conflict.service) publishes port \(conflict.port), but \(conflict.holder.summary) is already listening there\(conflict.holder.belongs(to: workspace.url) ? ", started from this project" : "")."
            }.joined(separator: "\n") + "\n\nDocker can’t start a service on a port that’s taken.")
        }
        .task(id: workspace.revision) {
            compose = ComposeFile.load(projectRoot: workspace.url)
            let files = workspace.files, root = workspace.url, loaded = compose
            apps = await Task.detached(priority: .utility) {
                RunnableApp.detect(files: files, read: { path in
                    let url = root.appending(path: path)
                    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 256_000 else { return nil }
                    return try? String(contentsOf: url, encoding: .utf8)
                }, compose: loaded)
            }.value
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

    /// Why a service has no output: it isn't running.
    private func waiting(_ service: String) -> String? {
        let state = running.first { $0.service == service }
        guard state?.state != "running" else { return nil }
        return notes[service] ?? (state == nil ? "\(service) hasn’t been created yet. Start it to see its output." : "\(service) is \(state!.label).")
    }

    private var portPromptTitle: String {
        guard let prompt = portPrompt else { return "" }
        return prompt.conflicts.count == 1 ? "Port \(prompt.conflicts[0].port) is in use" : "\(prompt.conflicts.count) ports are in use"
    }

    /// Every port the compose file publishes, and anything else started from this project.
    private func projectPorts(_ compose: ComposeFile) -> [PortsCard.Row] {
        var rows: [PortsCard.Row] = []
        for service in compose.services {
            for port in service.publishedPorts where !rows.contains(where: { $0.port == port }) {
                let container = running.first { $0.service == service.name }
                let holder = holders.first { $0.port == port }
                rows.append(PortsCard.Row(port: port, service: service.name, holder: holder,
                                          isContainer: holder == nil && container?.state == "running",
                                          inProject: holder?.belongs(to: workspace.url) ?? false))
            }
        }
        for holder in holders where holder.belongs(to: workspace.url) && !rows.contains(where: { $0.port == holder.port }) {
            rows.append(PortsCard.Row(port: holder.port, service: nil, holder: holder, isContainer: false, inProject: true))
        }
        return rows.sorted { $0.port < $1.port }
    }

    private func freePort(after port: Int) -> Int {
        PortProbe.firstFree(from: port + 1, skipping: Set(holders.map(\.port)))
    }

    /// Moves each conflicting service to the next free host port in the compose file.
    private func republish(_ conflicts: [PortConflict]) -> Bool {
        guard let compose, var text = try? String(contentsOf: compose.url, encoding: .utf8) else { return false }
        var taken = Set(holders.map(\.port))
        for conflict in conflicts {
            let port = PortProbe.firstFree(from: conflict.port + 1, skipping: taken)
            taken.insert(port)
            guard let moved = ComposeEditing.republishing(service: conflict.service, port: conflict.port, to: port, in: text) else {
                session.errorMessage = "Couldn’t find \(conflict.service)’s port \(conflict.port) in \(compose.url.lastPathComponent) to change it."
                return false
            }
            text = moved
        }
        do {
            try text.write(to: compose.url, atomically: true, encoding: .utf8)
            self.compose = ComposeFile.load(projectRoot: workspace.url)
            return true
        } catch {
            session.errorMessage = "Couldn’t write \(compose.url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    private func stop(_ holder: PortHolder) {
        Task {
            if let error = await PortCheck.stop(holder) { session.errorMessage = error }
            await refresh()
        }
    }

    /// Docker answers; a compose file missing values counts, since Start then asks for them.
    private var dockerReady: Bool {
        guard case .failure(let reason) = containers else { return true }
        return !ComposeVariables.named(inError: reason.message).isEmpty
    }

    private func facts(_ compose: ComposeFile) -> some View {
        let up = running.filter(\.isUp).count
        return HStack(spacing: 8) {
            Chip(text: "compose: \(compose.url.lastPathComponent)", symbol: "shippingbox", mono: true)
            let profiles = Set(compose.services.flatMap(\.profiles)).sorted()
            if !profiles.isEmpty { Chip(text: "profiles: \(profiles.joined(separator: ", "))") }
            Spacer()
            if containers == nil {
                Text("Asking Docker…")
                    .font(.dante(size: 12))
                    .foregroundStyle(theme.text3.color)
            } else if dockerReady {
                Text("\(up) of \(compose.services.count) services up")
                    .font(.dante(size: 12))
                    .foregroundStyle(theme.text3.color)
            }
        }
    }

    /// The project's apps and its containers outside compose.
    @ViewBuilder
    private func projectCards(compose: ComposeFile?) -> some View {
        if !apps.isEmpty {
            AppsCard(session: session, apps: apps, hasCompose: compose != nil, composeName: compose?.url.lastPathComponent ?? "docker-compose.yml",
                     databases: others.filter { $0.engine != nil }.map(\.name))
        }
        if !others.isEmpty {
            ContainersCard(session: session, containers: others, busy: busy) { container, start in
                act("container:\(container.name)", start ? ["start", container.name] : ["stop", container.name], plain: true)
            }
        }
    }

    private func refresh() async {
        // The project's containers outside compose, on this Mac (a remote host's aren't here).
        if session.remoteSync == nil, let all = await DockerContainer.load() {
            var next: [DockerContainer] = []
            for container in DockerContainer.related(all, project: workspace.name) {
                // A stopped container's ports come from inspect, once.
                if container.ports.isEmpty, !container.isRunning {
                    let known = others.first { $0.name == container.name && $0.state == container.state && !$0.ports.isEmpty }
                    if let known { next.append(known) } else { next.append(await DockerContainer.inspect(container).container) }
                } else {
                    next.append(container)
                }
            }
            if next != others { others = next }
        }
        guard compose != nil else { containers = nil; return }
        let next = await ContainerState.load(projectRoot: workspace.url)
        if next != containers { containers = next }
        checkValues()
        if case .success(let list) = next { await session.forwardPorts(of: list) }
        await diagnose()
    }

    private func diagnose() async {
        guard let compose, case .success(let list) = containers else {
            if !notes.isEmpty { notes = [:] }
            return
        }
        // A remote project's ports are the host's; what holds them on this Mac doesn't matter.
        let nextHolders = session.remoteSync == nil ? await PortCheck.holders(await ListeningPort.load()) : []
        if nextHolders != holders { holders = nextHolders }
        var health: [String: String] = [:]
        for container in list where container.health == "unhealthy" && !container.name.isEmpty {
            health[container.service] = await ComposeDiagnosis.lastHealthFailure(container: container.name, in: workspace.url)
        }
        let next = ComposeDiagnosis.notes(services: compose.services, containers: list, holders: holders, healthOutput: health)
        if next != notes { notes = next }
    }

    /// What compose would stop on, or start blank: from the compose file, `.env`, the
    /// environment compose runs in, and the names in compose's own error, if it gave one.
    private func checkValues() {
        guard let compose, let yaml = try? String(contentsOf: compose.url, encoding: .utf8) else {
            if !missing.isEmpty { missing = [] }
            return
        }
        let root = workspace.url
        let dotEnv = try? String(contentsOf: root.appending(path: ".env"), encoding: .utf8)
        let example = ComposeVariables.exampleNames.lazy.compactMap { try? String(contentsOf: root.appending(path: $0), encoding: .utf8) }.first
        var errors = ""
        if case .failure(let reason) = containers { errors += reason.message }
        if let command, command.status != nil, command.status != 0 { errors += "\n" + command.lines.joined(separator: "\n") }
        // A remote project's compose runs on the host, whose environment isn't this Mac's.
        let shell = session.remoteSync == nil ? Shell.environment() : [:]
        let next = ComposeVariables.missing(compose: yaml, env: ComposeVariables.environment(shell: shell, dotEnv: dotEnv), example: example,
                                            alsoRequired: ComposeVariables.named(inError: errors))
        if next != missing { missing = next }
        if !next.contains(where: \.blocks) { heldStart = nil }
    }

    /// Whether .gitignore already keeps .env out of the repository.
    private var gitIgnoresDotEnv: Bool {
        let text = (try? String(contentsOf: workspace.url.appending(path: ".gitignore"), encoding: .utf8)) ?? ""
        return GitIgnore.ensuring([".env"], in: text) == nil
    }

    /// Writes the values into .env (kept out of git), then carries on with a start that waited.
    private func fill(_ typed: [String: String]) {
        let root = workspace.url
        let url = root.appending(path: ".env")
        let lines = ComposeVariables.plan(missing, typed: typed)
        guard !lines.isEmpty else { return }
        do {
            let existing = try? String(contentsOf: url, encoding: .utf8)
            try EnvFile.setting(lines, in: existing, comment: "Values docker compose needs, added by Dante").write(to: url, atomically: true, encoding: .utf8)
            if FileManager.default.fileExists(atPath: root.appending(path: ".git").path) {
                let ignore = root.appending(path: ".gitignore")
                if let text = GitIgnore.ensuring([".env"], in: try? String(contentsOf: ignore, encoding: .utf8)) {
                    try text.write(to: ignore, atomically: true, encoding: .utf8)
                }
            }
        } catch {
            session.errorMessage = "Couldn’t write .env: \(error.localizedDescription)"
            return
        }
        command = nil
        // Compose's old error is about values that are there now: ask Docker again.
        if case .failure = containers { containers = nil }
        checkValues()
        let held = heldStart
        heldStart = nil
        if let held, !missing.contains(where: \.blocks) {
            act(held.id, held.arguments)
        } else {
            Task { await refresh() }
        }
    }

    /// Runs a compose command, showing its output as it goes: `up` waits for health
    /// checks and can take a minute before it says anything went wrong.
    /// Starts (`up`) look for taken ports first and ask what to do about them.
    private func act(_ id: String, _ arguments: [String], checkingPorts: Bool = true, plain: Bool = false) {
        // Compose refuses to start anything while a required value is missing: ask for it first.
        if !plain, arguments.first == "up", missing.contains(where: \.blocks) {
            heldStart = (id, arguments)
            return
        }
        if !plain, checkingPorts, arguments.first == "up", let compose, session.remoteSync == nil {
            busy = id
            Task {
                let found = await PortCheck.holders(await ListeningPort.load())
                holders = found
                let named = arguments.dropFirst().filter { !$0.hasPrefix("-") }
                let services = named.isEmpty ? compose.services : compose.services.filter { named.contains($0.name) }
                let conflicts = PortConflict.find(services: services, containers: running, holders: found)
                busy = nil
                if conflicts.isEmpty {
                    act(id, arguments, checkingPorts: false)
                } else {
                    portPrompt = PortPrompt(conflicts: conflicts, id: id, arguments: arguments)
                }
            }
            return
        }
        busy = id
        if !plain, let verb = arguments.first {
            let named = arguments.dropFirst().filter { !$0.hasPrefix("-") }
            let all = compose?.services.map(\.name) ?? []
            if ["stop", "down", "kill", "rm"].contains(verb) { session.serviceKeeper.youStopped(named, all: all) }
            if ["up", "start", "restart"].contains(verb) { session.serviceKeeper.youStarted(named, all: all) }
        }
        // `plain` runs docker itself, for containers outside compose.
        command = ComposeRun(title: ((plain ? ["docker"] : ["docker", "compose"]) + arguments).joined(separator: " "))
        Task {
            defer { busy = nil }
            guard let process = try? Shell.stream((plain ? ["docker"] : ["docker", "compose", "--progress", "plain"]) + arguments, in: workspace.url) else {
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
            checkValues()
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

/// Icon only when space is short; the title still reads to VoiceOver and in the tooltip.
private struct CompactLabel: LabelStyle {
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        if compact {
            Label(configuration).labelStyle(.iconOnly)
        } else {
            Label(configuration)
        }
    }
}

private struct ServiceCard: View {
    @Environment(\.theme) private var theme
    let service: ComposeFile.Service
    let state: ContainerState?
    /// Docker hasn't answered yet, so there's no telling whether it's running.
    let checking: Bool
    let note: String?
    let isShowingLogs: Bool
    let busy: Bool
    let logs: () -> Void
    let shell: () -> Void
    let restart: () -> Void
    let open: (ServiceOpening) -> Void
    let start: () -> Void

    /// Where Open goes, once the service runs.
    private var opening: ServiceOpening? {
        guard let state, state.state == "running" else { return nil }
        return ServiceOpening.target(service: service, ports: state.ports)
    }

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
                Text(state?.label ?? (checking ? "checking…" : "not created")).font(.dante(size: 12)).foregroundStyle(color)
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
                fact("Status", state.map { $0.status.replacing(/\s*\((healthy|unhealthy|health: starting)\)$/, with: "") }?.nonEmpty ?? "—")
            }
            // Narrow cards keep Open's word and show the rest as icons.
            ViewThatFits(in: .horizontal) {
                buttons(compact: false)
                buttons(compact: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isWarning ? color.opacity(0.6) : theme.line.color, lineWidth: isWarning ? 1.5 : 1))
    }


    private func buttons(compact: Bool) -> some View {
        HStack(spacing: 6) {
            if let opening {
                switch opening {
                case .data:
                    Button { open(opening) } label: { Label("Browse", systemImage: "tablecells") }
                        .buttonStyle(DanteButtonStyle(primary: true)).labelStyle(.titleAndIcon)
                        .help("Open \(service.name) in Data: its tables, rows and queries.")
                case .browser(let url):
                    Button { open(opening) } label: { Label("Open", systemImage: "safari") }
                        .buttonStyle(DanteButtonStyle(primary: true)).labelStyle(.titleAndIcon)
                        .help("Open \(url.absoluteString) in your browser.")
                }
            }
            Button(action: logs) { Label("Logs", systemImage: "text.alignleft") }
                .buttonStyle(DanteButtonStyle(primary: isShowingLogs))
            if state?.state == "running" {
                Button(action: shell) { Label("Shell", systemImage: "terminal") }
                    .buttonStyle(DanteButtonStyle())
                Button(action: restart) { Label("Restart", systemImage: "arrow.clockwise") }
                    .buttonStyle(DanteButtonStyle())
                    .disabled(busy)
            } else if !checking {
                Button(action: start) { Label("Start", systemImage: "play.fill") }
                    .buttonStyle(DanteButtonStyle())
                    .disabled(busy)
            }
        }
        .labelStyle(CompactLabel(compact: compact))
        .fixedSize()
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            Text(value).font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text.color).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DiagnoseCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let service: String
    let problem: String
    let note: String?
    /// What its logs said when Keep running last brought it back or gave up.
    var crash: CrashReport?

    var body: some View {
        Card(accent: true) {
            HStack(spacing: 8) {
                ClaudeSparkIcon()
                Text("\(service) is \(problem)").font(.dante(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
            }
            if let note {
                Text(note).font(.dante(size: 12)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
            }
            if let summary = crash?.summary {
                Text(summary).font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text.color).lineLimit(3).textSelection(.enabled)
            }
            Button(crash == nil ? "Find the cause" : "Fix the cause") {
                if let crash { return session.askClaude(crash.brief) }
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

/// What Keep running did lately: services brought back, ones left down, compose changes applied.
private struct KeeperEvents: View {
    @Environment(\.theme) private var theme
    let session: Session
    let events: [ServiceKeeper.Event]
    /// The service the page's own Find the cause card is about, which offers the fix instead.
    var covered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let shown = Array(events.suffix(3).reversed())
            // One Fix the cause per service, on its newest event.
            let fixable = Set(Dictionary(shown.compactMap { event in event.crash.flatMap { $0.service == covered ? nil : ($0.service, event.id) } }) { first, _ in first }.values)
            ForEach(shown) { event in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: event.failed ? "exclamationmark.triangle.fill" : "arrow.clockwise.heart")
                        .font(.dante(size: 11)).foregroundStyle(event.failed ? theme.amber.color : theme.green.color).frame(width: 14)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.text).font(.dante(size: 12)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                        if let summary = event.crash?.summary {
                            Text(summary).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text.color)
                                .lineLimit(2).textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                    if let crash = event.crash, fixable.contains(event.id), event.failed || crash.headline != nil {
                        Button("Fix the cause") { session.askClaude(crash.brief) }
                            .buttonStyle(DanteButtonStyle(primary: event.failed))
                            .help("Hands \(session.agentName) the end of \(crash.service)’s logs and asks it to fix what makes it crash")
                    }
                    Text(event.date.formatted(date: .omitted, time: .shortened)).font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.line.color))
    }
}

/// The last start, stop or rebuild: a line per service saying where it got to, the errors,
/// and Docker's own output folded away.
private struct CommandOutputCard: View {
    @Environment(\.theme) private var theme
    let run: EnvironmentView.ComposeRun
    var services: [String] = []
    let close: () -> Void
    @State private var showsRaw = false

    var body: some View {
        let progress = ComposeProgress.parse(run.lines, known: services)
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
                Button(showsRaw ? "Hide raw output" : "Raw output") { withAnimation(.snappy(duration: 0.18)) { showsRaw.toggle() } }
                    .buttonStyle(.plain)
                    .font(.dante(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.accent.color)
                    .help("Docker’s own output, line by line")
                if run.status != nil {
                    IconButton(symbol: "xmark", label: "Close", size: 10, action: close)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(theme.panel.color)
            Rectangle().fill(theme.line.color).frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                if progress.services.isEmpty, progress.errors.isEmpty {
                    Text(run.lines.isEmpty ? "Waiting for docker compose…" : (run.lines.last ?? ""))
                        .font(.dante(size: 12)).foregroundStyle(theme.text3.color).lineLimit(1)
                }
                ForEach(progress.services) { service in
                    HStack(spacing: 8) {
                        icon(service.phase).frame(width: 14)
                        Text(service.name).font(.dante(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color)
                        Text(service.phase.text).font(.dante(size: 12)).foregroundStyle(service.phase.isFailed ? theme.red.color : theme.text2.color)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        if service.cached + service.ran > 0 {
                            Text("\(service.ran) built · \(service.cached) from cache").font(.dante(size: 11)).foregroundStyle(theme.text3.color).monospacedDigit()
                                .help("Build steps Docker ran, and ones it reused from an earlier build")
                        }
                    }
                }
                if !progress.errors.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(progress.errors, id: \.self) { error in
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.dante(size: 11.5)).foregroundStyle(theme.red.color)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.red.color.opacity(0.07)))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsRaw {
                Rectangle().fill(theme.line.color).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 2) {
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
                    .onAppear { if !run.lines.isEmpty { proxy.scrollTo(run.lines.count - 1, anchor: .bottom) } }
                }
                .frame(height: 180)
                .background(theme.codeBackground.color)
            }
        }
        .background(theme.card.color)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(run.status.map { $0 == 0 ? theme.line.color : theme.red.color.opacity(0.5) } ?? theme.line.color))
    }

    @ViewBuilder
    private func icon(_ phase: ComposeProgress.Phase) -> some View {
        switch phase {
        case .building, .starting: ProgressView().controlSize(.mini)
        case .built, .running: Image(systemName: "checkmark").font(.dante(size: 10, weight: .bold)).foregroundStyle(theme.green.color)
        case .stopped: Image(systemName: "stop.fill").font(.dante(size: 9)).foregroundStyle(theme.text3.color)
        case .failed: Image(systemName: "xmark").font(.dante(size: 10, weight: .bold)).foregroundStyle(theme.red.color)
        }
    }
}

/// The ports the project publishes or listens on, and who has each one.
private struct PortsCard: View {
    @Environment(\.theme) private var theme
    struct Row: Identifiable {
        var port: Int
        var service: String?
        var holder: PortHolder?
        var isContainer: Bool
        var inProject: Bool
        var id: Int { port }
    }

    let ports: [Row]
    /// For a remote project: which ports reach the host from here.
    let remote: RemoteSync?
    let stop: (PortHolder) -> Void
    @State private var confirming: PortHolder?

    var body: some View {
        if !ports.isEmpty {
            Card("Ports") {
                Text(remote.map { "Forwarded from \($0.project.host) to this Mac" } ?? "Checked before every start")
                    .font(.dante(size: 12)).foregroundStyle(theme.text3.color)
            } content: {
                RowList(data: ports, padding: 6) { row in
                    HStack(spacing: 10) {
                        StatusDot(color: color(row), size: 7)
                        Text(":\(row.port)")
                            .font(.dante(size: 12.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.text.color)
                            .frame(width: 64, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(row)).font(.dante(size: 12.5)).foregroundStyle(theme.text.color).lineLimit(1)
                            if let holder = row.holder {
                                Text(holder.commandLine)
                                    .font(.dante(size: 11, design: .monospaced))
                                    .foregroundStyle(theme.text3.color)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help([holder.commandLine, holder.directory.map { "in \($0)" }].compactMap { $0 }.joined(separator: "\n"))
                            }
                        }
                        Spacer(minLength: 6)
                        if let url = URL(string: "http://localhost:\(row.port)"), row.holder != nil || row.isContainer {
                            IconButton(symbol: "safari", label: "Open localhost:\(row.port)", size: 11) { NSWorkspace.shared.open(url) }
                        }
                        if let holder = row.holder {
                            Button("Stop") { row.inProject ? stop(holder) : (confirming = holder) }
                                .buttonStyle(DanteButtonStyle())
                                .help("Ask \(holder.listening.command) to quit (pid \(holder.pid))")
                        }
                    }
                }
            }
            .alert("Stop \(confirming?.listening.command ?? "")?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { holder in
                Button("Stop") { stop(holder) }
                Button("Cancel", role: .cancel) {}
            } message: { holder in
                Text("\(holder.summary) wasn’t started from this project.\(holder.directory.map { " It runs in \($0)." } ?? "") Dante will ask it to quit.")
            }
        }
    }

    private func title(_ row: Row) -> String {
        if let holder = row.holder {
            let owner = row.service.map { "Taken: \($0) needs it. " } ?? ""
            return owner + "\(holder.listening.command), pid \(holder.pid)\(holder.elapsed.map { ", up \($0)" } ?? "")\(row.inProject ? " · from this project" : "")"
        }
        if let remote {
            if remote.unforwarded[row.port] != nil { return "\(row.service ?? "") · taken on this Mac, not forwarded" }
            if row.isContainer { return "\(row.service ?? "") · Docker on \(remote.project.host)\(remote.forwarded.contains(row.port) ? ", forwarded" : "")" }
            return "\(row.service ?? "") · not running"
        }
        if row.isContainer { return "\(row.service ?? "") · Docker" }
        return "\(row.service ?? "") · free"
    }

    private func color(_ row: Row) -> Color {
        if let remote, remote.unforwarded[row.port] != nil { return theme.amber.color }
        if row.holder != nil { return row.service == nil ? theme.accent.color : theme.amber.color }
        return row.isContainer ? theme.green.color : theme.text3.color
    }
}

/// The project's own apps: frontends, APIs and workers found in the code, how each starts,
/// and whether compose runs it. Run types its command into the terminal; Add to compose asks
/// the agent in charge to containerise it beside the services already there.
private struct AppsCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let apps: [RunnableApp]
    let hasCompose: Bool
    let composeName: String
    /// Database containers outside compose, which a new service may need to reach.
    let databases: [String]

    var body: some View {
        let missing = apps.filter { $0.service == nil }
        Card("Apps in this project") {
            if missing.count > 1 {
                Button("Add All to Compose") { add(missing) }
                    .buttonStyle(DanteButtonStyle())
                    .help("\(session.agentName) writes the Dockerfiles that are missing and adds a service for each app to \(composeName); you approve each edit.")
            }
        } content: {
            RowList(data: apps, padding: 6) { app in
                HStack(spacing: 10) {
                    Image(systemName: app.kind == .frontend ? "macwindow" : "server.rack")
                        .font(.dante(size: 13))
                        .foregroundStyle(theme.text2.color)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(app.name).font(.dante(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
                            Text(app.stack).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                        }
                        Text("\(app.folder.isEmpty ? "." : app.folder) · \(app.command)")
                            .font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if let service = app.service {
                        Label("in compose as \(service)", systemImage: "checkmark")
                            .font(.dante(size: 11.5)).foregroundStyle(theme.green.color)
                    } else {
                        if let root = session.workspace?.url, app.needsInstall(exists: { FileManager.default.fileExists(atPath: root.appending(path: $0).path) }) {
                            Button("Install and run") { session.runInTerminal(app.installingCommandFromRoot) }
                                .buttonStyle(DanteButtonStyle())
                                .help("Its dependencies aren’t installed (no node_modules), so it would stop at once. Runs \(app.installingCommandFromRoot) in the terminal, which downloads the packages its lockfile lists first.")
                        } else {
                            Button("Run") { session.runInTerminal(app.commandFromRoot) }
                                .buttonStyle(DanteButtonStyle())
                                .help("Runs \(app.commandFromRoot) in the terminal, on this Mac.")
                        }
                        Button("Add to Compose") { add([app]) }
                            .buttonStyle(DanteButtonStyle(primary: missing.count == 1))
                            .help("\(session.agentName) adds \(app.name) to \(composeName)\(app.hasDockerfile ? "" : " and writes its Dockerfile"); you approve each edit.")
                    }
                }
            }
        }
    }

    private func add(_ chosen: [RunnableApp]) {
        let list = chosen.map { app in
            "- \(app.name) (\(app.kind.rawValue), \(app.stack)) in \(app.folder.isEmpty ? "the repo root" : app.folder + "/"): starts with `\(app.command)`\(app.hasDockerfile ? ", has a Dockerfile" : ", no Dockerfile yet")"
        }.joined(separator: "\n")
        let target = hasCompose ? "Add them as services to \(composeName), beside the services already there" : "Write a docker-compose.yml that runs them"
        let outside = databases.isEmpty ? "" : " The data may live in a database container started outside compose (\(databases.joined(separator: ", "))): say so and ask before pointing a service away from the compose database."
        session.askClaude("""
        Run these parts of the project with Docker Compose for local development:
        \(list)

        \(target). Write a Dockerfile where one is missing (multi-stage, small runtime image, non-root user) and reuse the ones that exist. Wire each service to what it needs (the database and other services) through environment variables read from the code's own config, publish a port that doesn't clash with the others, add depends_on with health checks, and keep secrets out of the files (use .env). Don't change application code.\(outside) Explain each service in a sentence when you're done.
        """)
    }
}

/// This project's containers that compose doesn't manage: started by hand or by a script,
/// like a database (`sp-pg`) or a test build of the app.
private struct ContainersCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let containers: [DockerContainer]
    let busy: String?
    let toggle: (DockerContainer, _ start: Bool) -> Void

    var body: some View {
        Card("This project’s containers") {
            Text("Started outside compose").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                .help("Containers run by hand (docker run) that belong to this project: built from its image or named after it. Nothing else on this Mac is shown.")
        } content: {
            RowList(data: containers, padding: 6) { container in
                HStack(spacing: 10) {
                    Circle()
                        .fill(container.isRunning ? theme.green.color : theme.text3.color.opacity(0.5))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(container.name).font(.dante(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
                            if let engine = container.engine {
                                Text(engine.name).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                            }
                            if let reason = container.belonging(to: session.workspace?.name ?? "") {
                                Text(reason).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color.opacity(0.8))
                            }
                        }
                        Text(([container.image] + container.ports.map { ":\($0.host)" } + [container.status]).joined(separator: " · "))
                            .font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button("Logs") { session.runInTerminal("docker logs --tail 200 -f \(Shell.quote(container.name))") }
                        .buttonStyle(DanteButtonStyle())
                    Button(container.isRunning ? "Stop" : "Start") { toggle(container, !container.isRunning) }
                        .buttonStyle(DanteButtonStyle(primary: !container.isRunning))
                        .disabled(busy != nil)
                }
            }
        }
    }
}
