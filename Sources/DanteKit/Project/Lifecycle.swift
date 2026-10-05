import Foundation

/// A project's lifecycle phases and where the project is now.
///
/// Phases are guidance, not gates: nothing in Dante blocks work because of the
/// current phase. They organise tasks, docs and the context Claude gets.
public struct Lifecycle: Equatable, Sendable {
    public static let defaultPhases = ["Discover", "Define", "Design", "Build", "Test", "Release", "Operate"]

    public var phases: [String]
    /// Index into `phases`, or nil when no current phase is set.
    public var currentIndex: Int?
    /// Whether the project has a `.dante/project.yaml`.
    public var hasSpec: Bool

    public init(phases: [String] = Lifecycle.defaultPhases, currentIndex: Int? = nil, hasSpec: Bool = false) {
        self.phases = phases
        self.currentIndex = currentIndex
        self.hasSpec = hasSpec
    }

    /// Reads `.dante/project.yaml` from a project root.
    public static func load(projectRoot: URL) -> Lifecycle {
        let file = projectRoot.appending(path: ".dante/project.yaml")
        guard let yaml = try? String(contentsOf: file, encoding: .utf8) else { return Lifecycle() }
        return parse(projectYAML: yaml)
    }

    /// Reads `lifecycle.current` and an optional `lifecycle.phases` list.
    /// This is a deliberately small reader for the keys the shell needs; the
    /// full `.dante` schema gets a real YAML parser when the spec features land.
    public static func parse(projectYAML yaml: String) -> Lifecycle {
        var phases = defaultPhases
        var current: String?
        var inLifecycle = false

        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if indent == 0 {
                inLifecycle = trimmed == "lifecycle:"
                continue
            }
            guard inLifecycle else { continue }

            if let value = value(of: "current", in: trimmed) {
                current = value
            } else if let value = value(of: "phases", in: trimmed), value.hasPrefix("[") {
                let list = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                    .filter { !$0.isEmpty }
                if !list.isEmpty { phases = list.map(\.capitalized) }
            }
        }

        let index = current.flatMap { name in phases.firstIndex { $0.lowercased() == name.lowercased() } }
        return Lifecycle(phases: phases, currentIndex: index, hasSpec: true)
    }

    private static func value(of key: String, in line: String) -> String? {
        guard line.hasPrefix(key + ":") else { return nil }
        return line.dropFirst(key.count + 1)
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
}
