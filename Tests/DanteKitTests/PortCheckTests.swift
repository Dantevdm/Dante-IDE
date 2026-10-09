import Foundation
import Testing
@testable import DanteKit

struct PortCheckTests {
    @Test func readsProcessesAndDirectories() {
        let ps = "  812    01:16:22 /home/me/shop/bin/server --port 3000\n  900 2-03:00:00 node vite\n"
        let processes = PortCheck.parseProcesses(ps)
        #expect(processes[812]?.elapsed == "01:16:22" && processes[812]?.command == "/home/me/shop/bin/server --port 3000")
        #expect(processes[900]?.command == "node vite")
        #expect(PortCheck.parseDirectories("p812\nfcwd\nn/home/me/shop\np900\nfcwd\nn/home/me/other\n") == [812: "/home/me/shop", 900: "/home/me/other"])
    }

    @Test func knowsWhatBelongsToTheProject() {
        let root = URL(filePath: "/home/me/shop")
        let server = PortHolder(listening: ListeningPort(port: 3000, pid: 812, command: "server"), commandLine: "/home/me/shop/bin/server", directory: "/home/me")
        let vite = PortHolder(listening: ListeningPort(port: 5173, pid: 900, command: "node"), commandLine: "node vite", directory: "/home/me/shop/web")
        let other = PortHolder(listening: ListeningPort(port: 8080, pid: 901, command: "java"), commandLine: "java -jar x.jar", directory: "/home/me/shopping")
        #expect(server.belongs(to: root) && vite.belongs(to: root) && !other.belongs(to: root))
    }

    @Test func findsConflictsOnlyForServicesThatArentRunning() {
        let services = [ComposeFile.Service(name: "app", ports: ["3000:3000"]), ComposeFile.Service(name: "db", ports: ["5432:5432"])]
        let holders = [PortHolder(listening: ListeningPort(port: 3000, pid: 812, command: "server")),
                       PortHolder(listening: ListeningPort(port: 5432, pid: 77, command: "postgres"))]
        let conflicts = PortConflict.find(services: services, containers: [ContainerState(service: "db", state: "running")], holders: holders)
        #expect(conflicts.map(\.id) == ["app:3000"])
    }

    @Test func republishesAServicePort() {
        let yaml = """
        services:
          app:
            build: .
            ports:
              - "3000:3000"   # web
              - 9229:9229
          other:
            ports:
              - "3000:80"
        """
        let moved = ComposeEditing.republishing(service: "app", port: 3000, to: 3001, in: yaml)
        #expect(moved?.contains(#"- "3001:3000"   # web"#) == true)
        #expect(moved?.contains(#"- "3000:80""#) == true)
        #expect(ComposeEditing.republishing(service: "app", port: 9229, to: 9230, in: yaml)?.contains("- 9230:9229") == true)
        #expect(ComposeEditing.republishing(service: "other", port: 3000, to: 3002, in: yaml)?.contains(#"- "3002:80""#) == true)
        #expect(ComposeEditing.republishing(service: "app", port: 4000, to: 4001, in: yaml) == nil)
        #expect(ComposeEditing.republishing(service: "db", port: 3000, to: 3001, in: yaml) == nil)
        let bound = "services:\n  db:\n    ports:\n      - \"127.0.0.1:5432:5432\"\n"
        #expect(ComposeEditing.republishing(service: "db", port: 5432, to: 5433, in: bound) == "services:\n  db:\n    ports:\n      - \"127.0.0.1:5433:5432\"\n")
    }

    @Test func freesAPortItStarted() async throws {
        // A listener of our own, on a free port.
        let port = PortProbe.firstFree(from: 47_000)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/nc")
        process.arguments = ["-l", "127.0.0.1", "\(port)"]
        try process.run()
        for _ in 0..<50 where PortProbe.isFree(port) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!PortProbe.isFree(port))
        let holder = PortHolder(listening: ListeningPort(port: port, pid: process.processIdentifier, command: "nc"))
        #expect(await PortCheck.stop(holder) == nil)
        #expect(PortProbe.isFree(port))
    }
}
