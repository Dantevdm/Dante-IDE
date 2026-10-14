@testable import DanteKit
import Foundation
import Testing

struct RemoteProjectTests {
    let project = RemoteProject(host: "devbox", path: "/srv/shop/", mirror: "/home/me/Mirror/shop")

    @Test func mapsPathsBetweenTheHostAndTheMirror() {
        #expect(project.path == "/srv/shop")
        #expect(project.remotePath(forLocal: "/home/me/Mirror/shop/api/main.go") == "/srv/shop/api/main.go")
        #expect(project.remotePath(forLocal: "/home/me/Mirror/shop") == "/srv/shop")
        #expect(project.remotePath(forLocal: "/home/me/Mirror/shopping/x") == nil)
        #expect(project.localPath(forRemote: "/srv/shop/web/app.ts") == "/home/me/Mirror/shop/web/app.ts")
        #expect(project.localPath(forRemote: "/etc/hosts") == nil)
    }

    @Test func namesTheMirrorAfterTheProject() {
        let base = URL(filePath: "/home/me/Mirrors")
        let a = RemoteProject.mirrorFolder(host: "me@box.example.com", path: "/srv/app", in: base)
        let b = RemoteProject.mirrorFolder(host: "me@box.example.com", path: "/home/me/app/", in: base)
        #expect(a.lastPathComponent == "app" && b.lastPathComponent == "app" && a != b)
        #expect(a.path.hasPrefix("/home/me/Mirrors/me_box.example.com/"))
        #expect(a == RemoteProject.mirrorFolder(host: "me@box.example.com", path: "/srv/app", in: base))
    }

    @Test func buildsTheHostsCommandLine() {
        let command = SSH.remoteCommand(["git", "commit", "-m", "it's done"], in: "/srv/my shop", environment: ["NO_COLOR": "1"])
        #expect(command == #"exec "$SHELL" -lc 'cd '\''/srv/my shop'\'' && exec env NO_COLOR=1 git commit -m '\''it'\''\'\'''\''s done'\'''"#)
        let arguments = SSH.arguments(host: "devbox", command: "true")
        #expect(arguments.contains("BatchMode=yes") && arguments.contains("ControlMaster=no") && arguments.suffix(2) == ["devbox", "true"])
        #expect(SSH.options(master: true).contains("-N"))
    }

    @Test func readsHostAliasesFromSSHConfig() {
        let config = """
            Host devbox build-*
              HostName 10.0.0.4
            Host=staging prod
            # Host commented
            Host *
              ServerAliveInterval 30
            Match host foo
            """
        #expect(SSHConfig.hosts(in: config) == ["devbox", "staging", "prod"])
    }

    @Test func readsDeletionsAndKeepsPathsInsideTheProject() {
        let itemized = "*deleting old/z.txt\n*deleting old/\n>f+++++++ x.txt\ncd+++++++ .git/\n*deleting gone.txt\n"
        #expect(RemoteSync.deletions(in: itemized) == ["old/z.txt", "old/", "gone.txt"])
        #expect(RemoteSync.isSafeRelative("a/b.txt") && !RemoteSync.isSafeRelative("../etc") && !RemoteSync.isSafeRelative("/etc"))
        #expect(RemoteSync.deletionLimit(snapshotCount: 40) == 50 && RemoteSync.deletionLimit(snapshotCount: 4_000) == 1_000)
    }

    @Test func removesHereOnlyWhatsUnchangedSinceTheLastSync() {
        let snapshot: [String: Double] = ["a.txt": 10, "b.txt": 10, "old/": 0]
        let now: [String: Double] = ["a.txt": 10, "b.txt": 12, "new.txt": 13, "old/": 0]
        let deleted: Set<String> = ["a.txt", "b.txt", "new.txt", "old/"]
        #expect(RemoteSync.removable(deleted, before: now, snapshot: snapshot) == ["a.txt", "old/"])
        #expect(RemoteSync.removable(deleted, before: now, snapshot: nil) == deleted)
        #expect(RemoteSync.changed(now, since: snapshot) == ["b.txt", "new.txt"])
        #expect(RemoteSync.changed(now, since: nil).isEmpty)
    }

    @Test func syncsOnlyHEADFromGitAndSkipsDependencies() {
        let pull = RemoteSync.filters(.pull)
        #expect(pull.prefix(3) == ["--include=/.git/", "--include=/.git/HEAD", "--exclude=/.git/*"])
        #expect(RemoteSync.filters(.push).first == "--exclude=/.git/")
        #expect(pull.contains("--exclude=node_modules/") && !pull.contains("--exclude=coverage/"))
        let arguments = RemoteSync.rsyncArguments(for: project, direction: .push)
        #expect(arguments.suffix(2) == ["/home/me/Mirror/shop/", "devbox:/srv/shop/"])
    }

