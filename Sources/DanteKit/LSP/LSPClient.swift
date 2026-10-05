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
                ],
                "workspace": ["workspaceFolders": true, "configuration": true],
            ],
        ])
        guard result["capabilities"] != nil else {
            if case .starting = state { state = .stopped("\(server.name) didn’t start.") }
            return false
        }
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
