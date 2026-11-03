import Foundation

/// mise (mise.jdx.dev) pins a project's tools (node, go, java…), environment variables and
/// tasks in `mise.toml`. A shell with `mise activate` picks them up at each prompt, but Dante's
/// own commands (tests, runs, language servers, the agents) start without a prompt, so Dante
/// asks `mise env` once per project and lays the answer over every command run inside it.
///
/// Dante never trusts a config or installs tools itself: an untrusted config (mise runs its
/// hooks and templates) and missing tools are shown with the command to type, as with Tools.
public enum Mise {
    /// The files mise reads in a folder, closest first.
    public static let configNames = [
        "mise.local.toml", ".mise.local.toml", "mise.toml", ".mise.toml", ".mise/config.toml",
        "mise/config.toml", ".config/mise.toml", ".config/mise/config.toml", ".tool-versions",
    ]

    public static func configFiles(in root: URL) -> [String] {
        configNames.filter { FileManager.default.fileExists(atPath: root.appending(path: $0).path) }
    }

    public struct Tool: Equatable, Sendable, Identifiable {
        public var name: String
        public var version: String
        public var requested: String?
        public var installed: Bool
        /// The config file that asks for it.
        public var source: String?
        public var id: String { name + "@" + version }

        public init(name: String, version: String, requested: String? = nil, installed: Bool, source: String? = nil) {
            self.name = name
            self.version = version
            self.requested = requested
            self.installed = installed
            self.source = source
        }
    }

    public struct Task: Equatable, Sendable, Identifiable {
        public var name: String
        public var description: String
        public var run: [String]
        public var id: String { name }

        public init(name: String, description: String = "", run: [String] = []) {
            self.name = name
            self.description = description
            self.run = run
        }
    }

    public struct Status: Equatable, Sendable {
        public var configs: [String]
        public var tools: [Tool] = []
        public var tasks: [Task] = []
        /// Names mise sets beyond PATH (values are left out: they can be secrets).
        public var variables: [String] = []
        public var untrusted = false
        /// mise isn't installed: the config is there but nothing reads it.
        public var notInstalled = false
        public var problem: String?

        public var missing: [Tool] { tools.filter { !$0.installed } }

        public init(configs: [String]) { self.configs = configs }
    }

    // MARK: Reading mise's answers (pure)

    /// `mise ls --current --json`: tool → its versions.
    public static func tools(fromJSON text: String) -> [Tool] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object.keys.sorted().flatMap { name -> [Tool] in
            (object[name] as? [[String: Any]] ?? []).map { entry in
                Tool(name: name, version: entry["version"] as? String ?? "?",
                     requested: entry["requested_version"] as? String,
                     installed: entry["installed"] as? Bool ?? false,
                     source: (entry["source"] as? [String: Any])?["path"] as? String)
            }
        }
    }

    /// `mise tasks ls --json`, leaving out hidden ones.
    public static func tasks(fromJSON text: String) -> [Task] {
        guard let data = text.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let name = entry["name"] as? String, entry["hide"] as? Bool != true else { return nil }
            let run: [String] = (entry["run"] as? [String]) ?? (entry["run"] as? String).map { [$0] } ?? []
            return Task(name: name, description: entry["description"] as? String ?? "", run: run)
        }
    }

    /// `mise env --json`: the variables to set.
    public static func environment(fromJSON text: String) -> [String: String] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.compactMapValues { $0 as? String }
    }

    public static func isUntrusted(_ errors: String) -> Bool {
        errors.contains("not trusted")
    }

    // MARK: Loading

    /// Reads the project's mise setup and remembers its environment for `overlay(for:)`.
    /// Nil when the project has no mise config.
    public static func load(root: URL) async -> Status? {
        let configs = configFiles(in: root)
        guard !configs.isEmpty else {
            store.set(nil, for: root)
            return nil
        }
        var status = Status(configs: configs)
        guard Shell.which("mise") != nil else {
            status.notInstalled = true
            store.set(nil, for: root)
            return status
        }
        // Without the overlay, so a stale answer can't feed back into the new one.
        let env = await Shell.run(["mise", "env", "--json", "-C", root.path], in: root, trimming: false, withoutMise: true)
        if isUntrusted(env.stderr) {
            status.untrusted = true
            store.set(nil, for: root)
            return status
        }
        let environment = environment(fromJSON: env.stdout)
        if env.status != 0 || environment.isEmpty, !env.stderr.isEmpty {
            status.problem = env.stderr.split(separator: "\n").first { $0.contains("ERROR") }.map(String.init)
        }
        store.set(environment.isEmpty ? nil : environment, for: root)
        status.variables = environment.keys.filter { $0 != "PATH" }.sorted()
        async let tools = Shell.run(["mise", "ls", "--current", "--json", "-C", root.path], in: root, trimming: false, withoutMise: true)
        async let tasks = Shell.run(["mise", "tasks", "ls", "--json", "-C", root.path], in: root, trimming: false, withoutMise: true)
        status.tools = Self.tools(fromJSON: await tools.stdout)
        status.tasks = Self.tasks(fromJSON: await tasks.stdout)
        return status
    }

    /// What mise sets for a command run in `directory`: the environment of the deepest loaded
    /// project that holds it.
    public static func overlay(for directory: URL) -> [String: String] {
        store.overlay(for: directory.standardizedFileURL.path)
    }

    /// The base environment with mise's laid over it.
    static func applying(_ overlay: [String: String], to base: [String: String]) -> [String: String] {
        base.merging(overlay) { _, mise in mise }
    }

    private static let store = Store()

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var environments: [String: [String: String]] = [:]

        func set(_ environment: [String: String]?, for root: URL) {
            lock.withLock { environments[root.standardizedFileURL.path] = environment }
        }

        func overlay(for path: String) -> [String: String] {
            lock.withLock {
                environments.filter { path == $0.key || path.hasPrefix($0.key + "/") }
                    .max { $0.key.count < $1.key.count }?.value ?? [:]
            }
        }
    }
}