    @Test func sendsEnvironmentOnStdinNotTheCommandLine() throws {
        let (arguments, input) = Shell.readingEnvironment(["psql", "-c", "select 1"], ["PGPASSWORD": "pa ss'word", "PGAPPNAME": "Dante", "BAD NAME": "x"])
        #expect(arguments == ["sh", "-c", #"IFS= read -r PGAPPNAME; export PGAPPNAME; IFS= read -r PGPASSWORD; export PGPASSWORD; exec "$@""#, "sh", "psql", "-c", "select 1"])
        #expect(input.map { String(decoding: $0, as: UTF8.self) } == "Dante\npa ss'word\n")
        #expect(Shell.readingEnvironment(["ls"], [:]).input == nil)
        #expect(SSH.forwardSpec(5432) == "127.0.0.1:5432:localhost:5432")
    }

    @Test func explainsFailures() {
        let denied = Shell.Output(status: 255, stdout: "", stderr: "me@devbox: Permission denied (publickey).")
        #expect(RemoteSync.explain(denied, host: "devbox").contains("ssh key"))
        let unknown = Shell.Output(status: 255, stdout: "", stderr: "ssh: Could not resolve hostname nobox: nodename nor servname provided")
        #expect(RemoteSync.explain(unknown, host: "nobox").hasPrefix("There’s no host called nobox"))
    }
}

