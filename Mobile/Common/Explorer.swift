import CryptoKit
import Foundation
import Observation

/// Reading a project from the phone: libraries and pages come from the Mac, drawn for this
/// screen, and are kept on the phone so nothing is sent twice. A page shows from the cache at
/// once (offline too), then the Mac is asked whether it changed: it answers `unchanged` or
/// sends the new one.
@MainActor @Observable
final class Explorer {
    enum Listing: Equatable {
        case loading
        case loaded(CompanionLibrary)
        case failed(String)
    }

    let connection: CompanionConnection
    private(set) var libraries: [String: Listing] = [:]
    @ObservationIgnored private let cache = PageCache()

    init(connection: CompanionConnection) {
        self.connection = connection
    }

    /// Open projects first, then the Mac's recent ones.
    var projects: [(id: String, name: String, isOpen: Bool)] {
        guard let snapshot = connection.snapshot else { return [] }
        return snapshot.projects.map { ($0.id, $0.name, true) } + (snapshot.recent ?? []).map { ($0.id, $0.name, false) }
    }

    func listing(of project: String) -> Listing { libraries[project] ?? .loading }

    func loadLibrary(_ project: String) async {
        if libraries[project] == nil, let saved: CompanionLibrary = cache.read(key: "library|" + project) { libraries[project] = .loaded(saved) }
        switch await connection.library(of: project) {
        case .success(let library):
            libraries[project] = .loaded(library)
            cache.write(library, key: "library|" + project)
        case .failure(let failure):
            if case .loaded = libraries[project] { return }
            libraries[project] = .failed(failure.message)
        }
    }

    /// Shows the kept copy through `show` straight away, then the Mac's when it differs.
    /// Returns why the Mac couldn't be asked, when it couldn't and nothing was kept.
    func fetch(_ request: CompanionPageRequest, project: String, show: (CompanionPage) -> Void) async -> String? {
        var request = request
        let key = project + "|" + request.cacheKey
        let kept: CompanionPage? = cache.read(key: key)
        if let kept { show(kept) }
        request.known = kept?.hash
        switch await connection.page(request, project: project) {
        case .success(let page):
            guard !page.unchanged else { return nil }
            show(page)
            if page.problem == nil { cache.write(page, key: key) }
            return nil
        case .failure(let failure):
            return kept == nil ? failure.message : nil
        }
    }

    /// A copy of this page is on the device, so showing it costs next to nothing.
    func isKept(_ request: CompanionPageRequest, project: String) -> Bool {
        let kept: CompanionPage? = cache.read(key: project + "|" + request.cacheKey)
        return kept != nil
    }

    func clearCache() { cache.clear() }
    var cacheSize: Int { cache.size }
}

/// Pages on disk in Caches (iOS may clear it), named by a hash of the project and request,
/// trimmed to the newest 300 MB.
final class PageCache: @unchecked Sendable {
    private let folder: URL
    private static let limit = 300 << 20

    init() {
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "DantePages")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func file(_ key: String) -> URL {
        folder.appending(path: SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
    }

    func read<T: Decodable>(key: String) -> T? {
        let url = file(key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Touched, so trimming keeps what's read.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return CompanionCoding.decode(T.self, from: data)
    }

    func write<T: Encodable>(_ value: T, key: String) {
        try? CompanionCoding.encode(value).write(to: file(key), options: .atomic)
        trim()
    }

    var size: Int { entries().reduce(0) { $0 + $1.size } }

    func clear() {
        for entry in entries() { try? FileManager.default.removeItem(at: entry.url) }
    }

    private func entries() -> [(url: URL, size: Int, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
        }
    }

    private func trim() {
        var all = entries().sorted { $0.date > $1.date }
        var total = all.reduce(0) { $0 + $1.size }
        while total > Self.limit, let oldest = all.popLast() {
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
        }
    }
}
