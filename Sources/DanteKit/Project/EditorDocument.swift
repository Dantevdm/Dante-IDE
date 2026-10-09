import Foundation
import Observation

public enum DocumentError: LocalizedError {
    case notText(URL)
    case tooLarge(URL, Int)

    public var errorDescription: String? {
        switch self {
        case .notText(let url): "\(url.lastPathComponent) isn’t a text file."
        case .tooLarge(let url, let bytes): "\(url.lastPathComponent) is \(bytes / 1_048_576) MB, too large to open in the editor."
        }
    }
}

/// A file open in an editor tab.
@MainActor
@Observable
public final class EditorDocument: Identifiable {
    public static let maxBytes = 20 * 1_048_576

    public let id = UUID()
    public private(set) var url: URL
    public private(set) var language: Language
    public private(set) var isDirty = false
    /// Text in the editor, or a file shown as itself (PDF, image, binary). Only text saves.
    public private(set) var kind: FileKind
    /// Bumped when a file shown as itself changes on disk, so its viewer reloads.
    public private(set) var diskVersion = 0

    /// The current text. Set on every edit; dirty while it differs from the file as last
    /// read or saved, so undoing back to it clears the mark.
    public var text: String {
        didSet { if text != oldValue { isDirty = text.utf8.count != savedText.utf8.count || text != savedText } }
    }
    private var savedText: String

    public var name: String { url.lastPathComponent }

    /// A range for the editor to select and scroll to, such as a jump to a definition.
    /// The editor clears it once shown.
    public var revealRange: NSRange?

    public init(url: URL) throws {
        self.url = url
        self.language = Language(url: url)
        var kind = FileKind.of(url)
        var text = ""
        if kind.opensAsText {
            do {
                text = try Self.read(url)
            } catch DocumentError.notText, DocumentError.tooLarge {
                kind = .binary
            }
        }
        self.kind = kind
        self.text = text
        savedText = text
    }

    private static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard data.count <= maxBytes else { throw DocumentError.tooLarge(url, data.count) }
        guard !FileKind.looksBinary(data), let text = String(data: data, encoding: .utf8) else { throw DocumentError.notText(url) }
        return text
    }

    /// Replaces the text with the file's current contents and clears the dirty flag.
    public func reloadFromDisk() throws {
        guard kind.opensAsText else { return diskVersion += 1 }
        let current = try Self.read(url)
        savedText = current
        if current != text { text = current }
        isDirty = false
    }

    /// The file was renamed or moved: keep the tab and its edits, at the new path.
    public func relocate(to url: URL) {
        self.url = url
        language = Language(url: url)
    }

    public func save() throws {
        // A viewer's text is empty, not the file: writing it would wipe the file.
        guard kind.opensAsText else { return }
        try Data(text.utf8).write(to: url, options: .atomic)
        savedText = text
        isDirty = false
    }
}
