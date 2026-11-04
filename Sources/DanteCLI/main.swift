import DanteKit
import DanteOpen
import Foundation
import PDFKit

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

// `dante mindmap <outline|mermaid|write|new> …`: mind maps (XMind files) as outlines, for
// scripts and agents, which write an outline rather than editing the zip.
if CommandLine.arguments.dropFirst().first == "mindmap" {
    let arguments = Array(CommandLine.arguments.dropFirst(2))
    let usage = """
    dante mindmap outline <file.xmind> [--sheet 2]   the map as a markdown outline
    dante mindmap mermaid <file.xmind> [--sheet 2]   the map as a Mermaid mindmap
    dante mindmap write <file.xmind> <outline.md|->  the outline into the map (made if it's new)
    dante mindmap new <file.xmind> <central topic>   an empty map

    An outline is "# Central topic" then "-" items nested by two spaces; "##" headings make
    main branches too. Writing keeps other sheets, and the notes and styles of topics whose
    titles stay the same.
    """
    guard let command = arguments.first, !["-h", "--help", "help"].contains(command), arguments.count >= 2 else { print(usage); exit(0) }
    let here = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let target = URL(filePath: arguments[1], relativeTo: here).standardizedFileURL
    let sheet = arguments.firstIndex(of: "--sheet").flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil }.map { $0 - 1 } ?? 0
    func load() -> MindMap {
        guard let data = try? Data(contentsOf: target) else { fail("can't read \(target.lastPathComponent)") }
        do { return try MindMap.read(data) } catch { fail((error as? LocalizedError)?.errorDescription ?? "\(error)") }
    }
    func save(_ map: MindMap) {
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try map.data().write(to: target, options: .atomic)
        } catch { fail("can't write \(target.lastPathComponent): \(error.localizedDescription)") }
    }
    switch command {
    case "outline":
        let map = load()
        guard map.sheets.indices.contains(sheet) else { fail("there's no sheet \(sheet + 1); the map has \(map.sheets.count)") }
        print(map.outline(sheet: sheet), terminator: "")
    case "mermaid":
        let map = load()
        guard map.sheets.indices.contains(sheet) else { fail("there's no sheet \(sheet + 1); the map has \(map.sheets.count)") }
        print(map.mermaid(sheet: sheet), terminator: "")
    case "write":
        guard arguments.count >= 3 else { fail("write takes the map and an outline file (or - for stdin)") }
        let text: String
        if arguments[2] == "-" {
            text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        } else {
            guard let read = try? String(contentsOf: URL(filePath: arguments[2], relativeTo: here), encoding: .utf8) else { fail("can't read \(arguments[2])") }
            text = read
        }
        let outline = MindMap.fromOutline(text, title: MindMap.title(ofPath: target.path))
        let existing = FileManager.default.fileExists(atPath: target.path) ? load() : nil
        let map = existing.map { $0.replacingTree(with: outline, sheet: min(sheet, $0.sheets.count - 1)) } ?? outline
        save(map)
        let count = map.sheets[min(sheet, map.sheets.count - 1)].root.all.count
        print("Wrote \(target.lastPathComponent): \(count) topic\(count == 1 ? "" : "s")")
    case "new":
        if FileManager.default.fileExists(atPath: target.path) { fail("\(target.lastPathComponent) already exists") }
        let title = arguments.dropFirst(2).joined(separator: " ")
        save(MindMap(title: title.isEmpty ? MindMap.title(ofPath: target.path) : title))
        print("Wrote \(target.lastPathComponent)")
    default:
        fail("unknown mindmap command \(command).\n\(usage)")
    }
    exit(0)
}

