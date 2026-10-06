import Foundation
import Observation

/// One running language server for a project: keeps it in sync with open documents,
/// collects its diagnostics and answers go-to-definition.
@MainActor
@Observable
public final class LSPClient {
    public enum State: Equatable, Sendable {
        case starting, ready
        case stopped(String)
    }

    public let server: LanguageServer
    public let root: URL
    public private(set) var state: State = .starting
    /// Latest diagnostics per file, keyed by standardized path.
    public private(set) var diagnostics: [String: [LSPDiagnostic]] = [:]
    /// What the server said it can do, from `initialize`.
    public private(set) var capabilities: JSONValue = .null

    /// Characters after which the server wants to be asked for completions, such as `.`.
    public var completionTriggers: Set<Character> {
        Set((capabilities["completionProvider"]?["triggerCharacters"]?.array ?? []).compactMap { $0.string?.first })
    }
    public var completes: Bool { !(capabilities["completionProvider"]?.isNull ?? true) }
    public var findsReferences: Bool { Self.supports(capabilities["referencesProvider"]) }
    public var renames: Bool { Self.supports(capabilities["renameProvider"]) }
    public var formats: Bool { Self.supports(capabilities["documentFormattingProvider"]) }
    public var listsSymbols: Bool { Self.supports(capabilities["documentSymbolProvider"]) }
    public var searchesSymbols: Bool { Self.supports(capabilities["workspaceSymbolProvider"]) }

    /// A capability is `true` or an options object; absent or `false` means no.
    nonisolated static func supports(_ value: JSONValue?) -> Bool {
        guard let value, !value.isNull else { return false }
        return value.bool ?? true
    }

