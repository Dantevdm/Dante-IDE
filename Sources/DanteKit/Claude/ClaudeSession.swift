import Foundation
import Observation

/// A tool call Claude made, and where it's got to.
public struct ToolActivity: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case running
        case awaitingApproval(requestID: String)
        case declined
        case done
        case failed(String)
    }

    public var id: String
    public var name: String
    public var input: JSONValue
    public var status: Status
    /// The diff to review, for Edit, MultiEdit and Write.
    public var change: ProposedChange?
    /// What the project's Claude rules said about this call, if anything.
    public var ruleNote: String?
    /// Refused automatically by a `never` rule.
    public var blockedByRule = false

    public init(id: String, name: String, input: JSONValue, status: Status, change: ProposedChange? = nil) {
        self.id = id
        self.name = name
        self.input = input
        self.status = status
        self.change = change
    }

    public var isAwaitingApproval: Bool {
        if case .awaitingApproval = status { true } else { false }
    }

    /// The first half of the panel's one-line summary: what Claude did, or is asking to do.
    public var verb: String {
        let resolved = !isAwaitingApproval && status != .running
        if blockedByRule { return "Blocked" }
        switch name {
        case "Read": return "Read"
        case "Edit", "MultiEdit": return status == .declined ? "Declined edit" : (resolved ? "Edited" : "Edit")
        case "Write": return status == .declined ? "Declined" : (change?.isNewFile == true ? (resolved ? "Created" : "Create") : (resolved ? "Wrote" : "Write"))
        case "Bash": return status == .declined ? "Didn’t run" : (resolved ? "Ran" : "Run")
        case "Grep": return "Searched for"
        case "Glob": return "Listed"
        case "WebFetch": return "Fetched"
        case "WebSearch": return "Searched the web for"
        case "TodoWrite": return "Updated its to-do list"
        case "Task", "Agent": return "Delegated"
        case "AskUserQuestion": return isAwaitingApproval ? "Asks" : (status == .declined ? "Skipped questions" : "Asked")
        case "EnterPlanMode": return "Planning first"
        case "ExitPlanMode": return isAwaitingApproval ? "Plan ready" : (status == .declined ? "Kept planning" : "Started on the plan")
        case "Skill": return "Used skill"
        case "ToolSearch": return "Looked up tools"
        default:
            if let tool = Self.mcpTool(name) { return tool.action }
            return name
        }
    }

    /// `mcp__server__do_thing` as a readable action and the server's name. Servers added by
    /// claude.ai have an id rather than a name, so those read as "a connector".
    static func mcpTool(_ name: String) -> (action: String, server: String)? {
        guard name.hasPrefix("mcp__") else { return nil }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return nil }
        let words = parts.last!.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        let action = words.prefix(1).uppercased() + words.dropFirst()
        let server = parts.dropLast().joined(separator: " ")
        let looksLikeID = server.count >= 32 && server.allSatisfy { $0.isHexDigit || $0 == "-" }
        return (action, looksLikeID ? "a connector" : server)
    }

    /// The second half: the file, command, pattern or query it acted on.
    public func target(in root: URL) -> String {
        if let path = input["file_path"]?.string ?? input["notebook_path"]?.string {
            return ProposedChange.relativePath(of: URL(filePath: path), in: root)
        }
        if let command = input["command"]?.string {
            return command.split(separator: "\n").first.map(String.init) ?? command
        }
        if name == "AskUserQuestion" {
            return ClarifyingQuestion.parse(input).map { $0.header.isEmpty ? $0.question : $0.header }.joined(separator: ", ")
        }
        if name == "Skill", let skill = input["skill"]?.string ?? input["command"]?.string { return skill }
        let detail = input["pattern"]?.string ?? input["url"]?.string ?? input["query"]?.string ?? input["description"]?.string ?? ""
        if let tool = Self.mcpTool(name) { return detail.isEmpty ? "in \(tool.server)" : "\(detail) · \(tool.server)" }
        return detail
    }
}