// `dante pdf <info|text|comments|merge|extract|split|rotate|delete|move|protect> …`: the PDF
// view's tools for scripts and agents. Passwords come from DANTE_PDF_PASSWORD, never arguments.
if CommandLine.arguments.dropFirst().first == "pdf" {
    var arguments = Array(CommandLine.arguments.dropFirst(2))
    let usage = """
    dante pdf info <file>                          pages, title, author, encryption and what's in it
    dante pdf text <file> [--pages 1-3]            the text, page by page
    dante pdf comments <file>                      comments and their replies
    dante pdf merge <out.pdf> <a.pdf> <b.pdf>…     one PDF from several, in order
    dante pdf extract <file> --pages 2,5-7 -o <out.pdf>
    dante pdf split <file> [--every 1 | --at 4,9] [-o <folder>]
    dante pdf rotate <file> --pages 1-2 [--by 90] [-o <out.pdf>]
    dante pdf delete <file> --pages 3 [-o <out.pdf>]
    dante pdf move <file> --pages 5 --to 1 [-o <out.pdf>]
    dante pdf protect <file> [-o <out.pdf>]        sets DANTE_PDF_PASSWORD as its password

    Pages are 1-based: 1-3, 5, 8- (to the end), last. Without -o, changes are saved in place.
    An encrypted PDF opens with DANTE_PDF_PASSWORD.
    """
    func value(_ names: String...) -> String? {
        guard let index = arguments.firstIndex(where: names.contains), index + 1 < arguments.count else { return nil }
        defer { arguments.removeSubrange(index...index + 1) }
        return arguments[index + 1]
    }
    guard let command = arguments.first, !["-h", "--help", "help"].contains(command) else { print(usage); exit(0) }
    arguments.removeFirst()
    let password = ProcessInfo.processInfo.environment["DANTE_PDF_PASSWORD"]
    let here = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    func file(_ path: String) -> URL { URL(filePath: path, relativeTo: here).standardizedFileURL }
    let pagesText = value("--pages", "-p")
    let output = value("-o", "--output").map(file)
    let every = value("--every").flatMap(Int.init)
    let cuts = value("--at")
    let by = value("--by").flatMap(Int.init) ?? 90
    let destination = value("--to").flatMap(Int.init)
    do {
        if command == "merge" {
            guard arguments.count >= 3 else { fail("merge takes the output and at least two PDFs") }
            let target = file(arguments[0])
            let documents = try arguments.dropFirst().map { try PDFTools.open(file($0), password: password) }
            try PDFTools.save(PDFTools.combine(documents), to: target)
            print("Wrote \(target.lastPathComponent): \(documents.map(\.pageCount).reduce(0, +)) pages")
            exit(0)
        }
        guard let path = arguments.first else { fail("\(command) needs a PDF.\n\(usage)") }
        let source = file(path)
        let document = try PDFTools.open(source, password: password)
        let pages = { try PDFTools.pages(pagesText ?? "", count: document.pageCount) }
        func needsChanges() {
            if !document.allowsDocumentChanges { fail(PDFTools.Failure.notAllowed("changes").localizedDescription) }
        }
        switch command {
        case "info":
            print(PDFTools.info(document).summary)
        case "text":
            print(PDFTools.text(document, pages: try pages()))
        case "comments":
            let threads = PDFTools.threads(in: document)
            if threads.isEmpty { print("No comments.") }
            for thread in threads {
                print("Page \(thread.page + 1) · \(thread.author): \(thread.text)" + (thread.quote.map { "  [on “\($0)”]" } ?? ""))
                for reply in thread.replies { print("    ↳ \(reply.userName ?? "Someone"): \(reply.contents ?? "")") }
            }
        case "extract":
            guard pagesText != nil, let output else { fail("extract takes --pages and -o") }
            let chosen = try pages()
            try PDFTools.save(PDFTools.extract(document, pages: chosen), to: output)
            print("Wrote \(output.lastPathComponent): \(chosen.count) pages")
        case "split":
            let starts = try every.map { PDFTools.splitPoints(every: $0, count: document.pageCount) }
                ?? cuts.map { try PDFTools.pages($0, count: document.pageCount) } ?? PDFTools.splitPoints(every: 1, count: document.pageCount)
            let parts = PDFTools.split(document, cuttingAt: starts)
            let urls = PDFTools.partURLs(for: source, count: parts.count, in: output)
            if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
            for (part, url) in zip(parts, urls) { try PDFTools.save(part, to: url) }
            print("Wrote \(parts.count) \(parts.count == 1 ? "file" : "files"): \(urls.first!.lastPathComponent) … \(urls.last!.lastPathComponent)")
        case "rotate", "delete", "move":
            needsChanges()
            guard pagesText != nil else { fail("\(command) takes --pages") }
            let chosen = try pages()
            switch command {
            case "rotate": PDFTools.rotate(document, pages: chosen, by: by)
            case "delete":
                guard chosen.count < document.pageCount else { fail("that would delete every page") }
                PDFTools.delete(document, pages: chosen)
            default:
                guard let destination, destination >= 1, destination <= document.pageCount + 1 else { fail("move takes --to <page>") }
                PDFTools.move(document, pages: chosen, to: destination - 1)
            }
            try PDFTools.save(document, to: output ?? source, password: output == nil && document.isEncrypted ? password : nil)
            print("Saved \((output ?? source).lastPathComponent): \(document.pageCount) pages")
        case "protect":
            guard let password, !password.isEmpty else { fail("set DANTE_PDF_PASSWORD to the password") }
            try PDFTools.save(document, to: output ?? source, password: password)
            print("Protected \((output ?? source).lastPathComponent)")
        default:
            fail("no pdf command \(command).\n\(usage)")
        }
    } catch {
        fail(error.localizedDescription)
    }
    exit(0)
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
