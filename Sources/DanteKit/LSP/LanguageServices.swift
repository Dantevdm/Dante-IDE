import Foundation
import Observation

/// The language servers for one project window: started the first time a file in their
/// language opens, told about edits, and stopped with the window.
@MainActor
@Observable
public final class LanguageServices {
    public let root: URL
    public private(set) var clients: [String: LSPClient] = [:]
    /// Servers that couldn't start, so Dante doesn't keep retrying them.
    public private(set) var unavailable: [String: String] = [:]
    private var pendingChanges: [String: Task<Void, Never>] = [:]

    public init(root: URL) {
        self.root = root
    }

    public func client(for language: Language) -> LSPClient? {
        guard let server = LanguageServer.for(language) else { return nil }
        if let client = clients[server.name] { return client }
        guard unavailable[server.name] == nil else { return nil }
        do {
            let client = try LSPClient(server: server, root: root, environment: Shell.environment())
            clients[server.name] = client
            return client
        } catch {
            unavailable[server.name] = error.localizedDescription
            return nil
        }
    }

    /// Whichever client already holds `language`'s files, without starting one.
    public func existingClient(for language: Language) -> LSPClient? {
        LanguageServer.for(language).flatMap { clients[$0.name] }
    }

    public func opened(_ document: EditorDocument) {
        guard let client = client(for: document.language) else { return }
        let (url, language, text) = (document.url, document.language, document.text)
        Task { await client.open(url, language: language, text: text) }
    }

    /// Batches keystrokes: the server hears about the text once typing pauses.
    public func changed(_ document: EditorDocument) {
        guard let client = existingClient(for: document.language) else { return }
        let key = document.url.path
        pendingChanges[key]?.cancel()
        pendingChanges[key] = Task { [weak document] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let document else { return }
            await client.change(document.url, text: document.text)
        }
    }

    public func saved(_ document: EditorDocument) {
        guard let client = existingClient(for: document.language) else { return }
        let url = document.url
        Task { await client.save(url) }
    }

    public func closed(_ document: EditorDocument) {
        guard let client = existingClient(for: document.language) else { return }
        pendingChanges.removeValue(forKey: document.url.path)?.cancel()
        let url = document.url
        Task { await client.close(url) }
    }

    public func diagnostics(for document: EditorDocument) -> [LSPDiagnostic] {
        existingClient(for: document.language)?.diagnostics(for: document.url) ?? []
    }

    /// Where the symbol at `offset` is defined. Sends pending edits first so positions line up.
    public func definition(in document: EditorDocument, at offset: Int) async -> [LSPLocation] {
        guard let client = existingClient(for: document.language) else { return [] }
        await flush(document, to: client)
        let position = LSPPosition(offset: offset, in: document.text as NSString)
        return await client.definition(of: position, in: document.url)
    }

    public func hover(in document: EditorDocument, at offset: Int) async -> String? {
        guard let client = existingClient(for: document.language) else { return nil }
        await flush(document, to: client)
        return await client.hover(at: LSPPosition(offset: offset, in: document.text as NSString), in: document.url)
    }

    private func flush(_ document: EditorDocument, to client: LSPClient) async {
        if let pending = pendingChanges.removeValue(forKey: document.url.path) {
            pending.cancel()
            await client.change(document.url, text: document.text)
        }
    }

    public func stop() {
        for task in pendingChanges.values { task.cancel() }
        pendingChanges = [:]
        for client in clients.values { client.stop() }
        clients = [:]
    }
}
