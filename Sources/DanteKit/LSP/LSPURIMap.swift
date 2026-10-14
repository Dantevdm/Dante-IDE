import Foundation

/// Rewrites a language server's messages between a remote project's mirror and its host,
/// for a server running on the host. Only URI fields (`uri`, `rootUri`, `targetUri`…),
/// `rootPath` and the file-URI keys of a workspace edit's `changes` are touched, never a
/// document's text.
public struct LSPURIMap: Sendable, Equatable {
    let localURI: String
    let remoteURI: String
    let localPath: String
    let remotePath: String

    public init(localPath: String, remotePath: String) {
        self.localPath = localPath
        self.remotePath = remotePath
        localURI = Self.uri(localPath)
        remoteURI = Self.uri(remotePath)
    }

    public init(project: RemoteProject) {
        self.init(localPath: project.mirror, remotePath: project.path)
    }

    /// The URI LSPClient would write for the folder, without a trailing slash.
    static func uri(_ path: String) -> String {
        var uri = URL(filePath: path).standardizedFileURL.absoluteString
        while uri.hasSuffix("/") { uri.removeLast() }
        return uri
    }

    /// Mirror to host, for messages going to the server.
    public func toHost(_ message: JSONValue) -> JSONValue {
        rewrite(message, uri: (localURI, remoteURI), path: (localPath, remotePath))
    }

    /// Host to mirror, for messages from the server.
    public func toMirror(_ message: JSONValue) -> JSONValue {
        rewrite(message, uri: (remoteURI, localURI), path: (remotePath, localPath))
    }

    private func rewrite(_ value: JSONValue, uri: (from: String, to: String), path: (from: String, to: String)) -> JSONValue {
        switch value {
        case .array(let items):
            return .array(items.map { rewrite($0, uri: uri, path: path) })
        case .object(let object):
            var result: [String: JSONValue] = [:]
            for (key, item) in object {
                let newKey = key.hasPrefix("file://") ? Self.replacing(prefix: uri, in: key) : key
                if case .string(let text) = item, key.lowercased().hasSuffix("uri") {
                    result[newKey] = .string(Self.replacing(prefix: uri, in: text))
                } else if case .string(let text) = item, key == "rootPath" {
                    result[newKey] = .string(Self.replacing(prefix: path, in: text))
                } else {
                    result[newKey] = rewrite(item, uri: uri, path: path)
                }
            }
            return .object(result)
        default:
            return value
        }
    }

    static func replacing(prefix: (from: String, to: String), in text: String) -> String {
        if text == prefix.from { return prefix.to }
        guard text.hasPrefix(prefix.from + "/") else { return text }
        return prefix.to + text.dropFirst(prefix.from.count)
    }
}
