import Foundation

/// The Language Server Protocol's wire format: JSON-RPC messages, each preceded by a
/// `Content-Length` header and a blank line.
public enum LSPFraming {
    public static func encode(_ message: JSONValue) -> Data {
        let body = Data(message.jsonLine.utf8)
        return Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }

    /// Collects bytes as they arrive and hands back whole messages.
    public struct Decoder: Sendable {
        private var buffer = Data()

        public init() {}

        public mutating func append(_ data: Data) -> [JSONValue] {
            buffer.append(data)
            var messages: [JSONValue] = []
            while let message = next() { messages.append(message) }
            return messages
        }

        private mutating func next() -> JSONValue? {
            let separator = Data("\r\n\r\n".utf8)
            guard let headerEnd = buffer.range(of: separator) else { return nil }
            let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            let length = header.split(separator: "\r\n").lazy.compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }.first
            guard let length else {
                // Not a header we understand: drop it so one bad message can't wedge the stream.
                buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
                return next()
            }
            guard buffer.distance(from: headerEnd.upperBound, to: buffer.endIndex) >= length else { return nil }
            let bodyEnd = buffer.index(headerEnd.upperBound, offsetBy: length)
            let body = buffer[headerEnd.upperBound..<bodyEnd]
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
            buffer = Data(buffer)
            return (try? JSONDecoder().decode(JSONValue.self, from: body)) ?? next()
        }
    }
}
