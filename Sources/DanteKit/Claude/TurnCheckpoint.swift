import Foundation

/// What a turn's approved edits replaced: each file's text before Claude first touched it
/// in the turn (nil when Claude created it). Undoing the turn puts those back.
public struct TurnCheckpoint: Equatable, Sendable {
    public var originals: [String: String?] = [:]
    /// Commands ran too, and their effects can't be undone from here.
    public var ranCommands = false
    public var undone = false

    public init() {}

    public var files: [String] { originals.keys.sorted() }

    /// Remembers a file the first time an edit to it is approved in the turn.
    public mutating func record(_ path: String, read: (String) -> String?) {
        guard originals[path] == nil else { return }
        originals[path] = .some(read(path))
    }

    /// Restores every file and returns those it touched. `write(path, nil)` deletes.
    public mutating func undo(write: (String, String?) throws -> Void) rethrows -> [String] {
        guard !undone else { return [] }
        for path in files { try write(path, originals[path] ?? nil) }
        undone = true
        return files
    }
}
