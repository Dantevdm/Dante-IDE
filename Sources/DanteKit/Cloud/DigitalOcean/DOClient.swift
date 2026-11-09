import Foundation

/// DigitalOcean's API (api.digitalocean.com/v2) with the signed-in account's token. Requests
/// only ever go to that host, through an ephemeral session that doesn't follow redirects; logs
/// come from the signed links the API hands out, fetched without the token.
public struct DOClient: Sendable {
    public static let host = "api.digitalocean.com"
    static let base = URL(string: "https://api.digitalocean.com/v2/")!

    let token: @Sendable () async -> String?

    public init(token: @escaping @Sendable () async -> String? = { await DOAccount.accessToken() }) {
        self.token = token
    }

    public struct Failure: Error, Equatable, Sendable {
        public var status: Int
        public var id: String?
        public var message: String

        public init(status: Int, id: String? = nil, message: String) {
            self.status = status
            self.id = id
            self.message = message
        }

        public static let signedOut = Failure(status: 401, id: "signed_out", message: "Not signed in to DigitalOcean.")

        public var isSignedOut: Bool { status == 401 }
        public var isMissing: Bool { status == 404 }
        /// The request was dropped because the page that asked went away: not worth saying.
        public var isCancelled: Bool { id == "cancelled" }
        /// No answer in time: the request may still have done its work on DigitalOcean's side.
        public var isTimedOut: Bool { id == "timed_out" }
        static let cancelled = Failure(status: 0, id: "cancelled", message: "Cancelled.")

        /// DigitalOcean's `{"id": "…", "message": "…"}`.
        public static func parse(status: Int, data: Data) -> Failure {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (json?["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            switch status {
            case 401: return Failure(status: 401, id: json?["id"] as? String, message: "DigitalOcean no longer accepts the sign-in. Sign in again.")
            case 403: return Failure(status: 403, id: json?["id"] as? String, message: message ?? "The sign-in isn't allowed to do that.")
            case 429: return Failure(status: 429, id: "too_many", message: "DigitalOcean is limiting requests for a moment.")
            default: return Failure(status: status, id: json?["id"] as? String, message: message ?? "DigitalOcean answered \(status).")
            }
        }
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }()

    // MARK: Requests

    func send(_ method: String, _ path: String, query: [String: String] = [:], body: [String: any Sendable]? = nil) async throws(Failure) -> Data {
        try await send(method, path, query: query, json: body.flatMap { try? JSONSerialization.data(withJSONObject: $0) })
    }

