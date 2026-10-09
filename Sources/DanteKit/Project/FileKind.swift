import Foundation

/// How a file opens in a tab: as text in the editor, or shown as itself.
public enum FileKind: String, Equatable, Sendable {
    case text
    case pdf
    case image
    /// Word, RTF, OpenDocument: read as text through textutil.
    case document
    /// Audio and video, played in place.
    case media
    /// Spreadsheets, slides, fonts, archives and the like: shown by Quick Look.
    case quickLook
    /// Anything else that isn't UTF-8 text.
    case binary

    public var opensAsText: Bool { self == .text }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "ico", "icns"]
    static let documentExtensions: Set<String> = ["doc", "docx", "rtf", "rtfd", "odt", "wordml", "webarchive"]
    static let mediaExtensions: Set<String> = ["mp4", "mov", "m4v", "mp3", "m4a", "wav", "aac", "aif", "aiff", "caf", "flac"]
    static let quickLookExtensions: Set<String> = [
        "xls", "xlsx", "numbers", "ods", "ppt", "pptx", "key", "odp", "pages",
        "ttf", "otf", "woff", "woff2", "zip", "usdz", "reality", "epub", "eps", "psd", "ai", "sketch",
    ]
    static let binaryExtensions: Set<String> = [
        "db", "sqlite", "sqlite3", "db-wal", "db-shm", "bin", "exe", "dll", "so", "dylib", "a", "o",
        "class", "jar", "wasm", "pyc", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar", "dmg", "iso", "pkg",
    ]

    /// From the extension alone; files with an unknown one are tried as text.
    public static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        if documentExtensions.contains(ext) { return .document }
        if mediaExtensions.contains(ext) { return .media }
        if quickLookExtensions.contains(ext) { return .quickLook }
        if binaryExtensions.contains(ext) { return .binary }
        return .text
    }

    /// A NUL byte near the start, or bytes that aren't UTF-8, mean it isn't text.
    public static func looksBinary(_ data: Data) -> Bool {
        if data.prefix(8000).contains(0) { return true }
        return String(data: data, encoding: .utf8) == nil
    }

    /// "PDF", "Image", "Word document"… for the tab's path bar.
    public var title: String {
        switch self {
        case .text: "Text"
        case .pdf: "PDF"
        case .image: "Image"
        case .document: "Document"
        case .media: "Media"
        case .quickLook: "Preview"
        case .binary: "Binary file"
        }
    }
}
