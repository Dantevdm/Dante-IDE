import Foundation
import Observation

/// Debug Adapter Protocol messages: requests out; responses, events and the adapter's own
/// requests in.
public enum DAP {
    public enum Incoming: Equatable, Sendable {
        case response(requestSeq: Int, success: Bool, message: String?, body: JSONValue)
        case event(String, JSONValue)
        /// A request from the adapter to Dante (`runInTerminal`, `startDebugging`).
        case request(seq: Int, command: String)
    }

    public static func request(seq: Int, command: String, arguments: JSONValue? = nil) -> JSONValue {
        var message: [String: JSONValue] = ["seq": .number(Double(seq)), "type": .string("request"), "command": .string(command)]
        if let arguments { message["arguments"] = arguments }
        return .object(message)
    }

    /// The reply to a request from the adapter that Dante doesn't support.
    public static func refusal(seq: Int, requestSeq: Int, command: String) -> JSONValue {
        .object([
            "seq": .number(Double(seq)), "type": .string("response"), "request_seq": .number(Double(requestSeq)),
            "command": .string(command), "success": .bool(false), "message": .string("Dante doesn’t support \(command).")
        ])
    }

    public static func read(_ message: JSONValue) -> Incoming? {
        switch message["type"]?.string {
        case "response":
            guard let seq = message["request_seq"]?.int else { return nil }
            let text = message["body"]?["error"]?["format"]?.string ?? message["message"]?.string
            return .response(requestSeq: seq, success: message["success"]?.bool ?? false, message: text, body: message["body"] ?? .null)
        case "event":
            guard let name = message["event"]?.string else { return nil }
            return .event(name, message["body"] ?? .null)
        case "request":
            guard let seq = message["seq"]?.int, let command = message["command"]?.string else { return nil }
            return .request(seq: seq, command: command)
        default:
            return nil
        }
    }

    static func frames(in body: JSONValue) -> [DebugSession.Frame] {
        (body["stackFrames"]?.array ?? []).compactMap { frame in
            guard let id = frame["id"]?.int else { return nil }
            return DebugSession.Frame(
                id: id,
                name: frame["name"]?.string ?? "?",
                path: frame["source"]?["path"]?.string,
                line: frame["line"]?.int ?? 0,
                column: frame["column"]?.int ?? 0
            )
        }
    }

    static func scopes(in body: JSONValue) -> [DebugSession.Scope] {
        (body["scopes"]?.array ?? []).compactMap { scope in
            guard let name = scope["name"]?.string, let reference = scope["variablesReference"]?.int else { return nil }
            return DebugSession.Scope(name: name, reference: reference, expensive: scope["expensive"]?.bool ?? false)
        }
    }

    static func variables(in body: JSONValue, parent: Int) -> [DebugSession.Variable] {
        (body["variables"]?.array ?? []).enumerated().compactMap { index, variable in
            guard let name = variable["name"]?.string else { return nil }
            return DebugSession.Variable(
                id: "\(parent)/\(index)/\(name)",
                name: name,
                value: variable["value"]?.string ?? "",
                type: variable["type"]?.string,
                reference: variable["variablesReference"]?.int ?? 0
            )
        }
    }

    /// Verified lines from a `setBreakpoints` response, in the order they were asked for.
    static func verified(in body: JSONValue, requested: [Int]) -> [Int: Bool] {
        let answers = body["breakpoints"]?.array ?? []
        var result: [Int: Bool] = [:]
        for (index, line) in requested.enumerated() {
            result[line] = index < answers.count ? (answers[index]["verified"]?.bool ?? false) : false
        }
        return result
    }
}

/// One debugging run: the adapter, where the program is stopped, its stack and variables,
/// and what it printed. Breakpoints are the window's; the session sends them as they change.
@MainActor
@Observable
public final class DebugSession {
    public enum State: Equatable, Sendable {
        case starting, running, stopped, ended
    }

