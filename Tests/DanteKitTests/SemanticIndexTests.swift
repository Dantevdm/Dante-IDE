import Foundation
import Testing
@testable import DanteKit

@Suite struct ChunkerTests {
    @Test func piecesFollowTopLevelDeclarationsWithTheirComments() {
        let text = """
        import Foundation

        /// Retries a payment that failed.
        func retryPayment(_ id: String) {
            let attempt = 1
            print(attempt)
        }

        // The ledger.
        struct Ledger {
            func add() {}
        }
        """
        let chunks = Chunker.chunks(of: text, path: "Sources/Pay.swift")
        #expect(chunks.map(\.chunk.symbol) == ["retryPayment", "Ledger"])
        #expect(chunks[0].chunk.startLine == 3)
        #expect(chunks[0].chunk.endLine == 7)
        #expect(chunks[1].chunk.startLine == 9)
        #expect(chunks[1].chunk.endLine == 12)
        #expect(chunks[0].text.hasPrefix("Sources/Pay.swift\n/// Retries"))
    }

    @Test func longDeclarationsAreSplitIntoOverlappingWindows() {
        let body = (1...150).map { "    let value\($0) = \($0)" }.joined(separator: "\n")
        let chunks = Chunker.chunks(of: "func big() {\n\(body)\n}", path: "a.swift")
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.chunk.symbol == "big" })
        #expect(chunks[1].chunk.startLine == chunks[0].chunk.endLine + 1 - Chunker.overlap)
        #expect(chunks.last?.chunk.endLine == 152)
    }

    @Test func filesWithoutDeclarationsBecomeWindowsAndEmptyOnesNothing() {
        let text = (1...30).map { "line \($0) of the notes" }.joined(separator: "\n")
        let chunks = Chunker.chunks(of: text, path: "notes.conf")
        #expect(chunks.count == 1)
        #expect(chunks[0].chunk.symbol == nil)
        #expect(Chunker.chunks(of: "\n\n  \n", path: "empty.swift").isEmpty)
    }

    @Test func secretsDataAndLockfilesAreNotIndexed() {
        #expect(SemanticIndex.indexable("Sources/App.swift"))
        #expect(SemanticIndex.indexable("package.json"))
        #expect(!SemanticIndex.indexable(".env.local"))
        #expect(!SemanticIndex.indexable("package-lock.json"))
        #expect(!SemanticIndex.indexable("data/users.csv"))
        #expect(!SemanticIndex.indexable("node_modules/x/index.js"))
    }
}

@Suite struct SemanticIndexTests {
    /// A pretend model: one dimension per word it knows.
    static let words = ["payment", "retry", "ledger", "user", "login", "password"]
    static func embed(_ text: String) -> [Float] {
        let lower = text.lowercased()
        return words.map { lower.contains($0) ? 1 : 0 } + [0.01]
    }

    let files: [String: String] = [
        "pay.swift": "func retryPayment() {\n    // retry the payment later\n}\n",
        "auth.swift": "func login(user: String, password: String) {\n    check(password)\n}\n",
        "ledger.swift": "struct Ledger {\n    var entries: [Int] = []\n}\n",
    ]

    private func build(previous: SemanticIndex? = nil, files: [String: String]? = nil, counter: Counter = Counter()) async throws -> SemanticIndex {
        let files = files ?? self.files
        return try await SemanticIndex.build(files: files.keys.sorted(), read: { files[$0] }, model: "fake", dimensions: 7,
                                             previous: previous, embed: { texts in
            await counter.add(texts.count)
            return texts.map(Self.embed)
        })
    }

    @Test func questionsFindTheCodeThatAnswersThem() async throws {
        let index = try await build()
        #expect(index.chunks.count == 3)
        let hits = index.search(Self.embed("where do we retry a failed payment"), question: "where do we retry a failed payment", limit: 2)
        #expect(hits.first?.chunk.path == "pay.swift")
        let login = index.search(Self.embed("user login with password"), question: "user login", limit: 1)
        #expect(login.first?.chunk.symbol == "login")
    }

    @Test func onlyChangedPiecesAreEmbeddedAgain() async throws {
        let counter = Counter()
        let first = try await build(counter: counter)
        #expect(await counter.total == 3)
        var changed = files
        changed["ledger.swift"] = "struct Ledger {\n    var entries: [Int] = [1]\n}\n"
        let second = try await build(previous: first, files: changed, counter: counter)
        #expect(await counter.total == 4)
        #expect(second.chunks.count == 3)
    }

    @Test func savesAndLoadsTheVectors() async throws {
        let index = try await build()
        let folder = FileManager.default.temporaryDirectory.appending(path: "semantic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = URL(filePath: "/home/me/app")
        try index.save(for: root, in: folder)
        let loaded = SemanticIndex.load(for: root, in: folder)
        #expect(loaded?.chunks == index.chunks)
        #expect(loaded?.vectors == index.vectors)
    }

    @Test func embeddingsAreCutAndScaled() throws {
        let vector = SemanticIndex.normalised([3, 4, 12], to: 2)
        #expect(vector == [0.6, 0.8])
        #expect(try Ollama.parseEmbeddings(Data(#"{"model":"m","embeddings":[[0.5,0.25]]}"#.utf8)) == [[0.5, 0.25]])
    }

    @Test func picksALocalEmbeddingModel() {
        let installed = [OllamaModel(name: "qwen3:14b", size: 9), OllamaModel(name: "nomic-embed-text:latest", size: 2),
                         OllamaModel(name: "qwen3-embedding:0.6b", size: 1)]
        #expect(ModelRouting.embeddingModel(installed: installed) == "qwen3-embedding:0.6b")
        #expect(ModelRouting.embeddingModel(installed: [OllamaModel(name: "qwen3:14b", size: 9)]) == nil)
    }
}

actor Counter {
    private(set) var total = 0
    func add(_ count: Int) { total += count }
}

@Suite struct SearchCodeToolTests {
    @Test func searchCodeIsListedWithoutAWhyAndAnswers() async {
        var server = DelegateServer(project: "app", ledger: nil, models: { [] }) { _, _ in ("m", OllamaReply(text: "")) }
        server.searchCode = { question, limit in "\(limit) pieces for \(question)" }
        let names = server.tools.compactMap { $0["name"]?.string }
        #expect(names.contains("search_code"))
        let tool = server.tools.first { $0["name"]?.string == "search_code" }
        #expect(tool?["inputSchema"]?["properties"]?["why"] == nil)
        let reply = await server.call("search_code", arguments: ["question": "payment retries", "limit": 50])
        #expect(reply["content"]?.array?.first?["text"]?.string == "20 pieces for payment retries")
        let missing = await server.call("search_code", arguments: [:])
        #expect(missing["isError"]?.bool == true)
    }
}
