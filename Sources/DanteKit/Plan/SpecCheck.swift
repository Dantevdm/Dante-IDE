import Foundation
import Yams

/// Checks the `.dante` folder for the mistakes that quietly break things: YAML that
/// doesn't parse, a current phase that isn't in the list, tasks pointing at missing
/// phases or specs, phases without a definition.
public enum SpecCheck {
    public struct Issue: Equatable, Sendable, Identifiable {
        public enum Severity: Sendable { case error, warning }
        public var severity: Severity
        public var message: String
        /// Project-relative file the issue is in.
        public var path: String
        public var id: String { path + message }
    }

    @MainActor
    public static func run(_ workspace: Workspace) -> [Issue] {
        let root = workspace.url
        let fileManager = FileManager.default
        var issues: [Issue] = []

        let projectFile = root.appending(path: ".dante/project.yaml")
        guard let yaml = try? String(contentsOf: projectFile, encoding: .utf8) else {
            return [Issue(severity: .error, message: "There’s no project.yaml, so the project has no lifecycle or rules.", path: ".dante/project.yaml")]
        }
        do {
            let loaded = try Yams.load(yaml: yaml)
            if !(loaded is [String: Any]) {
                issues.append(Issue(severity: .error, message: "project.yaml should be a map of keys like name, lifecycle and claude.", path: ".dante/project.yaml"))
            }
        } catch {
            issues.append(Issue(severity: .error, message: "project.yaml isn’t valid YAML: \(error.localizedDescription)", path: ".dante/project.yaml"))
        }

        let lifecycle = workspace.lifecycle
        if lifecycle.currentIndex == nil {
            issues.append(Issue(severity: .warning, message: "lifecycle.current isn’t one of the phases (\(lifecycle.phases.joined(separator: ", "))).", path: ".dante/project.yaml"))
        }
        let missingDocs = lifecycle.phases.filter { workspace.phaseDocs[$0.lowercased()] == nil }
        if !missingDocs.isEmpty {
            let phaseList = missingDocs.map { $0.lowercased() }.joined(separator: ", ")
            issues.append(Issue(
                severity: .warning,
                message: "\(missingDocs.count) of \(lifecycle.phases.count) phases have no definition yet: \(phaseList).",
                path: ".dante/phases/"
            ))
        }

        if let error = workspace.tasks.loadError {
            issues.append(Issue(severity: .error, message: error, path: ".dante/tasks.yaml"))
        } else {
            let phases = Set(lifecycle.phases.map { $0.lowercased() })
            var seen = Set<String>()
            for task in workspace.tasks.tasks {
                if !seen.insert(task.id).inserted {
                    issues.append(Issue(severity: .error, message: "\(task.id) is used by more than one task.", path: ".dante/tasks.yaml"))
                }
                if !phases.contains(task.phase.lowercased()) {
                    issues.append(Issue(severity: .warning, message: "\(task.id) is in phase “\(task.phase)”, which isn’t in the lifecycle.", path: ".dante/tasks.yaml"))
                }
                if let spec = task.spec, !fileManager.fileExists(atPath: root.appending(path: ".dante/\(spec)").path) {
                    issues.append(Issue(severity: .warning, message: "\(task.id) points at .dante/\(spec), which doesn’t exist.", path: ".dante/tasks.yaml"))
                }
            }
        }
        return issues
    }
}
