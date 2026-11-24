import DanteKit
import Foundation
import Observation

/// Quality › Bliksem's state for one window: the target, the routes from the map, and the
/// run in progress, kept here so a run carries on while you look at other pages.
@MainActor @Observable
final class BliksemModel {
    enum Mode: String, CaseIterable, Identifiable {
        case load, fuzz, chaos
        var id: String { rawValue }
        var title: String {
            switch self {
            case .load: "Hammer it"
            case .fuzz: "Throw garbage"
            case .chaos: "Break things"
            }
        }
        var symbol: String {
            switch self {
            case .load: "bolt.fill"
            case .fuzz: "tornado"
            case .chaos: "hammer.fill"
            }
        }
    }

    var mode: Mode = .load
    var target = ""
    /// Addresses that answered, best first, with what they answered.
    var suggestions: [(url: URL, note: String)] = []
    var routes: [BliksemRoute] = []
    var chosen: Set<String> = []
    var includeWrites = false
    var routesLoaded = false
    /// Looking for the servers this project runs (lsof takes a few seconds).
    var findingTargets = false
    var problem: String?

    // Tasks from .dante/bliksem.yaml
    var tasks: BliksemTasks?
    /// Variables the tasks file names that nothing here sets.
    var missingVariables: [String] = []

    // Load
    enum Shape: String, CaseIterable, Identifiable {
        case standard, limit
        var id: String { rawValue }
        var title: String { self == .standard ? "Ramp and spike" : "Find the limit" }
    }
    var shape: Shape = .standard
    var peakUsers = 20
    var seconds = 60
    var loadTick: BliksemRunner.Tick?
    var loadSummary: LoadSummary?
    var loadPlan: LoadPlan?

    // Fuzz
    var fuzzKinds: Set<FuzzPayload.Kind> = Set(FuzzPayload.Kind.allCases)
    var fuzzProgress: BliksemRunner.FuzzProgress?
    var fuzzDone = false

    // Chaos
    var services: [String] = []
    var service: String?
    var fault: ChaosFault = .stop
    var chaosTick: BliksemRunner.ChaosTick?
    var chaosOutcome: BliksemRunner.ChaosOutcome?
    var chaosPlan: ChaosPlan?

    // Watching the target: CPU and memory, and a JVM's stacks
    /// What serves the target, found when a run starts.
    var watchSource: WatchSource?
    var resources: [ResourceSample] = []
    var profiling = true
    var profile: Profile?
    /// Why the last run couldn't be profiled.
    var profileNote: String?
    /// The last load run's requests, for each route's spread of times.
    var samples: [BliksemSample] = []
    var chaosSuggestions: [ChaosSuggestion] = []
    /// The route opened in the list.
    var openRoute: String?
    /// Each opened route's picture, by route id (nil inside when the code can't be read).
    var flows: [String: RouteFlow?] = [:]
    var readingFlows: Set<String> = []
    private var files: [String] = []
    private var watchers: [Task<Void, Never>] = []

    private(set) var running: Mode?
    private var task: Task<Void, Never>?
    private var root: URL?

    var selectedRoutes: [BliksemRoute] {
        routes.filter { chosen.contains($0.id) && ($0.isRead || $0.isTask || includeWrites) }
    }

    /// The load plan the settings make.
    var plan: LoadPlan {
        shape == .limit ? LoadPlan.limit(most: min(peakUsers * 2, Bliksem.maxUsers)) : LoadPlan.standard(peak: peakUsers, seconds: seconds)
    }

    /// The process's environment, mise, then .env and .env.local, later ones winning.
    nonisolated static func environment(root: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.merge(Mise.overlay(for: root)) { _, own in own }
        for name in [".env", ".env.local"] {
            guard let text = try? String(contentsOf: root.appending(path: name), encoding: .utf8) else { continue }
            env.merge(EnvFile.values(text)) { _, file in file }
        }
        return env
    }

    // MARK: Loading

