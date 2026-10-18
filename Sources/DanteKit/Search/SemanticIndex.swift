import Foundation

/// Search by meaning: the project cut into pieces at declarations, each turned into a vector
/// by an embedding model in Ollama on this Mac, and a question ranked against them. The
/// index lives per Mac in Application Support, never in the repo, and only pieces whose text
/// changed are embedded again.
public struct SemanticIndex: Codable, Sendable, Equatable {
    /// A piece of a file: a declaration and its body, or a window of lines.
    public struct Chunk: Codable, Sendable, Equatable, Hashable {
        public var path: String
        /// 1-based, inclusive.
        public var startLine: Int
        public var endLine: Int
        /// The declaration it starts with, when there is one.
        public var symbol: String?
        /// Of the text that was embedded, to reuse vectors for pieces that didn't change.
        public var hash: UInt64

        public init(path: String, startLine: Int, endLine: Int, symbol: String?, hash: UInt64) {
            self.path = path
            self.startLine = startLine
            self.endLine = endLine
            self.symbol = symbol
            self.hash = hash
        }

        public var location: String { "\(path):\(startLine)-\(endLine)" }
    }

    public struct Hit: Sendable, Equatable, Identifiable {
        public var chunk: Chunk
        /// Cosine similarity, plus a little for the question's words appearing in the piece.
        public var score: Float
        public var id: String { chunk.location }
    }

    public var model: String
    public var dimensions: Int
    public var chunks: [Chunk]
    /// `chunks.count × dimensions` floats, each vector unit length.
    public var vectors: [Float]
    public var date: Date

    public init(model: String, dimensions: Int, chunks: [Chunk] = [], vectors: [Float] = [], date: Date = Date()) {
        self.model = model
        self.dimensions = dimensions
        self.chunks = chunks
        self.vectors = vectors
        self.date = date
    }

    public var files: Int { Set(chunks.map(\.path)).count }

    /// The vector for a chunk index.
    func vector(_ index: Int) -> ArraySlice<Float> {
        vectors[(index * dimensions)..<((index + 1) * dimensions)]
    }

    // MARK: Building

    /// Embeds texts with the model: one vector per text, in order.
    public typealias Embedder = @Sendable (_ texts: [String]) async throws -> [[Float]]

    /// Cut, embed what's new, and keep what's the same. `read` gives a file's text (nil skips it).
    public static func build(files: [String], read: @Sendable (String) -> String?, model: String, dimensions: Int = 512,
                             previous: SemanticIndex?, embed: Embedder, batch: Int = 32,
                             progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil,
                             checkpoint: (@Sendable (SemanticIndex) -> Void)? = nil) async throws -> SemanticIndex {
        var pieces: [(chunk: Chunk, text: String)] = []
        for path in files where indexable(path) {
            guard let text = read(path) else { continue }
            pieces += Chunker.chunks(of: text, path: path)
        }
        if pieces.count > limit { pieces = Array(pieces.prefix(limit)) }

        var known: [UInt64: ArraySlice<Float>] = [:]
        if let previous, previous.model == model, previous.dimensions == dimensions {
            for (index, chunk) in previous.chunks.enumerated() { known[chunk.hash] = previous.vector(index) }
        }
        // Main code first, then tests and docs, so a big project is useful before it's finished.
        let pathByHash = Dictionary(pieces.map { ($0.chunk.hash, $0.chunk.path) }, uniquingKeysWith: { first, _ in first })
        let missing = Set(pieces.map(\.chunk.hash)).subtracting(known.keys).sorted { a, b in
            let (x, y) = (priority(pathByHash[a] ?? ""), priority(pathByHash[b] ?? ""))
            return x != y ? x < y : (pathByHash[a] ?? "", a) < (pathByHash[b] ?? "", b)
        }
        let textByHash = Dictionary(pieces.map { ($0.chunk.hash, $0.text) }, uniquingKeysWith: { first, _ in first })
        var done = 0
        progress?(0, missing.count)
        for start in stride(from: 0, to: missing.count, by: batch) {
            try Task.checkCancellation()
            let hashes = Array(missing[start..<min(start + batch, missing.count)])
            let vectors = try await embed(hashes.map { textByHash[$0] ?? "" })
            guard vectors.count == hashes.count else { throw Ollama.Failure(message: "The embedding model returned \(vectors.count) vectors for \(hashes.count) pieces.") }
            for (hash, vector) in zip(hashes, vectors) { known[hash] = ArraySlice(normalised(vector, to: dimensions)) }
            done += hashes.count
            progress?(done, missing.count)
            if let checkpoint, done % (batch * 16) == 0, done < missing.count {
                checkpoint(assemble(pieces.map(\.chunk), known: known, model: model, dimensions: dimensions))
            }
        }
        return assemble(pieces.map(\.chunk), known: known, model: model, dimensions: dimensions)
    }

