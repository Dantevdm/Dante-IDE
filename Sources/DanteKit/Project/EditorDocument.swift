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
    public let url: URL
    public let language: Language
    public private(set) var isDirty = false

    /// The current text. Set on every edit; marks the document dirty.
    public var text: String {
        didSet { if text != oldValue { isDirty = true } }
    }

    public var name: String { url.lastPathComponent }

    public init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maxBytes else { throw DocumentError.tooLarge(url, data.count) }
        guard let text = String(data: data, encoding: .utf8) else { throw DocumentError.notText(url) }
        self.url = url
        self.language = Language(url: url)
        self.text = text
    }

    public func save() throws {
        try Data(text.utf8).write(to: url, options: .atomic)
        isDirty = false
    }
}