/// Syncs a "host" folder on this Mac through an ssh stand-in that runs commands locally.
@MainActor
@Suite(.serialized)
struct RemoteSyncTests {
    let base: URL
    let host: URL
    let project: RemoteProject

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "dante-remote-\(UUID().uuidString)").resolvingSymlinksInPath()
        host = base.appending(path: "host/shop")
        try FileManager.default.createDirectory(at: host.appending(path: ".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: host.appending(path: "node_modules/left-pad"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: host.appending(path: ".git/HEAD"), atomically: true, encoding: .utf8)
        try "[core]\n".write(to: host.appending(path: ".git/config"), atomically: true, encoding: .utf8)
        try "module.exports = 1\n".write(to: host.appending(path: "node_modules/left-pad/index.js"), atomically: true, encoding: .utf8)
        try Self.write("package main\n", to: host.appending(path: "main.go"))
        try Self.write("old\n", to: host.appending(path: "docs/old.md"))

        let ssh = base.appending(path: "fake-ssh")
        try Self.fakeSSH.write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
        setenv("DANTE_SSH", ssh.path, 1)
        project = RemoteProject(host: "devbox", path: host.path, mirror: base.appending(path: "mirror/shop").path)
    }

    /// Skips ssh's options and the host, then runs the command here.
    static let fakeSSH = """
        #!/bin/sh
        while [ $# -gt 0 ]; do
          case "$1" in
            -O) exit 0 ;;
            -o|-p|-i|-l|-F) shift 2 ;;
            -*) shift ;;
            *) break ;;
          esac
        done
        shift
        [ $# -eq 0 ] && exit 0
        exec sh -c "$*"

        """

    static func write(_ text: String, to url: URL, age: TimeInterval = 0) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test func copiesThenKeepsBothSidesInStep() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let mirror = project.mirrorURL
        let sync = RemoteSync(project: project)
        try await sync.pullAll()
        #expect(read(mirror.appending(path: "main.go")) == "package main\n")
        #expect(read(mirror.appending(path: ".git/HEAD")) == "ref: refs/heads/main\n")
        #expect(!FileManager.default.fileExists(atPath: mirror.appending(path: ".git/config").path))
        #expect(!FileManager.default.fileExists(atPath: mirror.appending(path: "node_modules").path))

        // Changed there: an edit, a new file and a deletion come across.
        try Self.write("package main\n\nfunc main() {}\n", to: host.appending(path: "main.go"))
        try Self.write("# API\n", to: host.appending(path: "docs/api.md"))
        try FileManager.default.removeItem(at: host.appending(path: "docs/old.md"))
        await sync.sync()
        #expect(sync.state == .idle)
        #expect(read(mirror.appending(path: "main.go"))?.contains("func main") == true)
        #expect(read(mirror.appending(path: "docs/api.md")) == "# API\n")
        #expect(!FileManager.default.fileExists(atPath: mirror.appending(path: "docs/old.md").path))

        // Changed here: an edit, a new file and a deletion go across.
        try Self.write("package main // edited here\n", to: mirror.appending(path: "main.go"))
        try Self.write("notes\n", to: mirror.appending(path: "NOTES.md"))
        try FileManager.default.removeItem(at: mirror.appending(path: "docs/api.md"))
        await sync.sync()
        #expect(sync.state == .idle)
        #expect(read(host.appending(path: "main.go")) == "package main // edited here\n")
        #expect(read(host.appending(path: "NOTES.md")) == "notes\n")
        #expect(!FileManager.default.fileExists(atPath: host.appending(path: "docs/api.md").path))
        #expect(read(host.appending(path: ".git/config")) == "[core]\n")

        // A file made here after the last sync isn't taken for one the host deleted.
        try Self.write("draft\n", to: mirror.appending(path: "draft.md"))
        await sync.sync()
        #expect(read(host.appending(path: "draft.md")) == "draft\n")
    }

    @Test func anEditHereOutlivesADeletionThere() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let sync = RemoteSync(project: project)
        try await sync.pullAll()
        try Self.write("old, but edited here\n", to: project.mirrorURL.appending(path: "docs/old.md"))
        try FileManager.default.removeItem(at: host.appending(path: "docs/old.md"))
        await sync.sync()
        #expect(read(host.appending(path: "docs/old.md")) == "old, but edited here\n")
        #expect(read(project.mirrorURL.appending(path: "docs/old.md")) == "old, but edited here\n")
    }

    @Test func holdsBackMassDeletions() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        for index in 0..<60 { try Self.write("\(index)\n", to: host.appending(path: "gen/f\(index).txt")) }
        let sync = RemoteSync(project: project)
        try await sync.pullAll()
        try FileManager.default.removeItem(at: project.mirrorURL.appending(path: "gen"))
        await sync.sync()
        #expect(sync.heldDeletions == 60)
        #expect(FileManager.default.fileExists(atPath: host.appending(path: "gen/f0.txt").path))
        #expect(FileManager.default.fileExists(atPath: project.mirrorURL.appending(path: "gen/f0.txt").path))
    }

    @Test func asksTheHostForLanguageServers() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let command = SSH.remoteCommand(["sh", "-c", LanguageServer.hostProbeScript()], in: host.path)
        let output = await Shell.run([SSH.program] + SSH.arguments(host: "devbox", command: command), in: base)
        #expect(output.succeeded)
        // Whatever this Mac has; each command is a full path the host can start.
        #expect(LanguageServer.hostCommands(fromProbe: output.stdout).values.allSatisfy { FileManager.default.isExecutableFile(atPath: $0[0]) })
    }

    @Test func runsDatabaseClientsOnTheHost() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try await RemoteSync(project: project).pullAll()
        RemoteRegistry.register(project) {}
        defer { RemoteRegistry.unregister(mirror: project.mirror) }
        let secret = await Shell.run(["sh", "-c", #"printf %s "$PGPASSWORD""#], in: project.mirrorURL, extra: ["PGPASSWORD": "it's secret"])
        #expect(secret.stdout == "it's secret")

        let postgres = DatabaseConnection(name: "app", engine: .postgres, database: "app", service: "db")
        #expect(DatabaseClient.route(for: postgres, hasCompose: true, projectRoot: project.mirrorURL) == .compose(service: "db"))
        #expect(DatabaseClient.route(for: postgres, hasCompose: false, projectRoot: project.mirrorURL) == .local("psql"))
        let sqlite = DatabaseConnection(name: "local", engine: .sqlite, database: "dev.db", file: "data/dev.db")
        let command = DatabaseClient.command(for: SQLScript.statements("select 1"), on: sqlite, password: nil, route: .local("sqlite3"), projectRoot: project.mirrorURL)
        #expect(command.arguments.contains(host.appending(path: "data/dev.db").path))
    }

    @Test func runsCommandsForTheMirrorOnTheHost() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try await RemoteSync(project: project).pullAll()
        RemoteRegistry.register(project) {}
        defer { RemoteRegistry.unregister(mirror: project.mirror) }
        let output = await Shell.run(["pwd"], in: project.mirrorURL.appending(path: "docs"))
        #expect(output.stdout == host.appending(path: "docs").path)
        let missing = await RemoteSync.check(host: "devbox", path: base.appending(path: "nowhere").path)
        #expect(missing?.hasPrefix("There’s no folder") == true)
        #expect(await RemoteSync.check(host: "devbox", path: host.path) == nil)
    }
}
