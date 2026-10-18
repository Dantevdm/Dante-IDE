import DanteKit
import DanteOpen
import Foundation
import Testing

struct OpenRequestTests {
    let existing: Set<String> = ["/home/me/shop", "/home/me/shop/api/main.go", "/home/me/shop/web/app.ts", "/home/me/notes.md", "/home/me/a b/c:d.txt"]

    func parse(_ arguments: [String], in directory: String = "/home/me/shop") throws -> OpenRequest.Command {
        try OpenRequest.parse(arguments: arguments, in: directory, exists: existing.contains)
    }

    @Test func noPathsOpensTheCurrentFolder() throws {
        #expect(try parse([]) == .open(OpenRequest(items: [.init(path: "/home/me/shop")])))
    }

    @Test func relativePathsLinesAndOptions() throws {
        let command = try parse(["-n", ".", "api/main.go:42", "web/app.ts:7:3", "../notes.md"])
        #expect(command == .open(OpenRequest(items: [
            .init(path: "/home/me/shop"),
            .init(path: "/home/me/shop/api/main.go", line: 42),
            .init(path: "/home/me/shop/web/app.ts", line: 7),
            .init(path: "/home/me/notes.md"),
        ], newWindow: true)))
        #expect(try parse(["--help"]) == .help)
        #expect(try parse(["-v"]) == .version)
    }

    @Test func aColonInARealNameIsKeptAndMissingPathsAreRefused() throws {
        #expect(try parse(["c:d.txt"], in: "/home/me/a b") == .open(OpenRequest(items: [.init(path: "/home/me/a b/c:d.txt")])))
        #expect(throws: OpenRequest.ArgumentError.self) { try parse(["missing.go"]) }
        #expect(throws: OpenRequest.ArgumentError.self) { try parse(["api/main.go:x"]) }
        #expect(throws: OpenRequest.ArgumentError.self) { try parse(["--frobnicate"]) }
    }

    @Test func urlRoundTripsWithSpacesAndLines() throws {
        let request = OpenRequest(items: [.init(path: "/home/me/a b"), .init(path: "/home/me/a b/c&d=e.go", line: 3)], newWindow: true)
        #expect(request.url.absoluteString.hasPrefix("dante://open?path="))
        #expect(OpenRequest(url: request.url) == request)
        #expect(OpenRequest(url: URL(filePath: "/home/me/shop")) == OpenRequest(items: [.init(path: "/home/me/shop")]))
        #expect(OpenRequest(url: URL(string: "dante://open?path=relative")!) == nil)
        #expect(OpenRequest(url: URL(string: "https://example.com")!) == nil)
    }

    @Test func filesGoToTheirFolderAnOpenProjectOrTheirOwnProject() {
        let request = OpenRequest(items: [
            .init(path: "/home/me/shop/api/main.go", line: 4),
            .init(path: "/home/me/shop"),
            .init(path: "/home/me/blog/post.md"),
            .init(path: "/home/me/notes.md"),
            .init(path: "/home/me/shop"),
        ])
        let folders: Set<String> = ["/home/me/shop", "/home/me/blog"]
        let targets = OpenTarget.plan(
            request,
            openFolders: ["/home/me/blog", "/home/me"],
            isDirectory: folders.contains,
            projectRoot: { ($0 as NSString).deletingLastPathComponent }
        )
        #expect(targets == [
            OpenTarget(folder: "/home/me/shop", files: [.init(path: "/home/me/shop/api/main.go", line: 4)]),
            OpenTarget(folder: "/home/me/blog", files: [.init(path: "/home/me/blog/post.md")], named: false),
            OpenTarget(folder: "/home/me", files: [.init(path: "/home/me/notes.md")], named: false),
        ])
    }

    @Test func projectRootIsTheNearestRepository() {
        let markers: Set<String> = ["/home/me/shop/.git", "/home/me/.dante"]
        #expect(OpenTarget.projectRoot(of: "/home/me/shop/api/v1/main.go", home: "/home/me", exists: markers.contains) == "/home/me/shop")
        // The home folder never counts, even with .dante in it.
        #expect(OpenTarget.projectRoot(of: "/home/me/scratch/x.py", home: "/home/me", exists: markers.contains) == "/home/me/scratch")
        #expect(!OpenTarget.contains("/home/me/shop", "/home/me/shopping/a.go"))
    }
}