    public struct Frame: Identifiable, Equatable, Sendable {
        public var id: Int
        public var name: String
        public var path: String?
        /// 1-based.
        public var line: Int
        public var column: Int
    }

    public struct Scope: Identifiable, Equatable, Sendable {
        public var name: String
        public var reference: Int
        public var expensive: Bool
        public var id: Int { reference }
    }

    public struct Variable: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var value: String
        public var type: String?
        /// Non-zero when it has children to expand.
        public var reference: Int
    }

    public struct OutputLine: Identifiable, Equatable, Sendable {
        public var id: Int
        /// `stdout`, `stderr`, `console` (the adapter's own notes) or `result` (an evaluation).
        public var category: String
        public var text: String
    }

    public let adapter: DebugAdapter
    /// The file the run was started from.
    public let file: String
    public private(set) var state: State = .starting
    /// Why the program stopped: "breakpoint", "step", "pause", "exception".
    public private(set) var stopReason: String?
    public private(set) var stopDescription: String?
    public private(set) var frames: [Frame] = []
    public private(set) var selectedFrameID: Int?
    public private(set) var scopes: [Scope] = []
    public private(set) var children: [Int: [Variable]] = [:]
    public private(set) var output: [OutputLine] = []
    /// Breakpoint lines the adapter confirmed, per file.
    public private(set) var verified: [String: [Int: Bool]] = [:]
    /// Why the run ended early, when it did.
    public private(set) var failure: String?

    /// Called when the program stops, with the frame to show.
    public var onStopped: ((Frame?) -> Void)?
    public var onEnded: (() -> Void)?

    public var selectedFrame: Frame? { frames.first { $0.id == selectedFrameID } }

    private var connection: DAPConnection?
    private var seq = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var initialized: CheckedContinuation<Void, Never>?
    private var hasInitialized = false
    /// Set when `launch` fails before the adapter says it's initialized, so starting stops waiting.
    private var launchFailure: Error?
    private var threadID: Int?
    private var nextOutputID = 0

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    public init(adapter: DebugAdapter, file: String) {
        self.adapter = adapter
        self.file = Self.canonical(file)
    }

    /// The path with symlinks resolved the way the kernel sees it (`/tmp` → `/private/tmp`),
    /// which is how adapters report frames. Foundation's own resolving drops `/private`, and Go
    /// then thinks the package is outside its module.
    public nonisolated static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: Starting and stopping

    /// Starts the adapter, sends the breakpoints (1-based lines per file) and launches the program.
    public func start(root rootURL: URL, environment: [String: String], breakpoints: [String: [Int]]) async {
        let root = URL(filePath: Self.canonical(rootURL.path))
        guard let executable = adapter.resolve(path: environment["PATH"] ?? "") else {
            end(failure: "\(adapter.name) isn’t installed. Install it with: \(adapter.install)")
            return
        }
        do {
            let connection = try await DAPConnection.open(adapter, executable: executable, root: root, environment: environment)
            self.connection = connection
            connection.onMessage = { [weak self] in self?.handle($0) }
            connection.onText = { [weak self] line, isError in self?.append(line, category: isError ? "console" : "stdout") }
            connection.onClose = { [weak self] errors in
                guard let self, self.state != .ended else { return }
                self.end(failure: self.state == .starting ? (errors ?? "\(self.adapter.name) stopped before the program started.") : nil)
            }

            _ = try await request("initialize", [
                "clientID": .string("dante"), "clientName": .string("Dante"), "adapterID": .string(adapter.id),
                "linesStartAt1": .bool(true), "columnsStartAt1": .bool(true), "pathFormat": .string("path"),
                "supportsVariableType": .bool(true), "supportsRunInTerminalRequest": .bool(false),
            ])
            // The launch response comes after configurationDone, so it's awaited last.
            let launch = Task {
                do {
                    return try await self.request("launch", self.adapter.launchArguments(file: self.file, root: root.path))
                } catch {
                    self.launchFailure = error
                    self.initialized?.resume()
                    self.initialized = nil
                    throw error
                }
            }
            await waitForInitialized()
            if let launchFailure { throw launchFailure }
            for (path, lines) in breakpoints where !lines.isEmpty {
                await setBreakpoints(path, lines: lines)
            }
            _ = try? await request("setExceptionBreakpoints", ["filters": .array([])])
            _ = try await request("configurationDone")
            _ = try await launch.value
            if state == .starting { state = .running }
        } catch {
            let message = (error as? Failure)?.message ?? error.localizedDescription
            if adapter.id == "python", message.contains("No module named debugpy") {
                end(failure: "debugpy isn’t installed for python3. Install it with: \(adapter.install)")
            } else {
                end(failure: message)
            }
        }
    }

    private func waitForInitialized() async {
        if hasInitialized || launchFailure != nil { return }
        await withCheckedContinuation { continuation in
            if hasInitialized || launchFailure != nil { continuation.resume() } else { initialized = continuation }
        }
    }

    /// Ends the program and the adapter.
    public func stop() async {
        guard state != .ended else { return }
        // Ending resumes every pending request, so the timer frees a disconnect that never answers.
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self?.end(failure: nil) }
        }
        _ = try? await request("disconnect", ["terminateDebuggee": .bool(true)])
        timer.cancel()
        end(failure: nil)
    }

    private func end(failure: String?) {
        guard state != .ended else { return }
        if let failure { self.failure = failure }
        state = .ended
        frames = []
        scopes = []
        children = [:]
        selectedFrameID = nil
        for continuation in pending.values { continuation.resume(throwing: Failure(message: "The debugger stopped.")) }
        pending = [:]
        initialized?.resume()
        initialized = nil
        connection?.close()
        connection = nil
        onEnded?()
    }

    // MARK: Controls

    public func resume() { command("continue") }
    public func stepOver() { command("next") }
    public func stepIn() { command("stepIn") }
    public func stepOut() { command("stepOut") }

    public func pause() {
        Task {
            if threadID == nil { threadID = await firstThread() }
            _ = try? await request("pause", ["threadId": .number(Double(threadID ?? 1))])
        }
    }

    private func command(_ name: String) {
        guard state == .stopped else { return }
        let thread = threadID ?? 1
        state = .running
        frames = []
        scopes = []
        children = [:]
        selectedFrameID = nil
        Task { _ = try? await request(name, ["threadId": .number(Double(thread))]) }
    }

    private func firstThread() async -> Int? {
        guard let body = try? await request("threads") else { return nil }
        return body["threads"]?.array?.first?["id"]?.int
    }

    // MARK: Breakpoints

    /// Replaces the breakpoints in one file (1-based lines). Safe to call while running.
    public func setBreakpoints(_ path: String, lines: [Int]) async {
        guard state != .ended, connection != nil else { return }
        let path = Self.canonical(path)
        let requested = lines.sorted()
        let arguments: JSONValue = .object([
            "source": .object(["path": .string(path), "name": .string((path as NSString).lastPathComponent)]),
            "breakpoints": .array(requested.map { .object(["line": .number(Double($0))]) }),
            "lines": .array(requested.map { .number(Double($0)) }),
        ])
        if let body = try? await request("setBreakpoints", arguments) {
            verified[path] = DAP.verified(in: body, requested: requested)
        }
    }

    // MARK: Inspecting

    public func select(frame id: Int) {
        guard selectedFrameID != id else { return }
        selectedFrameID = id
        scopes = []
        Task { await loadScopes(frame: id) }
    }

    private func loadScopes(frame id: Int) async {
        guard let body = try? await request("scopes", ["frameId": .number(Double(id))]), selectedFrameID == id else { return }
        scopes = DAP.scopes(in: body)
        for scope in scopes where !scope.expensive { await loadChildren(scope.reference) }
    }

    /// The children of a scope or variable, fetched once.
    public func loadChildren(_ reference: Int) async {
        guard reference > 0, children[reference] == nil,
              let body = try? await request("variables", ["variablesReference": .number(Double(reference))]) else { return }
        children[reference] = DAP.variables(in: body, parent: reference)
    }

    /// Evaluates an expression in the selected frame, as typed into the console.
    public func evaluate(_ expression: String) async {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, state != .ended else { return }
        append("› \(trimmed)", category: "input")
        var arguments: [String: JSONValue] = ["expression": .string(trimmed), "context": .string("repl")]
        if let selectedFrameID { arguments["frameId"] = .number(Double(selectedFrameID)) }
        do {
            let body = try await request("evaluate", .object(arguments))
            append(body["result"]?.string ?? "", category: "result")
        } catch {
            append((error as? Failure)?.message ?? error.localizedDescription, category: "stderr")
        }
    }

    public func clearOutput() { output = [] }

    // MARK: Messages

    private func request(_ command: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        try await request(command, .object(arguments))
    }

    private func request(_ command: String, _ arguments: JSONValue? = nil) async throws -> JSONValue {
        guard let connection else { throw Failure(message: "The debugger isn’t running.") }
        let id = seq
        seq += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            connection.send(DAP.request(seq: id, command: command, arguments: arguments))
        }
    }

    private func handle(_ message: JSONValue) {
        switch DAP.read(message) {
        case .response(let requestSeq, let success, let text, let body):
            guard let continuation = pending.removeValue(forKey: requestSeq) else { return }
            if success { continuation.resume(returning: body) } else { continuation.resume(throwing: Failure(message: text ?? "The debugger refused the request.")) }
        case .event(let name, let body):
            event(name, body)
        case .request(let requestSeq, let command):
            connection?.send(DAP.refusal(seq: seq, requestSeq: requestSeq, command: command))
            seq += 1
        case nil:
            break
        }
    }

    private func event(_ name: String, _ body: JSONValue) {
        switch name {
        case "initialized":
            hasInitialized = true
            initialized?.resume()
            initialized = nil
        case "stopped":
            state = .stopped
            stopReason = body["reason"]?.string
            stopDescription = body["text"]?.string ?? body["description"]?.string
            if let thread = body["threadId"]?.int { threadID = thread }
            Task { await loadStack() }
        case "continued":
            if state == .stopped {
                state = .running
                frames = []
                scopes = []
                selectedFrameID = nil
            }
        case "output":
            let category = body["category"]?.string ?? "console"
            guard category != "telemetry", let text = body["output"]?.string else { return }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast(text.hasSuffix("\n") ? 1 : 0) {
                append(String(line), category: category)
            }
        case "exited":
            if let code = body["exitCode"]?.int { append("Program exited with code \(code).", category: "console") }
        case "terminated":
            end(failure: nil)
        case "breakpoint":
            if let path = body["breakpoint"]?["source"]?["path"]?.string, let line = body["breakpoint"]?["line"]?.int {
                verified[path, default: [:]][line] = body["breakpoint"]?["verified"]?.bool ?? false
            }
        default:
            break
        }
    }

    private func loadStack() async {
        let thread = threadID ?? 1
        guard let body = try? await request("stackTrace", ["threadId": .number(Double(thread)), "startFrame": .number(0), "levels": .number(50)]),
              state == .stopped else { return }
        frames = DAP.frames(in: body)
        let first = frames.first { $0.path != nil } ?? frames.first
        children = [:]
        if let first { select(frame: first.id) }
        onStopped?(first)
    }

    private func append(_ text: String, category: String) {
        output.append(OutputLine(id: nextOutputID, category: category, text: text))
        nextOutputID += 1
        if output.count > 5_000 { output.removeFirst(output.count - 5_000) }
    }
}
