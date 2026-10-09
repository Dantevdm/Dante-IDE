import Foundation
import Yams

/// The descriptive parts of `.dante/project.yaml`, for Home and Spec.
public struct ProjectInfo: Equatable, Sendable {
    public var name: String?
    public var summary: String?
    /// Health checks the Run area polls: `operate: { checks: [{ name, url }] }`.
    public var checks: [HealthCheck]
    /// A command that streams production logs: `operate: { logs: "fly logs" }`.
    public var logsCommand: String?
    /// Monitoring alarms to show in Run: `operate: { alarms: [{ source: cloudwatch, … }] }`.
    public var alarms: [AlarmSource]

    public struct HealthCheck: Equatable, Sendable, Identifiable {
        public var name: String
        public var url: URL
        public var id: String { name }

        public init(name: String, url: URL) {
            self.name = name
            self.url = url
        }
    }

    public init(name: String? = nil, summary: String? = nil, checks: [HealthCheck] = [], logsCommand: String? = nil, alarms: [AlarmSource] = []) {
        self.name = name
        self.summary = summary
        self.checks = checks
        self.logsCommand = logsCommand
        self.alarms = alarms
    }

    public static func parse(projectYAML yaml: String) -> ProjectInfo {
        guard let root = (try? Yams.load(yaml: yaml)) as? [String: Any] else { return ProjectInfo() }
        var checks: [HealthCheck] = []
        let operate = root["operate"] as? [String: Any]
        // `checks`, or `health` as people (and Claude) often write it; a bare URL works too.
        let list = operate?["checks"] as? [Any] ?? operate?["health"] as? [Any] ?? operate?["healthchecks"] as? [Any] ?? []
        for item in list {
            let entry = item as? [String: Any] ?? [:]
            guard let address = (entry["url"] as? String) ?? (item as? String), let url = URL(string: address),
                  url.scheme?.hasPrefix("http") == true else { continue }
            let name = (entry["name"] as? String) ?? [url.host(), url.port.map { ":\($0)" }, url.path.isEmpty ? nil : url.path].compactMap { $0 }.joined()
            checks.append(HealthCheck(name: checks.contains { $0.name == name } ? address : name, url: url))
        }
        // `logs: "fly logs"`, or `logs: { command: … }`.
        let logs = operate?["logs"]
        let logsCommand = (logs as? String) ?? ((logs as? [String: Any]).flatMap { ($0["command"] ?? $0["run"]) as? String })
        return ProjectInfo(
            name: (root["name"] as? String)?.nonEmptyTrimmed,
            summary: (root["summary"] as? String)?.nonEmptyTrimmed,
            checks: checks,
            logsCommand: logsCommand?.nonEmptyTrimmed,
            alarms: (operate?["alarms"] as? [Any] ?? []).compactMap(AlarmSource.parse)
        )
    }

    public static func load(projectRoot: URL) -> ProjectInfo {
        guard let yaml = try? String(contentsOf: projectRoot.appending(path: ".dante/project.yaml"), encoding: .utf8) else {
            return ProjectInfo()
        }
        return parse(projectYAML: yaml)
    }
}

/// The languages a project is mostly written in, by file count.
public enum LanguageStats {
    /// Languages that describe a codebase. Config and docs formats don't count.
    static let ignored: Set<Language> = [.json, .yaml, .toml, .markdown, .plain, .html, .css, .shell, .sql, .dockerfile]

    public static func top(_ paths: [String], limit: Int = 2) -> [(language: Language, files: Int)] {
        var counts: [Language: Int] = [:]
        for path in paths {
            let language = Language(url: URL(filePath: path))
            if !ignored.contains(language) { counts[language, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
            .prefix(limit)
            .map { ($0.key, $0.value) }
    }
}

extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
