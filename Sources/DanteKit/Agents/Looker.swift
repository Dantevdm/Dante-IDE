import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Looker: reads screenshots, mockups, diagrams and pictures of errors with a vision model in
/// Ollama on this Mac, so Claude and Codex can ask about an image without sending it away or
/// spending their plans' usage on it. Only models that read UI reliably are used; older ones
/// (llava, granite-vision) describe things that aren't there.
public enum Looker {
    public static let agent = "Looker"
    public static let kind = "look"
    public static let suggestedModel = "qwen3-vl:8b"
    /// Images are scaled so their longer side is at most this, which the models read well.
    public static let maxSide = 1344

    /// Vision families that read text and UI well, best first.
    static let capable = ["qwen3-vl", "qwen2.5vl", "gemma3", "mistral-small3", "minicpm-v", "llama4"]
    /// Families that answer confidently about things that aren't in the image.
    static let unreliable = ["llava", "bakllava", "granite3.2-vision", "moondream", "llama3.2-vision"]

    /// The best capable vision model that fits this Mac's memory, or the chosen one.
    public static func model(installed: [OllamaModel], memory: UInt64 = ProcessInfo.processInfo.physicalMemory, chosen: String? = nil) -> String? {
        let local = installed.filter { !$0.isCloud && !$0.isEmbedding }
        if let chosen, local.contains(where: { $0.name == chosen }) { return chosen }
        // Leave room for the app, Xcode and the rest: a model over 60% of memory swaps.
        let fits = local.filter { $0.size == 0 || Double($0.size) <= Double(memory) * 0.6 }
        for family in capable {
            let matches = fits.filter { $0.name.lowercased().hasPrefix(family) }
            if let best = matches.max(by: { $0.size < $1.size }) { return best.name }
        }
        return nil
    }

    /// Why there's no model: none installed, or only ones too big or too weak.
    public static func missingReason(installed: [OllamaModel], memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> String {
        func family(_ model: OllamaModel, in families: [String]) -> Bool { families.contains { model.name.lowercased().hasPrefix($0) } }
        let local = installed.filter { !$0.isCloud }
        let tooBig = local.filter { family($0, in: capable) && Double($0.size) > Double(memory) * 0.6 }
        let weak = local.filter { family($0, in: unreliable) }
        var reason = "Looker needs a vision model that reads screens reliably: ollama pull \(suggestedModel) (about 6 GB)."
        if !tooBig.isEmpty { reason += " \(AgentDigest.list(tooBig.map(\.name))) \(tooBig.count == 1 ? "is" : "are") too big for this Mac’s memory." }
        if !weak.isEmpty { reason += " \(AgentDigest.list(weak.map(\.name))) \(weak.count == 1 ? "describes" : "describe") things that aren’t there, so Dante doesn’t use \(weak.count == 1 ? "it" : "them")." }
        return reason
    }

    static let system = """
    You read images for a software engineer: screenshots of apps and web pages, design mockups, diagrams, and pictures of errors or terminals. Describe only what is actually visible. Quote text exactly as it appears. When something is too small or blurry to read, say so instead of guessing. Answer the question directly and briefly; use a short list when there are several things.
    """

    /// The image as Ollama wants it: base64 JPEG or PNG, scaled down when it's large.
    public static func prepare(_ data: Data) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw Ollama.Failure(message: "That isn’t an image Looker can read.") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxSide, max(width, height, 1)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Ollama.Failure(message: "That isn’t an image Looker can read.")
        }
        let output = NSMutableData()
        // JPEG on white keeps screenshots small; text stays sharp at this quality.
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Ollama.Failure(message: "Couldn’t prepare the image.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Ollama.Failure(message: "Couldn’t prepare the image.") }
        return (output as Data).base64EncodedString()
    }
}

extension Ollama {
    /// Asks a vision model about images (`/api/chat` with `images`).
    public func look(model: String, images: [String], question: String, maxTokens: Int = 1024) async throws -> OllamaReply {
        var request = URLRequest(url: base.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        request.httpBody = Self.lookBody(model: model, images: images, question: question, maxTokens: maxTokens)
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure(message: "Ollama isn’t answering at \(base.host() ?? "localhost"): \(error.localizedDescription)")
        }
        return try OllamaReply.parse(data)
    }

    static func lookBody(model: String, images: [String], question: String, maxTokens: Int) -> Data {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": Looker.system],
                ["role": "user", "content": question, "images": images],
            ],
            "stream": false,
            "think": false,
            "keep_alive": "5m",
            "options": ["num_ctx": 8192, "num_predict": maxTokens, "temperature": 0.1],
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }
}
