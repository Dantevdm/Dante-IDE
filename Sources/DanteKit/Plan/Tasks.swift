import Foundation
import Observation
import Yams

public enum TaskState: String, Codable, CaseIterable, Sendable, Identifiable {
    case ready
    case inProgress = "in_progress"
    case review
    case done

    public var id: String { rawValue }

    /// Reads the spellings other tools and people use: open, todo, doing, wip, closed…
    /// Anything unknown is ready.
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        self = TaskState(loosely: text)
    }

    public init(loosely text: String) {
        let key = text.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        switch key {
        case "in_progress", "inprogress", "doing", "active", "started", "wip", "working", "ongoing": self = .inProgress
        case "review", "in_review", "reviewing", "testing", "qa", "verify": self = .review
        case "done", "closed", "complete", "completed", "resolved", "fixed", "finished", "shipped": self = .done
        default: self = .ready
        }
    }

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
    /// The monitoring alarm the task came from (`Alarm.id`), so Operate can show its state.
    public var alarm: String?
    /// Fields Dante doesn't use (`source:`, `owner:`…), kept so saving the board doesn't drop them.
    public var extra: [String: String] = [:]

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private static let known: Set<String> = ["id", "title", "phase", "state", "status", "spec", "note", "notes", "claude", "alarm"]

    /// Takes `status` for `state` and `notes` for `note`, as hand-written and generated files use them.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        func text(_ names: String...) throws -> String? {
            for name in names {
                if let value = try? container.decodeIfPresent(String.self, forKey: Key(name)) { return value }
                if let value = try? container.decodeIfPresent(Int.self, forKey: Key(name)) { return String(value) }
            }
            return nil
        }
        guard let id = try text("id") else {
            throw DecodingError.keyNotFound(Key("id"), .init(codingPath: container.codingPath, debugDescription: "A task has no id."))
        }
        self.id = id
        title = try text("title", "name") ?? id
        phase = (try text("phase") ?? "build").lowercased()
        state = TaskState(loosely: try text("state", "status") ?? "ready")
        spec = try text("spec")
        note = try text("note", "notes", "description")
        claude = try? container.decodeIfPresent(Bool.self, forKey: Key("claude"))
        alarm = try text("alarm")
        for key in container.allKeys where !Self.known.contains(key.stringValue) {
            if let value = try text(key.stringValue) { extra[key.stringValue] = value }
            else if let value = try? container.decode(Bool.self, forKey: key) { extra[key.stringValue] = String(value) }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(id, forKey: Key("id"))
        try container.encode(title, forKey: Key("title"))
        try container.encode(phase, forKey: Key("phase"))
        try container.encode(state, forKey: Key("state"))
        try container.encodeIfPresent(spec, forKey: Key("spec"))
        try container.encodeIfPresent(note, forKey: Key("note"))
        try container.encodeIfPresent(claude, forKey: Key("claude"))
        try container.encodeIfPresent(alarm, forKey: Key("alarm"))
        for key in extra.keys.sorted() { try container.encode(extra[key], forKey: Key(key)) }
    }

    public init(id: String, title: String, phase: String, state: TaskState = .ready, spec: String? = nil, note: String? = nil, claude: Bool? = nil, alarm: String? = nil) {
        self.id = id
        self.title = title
        self.phase = phase
        self.state = state
        self.spec = spec
        self.note = note
        self.claude = claude
        self.alarm = alarm
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

    private enum CodingKeys: String, CodingKey { case prefix, tasks }

    /// A missing prefix is taken from the existing ids (`TN-3` → `TN`).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try container.decodeIfPresent([PlanTask].self, forKey: .tasks) ?? []
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix)
            ?? tasks.first.flatMap { $0.id.split(separator: "-").first.map(String.init) } ?? "TASK"
    }

    /// A decoding error in words: which task and which field, rather than Foundation's
    /// "the data couldn't be read because it is missing".
    public static func explain(_ error: Error) -> String {
        func place(_ path: [CodingKey]) -> String {
            let index = path.first { $0.intValue != nil }?.intValue
            return index.map { "task \($0 + 1)" } ?? "the file"
        }
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return "\(place(context.codingPath)) has no `\(key.stringValue)`."
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            let field = context.codingPath.last.map { "`\($0.stringValue)` in " } ?? ""
            return "\(field)\(place(context.codingPath)) isn’t the expected kind of value."
        case DecodingError.dataCorrupted(let context):
            return context.debugDescription
        default:
            return "\(error)"
        }
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
            loadError = "tasks.yaml couldn’t be read: \(TaskFile.explain(error))"
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
    public func add(title: String, phase: String, state: TaskState = .ready, spec: String? = nil, note: String? = nil, alarm: String? = nil) throws -> PlanTask {
        let task = PlanTask(id: nextID, title: title, phase: phase.lowercased(), state: state, spec: spec?.isEmpty == true ? nil : spec,
                            note: note, alarm: alarm)
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
