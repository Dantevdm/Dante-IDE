import Foundation

/// A shell in a running App Platform component, as `doctl apps console` opens one: the API
/// hands out a WebSocket address (its own short-lived token in the query), keystrokes go up as
/// `{"op":"stdin","data":…}`, the size as `{"op":"resize","width":…,"height":…}`, and output
/// comes back as `{"data":…}`. Needs the `app:access_console` scope.
public enum DOConsole {
    public static func stdin(_ text: String) -> String { encode(["op": "stdin", "data": text]) }

    public static func resize(width: Int, height: Int) -> String { encode(["op": "resize", "width": width, "height": height]) }

    /// What a message from the console says to print, or nil when it carries nothing.
    public static func output(_ message: String) -> String? {
        guard let data = message.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return message.isEmpty ? nil : message }
        guard let text = json["data"] as? String, !text.isEmpty else { return nil }
        return text
    }

    /// Only DigitalOcean's own secure WebSocket addresses are opened.
    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "wss", let host = url.host?.lowercased() else { return false }
        return host == "digitalocean.com" || host.hasSuffix(".digitalocean.com") || host.hasSuffix(".ondigitalocean.app")
    }

    /// A one-use file holding the address for `dante do-console`, readable only by this user,
    /// so the token never sits on a command line or in the terminal's history.
    public static func handOver(_ url: URL, folder: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let file = folder.appending(path: "dante-console-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try Data(url.absoluteString.utf8).write(to: file)
        return file
    }

    /// Reads the address `handOver` wrote, and removes the file.
    public static func takeOver(_ file: URL) -> URL? {
        defer { try? FileManager.default.removeItem(at: file) }
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), isAllowed(url) else { return nil }
        return url
    }

    static func encode(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }
}
