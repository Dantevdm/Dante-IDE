import DanteKit
import DanteOpen
import Foundation

// `dante`: opens folders and files in Dante from the terminal. It lives in Dante.app at
// Contents/Resources/bin/dante and hands a dante://open URL to the app it's inside.

// `dante mcp` writes prompts to Claude Code and Codex; one that exits early must not kill it.
signal(SIGPIPE, SIG_IGN)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("dante: \(message)\n".utf8))
    exit(1)
}

/// The app this command is inside (following the symlink on the PATH), else the installed one.
func danteApp() -> URL? {
    if let path = Bundle.main.executablePath {
        let app = URL(filePath: path).resolvingSymlinksInPath()
            .deletingLastPathComponent() // bin
            .deletingLastPathComponent() // Resources
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent()
        if app.pathExtension == "app" { return app }
    }
    let found = Process()
    found.executableURL = URL(filePath: "/usr/bin/mdfind")
    found.arguments = ["kMDItemCFBundleIdentifier == 'dev.dante.ide'"]
    let pipe = Pipe()
    found.standardOutput = pipe
    try? found.run()
    found.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return output.split(separator: "\n").first.map { URL(filePath: String($0)) }
}

/// Runs the main run loop for good. Main-actor work still runs: the main run loop drains the
/// main queue.
func runMainLoop() -> Never {
    CFRunLoopRun()
    exit(0)
}

// `dante mcp`: the MCP server Claude Code starts so it can delegate jobs to local models.
if CommandLine.arguments.dropFirst().first == "mcp" {
    let project = ProcessInfo.processInfo.environment[DelegateEnvironment.project]
        ?? URL(filePath: FileManager.default.currentDirectoryPath).lastPathComponent
    let server = DelegateServer.live(project: project)
    // The agents' browser (WebKit) needs the main run loop, so stdin is read off the main thread.
    Task.detached {
        await server.serve()
        exit(0)
    }
    runMainLoop()
}

// `dante scan [folder] [--json] [--online] [--all] [--fail-on high]`: the Security area's scan,
// for a terminal or CI. Exits 2 when a graded finding (not one in tests, docs or examples) is at
// least as bad as --fail-on; --all lists those too.
if CommandLine.arguments.dropFirst().first == "scan" {
    var arguments = Array(CommandLine.arguments.dropFirst(2))
    func flag(_ name: String) -> Bool {
        guard let index = arguments.firstIndex(of: name) else { return false }
        arguments.remove(at: index)
        return true
    }
    func value(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        defer { arguments.removeSubrange(index...index + 1) }
        return arguments[index + 1]
    }
    let json = flag("--json")
    let online = flag("--online")
    let noTools = flag("--no-tools")
    let all = flag("--all")
    let threshold = value("--fail-on").map { SecurityFinding.Severity(rawValue: $0.lowercased()) }
    if case .some(nil) = threshold { fail("--fail-on takes critical, high, medium, low or info") }
    let root = URL(filePath: arguments.first ?? ".", directoryHint: .isDirectory,
                   relativeTo: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)).standardizedFileURL
    guard FileManager.default.fileExists(atPath: root.path) else { fail("no folder at \(root.path)") }
    let report = await ProjectSecurity.scan(root: root, options: .init(externalTools: !noTools, onlineAdvisories: online, save: false))
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: (try? encoder.encode(report)) ?? Data(), as: UTF8.self))
    } else {
        print(ProjectSecurity.summary(report, root: root, all: all))
    }
    if let threshold = threshold ?? nil, report.findings.contains(where: { $0.severity >= threshold }) { exit(2) }
    exit(0)
}

// `dante search <question> [--in folder] [--limit n]`: search the project by meaning with an
// embedding model in Ollama, updating the index first (only changed code is embedded again).
if CommandLine.arguments.dropFirst().first == "search" {
    var arguments = Array(CommandLine.arguments.dropFirst(2))
    func value(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        defer { arguments.removeSubrange(index...index + 1) }
        return arguments[index + 1]
    }
    let folder = value("--in")
    let limit = value("--limit").flatMap(Int.init) ?? 8
    let question = arguments.joined(separator: " ")
    guard !question.isEmpty else { fail("usage: dante search <question> [--in folder] [--limit n]") }
    let root = URL(filePath: folder ?? ".", directoryHint: .isDirectory,
                   relativeTo: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)).standardizedFileURL
    let search = SemanticSearch()
    do {
        let started = Date()
        let index = try await search.update(root: root) { done, total in
            if total > 0 { FileHandle.standardError.write(Data("\rIndexing \(done)/\(total) pieces".utf8)) }
        }
        let indexed = Date().timeIntervalSince(started)
        let hits = try await search.search(question, in: index, limit: limit)
        FileHandle.standardError.write(Data("\r\(index.chunks.count) pieces in \(index.files) files · \(index.model) · \(String(format: "%.1f", indexed)) s to update, \(String(format: "%.1f", Date().timeIntervalSince(started) - indexed)) s to search\n".utf8))
        for hit in hits {
            print("\(String(format: "%.2f", hit.score))  \(hit.chunk.location)\(hit.chunk.symbol.map { "  \($0)" } ?? "")")
        }
    } catch {
        fail(error.localizedDescription)
    }
    exit(0)
}

/// Hands a dante:// URL to the app this command belongs to.
func send(_ url: URL, background: Bool = false) -> Never {
    guard let app = danteApp() else { fail("can't find Dante.app") }
    let open = Process()
    open.executableURL = URL(filePath: "/usr/bin/open")
    open.arguments = (background ? ["-g"] : []) + ["-a", app.path, url.absoluteString]
    do {
        try open.run()
        open.waitUntilExit()
    } catch {
        fail("couldn't open Dante: \(error.localizedDescription)")
    }
    exit(open.terminationStatus)
}

// `dante job <what to do> [--in folder] [--away minutes] [--codex]`: hands a job to an agent
// that works on its own branch in its own worktree, without bringing Dante forward.
if CommandLine.arguments.dropFirst().first == "job" {
    let arguments = Array(CommandLine.arguments.dropFirst(2))
    if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
        print(JobRequest.usage)
        exit(0)
    }
    do {
        var request = try JobRequest.parse(arguments: arguments, in: FileManager.default.currentDirectoryPath) { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        // Proves the job came from this Mac's user, so Dante starts it without asking.
        request.key = JobRequest.localKey()
        print("Handed to Dante: \(request.brief)\(request.awayMinutes.map { " (away for \($0) min)" } ?? "")")
        send(request.url, background: true)
    } catch {
        fail("\(error)")
    }
}

let command: OpenRequest.Command
do {
    command = try OpenRequest.parse(
        arguments: Array(CommandLine.arguments.dropFirst()),
        in: FileManager.default.currentDirectoryPath,
        exists: { FileManager.default.fileExists(atPath: $0) }
    )
} catch {
    fail("\(error)")
}

switch command {
case .help:
    print(OpenRequest.usage)
case .version:
    let info = danteApp().flatMap { Bundle(url: $0)?.infoDictionary }
    print("Dante \(info?["CFBundleShortVersionString"] as? String ?? "(not found)")")
case .open(var request):
    request.key = JobRequest.localKey()
    send(request.url)
}