    /// The index of every piece that has a vector so far.
    static func assemble(_ chunks: [Chunk], known: [UInt64: ArraySlice<Float>], model: String, dimensions: Int) -> SemanticIndex {
        var index = SemanticIndex(model: model, dimensions: dimensions)
        index.vectors.reserveCapacity(chunks.count * dimensions)
        for chunk in chunks {
            guard let vector = known[chunk.hash], vector.count == dimensions else { continue }
            index.chunks.append(chunk)
            index.vectors.append(contentsOf: vector)
        }
        return index
    }

    /// 0 for main code, 1 for tests, 2 for docs.
    static func priority(_ path: String) -> Int {
        if ["md", "markdown", "rst", "adoc"].contains((path as NSString).pathExtension.lowercased()) { return 2 }
        return SecurityScanner.isTest(path) ? 1 : 0
    }

    /// Big enough for a large app; past it the index would cost more memory than it's worth.
    public static let limit = 40_000

    /// Code and docs worth searching: not binaries, lockfiles, vendored code, data or env files.
    public static func indexable(_ path: String) -> Bool {
        guard SecurityScanner.isScannable(path) else { return false }
        let name = (path as NSString).lastPathComponent.lowercased()
        if name.hasPrefix(".env") || name.hasSuffix(".pem") || name.hasSuffix(".key") { return false }
        let ext = (name as NSString).pathExtension
        return !["json", "lock", "log", "txt", "xml", "plist", "pbxproj", "xcstrings", "strings", "svg", "map"].contains(ext)
            || name == "package.json"
    }

    /// Cut to the first `dimensions` numbers (the model is trained so a prefix still works)
    /// and scaled to unit length, so a dot product is the cosine.
    static func normalised(_ vector: [Float], to dimensions: Int) -> [Float] {
        var cut = Array(vector.prefix(dimensions))
        if cut.count < dimensions { cut += Array(repeating: 0, count: dimensions - cut.count) }
        let length = cut.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? cut.map { $0 / length } : cut
    }

    // MARK: Searching

    /// What the model is told about a question, so it's placed near the code that answers it.
    public static func queryText(_ question: String) -> String {
        "Instruct: Given a question about a codebase, find the code that answers it\nQuery: \(question)"
    }

    /// The best pieces for a question already embedded; at most two per file, so one long
    /// file doesn't fill the list.
    public func search(_ queryVector: [Float], question: String, limit: Int = 20, perFile: Int = 2) -> [Hit] {
        guard !chunks.isEmpty else { return [] }
        let query = Self.normalised(queryVector, to: dimensions)
        let words = Set(question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
        var scored: [(Int, Float)] = []
        scored.reserveCapacity(chunks.count)
        vectors.withUnsafeBufferPointer { all in
            query.withUnsafeBufferPointer { q in
                for index in chunks.indices {
                    let base = index * dimensions
                    var dot: Float = 0
                    for d in 0..<dimensions { dot += all[base + d] * q[d] }
                    scored.append((index, dot))
                }
            }
        }
        scored.sort { $0.1 > $1.1 }
        var hits: [Hit] = []
        var perPath: [String: Int] = [:]
        for (index, similarity) in scored.prefix(limit * 6) {
            let chunk = chunks[index]
            let named = (chunk.path + " " + (chunk.symbol ?? "")).lowercased()
            let boost = words.isEmpty ? 0 : Float(words.filter { named.contains($0) }.count) / Float(words.count) * 0.04
            hits.append(Hit(chunk: chunk, score: similarity + boost))
        }
        hits.sort { $0.score > $1.score }
        return hits.filter { hit in
            let count = perPath[hit.chunk.path, default: 0]
            perPath[hit.chunk.path] = count + 1
            return count < perFile
        }.prefix(limit).map { $0 }
    }

    /// FNV-1a over the UTF-8 bytes: stable across launches, unlike `hashValue`.
    static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100_0000_01b3
        }
        return value
    }

    // MARK: Saving

    public static func folder() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Dante/semantic")
    }

    public static func url(for root: URL, in folder: URL = folder()) -> URL {
        let path = root.standardizedFileURL.path
        return folder.appending(path: "\(root.lastPathComponent)-\(String(hash(path), radix: 16)).plist")
    }

    public static func load(for root: URL, in folder: URL = folder()) -> SemanticIndex? {
        guard let data = try? Data(contentsOf: url(for: root, in: folder)) else { return nil }
        return try? PropertyListDecoder().decode(SemanticIndex.self, from: data)
    }

    public func save(for root: URL, in folder: URL = Self.folder()) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(self).write(to: Self.url(for: root, in: folder), options: .atomic)
    }

    // Vectors as raw bytes: a plist of 20 million numbers would be slow and huge.
    enum CodingKeys: String, CodingKey { case model, dimensions, chunks, vectors, date }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        dimensions = try container.decode(Int.self, forKey: .dimensions)
        chunks = try container.decode([Chunk].self, forKey: .chunks)
        date = try container.decode(Date.self, forKey: .date)
        let data = try container.decode(Data.self, forKey: .vectors)
        vectors = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard vectors.count == chunks.count * dimensions else {
            throw DecodingError.dataCorruptedError(forKey: .vectors, in: container, debugDescription: "Vectors don't match the pieces.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(dimensions, forKey: .dimensions)
        try container.encode(chunks, forKey: .chunks)
        try container.encode(date, forKey: .date)
        try container.encode(vectors.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .vectors)
    }
}

