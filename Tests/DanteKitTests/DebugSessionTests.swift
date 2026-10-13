import DanteKit
import Foundation
import Testing

struct DebugAdapterTests {
    @Test func picksAnAdapterAndBuildsItsLaunch() {
        #expect(DebugAdapter.for(file: "/home/me/shop/main.go") == .go)
        #expect(DebugAdapter.for(file: "/home/me/tool/run.py") == .python)
        #expect(DebugAdapter.for(file: "/home/me/readme.md") == nil)

        let launch = DebugAdapter.go.launchArguments(file: "/home/me/shop/api/handlers_test.go", root: "/home/me/shop")
        #expect(launch["mode"]?.string == "test" && launch["program"]?.string == "/home/me/shop/api")
        #expect(DebugAdapter.go.launchArguments(file: "/home/me/shop/main.go", root: "/home/me/shop")["mode"]?.string == "debug")
        #expect(DebugAdapter.python.launchArguments(file: "/home/me/run.py", root: "/home/me")["program"]?.string == "/home/me/run.py")
    }

    @Test func readsTheAnnouncedAddress() {
        #expect(DebugAdapter.announcedAddress(in: "DAP server listening at: 127.0.0.1:50744")! == ("127.0.0.1", 50744))
        #expect(DebugAdapter.announcedAddress(in: "DAP server listening at: [::1]:4000")! == ("::1", 4000))
        #expect(DebugAdapter.announcedAddress(in: "API server listening") == nil)
    }

    @Test func findsTheAdapterInItsUsualFolder() {
        let found = DebugAdapter.go.resolve(path: "/usr/bin", home: "/home/me", isExecutable: { $0 == "/home/me/go/bin/dlv" })
        #expect(found?.path == "/home/me/go/bin/dlv")
    }

    @Test func readsMessages() {
        let response: JSONValue = .object(["type": .string("response"), "request_seq": .number(3), "success": .bool(false),
                                           "message": .string("bad"), "body": .object(["error": .object(["format": .string("No such file")])])])
        #expect(DAP.read(response) == .response(requestSeq: 3, success: false, message: "No such file", body: response["body"]!))
        let event: JSONValue = .object(["type": .string("event"), "event": .string("stopped"), "body": .object(["reason": .string("breakpoint")])])
        #expect(DAP.read(event) == .event("stopped", .object(["reason": .string("breakpoint")])))
        #expect(DAP.read(.object(["type": .string("request"), "seq": .number(9), "command": .string("runInTerminal")])) == .request(seq: 9, command: "runInTerminal"))
        let request = DAP.request(seq: 1, command: "next", arguments: .object(["threadId": .number(1)]))
        #expect(request["command"]?.string == "next" && request["arguments"]?["threadId"]?.int == 1)
    }
}

/// Debugs a small Go program with Delve, when it's installed.
@MainActor
struct DebugSessionTests {
    nonisolated static let dlv: Bool = DebugAdapter.go.resolve(path: ProcessInfo.processInfo.environment["PATH"] ?? "") != nil
        && ["/opt/homebrew/bin/go", "/usr/local/go/bin/go"].contains { FileManager.default.isExecutableFile(atPath: $0) }

    @Test(.enabled(if: dlv), .timeLimit(.minutes(1)))
    func stopsAtABreakpointShowsVariablesAndSteps() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dante-debug-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "module example.com/sum\n\ngo 1.21\n".write(to: folder.appending(path: "go.mod"), atomically: true, encoding: .utf8)
        let source = """
            package main

            import "fmt"

            func main() {
            \ttotal := 0
            \tfor i := 1; i <= 3; i++ {
            \t\ttotal += i
            \t}
            \tfmt.Println("total", total)
            }

            """
        let file = folder.appending(path: "main.go").resolvingSymlinksInPath().path
        try source.write(toFile: file, atomically: true, encoding: .utf8)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/go/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment.removeValue(forKey: "CLAUDECODE")
        let session = DebugSession(adapter: .go, file: file)
        await session.start(root: folder.resolvingSymlinksInPath(), environment: environment, breakpoints: [file: [10]])
        #expect(session.failure == nil)

        try await waitFor { session.state == .stopped && !session.scopes.isEmpty }
        #expect(session.stopReason == "breakpoint")
        #expect(session.selectedFrame?.line == 10)
        #expect(session.selectedFrame?.name.contains("main.main") == true)
        let locals = try #require(session.scopes.first.flatMap { session.children[$0.reference] })
        #expect(locals.contains { $0.name == "total" && $0.value == "6" })

        await session.evaluate("total * 2")
        #expect(session.output.last { $0.category == "result" }?.text == "12")

        session.stepOver()
        try await waitFor { session.state == .stopped && session.selectedFrame?.line == 11 }
        #expect(session.output.contains { $0.text.contains("total 6") })

        session.resume()
        try await waitFor { session.state == .ended }
        #expect(session.failure == nil)
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("Timed out waiting")
        throw CancellationError()
    }
}