    private let process = Process()
    private let input: FileHandle
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Never>] = [:]
    private var versions: [String: Int] = [:]
    private var ready: Task<Bool, Never>?

    public init(server: LanguageServer, root: URL, environment: [String: String]) throws {
        guard let command = server.resolve(environment: environment) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "\(server.name) isn’t installed."])
        }
        self.server = server
        self.root = root.standardizedFileURL
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = root
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting

        // Bytes arrive on a background thread; the stream keeps them in order.
        let (bytes, continuation) = AsyncStream.makeStream(of: Data.self)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        try process.run()
        Task { [weak self] in
            var decoder = LSPFraming.Decoder()
            for await chunk in bytes {
                for message in decoder.append(chunk) { self?.receive(message) }
            }
            self?.didExit()
        }
        ready = Task { await self.initialize() }
    }

    public func diagnostics(for url: URL) -> [LSPDiagnostic] {
        diagnostics[url.standardizedFileURL.path] ?? []
    }

    // MARK: Documents

    public func open(_ url: URL, language: Language, text: String) async {
        guard await isReady, let languageID = server.languageIDs[language] else { return }
        let key = url.standardizedFileURL.path
        guard versions[key] == nil else { return await change(url, text: text) }
        versions[key] = 1
        notify("textDocument/didOpen", ["textDocument": [
            "uri": .string(Self.uri(url)), "languageId": .string(languageID), "version": 1, "text": .string(text),
        ]])
    }

    /// Sends the whole text: simpler than incremental edits and cheap at editor sizes.
    public func change(_ url: URL, text: String) async {
        guard await isReady else { return }
        let key = url.standardizedFileURL.path
        guard let version = versions[key].map({ $0 + 1 }) else { return }
        versions[key] = version
        notify("textDocument/didChange", [
            "textDocument": ["uri": .string(Self.uri(url)), "version": .number(Double(version))],
            "contentChanges": [["text": .string(text)]],
        ])
    }

    public func save(_ url: URL) async {
        guard await isReady, versions[url.standardizedFileURL.path] != nil else { return }
        notify("textDocument/didSave", ["textDocument": ["uri": .string(Self.uri(url))]])
    }

    /// Files in the server's languages that changed on disk without being open here
    /// (a checkout, a rename written to closed files, another editor), so its index stays current.
    public func filesChanged(_ urls: [URL]) async {
        let changes: [JSONValue] = urls.compactMap { url in
            guard server.languageIDs[Language(url: url)] != nil, versions[url.standardizedFileURL.path] == nil else { return nil }
            let exists = FileManager.default.fileExists(atPath: url.path)
            return ["uri": .string(Self.uri(url)), "type": .number(exists ? 2 : 3)]
        }
        guard !changes.isEmpty, await isReady else { return }
        notify("workspace/didChangeWatchedFiles", ["changes": .array(changes)])
    }

    public func close(_ url: URL) async {
        let key = url.standardizedFileURL.path
        guard await isReady, versions.removeValue(forKey: key) != nil else { return }
        notify("textDocument/didClose", ["textDocument": ["uri": .string(Self.uri(url))]])
        diagnostics[key] = nil
    }

    public func definition(of position: LSPPosition, in url: URL) async -> [LSPLocation] {
        guard await isReady else { return [] }
        let result = await request("textDocument/definition", [
            "textDocument": ["uri": .string(Self.uri(url))], "position": position.json,
        ])
        return LSPLocation.list(result)
    }

    public func completion(at position: LSPPosition, in url: URL, trigger: Character?) async -> (items: [LSPCompletionItem], isIncomplete: Bool) {
        guard await isReady, completes else { return ([], false) }
        var context: JSONValue = ["triggerKind": 1]
        if let trigger, completionTriggers.contains(trigger) {
            context = ["triggerKind": 2, "triggerCharacter": .string(String(trigger))]
        }
        let result = await request("textDocument/completion", [
            "textDocument": ["uri": .string(Self.uri(url))], "position": position.json, "context": context,
        ])
        return LSPCompletionItem.list(result)
    }

    /// The symbols declared in a file, nested ones flattened.
    public func documentSymbols(in url: URL) async -> [CodeSymbol] {
        guard await isReady, listsSymbols else { return [] }
        let result = await request("textDocument/documentSymbol", ["textDocument": ["uri": .string(Self.uri(url))]])
        return CodeSymbol.list(result, in: url)
    }

    /// Symbols across the project whose names match `query`, from the server's index.
    public func workspaceSymbols(matching query: String) async -> [CodeSymbol] {
        guard await isReady, searchesSymbols else { return [] }
        return CodeSymbol.list(await request("workspace/symbol", ["query": .string(query)]), in: nil)
    }

    public func references(at position: LSPPosition, in url: URL) async -> [LSPLocation] {
        guard await isReady, findsReferences else { return [] }
        let result = await request("textDocument/references", [
            "textDocument": ["uri": .string(Self.uri(url))], "position": position.json,
            "context": ["includeDeclaration": true],
        ])
        return LSPLocation.list(result)
    }

    /// The edits that rename the symbol at `position`; nil when the server can't.
    public func rename(at position: LSPPosition, in url: URL, to name: String) async -> LSPWorkspaceEdit? {
        guard await isReady, renames else { return nil }
        let result = await request("textDocument/rename", [
            "textDocument": ["uri": .string(Self.uri(url))], "position": position.json, "newName": .string(name),
        ])
        return result.isNull ? nil : LSPWorkspaceEdit(result)
    }

    public func formatting(of url: URL, tabSize: Int, insertSpaces: Bool) async -> [LSPTextEdit]? {
        guard await isReady, formats else { return nil }
        let result = await request("textDocument/formatting", [
            "textDocument": ["uri": .string(Self.uri(url))],
            "options": ["tabSize": .number(Double(tabSize)), "insertSpaces": .bool(insertSpaces)],
        ])
        return result.isNull ? nil : LSPTextEdit.list(result)
    }

    /// What the server says about the symbol at `position`, as markdown.
    public func hover(at position: LSPPosition, in url: URL) async -> String? {
        guard await isReady else { return nil }
        let result = await request("textDocument/hover", [
            "textDocument": ["uri": .string(Self.uri(url))], "position": position.json,
        ])
        return Self.hoverText(result["contents"] ?? .null)
    }

    /// Hover contents come as a string, MarkupContent, a MarkedString, or an array of them.
    nonisolated static func hoverText(_ contents: JSONValue) -> String? {
        func text(_ value: JSONValue) -> String? {
            if let string = value.string { return string }
            guard let body = value["value"]?.string else { return nil }
            if let language = value["language"]?.string { return "```\(language)\n\(body)\n```" }
            return body
        }
        let parts = (contents.array ?? [contents]).compactMap(text).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    public func stop() {
        guard process.isRunning else { return }
        Task {
            _ = await request("shutdown", nil)
            notify("exit", nil)
            try? await Task.sleep(for: .seconds(1))
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: Protocol

    private var isReady: Bool {
        get async { await ready?.value ?? false }
    }

    private func initialize() async -> Bool {
        let rootURI = JSONValue.string(Self.uri(root))
        let result = await request("initialize", [
            "processId": .number(Double(ProcessInfo.processInfo.processIdentifier)),
            "clientInfo": ["name": "Dante"],
            "rootUri": rootURI,
            "workspaceFolders": [["uri": rootURI, "name": .string(root.lastPathComponent)]],
            "capabilities": [
                "general": ["positionEncodings": ["utf-16"]],
                "textDocument": [
                    "synchronization": ["didSave": true],
                    "publishDiagnostics": ["relatedInformation": false],
                    "definition": ["linkSupport": true],
                    "hover": ["contentFormat": ["markdown", "plaintext"]],
                    "completion": [
                        "completionItem": [
                            "snippetSupport": true,
                            "documentationFormat": ["markdown", "plaintext"],
                            "labelDetailsSupport": true,
                        ],
                        "contextSupport": true,
                    ],
                    "references": [:],
                    "rename": ["prepareSupport": false],
                    "formatting": [:],
                ],
                "workspace": ["workspaceFolders": true, "configuration": true, "didChangeWatchedFiles": ["dynamicRegistration": false]],
            ],
        ])
        guard result["capabilities"] != nil else {
            if case .starting = state { state = .stopped("\(server.name) didn’t start.") }
            return false
        }
        capabilities = result["capabilities"] ?? .null
        notify("initialized", [:])
        state = .ready
        return true
    }

    private func request(_ method: String, _ params: JSONValue?) async -> JSONValue {
        guard process.isRunning else { return .null }
        let id = nextID
        nextID += 1
        return await withCheckedContinuation { continuation in
            pending[id] = continuation
            send(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params ?? .null])
        }
    }

    private func notify(_ method: String, _ params: JSONValue?) {
        var message: JSONValue = ["jsonrpc": "2.0", "method": .string(method)]
        if let params, case .object(var object) = message {
            object["params"] = params
            message = .object(object)
        }
        send(message)
    }

    private func send(_ message: JSONValue) {
        guard process.isRunning else { return }
        try? input.write(contentsOf: LSPFraming.encode(message))
    }

    func receive(_ message: JSONValue) {
        let method = message["method"]?.string
        let id = message["id"]
        switch (method, id) {
        case (let method?, let id?):
            // A request from the server. Dante has no settings to give, so answer each item with null.
            let count = message["params"]?["items"]?.array?.count
            let result: JSONValue = method == "workspace/configuration" ? .array(Array(repeating: .null, count: count ?? 0)) : .null
            send(["jsonrpc": "2.0", "id": id, "result": result])
        case (nil, let id?):
            if let number = id.int, let continuation = pending.removeValue(forKey: number) {
                continuation.resume(returning: message["result"] ?? .null)
            }
        case ("textDocument/publishDiagnostics"?, nil):
            guard let uri = message["params"]?["uri"]?.string, let url = URL(string: uri) else { return }
            let items = message["params"]?["diagnostics"]?.array ?? []
            diagnostics[url.standardizedFileURL.path] = items.compactMap(LSPDiagnostic.init).sorted {
                ($0.range.start.line, $0.severity.rawValue) < ($1.range.start.line, $1.severity.rawValue)
            }
        default:
            break
        }
    }

    private func didExit() {
        for continuation in pending.values { continuation.resume(returning: .null) }
        pending = [:]
        if case .stopped = state { return }
        state = .stopped("\(server.name) stopped.")
    }

    static func uri(_ url: URL) -> String {
        url.standardizedFileURL.absoluteString
    }
}
