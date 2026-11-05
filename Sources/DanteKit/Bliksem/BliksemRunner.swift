import Foundation

/// Sends Bliksem's requests: load from virtual users, fuzz cases, and the light load a chaos
/// run watches. Every request's URL is checked against `BrowserHosts` before it goes, and
/// redirects aren't followed, so nothing leaves the hosts the target was checked against.
public final class BliksemRunner: Sendable {
    public let base: URL
    let hosts: BrowserHosts
    let session: URLSession

    public init(base: URL, hosts: BrowserHosts, timeout: TimeInterval = 10, connections: Int = Bliksem.maxUsers) {
        self.base = base
        self.hosts = hosts
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpMaximumConnectionsPerHost = connections
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public struct Answer: Sendable {
        public var sample: BliksemSample
        public var body: String
        public var contentType: String?
    }

    /// One request, timed. Nil when cancelled, so a stopped run doesn't count its own stop
    /// as failures.
    func send(_ request: URLRequest, route: String, since start: ContinuousClock.Instant, keepsBody: Bool = false) async -> Answer? {
        let began = ContinuousClock.now
        let offset = (began - start).seconds
        guard let url = request.url, hosts.allows(url) else {
            return Answer(sample: BliksemSample(route: route, start: offset, duration: 0, status: nil, error: "refused: not a local host"), body: "", contentType: nil)
        }
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let body = keepsBody ? String(decoding: data.prefix(200_000), as: UTF8.self) : ""
            return Answer(sample: BliksemSample(route: route, start: offset, duration: (ContinuousClock.now - began).seconds, status: http?.statusCode),
                          body: body, contentType: http?.value(forHTTPHeaderField: "Content-Type"))
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return nil }
            return Answer(sample: BliksemSample(route: route, start: offset, duration: (ContinuousClock.now - began).seconds, status: nil, error: Self.describe(error)),
                          body: "", contentType: nil)
        }
    }

    static func describe(_ error: Error) -> String {
        switch (error as? URLError)?.code {
        case .timedOut: "timed out"
        case .cannotConnectToHost: "refused"
        case .networkConnectionLost: "connection dropped"
        case .badServerResponse: "bad response"
        case .cannotFindHost: "no such host"
        default: "failed"
        }
    }

    /// The plain request for a route under load: its sample path, and `{}` for a body.
    public func request(_ route: BliksemRoute) -> URLRequest? {
        guard let url = BliksemTarget.url(base, path: route.samplePath) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = route.method
        request.setValue("Dante Bliksem", forHTTPHeaderField: "User-Agent")
        if route.takesBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
        }
        return request
    }

    // MARK: Load

    public struct Tick: Sendable {
        public var elapsed: Double
        public var users: Int
        public var stage: String
        public var timeline: [BliksemSecond]
        public var routes: [BliksemRouteStats]

        public init(elapsed: Double, users: Int, stage: String, timeline: [BliksemSecond], routes: [BliksemRouteStats]) {
            self.elapsed = elapsed
            self.users = users
            self.stage = stage
            self.timeline = timeline
            self.routes = routes
        }
    }

    /// Runs the plan, calling `tick` every second, until it ends or the task is cancelled.
    public func load(plan: LoadPlan, routes: [BliksemRoute], tick: @escaping @Sendable (Tick) -> Void) async -> [BliksemSample] {
        let requests = routes.compactMap { route in request(route).map { (route.id, $0) } }
        guard !requests.isEmpty else { return [] }
        let sink = SampleSink()
        let start = ContinuousClock.now
        let users = plan.peak
        await withTaskGroup(of: Void.self) { group in
            for user in 0..<users {
                group.addTask {
                    var next = user
                    while !Task.isCancelled {
                        let t = (ContinuousClock.now - start).seconds
                        if t >= plan.duration { return }
                        if user >= plan.users(at: t) {
                            try? await Task.sleep(for: .milliseconds(100))
                            continue
                        }
                        let (route, request) = requests[next % requests.count]
                        next += 1
                        if let answer = await self.send(request, route: route, since: start) { await sink.add(answer.sample) }
                    }
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    let t = (ContinuousClock.now - start).seconds
                    // Whole seconds only, so the one still filling doesn't look like a dip.
                    let samples = await sink.samples.filter { $0.start < t.rounded(.down) }
                    let stage = plan.stage(at: t)
                    tick(Tick(elapsed: min(t, plan.duration), users: stage.users, stage: stage.name,
                              timeline: BliksemStats.seconds(samples) { plan.users(at: Double($0)) }, routes: BliksemStats.routes(samples)))
                    if t >= plan.duration { return }
                }
            }
        }
        return await sink.samples
    }

    // MARK: Fuzz

    public struct FuzzProgress: Sendable {
        public var done: Int
        public var total: Int
        public var findings: [FuzzFinding]

        public init(done: Int, total: Int, findings: [FuzzFinding]) {
            self.done = done
            self.total = total
            self.findings = findings
        }
    }

    /// Sends every case, four at a time, after one plain request per route to know how it
    /// answers normally.
    public func fuzz(_ cases: [FuzzCase], timeout: TimeInterval = 8, progress: @escaping @Sendable (FuzzProgress) -> Void) async -> [FuzzFinding] {
        let start = ContinuousClock.now
        var baseline: [String: Int] = [:]
        for route in Set(cases.map(\.route)) {
            guard !Task.isCancelled, let request = request(route) else { continue }
            if let answer = await send(request, route: route.id, since: start), let status = answer.sample.status { baseline[route.id] = status }
        }
        let known = baseline
        var findings: [FuzzFinding] = []
        var done = 0
        await withTaskGroup(of: FuzzFinding?.self) { group in
            var pending = cases.makeIterator()
            func addNext() -> Bool {
                guard let fuzz = pending.next() else { return false }
                group.addTask {
                    guard let request = Fuzz.request(fuzz, base: self.base, timeout: timeout),
                          let answer = await self.send(request, route: fuzz.route.id, since: start, keepsBody: true) else { return nil }
                    return Fuzz.classify(fuzz, status: answer.sample.status, error: answer.sample.error, contentType: answer.contentType,
                                         body: answer.body, duration: answer.sample.duration, timeout: timeout, baselineStatus: known[fuzz.route.id])
                }
                return true
            }
            for _ in 0..<4 where addNext() {}
            while let result = await group.next() {
                done += 1
                if let result { findings.append(result) }
                if done % 5 == 0 || result != nil { progress(FuzzProgress(done: done, total: cases.count, findings: Fuzz.merged(findings))) }
                if Task.isCancelled { group.cancelAll(); break }
                _ = addNext()
            }
        }
        progress(FuzzProgress(done: done, total: cases.count, findings: Fuzz.merged(findings)))
        return Fuzz.merged(findings)
    }

    // MARK: Chaos

    public enum ChaosPhase: String, Sendable {
        case baseline = "Measuring normal"
        case breaking = "Breaking it"
        case outage = "Broken"
        case restoring = "Putting it back"
        case recovering = "Watching it recover"
        case done = "Done"
    }

    public struct ChaosTick: Sendable {
        public var phase: ChaosPhase
        public var elapsed: Double
        public var timeline: [BliksemSecond]
        public var times: ChaosTimes?

        public init(phase: ChaosPhase, elapsed: Double, timeline: [BliksemSecond], times: ChaosTimes?) {
            self.phase = phase
            self.elapsed = elapsed
            self.timeline = timeline
            self.times = times
        }
    }

    public struct ChaosOutcome: Sendable {
        public var samples: [BliksemSample]
        public var times: ChaosTimes
        public var analysis: ChaosAnalysis?
        /// Why the fault or the restore didn't happen.
        public var problem: String?
    }

    /// Light load throughout; the fault after the baseline; the service always put back, even
    /// when the run is stopped, through a task the stop can't cancel.
    public func chaos(_ plan: ChaosPlan, routes: [BliksemRoute], projectRoot: URL, tick: @escaping @Sendable (ChaosTick) -> Void) async -> ChaosOutcome {
        let requests = routes.filter(\.isRead).compactMap { route in request(route).map { (route.id, $0) } }
        let sink = SampleSink()
        let start = ContinuousClock.now
        func now() -> Double { (ContinuousClock.now - start).seconds }
        let users = min(max(plan.users, 1), 20)
        let traffic = Task {
            await withTaskGroup(of: Void.self) { group in
                for user in 0..<users {
                    group.addTask {
                        var next = user
                        while !Task.isCancelled, !requests.isEmpty {
                            let (route, request) = requests[next % requests.count]
                            next += 1
                            if let answer = await self.send(request, route: route, since: start) { await sink.add(answer.sample) }
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    }
                }
            }
        }
        let phase = PhaseBox()
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let (current, times) = await phase.get()
                let whole = now().rounded(.down)
                tick(ChaosTick(phase: current, elapsed: now(), timeline: BliksemStats.seconds(await sink.samples.filter { $0.start < whole }) { _ in users }, times: times))
            }
        }
        defer { traffic.cancel(); ticker.cancel() }

        await phase.set(.baseline)
        try? await Task.sleep(for: .seconds(plan.baseline))
        if Task.isCancelled { return ChaosOutcome(samples: await sink.samples, times: ChaosTimes(broke: now(), restored: now(), ended: now()), problem: "Stopped before anything was broken.") }

        await phase.set(.breaking)
        let broke = now()
        let breaking = await Self.uncancelled { await Shell.run(plan.fault.breaking(plan.service), in: projectRoot, timeout: .seconds(90)) }
        guard breaking.succeeded else {
            let times = ChaosTimes(broke: broke, restored: now(), ended: now())
            return ChaosOutcome(samples: await sink.samples, times: times, problem: "Docker couldn’t \(plan.fault.rawValue) \(plan.service): " + breaking.message.prefix(300))
        }
        if plan.fault != .restart {
            await phase.set(.outage, ChaosTimes(broke: broke, restored: broke + plan.outage, ended: broke + plan.outage))
            try? await Task.sleep(for: .seconds(plan.outage))
        }

        // Put it back whatever happens; Stop only shortens the outage and the watch.
        var problem: String?
        if let restore = plan.fault.restoring(plan.service) {
            await phase.set(.restoring)
            let restored = await Self.uncancelled { await Shell.run(restore, in: projectRoot, timeout: .seconds(120)) }
            if !restored.succeeded { problem = "Docker couldn’t put \(plan.service) back: " + restored.message.prefix(300) + " Start it from Services." }
        }
        let restored = now()
        await phase.set(.recovering, ChaosTimes(broke: broke, restored: restored, ended: restored + plan.recovery))
        while !Task.isCancelled, now() < restored + plan.recovery {
            try? await Task.sleep(for: .seconds(1))
            let samples = await sink.samples
            let sofar = ChaosAnalysis.analyse(samples, times: ChaosTimes(broke: broke, restored: restored, ended: now()))
            if case .recovered = sofar.verdict, now() > restored + 5 { break }
            if case .rodeItOut = sofar.verdict, now() > restored + 5 { break }
        }
        traffic.cancel()
        let times = ChaosTimes(broke: broke, restored: restored, ended: now())
        await phase.set(.done, times)
        let samples = await sink.samples
        return ChaosOutcome(samples: samples, times: times, analysis: ChaosAnalysis.analyse(samples, times: times), problem: problem)
    }

    /// Runs work the caller's cancellation can't stop.
    static func uncancelled<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        await Task.detached(operation: work).value
    }
}

actor SampleSink {
    private(set) var samples: [BliksemSample] = []
    func add(_ sample: BliksemSample) { samples.append(sample) }
}

private actor PhaseBox {
    var phase: BliksemRunner.ChaosPhase = .baseline
    var times: ChaosTimes?
    func set(_ phase: BliksemRunner.ChaosPhase, _ times: ChaosTimes? = nil) {
        self.phase = phase
        if let times { self.times = times }
    }
    func get() -> (BliksemRunner.ChaosPhase, ChaosTimes?) { (phase, times) }
}

/// Answers redirects with nothing, so a 302 elsewhere is reported rather than followed.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
