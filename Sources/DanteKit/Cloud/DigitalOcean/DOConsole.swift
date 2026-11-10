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
    /// so the token never sits on a command line or in the terminal's history. `run`, when
    /// given, is typed into the shell once it answers (Deploy's Getting in steps).
    public static func handOver(_ url: URL, run: String? = nil, folder: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let file = folder.appending(path: "dante-console-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let command = run?.replacingOccurrences(of: "\n", with: " ") ?? ""
        try Data((url.absoluteString + (command.isEmpty ? "" : "\n" + command)).utf8).write(to: file)
        return file
    }

    /// Reads the address (and the command to type) `handOver` wrote, and removes the file.
    public static func takeOver(_ file: URL) -> (url: URL, run: String?)? {
        defer { try? FileManager.default.removeItem(at: file) }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = lines.first, let url = URL(string: first.trimmingCharacters(in: .whitespacesAndNewlines)), isAllowed(url) else { return nil }
        let run = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (url, run.isEmpty ? nil : run)
    }

    static func encode(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }
}
