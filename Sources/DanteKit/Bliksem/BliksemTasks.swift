import Foundation
import Yams

/// `.dante/bliksem.yaml`: the work an app does beyond a bare GET, so Bliksem can measure it.
///
///     headers:                      # sent with every request
///       X-API-Key: ${API_KEY}       # filled from the environment, .env and mise
///     tasks:
///       - name: Price an order
///         method: POST
///         path: /api/v1/quotes
///         headers: { Accept: application/pdf }
///         body: |
///           {"items": [{"sku": "A1", "count": 2}]}
///
/// Values are never written back; `${NAME}` stays a reference in the file. Read leniently:
/// a task without a path is skipped and named in `problems`.
public struct BliksemTasks: Equatable, Sendable {
    public var headers: [String: String] = [:]
    public var tasks: [BliksemRoute] = []
    public var problems: [String] = []

    public static let path = ".dante/bliksem.yaml"

    public init(headers: [String: String] = [:], tasks: [BliksemRoute] = [], problems: [String] = []) {
        self.headers = headers
        self.tasks = tasks
        self.problems = problems
    }

    public static func load(projectRoot root: URL) -> BliksemTasks? {
        guard let text = try? String(contentsOf: root.appending(path: path), encoding: .utf8) else { return nil }
        return parse(text)
    }

    public static func parse(_ text: String) -> BliksemTasks {
        let object: Any?
        do { object = try Yams.load(yaml: text) } catch {
            return BliksemTasks(problems: ["\(path) isn’t valid YAML: \(String(describing: error).prefix(160))"])
        }
        guard let root = object as? [String: Any] else { return BliksemTasks() }
        var result = BliksemTasks(headers: strings(root["headers"]))
        for (index, raw) in ((root["tasks"] ?? root["workloads"]) as? [Any] ?? []).enumerated() {
            guard let entry = raw as? [String: Any] else { continue }
            let name = (entry["name"] as? String) ?? "Task \(index + 1)"
            guard let path = entry["path"] as? String, !path.isEmpty else {
                result.problems.append("“\(name)” has no path, so it’s left out.")
                continue
            }
            var body: String?
            if let text = entry["body"] as? String {
                body = text
            } else if let value = entry["body"], JSONSerialization.isValidJSONObject(value),
                      let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                body = String(decoding: data, as: UTF8.self)
            }
            var route = BliksemRoute(method: (entry["method"] as? String) ?? (body == nil ? "GET" : "POST"), path: path)
            route.name = name
            route.headers = strings(entry["headers"])
            route.body = body?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let weight = entry["weight"] as? Int { route.weight = max(1, min(weight, 100)) }
            result.tasks.append(route)
        }
        return result
    }

    static func strings(_ value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in dictionary {
            if let text = value as? String { result[key] = text } else { result[key] = "\(value)" }
        }
        return result
    }

    /// `${NAME}` and `$NAME` replaced from `env`, and the names it didn't have.
    public static func fill(_ text: String, env: [String: String]) -> (text: String, missing: [String]) {
        var missing: [String] = []
        let pattern = try! NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)"#)
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let range = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            let name = ns.substring(with: range)
            if let value = env[name] { out += value } else {
                missing.append(name)
                out += ns.substring(with: match.range)
            }
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return (out, missing)
    }

    /// Every variable the file refers to that `env` doesn't hold.
    public func missing(env: [String: String]) -> [String] {
        var names: [String] = []
        let texts = Array(headers.values) + tasks.flatMap { Array(($0.headers ?? [:]).values) + [$0.body ?? "", $0.path] }
        for text in texts { names += Self.fill(text, env: env).missing }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// The file with everything filled in, ready to send.
    public func filled(env: [String: String]) -> BliksemTasks {
        var copy = self
        copy.headers = headers.mapValues { Self.fill($0, env: env).text }
        copy.tasks = tasks.map { task in
            var task = task
            task.headers = task.headers?.mapValues { Self.fill($0, env: env).text }
            task.body = task.body.map { Self.fill($0, env: env).text }
            return task
        }
        return copy
    }

    /// What Bliksem asks the agent when the person wants tasks written.
    public static func brief(routes: [BliksemRoute], hasFile: Bool) -> String {
        let list = routes.prefix(60).map { "- \($0.method) \($0.path)" }.joined(separator: "\n")
        return """
        Write \(path) for Bliksem, Dante's load tester, so it can measure the work this app really does (the heavy requests, not only health checks), and find its maximum throughput.
        \(hasFile ? "The file already exists: keep what's there and add what's missing." : "")

        Format (YAML):
        headers:            # sent with every request, e.g. the API key the routes need
          X-API-Key: ${SOME_ENV_NAME}
        tasks:
          - name: A short sentence naming the work
            method: POST
            path: /api/v1/things
            headers: { Accept: application/json }   # optional
            weight: 3                                # optional: how often, relative to the others
            body: |
              {"realistic": "request body"}

        Rules:
        - Read the route handlers and their request types, and write bodies the app accepts and that do real work (a full calculation, a document render), with made-up data only.
        - Never put a secret in the file. Refer to environment variables with ${NAME}; Bliksem fills them from the environment, .env, .env.local and mise. Say which variable the person must set, and how they get a value (a seed script, a command, the README).
        - Prefer reads and idempotent work. Mark tasks that create data in their name ("creates a record").
        - JSON-RPC endpoints (an MCP server, for example) are tasks too: POST with the JSON-RPC body.
        - Don't run a load test yourself.

        Routes Dante found:
        \(list.isEmpty ? "(none: read the code for them)" : list)
        """
    }
}
