import Foundation

/// A debugger that speaks the Debug Adapter Protocol, and how to start it for a file.
/// Like the other tools, Dante doesn't install these; it says how.
public struct DebugAdapter: Identifiable, Equatable, Sendable {
    public enum Transport: Equatable, Sendable {
        /// DAP messages on the adapter's stdin and stdout.
        case stdio
        /// The adapter prints the address it listens on (`DAP server listening at: 127.0.0.1:5000`),
        /// then speaks DAP over TCP; its stdout after that is the program's.
        case announcedTCP
    }

    public var id: String
    public var name: String
    public var language: String
    public var extensions: [String]
    /// The executable and the arguments that start the adapter.
    public var command: [String]
    public var transport: Transport
    /// Folders to look in besides the PATH, such as `~/go/bin`.
    public var extraFolders: [String]
    public var install: String

    public static let go = DebugAdapter(
        id: "go", name: "Delve", language: "Go", extensions: ["go"],
        command: ["dlv", "dap", "--listen", "127.0.0.1:0"], transport: .announcedTCP,
        extraFolders: ["~/go/bin"], install: "go install github.com/go-delve/delve/cmd/dlv@latest"
    )

    public static let python = DebugAdapter(
        id: "python", name: "debugpy", language: "Python", extensions: ["py"],
        command: ["python3", "-m", "debugpy.adapter"], transport: .stdio,
        extraFolders: [], install: "python3 -m pip install --user debugpy"
    )

    public static let all: [DebugAdapter] = [.go, .python]

    public static func `for`(file: String) -> DebugAdapter? {
        let ext = (file as NSString).pathExtension.lowercased()
        return all.first { $0.extensions.contains(ext) }
    }

    /// The adapter's executable, from the PATH or its usual folders.
    public func resolve(path: String, home: String = NSHomeDirectory(), isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        guard let program = command.first else { return nil }
        let folders = path.split(separator: ":").map(String.init)
            + extraFolders.map { $0.replacingOccurrences(of: "~", with: home) }
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for folder in folders {
            let candidate = (folder as NSString).appendingPathComponent(program)
            if isExecutable(candidate) { return URL(filePath: candidate) }
        }
        return nil
    }

    /// The `launch` request's arguments for debugging `file` in a project at `root`.
    /// Go debugs the file's package (its tests for a `_test.go` file); Python runs the file.
    public func launchArguments(file: String, root: String) -> JSONValue {
        switch id {
        case "go":
            let isTest = file.hasSuffix("_test.go")
            return .object([
                "request": .string("launch"),
                "mode": .string(isTest ? "test" : "debug"),
                "program": .string((file as NSString).deletingLastPathComponent),
                "cwd": .string(root),
                // The program's output comes back as `output` events rather than dlv's stdout.
                "outputMode": .string("remote"),
            ])
        default:
            return .object([
                "request": .string("launch"),
                "program": .string(file),
                "cwd": .string(root),
                "console": .string("internalConsole"),
                "justMyCode": .bool(true),
            ])
        }
    }

    /// `host` and `port` from the line an `announcedTCP` adapter prints when it's ready.
    public static func announcedAddress(in line: String) -> (host: String, port: Int)? {
        guard let range = line.range(of: "listening at: ") ?? line.range(of: "listening at ") else { return nil }
        let address = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let colon = address.lastIndex(of: ":"), let port = Int(address[address.index(after: colon)...]) else { return nil }
        let host = String(address[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return (host.isEmpty ? "127.0.0.1" : host, port)
    }
}