/// Cuts a file into pieces worth embedding: one per top-level declaration (with the comment
/// above it), long ones split into overlapping windows, and plain windows where a language
/// has no declarations Dante can find.
public enum Chunker {
    public static let window = 60
    public static let overlap = 10
    /// Characters embedded per piece; the model reads about 2,000 tokens well.
    public static let characters = 3_000

    public static func chunks(of text: String, path: String) -> [(chunk: SemanticIndex.Chunk, text: String)] {
        let lines = text.components(separatedBy: "\n")
        guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return [] }
        let language = Language(url: URL(filePath: path))
        let symbols = DeclarationScanner.symbols(in: text, language: language, url: URL(filePath: path))
        // Top-level declarations only: nested ones stay inside their parent's piece.
        var starts: [(line: Int, name: String)] = []
        for symbol in symbols {
            let line = symbol.range.start.line
            let indent = lines[line].prefix { $0 == " " || $0 == "\t" }.count
            if indent == 0 || language == .markdown { starts.append((line, symbol.name)) }
        }

        var ranges: [(start: Int, end: Int, symbol: String?, first: Bool)] = []
        if starts.isEmpty {
            ranges = windows(from: 0, to: lines.count - 1).map { ($0.0, $0.1, nil, false) }
        } else {
            if starts[0].line > 0, (0..<starts[0].line).contains(where: { !isBoilerplate(lines[$0]) }) {
                ranges += windows(from: 0, to: starts[0].line - 1).map { ($0.0, $0.1, nil, false) }
            }
            for (offset, start) in starts.enumerated() {
                var from = start.line
                // Doc comments and attributes above the declaration belong to it.
                let previous = offset > 0 ? starts[offset - 1].line : -1
                while from - 1 > previous, isLeading(lines[from - 1]) { from -= 1 }
                let end = offset + 1 < starts.count ? starts[offset + 1].line - 1 : lines.count - 1
                for (number, window) in windows(from: from, to: end).enumerated() {
                    ranges.append((window.0, window.1, start.name, number == 0))
                }
            }
            // Comments taken by a declaration leave the end of the piece before it.
            for index in ranges.indices.dropLast() where ranges[index + 1].first && ranges[index].end >= ranges[index + 1].start {
                ranges[index].end = max(ranges[index].start, ranges[index + 1].start - 1)
            }
        }

        return ranges.compactMap { range in
            var end = range.end
            while end > range.start, lines[end].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
            let body = lines[range.start...end].joined(separator: "\n")
            guard body.trimmingCharacters(in: .whitespacesAndNewlines).count >= 12 else { return nil }
            let text = "\(path)\n\(String(body.prefix(characters)))"
            let chunk = SemanticIndex.Chunk(path: path, startLine: range.start + 1, endLine: end + 1, symbol: range.symbol, hash: SemanticIndex.hash(text))
            return (chunk, text)
        }
    }

    /// Windows of `window` lines overlapping by `overlap`, or the range itself when it's short.
    static func windows(from start: Int, to end: Int) -> [(Int, Int)] {
        guard end >= start else { return [] }
        guard end - start + 1 > window + overlap else { return [(start, end)] }
        var result: [(Int, Int)] = []
        var from = start
        while from <= end {
            let to = min(from + window - 1, end)
            result.append((from, to))
            if to == end { break }
            from = to + 1 - overlap
        }
        return result
    }

    static func isLeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("///") || trimmed.hasPrefix("//") || trimmed.hasPrefix("#") && !trimmed.hasPrefix("#!") && !trimmed.hasPrefix("#include")
            || trimmed.hasPrefix("@") || trimmed.hasPrefix("/**") || trimmed.hasPrefix("*") || trimmed.hasPrefix("--")
    }

    /// Imports and blank lines: a file's head with nothing else isn't worth a piece.
    static func isBoilerplate(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || ["import ", "package ", "use ", "from ", "require(", "#include", "@_", "//"].contains { trimmed.hasPrefix($0) }
    }
}