public struct TranscriptItem: Identifiable, Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        /// What the user wrote, and the names of the files they attached.
        case user(String, attachments: [String] = [])
        case assistant(String)
        case tool(ToolActivity)
        case notice(String, isError: Bool)
    }

    public var id: String
    public var content: Content
}

/// A conversation with Claude Code, run headless (`claude --input-format stream-json`)
/// in the project folder. Claude proposes; every edit and command waits for approval.
@MainActor
@Observable
public final class ClaudeSession {
    public enum State: Equatable, Sendable {
        case idle
        case working
        case unavailable(String)
    }

    public private(set) var items: [TranscriptItem] = []
    public private(set) var state: State = .idle
    public private(set) var model: String?
    /// What the conversation has cost at API prices. On a Pro or Max plan nothing is billed
    /// per token; it's a measure of how much of the plan's allowance the work took.
    public private(set) var totalCostUSD: Double = 0
    /// Cost from earlier processes in this conversation (it resumes in a new one when
    /// settings change), since each process reports its own running total.
    private var costBeforeThisProcess: Double = 0
    /// The tokens in the conversation's context as of Claude's latest reply.
    public private(set) var context: TokenUsage?
    /// The model's context window; Claude Code reports it at the end of each turn.
    public private(set) var contextWindow = 200_000
    /// The Claude Code session this conversation continues, for the history list.
    public var conversationID: String? { sessionID }
    /// Claude Code replied that it isn't signed in.
    public private(set) var needsLogin = false

    /// Called after Claude changes a file, so open editors can reload it.
    public var onFileChanged: (URL) -> Void = { _ in }
    /// Something the person should look at: a finished turn, or a change or question waiting.
    public var onAttention: (Attention) -> Void = { _ in }

    public enum Attention: Equatable, Sendable {
        /// The turn ended; the start of Claude's last reply.
        case finished(String)
        /// A tool call waits for approval: what it is, in a few words.
        case needsApproval(String)
    }

    public let root: URL
    public let executable: String?
    private let systemPrompt: () -> String
    private let rules: () -> ClaudeRules
    private var startedRules = ClaudeRules()
    /// Ask clarifying questions before starting ambiguous work. Takes effect on the next message.
    public var asksFirst = true
    private var startedAsksFirst = true
    /// The `--model` to start with; nil leaves it to Claude Code. Takes effect on the next message.
    public var requestedModel: String?
    private var startedModel: String?
    private var sessionID: String?

    private var process: Process?
    private var stdin: FileHandle?
    private var stderrTail = ""
    private var nextRequest = 0

    /// Per turn, keyed by the user message's item id: the files approved edits replaced.
    public private(set) var checkpoints: [String: TurnCheckpoint] = [:]
    private var currentTurn: String?
    /// Told to Claude with the next message, so it knows its edits were rolled back.
    private var pendingNotice: String?

    private var index: [String: Int] = [:]
    private var streamingMessageID = ""
    private var streamingTextItemID: String?
    private var streamedTextBlocks: [String: Int] = [:]
    private var finishedTextBlocks: [String: Int] = [:]

    public init(root: URL, executable: String?, systemPrompt: @escaping () -> String, rules: @escaping () -> ClaudeRules = { ClaudeRules() }) {
        self.root = root
        self.executable = executable
        self.systemPrompt = systemPrompt
        self.rules = rules
        if executable == nil {
            state = .unavailable("Claude Code isn’t installed. Install it from claude.com/claude-code, then reopen the project.")
        }
    }

    /// A message sent while Claude was working, sent when the turn ends.
    public struct QueuedMessage: Identifiable, Equatable {
        public let id = UUID()
        public var text: String
        public var context: String?
        public var attachments: [Attachment]

        public static func == (a: QueuedMessage, b: QueuedMessage) -> Bool { a.id == b.id }
    }

    /// Messages waiting for the current turn to finish, oldest first.
    public private(set) var queued: [QueuedMessage] = []

    public func cancelQueued(_ id: UUID) {
        queued.removeAll { $0.id == id }
    }

    /// The turn whose file edits are applied as they arrive ("Apply the rest of this turn").
    /// They are still checkpointed, so Undo this turn puts them back.
    public private(set) var autoAppliedTurn: String?