struct CommandLineToolTests {
    @Test func linksIntoAWritableFolderOnThePathElseUsesSudo() {
        let source = "/Applications/Dante.app/Contents/Resources/bin/dante"
        #expect(CommandLineTool.installCommand(source: source, path: "/usr/bin:/opt/homebrew/bin:/home/me/.local/bin", home: "/home/me", isWritable: { _ in true })
            == "ln -sf /Applications/Dante.app/Contents/Resources/bin/dante /opt/homebrew/bin/dante")
        #expect(CommandLineTool.installCommand(source: "/a b/Dante.app/bin/dante", path: "/usr/bin:/home/me/.local/bin/", home: "/home/me", isWritable: { $0.hasPrefix("/home") })
            == "ln -sf '/a b/Dante.app/bin/dante' /home/me/.local/bin/dante")
        #expect(CommandLineTool.installCommand(source: source, path: "/usr/bin:/bin", home: "/home/me", isWritable: { _ in true })
            .hasPrefix("sudo mkdir -p /usr/local/bin && sudo ln -sf"))
    }

    @Test func stateComparesWhereTheLinkLeads() {
        let bundled = "/Applications/Dante.app/Contents/Resources/bin/dante"
        #expect(CommandLineTool.state(found: nil, resolved: nil, bundled: bundled) == .notInstalled)
        #expect(CommandLineTool.state(found: "/usr/local/bin/dante", resolved: bundled, bundled: bundled) == .installed("/usr/local/bin/dante"))
        #expect(CommandLineTool.state(found: "/usr/local/bin/dante", resolved: "/old/Dante.app/Contents/Resources/bin/dante", bundled: bundled) == .elsewhere("/usr/local/bin/dante"))
    }
}

@Suite struct JobRequestTests {
    private let folders: Set<String> = ["/home/me/shop", "/home/me/other"]

    @Test func readsTheCommandLine() throws {
        let request = try JobRequest.parse(arguments: ["Fix", "the", "login", "redirect", "--away", "30", "--codex"], in: "/home/me/shop") { folders.contains($0) }
        #expect(request == JobRequest(folder: "/home/me/shop", brief: "Fix the login redirect", awayMinutes: 30, agent: "codex"))
        let elsewhere = try JobRequest.parse(arguments: ["--in", "../other", "Add tests"], in: "/home/me/shop") { folders.contains($0) }
        #expect(elsewhere.folder == "/home/me/other" && elsewhere.awayMinutes == nil && elsewhere.agent == nil)
    }

    @Test func refusesWhatItCantDo() {
        #expect(throws: OpenRequest.ArgumentError.self) { try JobRequest.parse(arguments: [], in: "/home/me/shop") { folders.contains($0) } }
        #expect(throws: OpenRequest.ArgumentError.self) { try JobRequest.parse(arguments: ["x", "--away", "soon"], in: "/home/me/shop") { folders.contains($0) } }
        #expect(throws: OpenRequest.ArgumentError.self) { try JobRequest.parse(arguments: ["x", "--in", "/home/me/missing"], in: "/home/me/shop") { folders.contains($0) } }
        #expect(throws: OpenRequest.ArgumentError.self) { try JobRequest.parse(arguments: ["x", "--fast"], in: "/home/me/shop") { folders.contains($0) } }
    }

    @Test func roundTripsThroughItsURL() throws {
        let request = JobRequest(folder: "/home/me/shop", brief: "Fix it & ship? 100% = done", awayMinutes: 60, agent: "claude")
        #expect(request.url.absoluteString.hasPrefix("dante://job?"))
        #expect(JobRequest(url: request.url) == request)
        #expect(OpenRequest(url: request.url) == nil)
        // Nonsense in a URL from elsewhere is dropped, not trusted.
        let odd = URL(string: "dante://job?path=/home/me/shop&brief=x&away=-5&agent=someone")!
        #expect(JobRequest(url: odd) == JobRequest(folder: "/home/me/shop", brief: "x"))
        #expect(JobRequest(url: URL(string: "dante://job?path=relative&brief=x")!) == nil)
        #expect(JobRequest(url: URL(string: "dante://job?path=/home/me/shop&brief=%20")!) == nil)
    }

    @Test func trustsOnlyThisMacsKey() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "job-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(JobRequest.localKey(in: folder, create: false) == nil)
        let key = try #require(JobRequest.localKey(in: folder))
        #expect(key.count == 64)
        #expect(JobRequest.localKey(in: folder) == key)
        let mode = try FileManager.default.attributesOfItem(atPath: folder.appending(path: "cli-key").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        let signed = JobRequest(folder: "/home/me/shop", brief: "x", awayMinutes: 30, key: key)
        let read = try #require(JobRequest(url: signed.url))
        #expect(read.isTrusted(by: key))
        #expect(!read.isTrusted(by: nil))
        #expect(!JobRequest(folder: "/home/me/shop", brief: "x").isTrusted(by: key))
        #expect(!JobRequest(folder: "/home/me/shop", brief: "x", key: "guess").isTrusted(by: key))
    }
}