    func send(_ method: String, _ path: String, query: [String: String] = [:], json body: Data?, timeout: TimeInterval = 30) async throws(Failure) -> Data {
        guard let token = await token() else { throw .signedOut }
        var components = URLComponents(url: Self.base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url, url.host == Self.host, url.scheme == "https" else { throw Failure(status: 0, message: "Not a DigitalOcean address.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await Self.session.data(for: request) } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw Failure.cancelled }
            if (error as? URLError)?.code == .timedOut { throw Failure(status: 0, id: "timed_out", message: "DigitalOcean took too long to answer.") }
            throw Failure(status: 0, message: "DigitalOcean couldn't be reached: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 { DOAccount.forget() }
            throw Failure.parse(status: status, data: data)
        }
        return data
    }

    func object(_ data: Data) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data, key: String) throws(Failure) -> T {
        guard let inner = object(data)[key], let innerData = try? JSONSerialization.data(withJSONObject: inner),
              let value = try? DOJSON.decoder.decode(T.self, from: innerData) else {
            throw Failure(status: 0, message: "DigitalOcean's answer wasn't what Dante expected.")
        }
        return value
    }

    // MARK: Account

    public func account() async throws(Failure) -> DOAccountInfo {
        try decode(DOAccountInfo.self, try await send("GET", "account"), key: "account")
    }

    // MARK: Apps

    public func apps() async throws(Failure) -> [DOApp] {
        let data = try await send("GET", "apps", query: ["per_page": "200"])
        return (object(data)["apps"] as? [Any] ?? []).compactMap(DOApp.parse)
    }

    public func app(_ id: String) async throws(Failure) -> DOApp {
        guard let app = DOApp.parse(object(try await send("GET", "apps/\(id)"))["app"] as Any) else { throw Failure(status: 0, message: "The app's details weren't readable.") }
        return app
    }

    /// `{"spec": …}` around a spec already in JSON (`DOSpecSend.json`).
    static func wrap(_ spec: Data, appID: String? = nil) -> Data {
        var body = Data("{\"spec\":".utf8) + spec
        if let appID, let id = try? JSONSerialization.data(withJSONObject: appID, options: .fragmentsAllowed) { body += Data(",\"app_id\":".utf8) + id }
        return body + Data("}".utf8)
    }

    /// Checks a spec and prices it without making anything.
    public func propose(_ spec: Data, appID: String? = nil) async throws(Failure) -> DOProposal {
        let data = try await send("POST", "apps/propose", json: Self.wrap(spec, appID: appID), timeout: 90)
        return (try? DOJSON.decoder.decode(DOProposal.self, from: data)) ?? DOProposal()
    }

    public func create(_ spec: Data) async throws(Failure) -> DOApp {
        guard let app = DOApp.parse(object(try await send("POST", "apps", json: Self.wrap(spec), timeout: 120))["app"] as Any) else { throw Failure(status: 0, message: "DigitalOcean made the app but its answer wasn't readable.") }
        return app
    }

    public func update(_ id: String, spec: Data) async throws(Failure) -> DOApp {
        guard let app = DOApp.parse(object(try await send("PUT", "apps/\(id)", json: Self.wrap(spec), timeout: 120))["app"] as Any) else { throw Failure(status: 0, message: "DigitalOcean updated the app but its answer wasn't readable.") }
        return app
    }

    public func delete(_ id: String) async throws(Failure) {
        _ = try await send("DELETE", "apps/\(id)")
    }

    public func deployments(_ appID: String) async throws(Failure) -> [DODeployment] {
        try decode([DODeployment].self, try await send("GET", "apps/\(appID)/deployments", query: ["per_page": "20"]), key: "deployments")
    }

    /// A new deployment of the app as it's specified; `forceBuild` rebuilds from source even
    /// when nothing changed.
    public func deploy(_ appID: String, forceBuild: Bool = true) async throws(Failure) -> DODeployment {
        try decode(DODeployment.self, try await send("POST", "apps/\(appID)/deployments", body: ["force_build": forceBuild]), key: "deployment")
    }

    public func cancel(_ appID: String, deployment: String) async throws(Failure) {
        _ = try await send("POST", "apps/\(appID)/deployments/\(deployment)/cancel")
    }

    /// Puts an earlier deployment back (its build, as it was). App Platform pins it, so pushes
    /// don't deploy until the rollback is committed or reverted.
    public func rollback(_ appID: String, to deployment: String) async throws(Failure) {
        _ = try await send("POST", "apps/\(appID)/rollback", body: ["deployment_id": deployment, "skip_pin": false])
    }

    public func commitRollback(_ appID: String) async throws(Failure) {
        _ = try await send("POST", "apps/\(appID)/rollback/commit")
    }

    public func health(_ appID: String) async throws(Failure) -> [DOComponentHealth] {
        let data = try await send("GET", "apps/\(appID)/health")
        return (try? DOJSON.decoder.decode(DOComponentHealth.Wrapper.self, from: data))?.appHealth?.components ?? []
    }

    public func alerts(_ appID: String) async throws(Failure) -> [DOAlert] {
        try decode([DOAlert].self, try await send("GET", "apps/\(appID)/alerts"), key: "alerts")
    }

    public func instanceSizes() async throws(Failure) -> [DOInstanceSize] {
        try decode([DOInstanceSize].self, try await send("GET", "apps/tiers/instance_sizes"), key: "instance_sizes")
    }

    public enum LogKind: String, CaseIterable, Sendable {
        case build = "BUILD", deploy = "DEPLOY", run = "RUN"
        public var title: String {
            switch self {
            case .build: "Build"
            case .deploy: "Deploy"
            case .run: "Runtime"
            }
        }
    }

    /// The text of a deployment's logs (every component's, or one's), from the signed links
    /// DigitalOcean gives for them.
    public func logs(_ appID: String, deployment: String, component: String?, kind: LogKind) async throws(Failure) -> String {
        let path = component.map { "apps/\(appID)/deployments/\(deployment)/components/\($0)/logs" } ?? "apps/\(appID)/deployments/\(deployment)/logs"
        // Without tail_lines, runtime logs come back empty; doctl always sends it.
        let data = try await send("GET", path, query: ["type": kind.rawValue, "follow": "false", "tail_lines": "1000"])
        let links = (try? DOJSON.decoder.decode(DOLogLinks.self, from: data)) ?? DOLogLinks()
        var text = ""
        for link in links.historicUrls ?? [] {
            guard let url = URL(string: link), url.scheme == "https" else { continue }
            if let (body, response) = try? await Self.session.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200 {
                text += String(decoding: body, as: UTF8.self)
            }
        }
        // Runtime logs come only as a stream: without following, it sends the last lines and closes.
        if text.isEmpty, let live = links.liveUrl.flatMap(Self.socketURL) {
            text = await Self.readStream(live)
        }
        return Self.plain(text)
    }

    /// Log text without the terminal colour codes App Platform's builder writes.
    public static func plain(_ text: String) -> String {
        text.replacing(/\x{1B}\[[0-9;?]*[A-Za-z]/, with: "")
    }

    /// The stream's address as a WebSocket one (doctl swaps the scheme the same way).
    static func socketURL(_ link: String) -> URL? {
        guard var components = URLComponents(string: link) else { return nil }
        switch components.scheme {
        case "https", "wss": components.scheme = "wss"
        default: return nil
        }
        return components.url
    }

    /// A stream message's log text: `{"data": "…"}`, or the message itself.
    public static func streamText(_ message: String) -> String {
        if let data = message.data(using: .utf8), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let line = json["data"] as? String {
            return line.hasSuffix("\n") ? line : line + "\n"
        }
        return message.hasSuffix("\n") ? message : message + "\n"
    }

    /// Reads the stream until it closes, or for `seconds` at most.
    static func readStream(_ url: URL, seconds: Double = 6) async -> String {
        let task = session.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let deadline = Date.now.addingTimeInterval(seconds)
        var text = ""
        while Date.now < deadline, text.utf8.count < 400_000 {
            let message = await withTaskGroup(of: URLSessionWebSocketTask.Message?.self) { group in
                group.addTask { try? await task.receive() }
                group.addTask {
                    try? await Task.sleep(for: .seconds(max(0.1, deadline.timeIntervalSinceNow)))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let message else { break }
            switch message {
            case .string(let string): text += streamText(string)
            case .data(let data): text += streamText(String(decoding: data, as: UTF8.self))
            @unknown default: break
            }
        }
        return text
    }

    // MARK: Metrics

    public enum Metric: String, Sendable {
        case cpu = "cpu_percentage", memory = "memory_percentage", restarts = "restart_count"
    }

    public func metric(_ metric: Metric, appID: String, component: String?, since: Date, until: Date = .now) async throws(Failure) -> DOSeries {
        var query = ["app_id": appID, "start": String(Int(since.timeIntervalSince1970)), "end": String(Int(until.timeIntervalSince1970))]
        if let component { query["app_component"] = component }
        return DOSeries.parse(try await send("GET", "monitoring/metrics/apps/\(metric.rawValue)", query: query))
    }

    // MARK: Container registry

    /// The account's registry, if it has one. Older accounts answer only on `/registry`.
    public func registry() async throws(Failure) -> DORegistry? {
        do {
            let list = try decode([DORegistry].self, try await send("GET", "registries"), key: "registries")
            if let first = list.first { return first }
        } catch where error.isMissing || error.status == 0 {}
        do {
            return try decode(DORegistry.self, try await send("GET", "registry"), key: "registry")
        } catch where error.isMissing {
            return nil
        }
    }

    /// Makes a registry on the free Starter plan (one repository, 500 MB).
    public func createRegistry(name: String, region: String) async throws(Failure) -> DORegistry {
        let body: [String: any Sendable] = ["name": name, "region": region, "subscription_tier_slug": "starter"]
        return try decode(DORegistry.self, try await send("POST", "registry", body: body), key: "registry")
    }

    /// How many repositories the registry's plan holds (nil or 0: no limit Dante knows of).
    public func registryRepositoryLimit() async throws(Failure) -> Int? {
        let data = try await send("GET", "registry/subscription")
        let tier = (object(data)["subscription"] as? [String: Any])?["tier"] as? [String: Any]
        return tier?["included_repositories"] as? Int
    }

    /// The registry's repository names.
    public func repositories(registry: String) async throws(Failure) -> [String] {
        let data = try await send("GET", "registry/\(registry)/repositoriesV2", query: ["per_page": "200"])
        return (object(data)["repositories"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    /// Docker credentials that push to the registry for `seconds`, as a Docker config.json.
    public func dockerConfig(seconds: Int = 1800) async throws(Failure) -> Data {
        try await send("GET", "registry/docker-credentials", query: ["read_write": "true", "expiry_seconds": String(seconds)])
    }

    // MARK: Databases

    public struct Cluster: Decodable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var engine: String?
    }

    public func databases() async throws(Failure) -> [Cluster] {
        try decode([Cluster].self, try await send("GET", "databases"), key: "databases")
    }

    public struct FirewallRule: Decodable, Equatable, Sendable {
        public var type: String?
        public var value: String?
    }

    public func trustedSources(cluster: String) async throws(Failure) -> [FirewallRule] {
        try decode([FirewallRule].self, try await send("GET", "databases/\(cluster)/firewall"), key: "rules")
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
