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

    // Load
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

    private(set) var running: Mode?
    private var task: Task<Void, Never>?
    private var root: URL?

    var selectedRoutes: [BliksemRoute] {
        routes.filter { chosen.contains($0.id) && ($0.isRead || includeWrites) }
    }

    // MARK: Loading

    func load(session: Session, workspace: Workspace) async {
        let root = workspace.url
        if self.root != root {
            self.root = root
            target = UserDefaults.standard.string(forKey: Self.targetKey(root)) ?? ""
            routesLoaded = false
            routes = []
        }
        await restoreLeftBroken(root: root)
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
        let found = BliksemRoute.from(system)
        if found.map(\.id) != routes.map(\.id) {
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
        let probes = Array(routes.filter(\.isRead).prefix(3))
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

    private func checkedTarget(root: URL) -> URL? {
        switch BliksemTarget.check(target, hosts: BrowserHosts.load(projectRoot: root)) {
        case .success(let url):
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
        let routes = selectedRoutes
        guard !routes.isEmpty else {
            problem = "Choose at least one route to send to."
            return
        }
        let hosts = BrowserHosts.load(projectRoot: root)
        running = mode
        switch mode {
        case .load:
            let plan = LoadPlan.standard(peak: peakUsers, seconds: seconds)
            loadPlan = plan
            loadTick = nil
            loadSummary = nil
            task = Task {
                let runner = BliksemRunner(base: base, hosts: hosts, connections: plan.peak)
                let began = ContinuousClock.now
                let samples = await runner.load(plan: plan, routes: routes) { tick in
                    Task { @MainActor in self.loadTick = tick }
                }
                let elapsed = ContinuousClock.now - began
                let timeline = BliksemStats.seconds(samples) { plan.users(at: Double($0)) }
                let duration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                self.loadTick = BliksemRunner.Tick(elapsed: min(duration, plan.duration), users: 0, stage: "Done", timeline: timeline, routes: BliksemStats.routes(samples))
                self.loadSummary = LoadSummary.make(samples, timeline: timeline, duration: max(duration, 1))
                self.finish()
            }
        case .fuzz:
            let cases = Fuzz.cases(for: routes, includeWrites: includeWrites, kinds: fuzzKinds)
            fuzzProgress = BliksemRunner.FuzzProgress(done: 0, total: cases.count, findings: [])
            fuzzDone = false
            task = Task {
                let runner = BliksemRunner(base: base, hosts: hosts, timeout: 8, connections: 8)
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
            task = Task {
                let runner = BliksemRunner(base: base, hosts: hosts, timeout: 5, connections: 20)
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
                self.finish()
                await self.loadServices(root: root)
            }
        }
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