    func load(session: Session, workspace: Workspace) async {
        let root = workspace.url
        if self.root != root {
            self.root = root
            target = UserDefaults.standard.string(forKey: Self.targetKey(root)) ?? ""
            liveHosts = UserDefaults.standard.stringArray(forKey: Self.liveKey(root)) ?? []
            routesLoaded = false
            routes = []
        }
        await restoreLeftBroken(root: root)
        if files != workspace.files { flows = [:]; readingFlows = [] }
        files = workspace.files
        let system: SystemMap
        if let cache = session.mapCache, cache.revision == workspace.revision, let cached = cache.system {
            system = cached
        } else {
            let files = workspace.files
            let compose = ComposeFile.load(projectRoot: root)
            let read = MapView.reader(root: root)
            let modules = await MapView.modules(root: root, files: files)
            system = await Task.detached(priority: .utility) { SystemMap.build(files: files, read: read, compose: compose, modules: modules) }.value
        }
        let file = BliksemTasks.load(projectRoot: root)
        tasks = file
        missingVariables = file.map { file in file.missing(env: Self.environment(root: root)) } ?? []
        let found = (file?.tasks ?? []) + BliksemRoute.from(system)
        if found != routes {
            let known = Set(routes.map(\.id))
            routes = found
            // New reads are chosen; writes only when asked for, and choices already made stay.
            chosen = Set(found.filter { known.contains($0.id) ? chosen.contains($0.id) : true }.map(\.id))
        }
        routesLoaded = true
        await loadServices(root: root)
        await findTargets(root: root)
    }

    func loadServices(root: URL) async {
        guard let compose = ComposeFile.load(projectRoot: root), case .success(let containers) = await ContainerState.load(projectRoot: root) else {
            services = []
            return
        }
        services = ChaosPlan.candidates(compose: compose, containers: containers)
        if service.map({ !services.contains($0) }) ?? true {
            // A database is the most telling thing to break.
            service = services.first { name in ["db", "postgres", "mysql", "mongo", "database"].contains { name.lowercased().contains($0) } } ?? services.first
        }
    }

    /// The servers this project runs: its compose services that serve on a port, and programs
    /// listening here whose working folder is inside the project. Each is asked for the first
    /// few routes, and those that know them come first. Nothing else on this Mac is asked: a
    /// usual port may be another project's server.
    func findTargets(root: URL) async {
        findingTargets = true
        defer { findingTargets = false }
        var candidates: [(URL, String)] = []
        if let compose = ComposeFile.load(projectRoot: root), case .success(let containers) = await ContainerState.load(projectRoot: root) {
            for state in containers where state.state == "running" {
                guard let service = compose.services.first(where: { $0.name == state.service }),
                      case .browser(let url) = ServiceOpening.target(service: service, ports: state.ports) else { continue }
                candidates.append((url, "the compose service \(service.name)"))
            }
        }
        for holder in await PortCheck.holders(await ListeningPort.load()) where !holder.listening.isDocker && holder.belongs(to: root) {
            let url = URL(string: "http://localhost:\(holder.port)")!
            if !candidates.contains(where: { $0.0 == url }) { candidates.append((url, holder.listening.command + " in this project")) }
        }
        let probes = Array(routes.filter { $0.isRead && !$0.isTask }.prefix(3))
        let scored = await withTaskGroup(of: (URL, String, Int)?.self) { group in
            for (url, source) in candidates {
                group.addTask { await Self.probe(url, routes: probes).map { (url, source, $0.1) } }
            }
            var results: [(URL, String, Int)] = []
            for await result in group { if let result { results.append(result) } }
            return results
        }
        suggestions = scored.sorted { ($0.2, $1.0.absoluteString) > ($1.2, $0.0.absoluteString) }.map { url, source, known in
            (url, source + (probes.isEmpty ? "" : known == 0 ? ", which doesn’t know the routes" : ", which knows \(known) of \(probes.count) routes"))
        }
        if target.isEmpty, let best = suggestions.first { target = best.url.absoluteString }
    }

