import Foundation
import Observation
import Yams

public enum TaskState: String, Codable, CaseIterable, Sendable, Identifiable {
    case ready
    case inProgress = "in_progress"
    case review
    case done

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ready: "Ready"
        case .inProgress: "In progress"
        case .review: "Review"
        case .done: "Done"
        }
    }
}

/// One task in `.dante/tasks.yaml`.
public struct PlanTask: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    /// Lower-case phase name, e.g. `build`.
    public var phase: String
    public var state: TaskState
    /// A doc the task implements, relative to `.dante/` (e.g. `specs/limits.md`).
    public var spec: String?
    public var note: String?
    /// Being worked on with Claude.
    public var claude: Bool?

    public init(id: String, title: String, phase: String, state: TaskState = .ready, spec: String? = nil, note: String? = nil, claude: Bool? = nil) {
        self.id = id
        self.title = title
        self.phase = phase
        self.state = state
        self.spec = spec
        self.note = note
        self.claude = claude
    }
}

/// The file format: a key prefix for new ids and the task list.
public struct TaskFile: Codable, Equatable, Sendable {
    public var prefix: String
    public var tasks: [PlanTask]

    public init(prefix: String, tasks: [PlanTask] = []) {
        self.prefix = prefix
        self.tasks = tasks
    }

    public static func decode(_ yaml: String) throws -> TaskFile {
        try YAMLDecoder().decode(TaskFile.self, from: yaml)
    }

    public func encode() throws -> String {
        let body = try YAMLEncoder().encode(self)
        return "# Tasks for this project. Edit here or on Dante's Plan board.\n" + body
    }

    /// A prefix from the project name: initials of its words, or its first three letters.
    public static func prefix(forProjectNamed name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        let letters = words.count > 1 ? String(words.compactMap(\.first)) : String(name.filter(\.isLetter).prefix(3))
        let prefix = letters.uppercased()
        return prefix.isEmpty ? "TASK" : prefix
    }
}

/// The project's tasks, read from and written to `.dante/tasks.yaml`.
@MainActor
@Observable
public final class TaskBoard {
    public private(set) var file: TaskFile
    /// Set when the file exists but couldn't be read; the board is read-only until it's fixed.
    public private(set) var loadError: String?
    public let url: URL

    public var tasks: [PlanTask] { file.tasks }

    public init(projectRoot: URL) {
        url = projectRoot.appending(path: ".dante/tasks.yaml")
        file = TaskFile(prefix: TaskFile.prefix(forProjectNamed: projectRoot.lastPathComponent))
        reload()
    }

    public func reload() {
        guard let yaml = try? String(contentsOf: url, encoding: .utf8) else {
            loadError = nil
            return
        }
        do {
            let decoded = try TaskFile.decode(yaml)
            if decoded != file { file = decoded }
            loadError = nil
        } catch {
            loadError = "tasks.yaml couldn’t be read: \(error.localizedDescription)"
        }
    }

    public func tasks(in phase: String, state: TaskState) -> [PlanTask] {
        file.tasks.filter { $0.phase == phase.lowercased() && $0.state == state }
    }

    public func count(in phase: String) -> (done: Int, total: Int) {
        let inPhase = file.tasks.filter { $0.phase == phase.lowercased() }
        return (inPhase.count { $0.state == .done }, inPhase.count)
    }

    /// The next free id, e.g. `DAN-7`.
    public var nextID: String {
        let numbers = file.tasks.compactMap { task -> Int? in
            guard task.id.hasPrefix(file.prefix + "-") else { return nil }
            return Int(task.id.dropFirst(file.prefix.count + 1))
        }
        return "\(file.prefix)-\((numbers.max() ?? 0) + 1)"
    }

    @discardableResult
    public func add(title: String, phase: String, state: TaskState = .ready, spec: String? = nil) throws -> PlanTask {
        let task = PlanTask(id: nextID, title: title, phase: phase.lowercased(), state: state, spec: spec?.isEmpty == true ? nil : spec)
        try update { $0.tasks.append(task) }
        return task
    }

    public func move(_ id: PlanTask.ID, to state: TaskState) throws {
        try update { file in
            guard let index = file.tasks.firstIndex(where: { $0.id == id }) else { return }
            file.tasks[index].state = state
        }
    }

    public func setWorkingWithClaude(_ id: PlanTask.ID, _ value: Bool) throws {
        try update { file in
            guard let index = file.tasks.firstIndex(where: { $0.id == id }) else { return }
            file.tasks[index].claude = value ? true : nil
        }
    }

    public func delete(_ id: PlanTask.ID) throws {
        try update { $0.tasks.removeAll { $0.id == id } }
    }

    private func update(_ change: (inout TaskFile) -> Void) throws {
        guard loadError == nil else { throw CocoaError(.fileReadCorruptFile) }
        var next = file
        change(&next)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(try next.encode().utf8).write(to: url, options: .atomic)
        file = next
    }
}
