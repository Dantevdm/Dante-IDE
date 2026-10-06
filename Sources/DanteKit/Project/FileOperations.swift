import Foundation

/// Creating, renaming, duplicating, moving and trashing files for the explorer. Nothing is
/// deleted outright: removal goes to the Trash. Names are checked before touching the disk,
/// so the explorer can show why a name won't do while it's being typed.
public enum FileOperations {
    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// Why a name can't be used in `folder`, or nil when it can. A new file's name may
    /// include folders (`views/Login.swift`), which are created as needed.
    public static func problem(with name: String, in folder: URL, allowsSubfolders: Bool, current: URL? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Enter a name." }
        if trimmed.hasPrefix("/") || trimmed.hasSuffix("/") { return "A name can’t start or end with /." }
        if !allowsSubfolders, trimmed.contains("/") { return "A name can’t contain /." }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        if parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) { return "That isn’t a valid name." }
        if trimmed.contains(":") { return "A name can’t contain a colon." }
        let target = folder.appending(path: trimmed)
        if FileManager.default.fileExists(atPath: target.path),
           target.standardizedFileURL.path.lowercased() != current?.standardizedFileURL.path.lowercased() {
            return "\(trimmed) already exists here."
        }
        return nil
    }

    @discardableResult
    public static func createFile(named name: String, in folder: URL) throws -> URL {
        if let problem = problem(with: name, in: folder, allowsSubfolders: true) { throw Failure(problem) }
        let url = folder.appending(path: name.trimmingCharacters(in: .whitespaces))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else { throw Failure("Couldn’t create \(name).") }
        return url
    }

    @discardableResult
    public static func createFolder(named name: String, in folder: URL) throws -> URL {
        if let problem = problem(with: name, in: folder, allowsSubfolders: true) { throw Failure(problem) }
        let url = folder.appending(path: name.trimmingCharacters(in: .whitespaces), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    public static func rename(_ url: URL, to name: String) throws -> URL {
        let folder = url.deletingLastPathComponent()
        if let problem = problem(with: name, in: folder, allowsSubfolders: false, current: url) { throw Failure(problem) }
        let destination = folder.appending(path: name.trimmingCharacters(in: .whitespaces))
        guard destination.lastPathComponent != url.lastPathComponent else { return url }
        // A change of case only: go through a temporary name, as case-insensitive volumes need.
        if destination.path.lowercased() == url.path.lowercased() {
            let step = folder.appending(path: ".\(UUID().uuidString)")
            try FileManager.default.moveItem(at: url, to: step)
            try FileManager.default.moveItem(at: step, to: destination)
        } else {
            try FileManager.default.moveItem(at: url, to: destination)
        }
        return destination
    }

    /// `name copy.ext`, then `name copy 2.ext` and so on, like Finder.
    public static func duplicateName(for url: URL, existing: (String) -> Bool) -> String {
        let ext = url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))
        var number = 1
        while true {
            let stem = number == 1 ? "\(base) copy" : "\(base) copy \(number)"
            let name = ext.isEmpty ? stem : "\(stem).\(ext)"
            if !existing(name) { return name }
            number += 1
        }
    }

    @discardableResult
    public static func duplicate(_ url: URL) throws -> URL {
        let folder = url.deletingLastPathComponent()
        let name = duplicateName(for: url) { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }
        let destination = folder.appending(path: name)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// Moves an item into another folder, keeping its name.
    @discardableResult
    public static func move(_ url: URL, into folder: URL) throws -> URL {
        let source = url.standardizedFileURL.path
        let target = folder.standardizedFileURL.path
        if target == source || target.hasPrefix(source + "/") { throw Failure("A folder can’t go inside itself.") }
        if url.deletingLastPathComponent().standardizedFileURL.path == target { return url }
        let destination = folder.appending(path: url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) { throw Failure("\(url.lastPathComponent) already exists in \(folder.lastPathComponent).") }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// Copies something dropped from outside the project into a folder, renaming on a clash.
    @discardableResult
    public static func copy(_ url: URL, into folder: URL) throws -> URL {
        var destination = folder.appending(path: url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appending(path: duplicateName(for: url) { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) })
        }
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    public static func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Where a URL ends up after `from` moves to `to`: itself, or a path inside the moved folder.
    public static func relocated(_ url: URL, from: URL, to: URL) -> URL? {
        let path = url.standardizedFileURL.path
        let old = from.standardizedFileURL.path
        if path == old { return to }
        guard path.hasPrefix(old + "/") else { return nil }
        return to.appending(path: String(path.dropFirst(old.count + 1)))
    }
}
