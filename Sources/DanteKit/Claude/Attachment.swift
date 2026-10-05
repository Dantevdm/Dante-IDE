import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A file handed to Claude with a message. Images and PDFs go as content blocks Claude
/// reads directly; text, and documents macOS can convert (Word, RTF, HTML), go as text.
/// Anything else is passed by path, for Claude's own tools to open.
public struct Attachment: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case image(mediaType: String, base64: String)
        case pdf(base64: String)
        case text(String)
        case reference
    }

    public var url: URL
    public var kind: Kind
    /// What Dante did to make it fit, such as resizing or truncating.
    public var note: String?
    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    public init(url: URL, kind: Kind, note: String? = nil) {
        self.url = url
        self.kind = kind
        self.note = note
    }

    public enum Failure: LocalizedError, Equatable {
        case unreadable(String)
        case tooLarge(String, limit: String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let name): "Couldn’t read \(name)."
            case .tooLarge(let name, let limit): "\(name) is too large to attach (the limit is \(limit))."
            }
        }
    }

    /// Longest image side sent; Claude scales larger images down anyway.
    public static let maxImageSide = 1568
    public static let maxPDFBytes = 30 * 1024 * 1024
    public static let maxTextCharacters = 150_000
    static let directImageTypes: [String: String] = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
    /// Converted to plain text with `textutil`, which ships with macOS.
    public static let convertibleExtensions: Set<String> = ["doc", "docx", "rtf", "rtfd", "odt", "html", "htm", "webarchive", "wordml"]

    /// A short label for chips: the kind of thing Claude will see.
    public var summary: String {
        switch kind {
        case .image: "image"
        case .pdf: "PDF"
        case .text(let text): "\(text.split(separator: "\n", omittingEmptySubsequences: false).count) lines"
        case .reference: "by path"
        }
    }

    public static func load(_ url: URL) async throws -> Attachment {
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        if type?.conforms(to: .image) == true {
            return try image(url)
        }
        if type?.conforms(to: .pdf) == true || ext == "pdf" {
            let data = try read(url)
            guard data.count <= maxPDFBytes else { throw Failure.tooLarge(url.lastPathComponent, limit: "30 MB") }
            return Attachment(url: url, kind: .pdf(base64: data.base64EncodedString()))
        }
        if convertibleExtensions.contains(ext) {
            let output = await Shell.run(["textutil", "-convert", "txt", "-stdout", url.path], in: url.deletingLastPathComponent(), trimming: false)
            if output.status == 0, !output.stdout.isEmpty { return text(output.stdout, url: url, converted: true) }
            return Attachment(url: url, kind: .reference)
        }
        let data = try read(url)
        if let string = String(data: data.prefix(4_000_000), encoding: .utf8), !string.contains("\0") {
            return text(string, url: url, converted: false)
        }
        return Attachment(url: url, kind: .reference)
    }

    /// An image on the pasteboard or dragged from a browser, saved so it has a name and path.
    public static func image(data: Data, savingIn folder: URL, name: String = "Pasted image") throws -> Attachment {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")
        let url = folder.appending(path: "\(name) \(stamp).png")
        try data.write(to: url)
        return try image(url)
    }

    private static func read(_ url: URL) throws -> Data {
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(url.lastPathComponent) }
        return data
    }

    private static func text(_ string: String, url: URL, converted: Bool) -> Attachment {
        let note = converted ? "converted to text" : nil
        guard string.count > maxTextCharacters else { return Attachment(url: url, kind: .text(string), note: note) }
        return Attachment(url: url, kind: .text(String(string.prefix(maxTextCharacters))),
                          note: [note, "first \(maxTextCharacters / 1000)k characters"].compactMap { $0 }.joined(separator: ", "))
    }

    /// Sent as is when it's a format Claude reads and isn't oversized; otherwise scaled down
    /// and re-encoded (PNG when it has transparency, JPEG when it doesn't).
    private static func image(_ url: URL) throws -> Attachment {
        let data = try read(url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw Failure.unreadable(url.lastPathComponent) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let ext = url.pathExtension.lowercased()
        if let mediaType = directImageTypes[ext], max(width, height) <= maxImageSide, data.count <= 3_500_000 {
            return Attachment(url: url, kind: .image(mediaType: mediaType, base64: data.base64EncodedString()))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImageSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        let alpha = image.alphaInfo
        let opaque = alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast
        let type = opaque ? UTType.jpeg : UTType.png
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable(url.lastPathComponent) }
        let resized = max(width, height) > maxImageSide ? "resized to \(image.width)×\(image.height)" : "converted to \(opaque ? "JPEG" : "PNG")"
        return Attachment(url: url, kind: .image(mediaType: opaque ? "image/jpeg" : "image/png", base64: (output as Data).base64EncodedString()), note: resized)
    }

    /// The content block for a stream-json user message.
    public var contentBlock: JSONValue {
        switch kind {
        case .image(let mediaType, let base64):
            ["type": "image", "source": ["type": "base64", "media_type": .string(mediaType), "data": .string(base64)]]
        case .pdf(let base64):
            ["type": "document", "title": .string(name), "source": ["type": "base64", "media_type": "application/pdf", "data": .string(base64)]]
        case .text(let text):
            ["type": "text", "text": .string("<attachment name=\"\(name)\"\(note.map { " note=\"\($0)\"" } ?? "")>\n\(text)\n</attachment>")]
        case .reference:
            ["type": "text", "text": .string("<attachment name=\"\(name)\" path=\"\(url.path)\">Dante can’t convert this kind of file; open it from that path with your tools if you need its contents.</attachment>")]
        }
    }
}