extension Ollama {
    /// Vectors for texts from an embedding model (`/api/embed`).
    public func embed(model: String, texts: [String]) async throws -> [[Float]] {
        var request = URLRequest(url: base.appending(path: "api/embed"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        let body: [String: Any] = ["model": model, "input": texts, "keep_alive": "10m", "truncate": true]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure(message: "Ollama isn’t answering at \(base.host() ?? "localhost"): \(error.localizedDescription)")
        }
        return try Self.parseEmbeddings(data)
    }

    static func parseEmbeddings(_ data: Data) throws -> [[Float]] {
        struct Response: Decodable {
            var embeddings: [[Float]]?
            var error: String?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        if let error = response.error { throw Failure(message: error) }
        return response.embeddings ?? []
    }
}

extension ModelRouting {
    /// The embedding model to index with: Qwen3's first (it reads code well), then others.
    public static func embeddingModel(installed: [OllamaModel]) -> String? {
        let local = installed.filter { $0.isEmbedding && !$0.isCloud }
        let preference = ["qwen3-embedding", "embeddinggemma", "nomic-embed", "mxbai-embed", "bge-m3", "snowflake-arctic-embed"]
        for name in preference {
            if let model = local.first(where: { $0.name.lowercased().hasPrefix(name) }) { return model.name }
        }
        return local.first?.name
    }
}

/// Keeps a project's index up to date and answers questions with it, through Ollama on
/// this Mac. Shared by the Search panel, `dante search` and the agents' `search_code` tool.
public struct SemanticSearch: Sendable {
    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static let suggestedModel = "qwen3-embedding:0.6b"

    public var ollama: Ollama

    public init(ollama: Ollama = Ollama()) {
        self.ollama = ollama
    }

    /// The installed embedding model, or a failure that says how to get one.
    public func model() async throws -> String {
        guard let installed = await ollama.models() else {
            throw Failure(message: "Ollama isn’t running on this Mac. Start it to search by meaning.")
        }
        guard let model = ModelRouting.embeddingModel(installed: installed) else {
            throw Failure(message: "Searching by meaning needs an embedding model in Ollama: ollama pull \(Self.suggestedModel)")
        }
        return model
    }

    /// Embeds what changed since the saved index (all of it the first time), saves and returns it.
    public func update(root: URL, files: [String]? = nil, progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil) async throws -> SemanticIndex {
        let model = try await model()
        let never = ClaudeRules.load(projectRoot: root).never
        let paths = (files ?? FileIndex.scan(root)).filter { path in !never.contains { ClaudeRules.path(path, matches: $0) } }
        let previous = SemanticIndex.load(for: root)
        let ollama = ollama
        let index = try await SemanticIndex.build(
            files: paths,
            read: { path in
                let url = root.appending(path: path)
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 512 * 1024 else { return nil }
                return try? String(contentsOf: url, encoding: .utf8)
            },
            model: model, previous: previous,
            embed: { texts in try await ollama.embed(model: model, texts: texts) },
            progress: progress,
            checkpoint: { partial in try? partial.save(for: root) })
        if index != previous { try? index.save(for: root) }
        return index
    }

    public func search(_ question: String, in index: SemanticIndex, limit: Int = 20) async throws -> [SemanticIndex.Hit] {
        let vectors = try await ollama.embed(model: index.model, texts: [SemanticIndex.queryText(question)])
        guard let vector = vectors.first else { throw Failure(message: "The embedding model returned nothing for the question.") }
        return index.search(vector, question: question, limit: limit)
    }

    /// Hits as an agent reads them: where, how close, and the lines.
    public static func report(_ hits: [SemanticIndex.Hit], root: URL, index: SemanticIndex) -> String {
        guard !hits.isEmpty else { return "Nothing in the index matches. Try grep." }
        var parts = ["\(hits.count) best of \(index.chunks.count) pieces in \(index.files) files (\(index.model)); higher scores are closer:"]
        for hit in hits {
            parts.append("\n## \(hit.chunk.location)\(hit.chunk.symbol.map { " (\($0))" } ?? "") · \(String(format: "%.2f", hit.score))\n" + excerpt(hit, root: root, maxLines: 30))
        }
        return parts.joined(separator: "\n")
    }

    /// A hit's lines as they are on disk now, numbered, for an agent or the terminal.
    public static func excerpt(_ hit: SemanticIndex.Hit, root: URL, maxLines: Int = 40) -> String {
        guard let text = try? String(contentsOf: root.appending(path: hit.chunk.path), encoding: .utf8) else { return "" }
        let lines = text.components(separatedBy: "\n")
        let start = max(hit.chunk.startLine - 1, 0)
        let end = min(hit.chunk.endLine, lines.count, start + maxLines)
        guard start < end else { return "" }
        return (start..<end).map { "\($0 + 1)\t\(lines[$0])" }.joined(separator: "\n")
            + (hit.chunk.endLine > end ? "\n…" : "")
    }
}