    public var appliesRestOfTurn: Bool { autoAppliedTurn != nil && autoAppliedTurn == currentTurn }

    /// Applies every waiting file edit, and with `restOfTurn` the ones still to come this turn.
    public func applyAll(restOfTurn: Bool = false) {
        if restOfTurn { autoAppliedTurn = currentTurn }
        for tool in pendingApprovals where Self.editTools.contains(tool.name) { approve(tool.id) }
    }

    public func stopApplyingRestOfTurn() { autoAppliedTurn = nil }

    static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    public var pendingApprovals: [ToolActivity] {
        items.compactMap { item in
            if case .tool(let tool) = item.content, tool.isAwaitingApproval { tool } else { nil }
        }
    }

    // MARK: Conversation

    /// Sends a message. `context` is passed to Claude but not shown in the transcript.
    public func send(_ text: String, context: String? = nil, attachments: [Attachment] = []) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        // Mid-turn, a button such as "Find untested code" waits its turn rather than vanishing.
        if state == .working {
            queued.append(QueuedMessage(text: text, context: context, attachments: attachments))
            return
        }
        // Rules are passed at launch, so pick up edits to project.yaml by resuming in a new process.
        if process != nil, rules() != startedRules || asksFirst != startedAsksFirst || requestedModel != startedModel {
            stop()
        }
        if process == nil {
            guard start() else { return }
        }
        let turn = "user-\(UUID().uuidString)"
        currentTurn = turn
        append(TranscriptItem(id: turn, content: .user(trimmed, attachments: attachments.map(\.name))))
        if trimmed.isEmpty { trimmed = "Take a look at \(attachments.count == 1 ? "this file" : "these files")." }
        let notes = [pendingNotice, context].compactMap { $0 }.joined(separator: "\n\n")
        pendingNotice = nil
        let message = notes.isEmpty ? trimmed : "\(trimmed)\n\n<dante-context>\n\(notes)\n</dante-context>"
        write(ClaudeInput.userMessage(message, attachments: attachments))
        state = .working
    }

    /// Stops the current turn. Pending approvals are declined.
    public func interrupt() {
        guard state == .working else { return }
        for tool in pendingApprovals { decline(tool.id, message: "The user stopped this turn.") }
        write(ClaudeInput.interrupt(requestID: requestID()))
    }

    public func approve(_ toolID: String) {
        guard let tool = tool(toolID), case .awaitingApproval(let requestID) = tool.status else { return }
        if let turn = currentTurn {
            var checkpoint = checkpoints[turn] ?? TurnCheckpoint()
            if Self.editTools.contains(tool.name),
               let path = tool.input["file_path"]?.string ?? tool.input["notebook_path"]?.string {
                checkpoint.record(path) { try? String(contentsOf: URL(filePath: $0), encoding: .utf8) }
            } else if tool.name == "Bash" {
                checkpoint.ranCommands = true
            }
            checkpoints[turn] = checkpoint
        }
        write(ClaudeInput.allow(requestID: requestID, input: tool.input))
        updateTool(toolID) { $0.status = .running }
    }

    /// Answers an AskUserQuestion call: Claude gets its input back with `answers` filled in,
    /// keyed by question text (several picks are joined with ", ").
    public func answer(_ toolID: String, answers: [String: String]) {
        guard let tool = tool(toolID), case .awaitingApproval(let requestID) = tool.status,
              case .object(var input) = tool.input else { return }
        input["answers"] = .object(answers.mapValues { .string($0) })
        write(ClaudeInput.allow(requestID: requestID, input: .object(input)))
        updateTool(toolID) {
            $0.input = .object(input)
            $0.status = .running
        }
    }

    public func decline(_ toolID: String, message: String = "The user declined this. Ask what they’d like instead.") {
        guard let tool = tool(toolID), case .awaitingApproval(let requestID) = tool.status else { return }
        write(ClaudeInput.deny(requestID: requestID, message: message))
        updateTool(toolID) { $0.status = .declined }
    }

    /// Puts back every file Claude's approved edits changed in a turn. Claude hears about it
    /// with the next message. Returns the files restored.
    @discardableResult
    public func undoTurn(_ turn: String) -> [URL] {
        guard state != .working, var checkpoint = checkpoints[turn], !checkpoint.undone else { return [] }
        var failed: [String] = []
        let paths = checkpoint.undo { path, text in
            let url = URL(filePath: path)
            do {
                if let text { try text.write(to: url, atomically: true, encoding: .utf8) } else { try FileManager.default.removeItem(at: url) }
            } catch {
                failed.append(path)
            }
        }
        checkpoints[turn] = checkpoint
        let urls = paths.map { URL(filePath: $0) }
        urls.forEach(onFileChanged)
        let names = paths.map { ProposedChange.relativePath(of: URL(filePath: $0), in: root) }
        pendingNotice = "The user undid your changes from an earlier turn, so these files are back as they were: \(names.joined(separator: ", ")). Read them again before editing."
        note("Undid the changes to \(names.count == 1 ? names[0] : "\(names.count) files")" + (checkpoint.ranCommands ? ". Commands that ran aren’t undone." : ".")
             + (failed.isEmpty ? "" : " Couldn’t restore \(failed.count)."), isError: !failed.isEmpty)
        return urls
    }

    /// Ends the conversation and clears the transcript. The next message starts a new one.
    public func reset() {
        stop()
        items = []
        index = [:]
        queued = []
        checkpoints = [:]
        currentTurn = nil
        autoAppliedTurn = nil
        pendingNotice = nil
        context = nil
        costBeforeThisProcess = 0
        totalCostUSD = 0
        needsLogin = false
        sessionID = nil
        if executable != nil { state = .idle }
    }

    /// Picks up an earlier conversation: its transcript is shown, and the next message
    /// continues it with `--resume`.
    public func resume(conversation id: String, items earlier: [TranscriptItem]) {
        reset()
        sessionID = id
        for item in earlier { append(item) }
        note("Earlier conversation. Your next message continues it.", isError: false)
    }

    /// Has Claude Code summarise the conversation so far, freeing context. Long conversations
    /// cost more per message, because every message re-reads everything before it.
    public func compact() {
        guard state == .idle, !items.isEmpty, executable != nil else { return }
        if process == nil {
            guard start() else { return }
        }
        note("Compacting the conversation: Claude keeps a summary and drops the rest.", isError: false)
        write(ClaudeInput.userMessage("/compact"))
        state = .working
    }

    public func stop() {
        costBeforeThisProcess = totalCostUSD
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        stdin = nil
        if state == .working { state = .idle }
    }

    // MARK: Process

    private func start() -> Bool {
        guard let executable else { return false }
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.currentDirectoryURL = root
        let rules = rules()
        let prompt = asksFirst ? systemPrompt() + "\n\n" + ClaudeBrief.clarifyingQuestions : systemPrompt()
        process.arguments = Self.arguments(systemPrompt: prompt, rules: rules, resume: sessionID, model: requestedModel)
        startedRules = rules
        startedAsksFirst = asksFirst
        startedModel = requestedModel
        process.environment = Self.environment()

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.processEnded(status: status) }
        }

        do {
            try process.run()
        } catch {
            note("Couldn’t start Claude Code: \(error.localizedDescription)", isError: true)
            return false
        }
        self.process = process
        stdin = input.fileHandleForWriting
        stderrTail = ""
        write(ClaudeInput.initialize(requestID: requestID()))

        let stdoutLines = Self.lines(from: output.fileHandleForReading)
        let stderrLines = Self.lines(from: errors.fileHandleForReading)
        Task.detached { [weak self] in
            for await line in stdoutLines {
                let event = ClaudeEvent(line: line)
                if event != .ignored { await self?.handle(event) }
            }
        }
        Task.detached { [weak self] in
            for await line in stderrLines { await self?.noteStderr(line) }
        }
        return true
    }

    /// Lines from a pipe as they arrive. (`FileHandle.bytes` buffers pipes, which stalls
    /// a streaming conversation, so this reads chunks with a readability handler.)
    nonisolated static func lines(from handle: FileHandle) -> AsyncStream<String> {
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        return AsyncStream { output in
            let task = Task {
                var buffer = Data()
                for await chunk in chunks {
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        output.yield(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                        buffer.removeSubrange(buffer.startIndex...newline)
                    }
                }
                if !buffer.isEmpty { output.yield(String(decoding: buffer, as: UTF8.self)) }
                output.finish()
            }
            output.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated static func arguments(systemPrompt: String, rules: ClaudeRules, resume sessionID: String?, model: String? = nil) -> [String] {
        var arguments = [
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-prompt-tool", "stdio",
            "--permission-mode", "default",
            "--append-system-prompt", systemPrompt,
        ]
        if let settings = rules.settingsJSON { arguments += ["--settings", settings] }
        if let sessionID { arguments += ["--resume", sessionID] }
        if let model { arguments += ["--model", model] }
        return arguments
    }

    private func processEnded(status: Int32) {
        costBeforeThisProcess = totalCostUSD
        process = nil
        stdin = nil
        for tool in pendingApprovals { updateTool(tool.id) { $0.status = .declined } }
        if state == .working { state = .idle }
        let detail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        note(detail.isEmpty ? "Claude Code stopped (exit \(status)). Send a message to start again." : "Claude Code stopped: \(detail)", isError: status != 0)
    }

    private func noteStderr(_ line: String) {
        stderrTail = String((stderrTail + line + "\n").suffix(600))
    }

    private func write(_ message: JSONValue) {
        guard let stdin else { return }
        do {
            try stdin.write(contentsOf: Data((message.jsonLine + "\n").utf8))
        } catch {
            note("Lost the connection to Claude Code.", isError: true)
            stop()
        }
    }

    private func requestID() -> String {
        nextRequest += 1
        return "dante-\(nextRequest)"
    }

    /// The app's environment, minus the markers Claude Code uses to refuse nested sessions,
    /// plus the usual tool folders (apps opened from Finder get a minimal PATH).
    nonisolated static func environment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"] { environment[key] = nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for extra in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] where !path.contains(extra) {
            path.append(extra)
        }
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }

    // MARK: Events

    func handle(_ event: ClaudeEvent) {
        switch event {
        case .started(let sessionID, let model):
            self.model = model
            if !sessionID.isEmpty { self.sessionID = sessionID }

        case .messageStarted(let id):
            streamingMessageID = id
            streamingTextItemID = nil

        case .blockStarted(let isText):
            guard isText else { streamingTextItemID = nil; return }
            let count = streamedTextBlocks[streamingMessageID, default: 0]
            streamedTextBlocks[streamingMessageID] = count + 1
            let id = "\(streamingMessageID)-t\(count)"
            streamingTextItemID = id
            upsert(TranscriptItem(id: id, content: .assistant("")))

        case .textDelta(let text):
            guard let id = streamingTextItemID, let position = index[id],
                  case .assistant(let current) = items[position].content else { return }
            items[position].content = .assistant(current + text)

        case .assistant(let messageID, let blocks, let usage):
            if let usage, usage.context > 0 { context = usage }
            for block in blocks {
                switch block {
                case .text(let text):
                    let count = finishedTextBlocks[messageID, default: 0]
                    finishedTextBlocks[messageID] = count + 1
                    upsert(TranscriptItem(id: "\(messageID)-t\(count)", content: .assistant(text)))
                case .toolUse(let id, let name, let input):
                    if index[id] == nil {
                        append(TranscriptItem(id: id, content: .tool(ToolActivity(id: id, name: name, input: input, status: .running))))
                    }
                }
            }

        case .toolResults(let results):
            for result in results {
                guard let tool = tool(result.toolUseID) else { continue }
                if result.isError {
                    // A declined tool reports an error too; keep it showing as declined.
                    if tool.status != .declined {
                        updateTool(tool.id) { $0.status = .failed(result.text) }
                    }
                } else {
                    updateTool(tool.id) { $0.status = .done }
                    if let change = tool.change ?? ProposedChange.make(toolName: tool.name, input: tool.input, root: root) {
                        onFileChanged(change.url)
                    }
                }
            }

        case .permissionRequest(let request):
            let id = request.toolUseID ?? "request-\(request.requestID)"
            defer {
                if case .awaitingApproval = activity(id)?.status {
                    if appliesRestOfTurn, Self.editTools.contains(request.toolName), activity(id)?.ruleNote == nil {
                        approve(id)
                    } else {
                        onAttention(.needsApproval(Self.attentionLabel(request.toolName, input: request.input)))
                    }
                }
            }
            let change = ProposedChange.make(toolName: request.toolName, input: request.input, root: root)
            if index[id] == nil {
                append(TranscriptItem(id: id, content: .tool(ToolActivity(id: id, name: request.toolName, input: request.input, status: .running))))
            }
            switch rules().verdict(toolName: request.toolName, input: request.input, root: root) {
            case .blocked(let message):
                write(ClaudeInput.deny(requestID: request.requestID, message: message))
                updateTool(id) {
                    $0.input = request.input
                    $0.change = change
                    $0.ruleNote = message
                    $0.blockedByRule = true
                    $0.status = .declined
                }
            case .note(let note):
                updateTool(id) {
                    $0.input = request.input
                    $0.change = change
                    $0.ruleNote = note
                    $0.status = .awaitingApproval(requestID: request.requestID)
                }
            case .allowed:
                updateTool(id) {
                    $0.input = request.input
                    $0.change = change
                    $0.status = .awaitingApproval(requestID: request.requestID)
                }
            }

        case .result(let result):
            state = .idle
            streamingTextItemID = nil
            if let cost = result.costUSD { totalCostUSD = costBeforeThisProcess + cost }
            if let window = result.contextWindow, window > 0 { contextWindow = window }
            needsLogin = result.isError && result.text.localizedCaseInsensitiveContains("not logged in")
            // Errors such as "Not logged in" usually arrive as assistant text too.
            let alreadyShown = items.last.map { $0.content == .assistant(result.text) } ?? false
            if result.isError, !result.text.isEmpty, !alreadyShown {
                note(result.text, isError: true)
            }
            if !queued.isEmpty {
                let next = queued.removeFirst()
                send(next.text, context: next.context, attachments: next.attachments)
            } else {
                let reply = items.last { if case .assistant = $0.content { true } else { false } }
                if case .assistant(let text) = reply?.content {
                    onAttention(.finished(String(text.prefix(160))))
                } else {
                    onAttention(.finished(result.isError ? result.text : "Done."))
                }
            }

        case .ignored:
            break
        }
    }

    private func activity(_ id: String) -> ToolActivity? {
        guard let position = index[id], case .tool(let tool) = items[position].content else { return nil }
        return tool
    }

    /// "Edit Mailer.swift", "Run go test ./...", "Answer a question".
    static func attentionLabel(_ toolName: String, input: JSONValue) -> String {
        if toolName == "AskUserQuestion" { return "Claude has a question" }
        if toolName == "ExitPlanMode" { return "Claude's plan is ready" }
        if let path = input["file_path"]?.string ?? input["notebook_path"]?.string {
            return "\(toolName == "Write" ? "Write" : "Edit") \((path as NSString).lastPathComponent)"
        }
        if let command = input["command"]?.string { return "Run \(command.prefix(60))" }
        return "Use \(toolName)"
    }

    // MARK: Transcript

    private func append(_ item: TranscriptItem) {
        index[item.id] = items.count
        items.append(item)
    }

    private func upsert(_ item: TranscriptItem) {
        if let position = index[item.id] {
            items[position] = item
        } else {
            append(item)
        }
    }

    private func note(_ text: String, isError: Bool) {
        append(TranscriptItem(id: "note-\(UUID().uuidString)", content: .notice(text, isError: isError)))
    }

    private func tool(_ id: String) -> ToolActivity? {
        guard let position = index[id], case .tool(let tool) = items[position].content else { return nil }
        return tool
    }

    private func updateTool(_ id: String, _ update: (inout ToolActivity) -> Void) {
        guard let position = index[id], case .tool(var tool) = items[position].content else { return }
        update(&tool)
        items[position].content = .tool(tool)
    }
}