    /// (url, routes it knew, port) when anything answered within half a second.
    nonisolated static func probe(_ url: URL, routes: [BliksemRoute]) async -> (URL, Int, Int)? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.6
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var answered = false
        var known = 0
        for path in routes.isEmpty ? ["/"] : routes.map(\.samplePath) {
            guard let full = BliksemTarget.url(url, path: path) else { continue }
            var request = URLRequest(url: full)
            request.httpMethod = "GET"
            guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
                if !answered { return nil }
                continue
            }
            answered = true
            if http.statusCode != 404, http.statusCode != 405 { known += 1 }
        }
        return answered ? (url, known, url.port ?? 80) : nil
    }

    // MARK: Running

    /// The project's allowed hosts plus the live app's address once the person confirmed it.
    private func hosts(root: URL) -> BrowserHosts {
        let local = BrowserHosts.load(projectRoot: root)
        return BrowserHosts(extra: local.extra + liveHosts)
    }

    private func checkedTarget(root: URL) -> URL? {
        switch BliksemTarget.check(target, hosts: hosts(root: root)) {
        case .success(let url):
            if targetsLive {
                guard mode == .load else {
                    problem = "On the live app only load tests run. Fuzz and chaos stay on this Mac's servers."
                    return nil
                }
                peakUsers = min(peakUsers, LiveLoadTest.maxUsers / 2)
            }
            problem = nil
            UserDefaults.standard.set(target, forKey: Self.targetKey(root))
            return url
        case .failure(let refusal):
            problem = refusal.explanation
            return nil
        }
    }

    func start(session: Session, root: URL) {
        guard running == nil, let base = checkedTarget(root: root) else { return }
        // Tasks and headers are filled from the environment only now, and only for this run.
        let filled = tasks?.filled(env: Self.environment(root: root))
        let routes = selectedRoutes.map { route in filled?.tasks.first { $0.id == route.id } ?? route }
        let headers = filled?.headers ?? [:]
        guard !routes.isEmpty else {
            problem = "Choose at least one route to send to."
            return
        }
        let hosts = hosts(root: root)
        running = mode
        switch mode {
        case .load:
            let plan = self.plan
            let stops = shape == .limit
            loadPlan = plan
            loadTick = nil
            loadSummary = nil
            samples = []
            task = Task {
                let runner = BliksemRunner(base: base, hosts: hosts, connections: plan.peak, headers: headers)
                await self.startWatching(base: base, root: root, profiles: self.profiling)
                let began = ContinuousClock.now
                let samples = await runner.load(plan: plan, routes: routes, stopsWhenBroken: stops) { tick in
                    Task { @MainActor in self.loadTick = tick }
                }
                let elapsed = ContinuousClock.now - began
                let timeline = BliksemStats.seconds(samples) { plan.users(at: Double($0)) }
                let duration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                self.loadTick = BliksemRunner.Tick(elapsed: min(duration, plan.duration), users: 0, stage: "Done", timeline: timeline, routes: BliksemStats.routes(samples))
                self.loadSummary = LoadSummary.make(samples, timeline: timeline, duration: max(duration, 1))
                self.samples = samples
                self.stopWatching()
                self.finish()
            }
        case .fuzz:
            let cases = Fuzz.cases(for: routes.filter { !$0.isTask }, includeWrites: includeWrites, kinds: fuzzKinds)
            fuzzProgress = BliksemRunner.FuzzProgress(done: 0, total: cases.count, findings: [])
            fuzzDone = false
            task = Task {
                let runner = BliksemRunner(base: base, hosts: hosts, timeout: 8, connections: 8, headers: headers)
                let findings = await runner.fuzz(cases) { progress in
                    Task { @MainActor in
                        guard !self.fuzzDone else { return }
                        self.fuzzProgress = progress
                    }
                }
                self.fuzzProgress?.findings = findings
                self.fuzzDone = true
                self.finish()
            }
        case .chaos:
            guard let service, services.contains(service) else {
                problem = "Choose a running service of this project to break."
                running = nil
                return
            }
            let plan = ChaosPlan(service: service, fault: fault)
            chaosPlan = plan
            chaosTick = nil
            chaosOutcome = nil
            // Keep running would put it back on its own; tell it this one is ours for now.
            session.serviceKeeper.youStopped([service], all: services)
            Self.remember(restore: plan, root: root)
            chaosSuggestions = []
            task = Task {
                let runner = BliksemRunner(base: base, hosts: hosts, timeout: 5, connections: 20, headers: headers)
                await self.startWatching(base: base, root: root, profiles: false)
                let outcome = await runner.chaos(plan, routes: routes, projectRoot: root) { tick in
                    Task { @MainActor in
                        guard self.chaosOutcome == nil else { return }
                        self.chaosTick = tick
                    }
                }
                Self.forget(restore: root)
                session.serviceKeeper.youStarted([service], all: self.services)
                self.chaosOutcome = outcome
                self.chaosTick = BliksemRunner.ChaosTick(phase: .done, elapsed: outcome.times.ended,
                                                         timeline: BliksemStats.seconds(outcome.samples) { _ in plan.users }, times: outcome.times)
                if let problem = outcome.problem { self.problem = problem }
                self.stopWatching()
                if let analysis = outcome.analysis { await self.suggest(analysis, plan: plan, root: root) }
                self.finish()
                await self.loadServices(root: root)
            }
        }
    }

    // MARK: Watching

    /// The program or container serving `base` on this Mac: a running compose service
    /// publishing its port, or the program listening on it.
    func findSource(base: URL, root: URL) async -> WatchSource? {
        guard let host = base.host(percentEncoded: false)?.lowercased(), ["localhost", "127.0.0.1", "::1"].contains(host) else { return nil }
        let port = base.port ?? (base.scheme == "https" ? 443 : 80)
        if case .success(let containers) = await ContainerState.load(projectRoot: root),
           let container = containers.first(where: { $0.state == "running" && $0.ports.contains { $0.contains(":\(port)->") } }) {
            return .container(name: container.name, service: container.service)
        }
        if let listening = await ListeningPort.load().first(where: { $0.port == port && !$0.isDocker }) {
            return .process(pid: listening.pid, command: listening.command)
        }
        return nil
    }

    private func startWatching(base: URL, root: URL, profiles: Bool) async {
        resources = []
        profile = nil
        profileNote = nil
        watchSource = await findSource(base: base, root: root)
        guard let source = watchSource else { return }
        let start = ContinuousClock.now
        watchers.append(Task.detached {
            await BliksemWatcher.resources(source, root: root, since: start) { sample in
                Task { @MainActor in self.resources.append(sample) }
            }
        })
        guard profiles else { return }
        switch await BliksemWatcher.dumpCommand(source, root: root) {
        case .success(let command):
            let files = files
            let read = MapView.reader(root: root)
            let packages = await Task.detached(priority: .utility) { Profile.packages(files: files, read: read) }.value
            guard !packages.isEmpty else {
                profileNote = "The profiler shows the project’s own code, and no Kotlin or Java package was found in it."
                return
            }
            profile = Profile(packages: packages)
            watchers.append(Task.detached {
                await BliksemWatcher.profile(command: command, root: root) { stacks in
                    Task { @MainActor in self.profile?.add(stacks) }
                }
            })
        case .failure(let refusal):
            profileNote = refusal.explanation
        }
    }

    private func stopWatching() {
        for watcher in watchers { watcher.cancel() }
        watchers = []
    }

    // MARK: Routes opened

    /// The route in the code behind a row (a task's handler, or the route itself).
    func handler(of route: BliksemRoute) -> BliksemRoute? { route.handler(in: routes) }

    /// Reads the picture of what a route does, once.
    func loadFlow(_ route: BliksemRoute, root: URL) {
        guard flows[route.id] == nil, !readingFlows.contains(route.id) else { return }
        guard let handler = handler(of: route), let file = handler.file, let line = handler.line else {
            flows[route.id] = .some(nil)
            return
        }
        readingFlows.insert(route.id)
        let files = files
        let read = MapView.reader(root: root)
        let title = "\(handler.method) \(handler.path)"
        Task {
            let flow = await Task.detached(priority: .userInitiated) { RouteFlow.build(file: file, line: line, title: title, files: files, read: read) }.value
            self.readingFlows.remove(route.id)
            self.flows[route.id] = .some(flow)
        }
    }

    /// The figures of one route from the last load run.
    func times(of route: BliksemRoute) -> [Double] {
        samples.filter { $0.route == route.id && !$0.failed }.map(\.duration).sorted()
    }

    // MARK: Chaos advice

    private func suggest(_ analysis: ChaosAnalysis, plan: ChaosPlan, root: URL) async {
        let files = files
        let read = MapView.reader(root: root)
        let health = routes.first { !$0.isTask && $0.file != nil && LocalHealth.routes.contains($0.path) }
            .flatMap { route in route.file.map { ($0, route.line ?? 1) } }
        chaosSuggestions = await Task.detached(priority: .utility) {
            ChaosAdvice.suggest(analysis, service: plan.service, fault: plan.fault, files: files, read: read, healthRoute: health)
        }.value
    }

    /// Stops the run; a chaos run still puts its service back first.
    func stop() {
        task?.cancel()
    }

    private func finish() {
        running = nil
        task = nil
    }

    // MARK: A service left broken

    /// Written before a fault and removed once the service is back, so a run cut off by a
    /// quit or a crash is put right the next time the page opens.
    private static func restoreKey(_ root: URL) -> String { "bliksem.restore." + root.path }
    private static func targetKey(_ root: URL) -> String { "bliksem.target." + root.path }
    private static func liveKey(_ root: URL) -> String { "bliksem.liveHosts." + root.path }

    // MARK: The live app

    /// The deployed app's own addresses the person allowed load tests on, for this project.
    var liveHosts: [String] = []

    /// Whether the target is one of them.
    var targetsLive: Bool {
        guard let host = URL(string: target.contains("://") ? target : "https://" + target)?.host(percentEncoded: false)?.lowercased() else { return false }
        return liveHosts.contains(host)
    }

    /// Allows load tests on the live app's address (confirmed in Deploy) and points Load at it.
    func allowLive(_ url: URL, root: URL) {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return }
        if !liveHosts.contains(host) { liveHosts.append(host) }
        UserDefaults.standard.set(liveHosts, forKey: Self.liveKey(root))
        target = url.absoluteString
        mode = .load
        peakUsers = min(peakUsers, LiveLoadTest.maxUsers / 2)
        problem = nil
    }

    /// Takes the live address off the list again.
    func forgetLive(root: URL) {
        let host = URL(string: target)?.host(percentEncoded: false)?.lowercased()
        liveHosts.removeAll { $0 == host }
        UserDefaults.standard.set(liveHosts, forKey: Self.liveKey(root))
        target = ""
    }

    private static func remember(restore plan: ChaosPlan, root: URL) {
        guard let command = plan.fault.restoring(plan.service) else { return }
        UserDefaults.standard.set(command, forKey: restoreKey(root))
    }

    private static func forget(restore root: URL) {
        UserDefaults.standard.removeObject(forKey: restoreKey(root))
    }

    private func restoreLeftBroken(root: URL) async {
        guard running == nil, let command = UserDefaults.standard.stringArray(forKey: Self.restoreKey(root)),
              command.count == 4, command[0] == "docker", command[1] == "compose", ["start", "unpause"].contains(command[2]) else { return }
        let output = await Shell.run(command, in: root, timeout: .seconds(120))
        Self.forget(restore: root)
        problem = output.succeeded
            ? "The last chaos run was cut off, so \(command[3]) has been put back (docker compose \(command[2]) \(command[3]))."
            : "The last chaos run was cut off and \(command[3]) couldn’t be put back: \(output.message.prefix(200)) Start it from Services."
    }
}
