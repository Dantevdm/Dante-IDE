import Foundation

/// A Grafana the project runs in Docker, found in any of its compose files (monitoring
/// often has its own, such as `compose.monitoring.yaml`), with the dashboards the repo
/// provisions, so the Health page can show it inside Dante.
public struct GrafanaSetup: Equatable, Sendable {
    public struct Dashboard: Equatable, Sendable, Identifiable {
        public var uid: String
        public var title: String
        /// The JSON file it's provisioned from, relative to the project.
        public var file: String
        public var id: String { uid }

        public init(uid: String, title: String, file: String) {
            self.uid = uid
            self.title = title
            self.file = file
        }
    }

    /// The compose file that runs it, relative to the project.
    public var composeFile: String
    public var service: String
    /// The port it's published on here.
    public var port: Int
    public var dashboards: [Dashboard]
    /// Anonymous viewing is on, so no sign-in is needed.
    public var anonymous: Bool
    /// How the project starts it: the mise task that brings this compose file up, else compose.
    public var startCommand: String
    /// Prometheus beside it, when that's published here too.
    public var prometheusPort: Int?

    public init(composeFile: String, service: String, port: Int, dashboards: [Dashboard] = [], anonymous: Bool = false,
                startCommand: String, prometheusPort: Int? = nil) {
        self.composeFile = composeFile
        self.service = service
        self.port = port
        self.dashboards = dashboards
        self.anonymous = anonymous
        self.startCommand = startCommand
        self.prometheusPort = prometheusPort
    }

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// A dashboard, or Grafana's list of them, in Dante's light or night; `focused` hides
    /// Grafana's own menus (kiosk mode).
    public func url(for dashboard: Dashboard?, dark: Bool, focused: Bool = false) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = dashboard.map { "/d/\($0.uid)" } ?? "/dashboards"
        var query = [URLQueryItem(name: "theme", value: dark ? "dark" : "light")]
        if focused, dashboard != nil { query.append(URLQueryItem(name: "kiosk", value: nil)) }
        components.queryItems = query
        return components.url!
    }

    /// Whether a page belongs to this Grafana (the embedded view keeps to it).
    public func owns(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) else { return false }
        return (url.port ?? (url.scheme == "https" ? 443 : 80)) == port
    }

    // MARK: Finding it

    /// Compose files at the project's top: `compose.yaml`, `docker-compose.yml`, and the
    /// named ones beside them (`compose.monitoring.yaml`, `docker-compose.dev.yml`).
    public static func isComposeFile(_ name: String) -> Bool {
        name.range(of: #"^(docker-)?compose(\.[A-Za-z0-9_.-]+)?\.ya?ml$"#, options: .regularExpression) != nil
    }

    /// Every Grafana the compose files run, one per port: the default compose file first,
    /// then development ones, then the rest.
    /// - Parameters:
    ///   - composeFiles: name and text of each compose file at the top of the project.
    ///   - env: `.env` and the environment, for `${PORT:-3000}`.
    ///   - jsonFiles: the JSON files in a folder of the project (relative path and text).
    ///   - mise: mise.toml's text, for the task that starts a compose file.
    public static func detect(composeFiles: [(name: String, text: String)], env: [String: String],
                              jsonFiles: (String) -> [(path: String, text: String)], mise: String?) -> [GrafanaSetup] {
        let ordered = composeFiles.filter { isComposeFile($0.name) }.sorted { rank($0.name) < rank($1.name) }
        var found: [GrafanaSetup] = []
        for file in ordered {
            guard let root = try? SafeYAML.load(file.text) as? [String: Any],
                  let services = root["services"] as? [String: Any] else { continue }
            for name in services.keys.sorted() {
                guard let spec = services[name] as? [String: Any], isGrafana(name: name, spec: spec) else { continue }
                let environment = environmentOf(spec)
                let inside = Int(EnvFile.interpolate(environment["GF_SERVER_HTTP_PORT"] ?? "", env: env)) ?? 3000
                guard let port = DataDetector.hostPort(ports(of: spec, env: env), container: inside),
                      !found.contains(where: { $0.port == port }) else { continue }
                let anonymous = EnvFile.interpolate(environment["GF_AUTH_ANONYMOUS_ENABLED"] ?? "", env: env).lowercased() == "true"
                var dashboards: [Dashboard] = []
                for folder in dashboardFolders(of: spec) {
                    for json in jsonFiles(folder) {
                        if let dashboard = dashboard(json.text, file: json.path), !dashboards.contains(where: { $0.uid == dashboard.uid }) {
                            dashboards.append(dashboard)
                        }
                    }
                }
                dashboards.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                let prometheus = services.compactMap { key, value -> Int? in
                    guard let other = value as? [String: Any], ((other["image"] as? String) ?? key).lowercased().contains("prometheus"),
                          !((other["image"] as? String) ?? "").lowercased().contains("exporter") else { return nil }
                    return DataDetector.hostPort(ports(of: other, env: env), container: 9090)
                }.first
                found.append(GrafanaSetup(composeFile: file.name, service: name, port: port, dashboards: dashboards, anonymous: anonymous,
                                          startCommand: startCommand(composeFile: file.name, service: name, mise: mise),
                                          prometheusPort: prometheus))
            }
        }
        return found
    }

    /// Reads the project's top folder, `.env`, mise.toml and the provisioned dashboards.
    public static func load(projectRoot root: URL, shell: [String: String] = [:]) -> [GrafanaSetup] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let files = names.filter(isComposeFile).compactMap { name -> (name: String, text: String)? in
            (try? String(contentsOf: root.appending(path: name), encoding: .utf8)).map { (name, $0) }
        }
        guard !files.isEmpty else { return [] }
        let dotEnv = try? String(contentsOf: root.appending(path: ".env"), encoding: .utf8)
        let env = ComposeVariables.environment(shell: shell, dotEnv: dotEnv)
        let mise = Mise.configFiles(in: root).lazy.compactMap { try? String(contentsOf: root.appending(path: $0), encoding: .utf8) }.first
        return detect(composeFiles: files, env: env, jsonFiles: { folder in
            let url = root.appending(path: folder)
            // Only folders inside the project, symlinks resolved.
            let inside = url.resolvingSymlinksInPath().standardizedFileURL.path, top = root.resolvingSymlinksInPath().standardizedFileURL.path
            guard inside.hasPrefix(top + "/"),
                  let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
            return entries.filter { $0.pathExtension.lowercased() == "json" }.compactMap { file in
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 4_000_000,
                      let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                return ((folder as NSString).appendingPathComponent(file.lastPathComponent), text)
            }
        }, mise: mise)
    }

    static func rank(_ name: String) -> Int {
        if ComposeFile.fileNames.contains(name) { return 0 }
        return name.lowercased().contains("dev") || name.lowercased().contains("local") ? 1 : 2
    }

    static func isGrafana(name: String, spec: [String: Any]) -> Bool {
        if let image = spec["image"] as? String { return image.lowercased().contains("grafana/grafana") || image.lowercased().hasPrefix("grafana:") }
        return name.lowercased() == "grafana"
    }

    static func environmentOf(_ spec: [String: Any]) -> [String: String] {
        var environment: [String: String] = [:]
        if let map = spec["environment"] as? [String: Any] {
            for (key, value) in map { environment[key] = (value is NSNull) ? "" : "\(value)" }
        } else if let list = spec["environment"] as? [Any] {
            for entry in list.map({ "\($0)" }) {
                let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                if let key = parts.first { environment[key] = parts.count > 1 ? parts[1] : "" }
            }
        }
        return environment
    }

    static func ports(of spec: [String: Any], env: [String: String]) -> [String] {
        (spec["ports"] as? [Any] ?? []).map { port -> String in
            if let object = port as? [String: Any] {
                let target = object["target"].map { "\($0)" } ?? ""
                return object["published"].map { "\($0):\(target)" } ?? target
            }
            return EnvFile.interpolate("\(port)", env: env)
        }
    }

    /// Folders of the project mounted where Grafana reads dashboards from.
    static func dashboardFolders(of spec: [String: Any]) -> [String] {
        (spec["volumes"] as? [Any] ?? []).compactMap { volume -> String? in
            let source: String, target: String
            if let object = volume as? [String: Any] {
                guard let s = object["source"] as? String, let t = object["target"] as? String else { return nil }
                (source, target) = (s, t)
            } else {
                let parts = "\(volume)".split(separator: ":").map(String.init)
                guard parts.count >= 2 else { return nil }
                (source, target) = (parts[0], parts[1])
            }
            guard source.hasPrefix("./") || (source.hasPrefix(".") == false && source.contains("/") && !source.hasPrefix("/")),
                  target.lowercased().contains("dashboards"), !target.lowercased().contains("provisioning") else { return nil }
            var folder = source
            while folder.hasPrefix("./") { folder.removeFirst(2) }
            return folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        }
    }

    /// A dashboard's uid and title from its JSON (exported files wrap it in `dashboard`).
    static func dashboard(_ text: String, file: String) -> Dashboard? {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let body = object["dashboard"] as? [String: Any] ?? object
        guard let uid = body["uid"] as? String, !uid.isEmpty, uid.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        let title = (body["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? uid
        return Dashboard(uid: uid, title: title, file: file)
    }

    /// The mise task that brings this compose file up, else compose itself.
    static func startCommand(composeFile: String, service: String, mise: String?) -> String {
        if let mise {
            var task: String?
            for line in mise.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") {
                    task = trimmed.range(of: #"^\[tasks\.("?)([A-Za-z0-9_:.-]+)\1\]$"#, options: .regularExpression) != nil
                        ? trimmed.dropFirst(7).dropLast().trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        : nil
                    continue
                }
                if let task, trimmed.contains(composeFile), trimmed.contains(" up") {
                    return "mise run \(task)"
                }
            }
        }
        return ComposeFile.fileNames.contains(composeFile)
            ? "docker compose up -d \(service)"
            : "docker compose -f \(Shell.quote(composeFile)) up -d"
    }
}
