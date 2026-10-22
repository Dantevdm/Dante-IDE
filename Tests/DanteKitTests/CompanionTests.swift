import DanteCore
import Foundation
import Testing
@testable import DanteKit

@Suite struct CompanionTests {
    @Test func pairingRoundTripsThroughItsURL() throws {
        let key = CompanionPairing.newKey()
        let pairing = CompanionPairing(host: "100.101.102.103", port: 47823, name: "Studio Mac", key: key)
        #expect(pairing.url.scheme == "dante-companion")
        let read = try #require(CompanionPairing(url: pairing.url))
        #expect(read == pairing)
        #expect(read.socketURL.absoluteString == "ws://100.101.102.103:47823/companion")
    }

    @Test func pairingRefusesBadCodes() {
        #expect(CompanionPairing(url: URL(string: "dante-companion://pair?host=1.2.3.4&port=1&key=short")!) == nil)
        #expect(CompanionPairing(url: URL(string: "https://pair?host=1.2.3.4&port=1")!) == nil)
        let key = CompanionPairing.newKey()
        #expect(CompanionPairing(url: URL(string: "dante-companion://pair?host=1.2.3.4&port=0&key=\(key)")!) == nil)
        #expect(CompanionPairing(url: URL(string: "dante-companion://pair?port=80&key=\(key)")!) == nil)
    }

    @Test func proofChecksTheKeyWithoutSendingIt() {
        let key = CompanionPairing.newKey()
        let nonce = CompanionAuth.nonce()
        let proof = CompanionAuth.proof(key: key, nonce: nonce)
        #expect(!proof.contains(key))
        #expect(CompanionAuth.verify(proof, key: key, nonce: nonce))
        #expect(!CompanionAuth.verify(proof, key: key, nonce: CompanionAuth.nonce()))
        #expect(!CompanionAuth.verify(proof, key: CompanionPairing.newKey(), nonce: nonce))
        #expect(!CompanionAuth.verify("", key: key, nonce: nonce))
        #expect(!CompanionAuth.verify(key, key: key, nonce: nonce))
    }

    @Test func tailnetAddressesAreTheCarrierGradeRange() {
        #expect(CompanionAddress.isTailnet("100.64.0.1"))
        #expect(CompanionAddress.isTailnet("100.127.255.254"))
        #expect(!CompanionAddress.isTailnet("100.128.0.1"))
        #expect(!CompanionAddress.isTailnet("100.63.0.1"))
        #expect(!CompanionAddress.isTailnet("192.168.1.10"))
        #expect(!CompanionAddress.isTailnet("100.64.0"))
        #expect(CompanionAddress.tailnet(among: ["127.0.0.1", "192.168.1.4", "100.88.1.2"]) == "100.88.1.2")
        #expect(CompanionAddress.tailnet(among: ["127.0.0.1"]) == nil)
        #expect(CompanionAddress.listening(environment: ["DANTE_COMPANION_HOST": "127.0.0.1"]) == "127.0.0.1")
    }

    @Test func messagesRoundTrip() throws {
        let messages: [ClientMessage] = [
            .hello(device: "Phone", proof: "abc", version: 1),
            .ask(id: "1", project: "p", job: nil, text: "How's it going?", spoken: true),
            .answer(id: "2", project: "p", approval: "main/t1", allow: true, note: nil, answers: ["Which?": "A"]),
            .startJob(id: "3", project: "p", brief: "Fix the flaky test", awayMinutes: 30),
            .stop(id: "4", project: "p", job: "j1"),
        ]
        for message in messages {
            #expect(CompanionCoding.decode(ClientMessage.self, from: CompanionCoding.encode(message)) == message)
        }
        #expect(messages.compactMap(\.id) == ["1", "2", "3", "4"])
        let snapshot = CompanionSnapshot(server: "Mac", projects: [
            .init(id: "p", name: "shop", lead: "Claude", working: true, lastReply: "On it.",
                  jobs: [.init(id: "j1", title: "Fix tests", state: .waiting, label: "1 waiting", lastReply: "")],
                  approvals: [.init(id: "main/t1", job: nil, from: "Main conversation", title: "Run go test ./...", detail: "go test ./...")]),
        ])
        let server: ServerMessage = .snapshot(snapshot: snapshot)
        #expect(CompanionCoding.decode(ServerMessage.self, from: CompanionCoding.encode(server)) == server)
        #expect(snapshot.waiting == 1)
    }

    @Test func approvalsDescribeWhatsWaiting() {
        var edit = ToolActivity(id: "t1", name: "Bash", input: ["command": "rm -rf build"], status: .awaitingApproval(requestID: "r"))
        edit.ruleNote = "Outside propose paths."
        let approval = CompanionSnapshot.Approval(JobInbox.Item(job: "j1", from: "Fix tests", tool: edit))
        #expect(approval.id == "j1/t1")
        #expect(approval.title == "Run rm -rf build")
        #expect(approval.detail == "rm -rf build")
        #expect(approval.note == "Outside propose paths.")
        let questions: JSONValue = ["questions": [["question": "Which database?", "options": [["label": "Postgres"], ["label": "SQLite"]]]]]
        let question = ToolActivity(id: "q", name: "AskUserQuestion", input: questions, status: .awaitingApproval(requestID: "r"))
        let asked = CompanionSnapshot.Approval(JobInbox.Item(job: nil, from: "Main conversation", tool: question))
        #expect(asked.questions == [.init(question: "Which database?", options: ["Postgres", "SQLite"])])
        let long = CompanionSnapshot.Approval(id: "x", job: nil, from: "", title: "", detail: String(repeating: "a", count: 9000))
        #expect(long.detail.count < 4100)
    }

    @Test func projectIDsDontCarryThePath() {
        let id = CompanionSnapshot.Project.id(for: URL(filePath: "/tmp/someone/Code/shop"))
        #expect(id.count == 12)
        #expect(!id.contains("shop"))
        #expect(id == CompanionSnapshot.Project.id(for: URL(filePath: "/tmp/someone/Code/shop/")))
    }

    // MARK: Over a socket

    @Test func pairedDeviceGetsTheSnapshotAndItsMessagesArrive() async throws {
        let key = CompanionPairing.newKey()
        let probe = Probe()
        let server = CompanionServer(host: "127.0.0.1", port: 0, name: "Test Mac", key: key,
                                     onState: { probe.state($0) }, onMessage: { _, message in probe.message(message) })
        server.start()
        let port = try #require(await probe.port())
        server.publish(CompanionSnapshot(server: "Test Mac", projects: [
            .init(id: "p", name: "shop", lead: "Claude", working: false, lastReply: "Hi", jobs: [], approvals: []),
        ]))

        let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/companion")!)
        socket.resume()
        guard case .challenge(let nonce, let name, _) = try await Self.read(socket) else { Issue.record("no challenge"); return }
        #expect(name == "Test Mac")
        try await Self.write(.hello(device: "Phone", proof: CompanionAuth.proof(key: key, nonce: nonce), version: Companion.version), to: socket)
        guard case .welcome(let snapshot) = try await Self.read(socket) else { Issue.record("no welcome"); return }
        #expect(snapshot.projects.map(\.name) == ["shop"])

        try await Self.write(.ask(id: "1", project: "p", job: nil, text: "Status?", spoken: true), to: socket)
        let received = await probe.nextMessage()
        #expect(received == .ask(id: "1", project: "p", job: nil, text: "Status?", spoken: true))

        server.publish(CompanionSnapshot(server: "Test Mac", projects: []))
        guard case .snapshot(let next) = try await Self.read(socket) else { Issue.record("no snapshot"); return }
        #expect(next.projects.isEmpty)
        socket.cancel(with: .goingAway, reason: nil)
        server.stop()
    }

    @Test func wrongKeyIsRefused() async throws {
        let probe = Probe()
        let server = CompanionServer(host: "127.0.0.1", port: 0, name: "Test Mac", key: CompanionPairing.newKey(),
                                     onState: { probe.state($0) }, onMessage: { _, message in probe.message(message) })
        server.start()
        let port = try #require(await probe.port())
        let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/companion")!)
        socket.resume()
        guard case .challenge(let nonce, _, _) = try await Self.read(socket) else { Issue.record("no challenge"); return }
        try await Self.write(.hello(device: "Stranger", proof: CompanionAuth.proof(key: CompanionPairing.newKey(), nonce: nonce), version: Companion.version), to: socket)
        guard case .refused = try await Self.read(socket) else { Issue.record("not refused"); return }
        socket.cancel(with: .goingAway, reason: nil)
        server.stop()
    }

    private static func read(_ socket: URLSessionWebSocketTask) async throws -> ServerMessage? {
        let data: Data = switch try await socket.receive() {
        case .string(let text): Data(text.utf8)
        case .data(let data): data
        @unknown default: Data()
        }
        return CompanionCoding.decode(ServerMessage.self, from: data)
    }

    private static func write(_ message: ClientMessage, to socket: URLSessionWebSocketTask) async throws {
        try await socket.send(.string(String(decoding: CompanionCoding.encode(message), as: UTF8.self)))
    }
}

/// Collects what the server reports from its queue, for the tests to wait on.
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var listening: UInt16?
    private var messages: [ClientMessage] = []

    func state(_ state: CompanionServer.State) {
        if case .listening(_, let port) = state { lock.withLock { listening = port } }
    }

    func message(_ message: ClientMessage) {
        lock.withLock { messages.append(message) }
    }

    func port() async -> UInt16? {
        for _ in 0..<100 {
            if let port = lock.withLock({ listening }) { return port }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return nil
    }

    func nextMessage() async -> ClientMessage? {
        for _ in 0..<100 {
            if let first = lock.withLock({ messages.isEmpty ? nil : messages.removeFirst() }) { return first }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return nil
    }
}

@Suite struct CompanionForemanTests {
    private func snapshot(working: Bool = false, reply: String = "", jobState: CompanionSnapshot.Job.State = .working,
                          approvals: [CompanionSnapshot.Approval] = []) -> CompanionSnapshot {
        CompanionSnapshot(server: "Mac", projects: [
            .init(id: "p", name: "shop", lead: "Claude", working: working, lastReply: reply,
                  jobs: [.init(id: "j", title: "Fix tests", state: jobState, label: "Working", lastReply: "")],
                  approvals: approvals),
        ])
    }

    @Test func aFinishedTurnIsSaidOnce() {
        let before = snapshot(working: true, reply: "Looking")
        let after = snapshot(working: false, reply: "The **build** is fixed.\n```\ncode\n```")
        let events = CompanionForeman.events(from: before, to: after)
        #expect(events == [.replied(project: "p", job: nil, text: after.projects[0].lastReply)])
        #expect(CompanionForeman.spoken(events[0], in: after) == "The build is fixed.")
        #expect(CompanionForeman.events(from: after, to: after).isEmpty)
        #expect(CompanionForeman.events(from: nil, to: after).isEmpty)
    }

    @Test func newApprovalsAndFinishedJobsAreSaid() {
        let run = CompanionSnapshot.Approval(id: "main/t", job: nil, from: "Main conversation", title: "Run go test ./...", detail: "go test ./...")
        let after = snapshot(jobState: .ready, approvals: [run])
        let events = CompanionForeman.events(from: snapshot(), to: after)
        #expect(events.count == 2)
        #expect(events.map { CompanionForeman.spoken($0, in: after) } == [
            "The job Fix tests in shop is ready to review.",
            "Claude wants to run go test ./... in shop. Yes or no?",
        ])
        let question = CompanionSnapshot.Approval(id: "q", job: "j", from: "Fix tests", title: "Claude has a question", detail: "",
                                                   questions: [.init(question: "Which database?", options: ["Postgres", "SQLite"])])
        #expect(CompanionForeman.ask(question, project: "shop", lead: "Claude")
            == "The job Fix tests in shop asks: Which database? The options are Postgres or SQLite.")
    }

    @Test func statusComesFromTheSnapshot() {
        let run = CompanionSnapshot.Approval(id: "a", job: nil, from: "", title: "Run x", detail: "")
        #expect(CompanionForeman.status(snapshot(working: true, approvals: [run]))
            == "shop needs you: one thing is waiting. Claude is working in shop. One job running in shop.")
        #expect(CompanionForeman.status(snapshot(jobState: .paused)) == "All quiet in shop.")
        #expect(CompanionForeman.status(CompanionSnapshot(server: "Studio", projects: [])) == "No projects are open on Studio.")
    }

    @Test func whatYouSayOnTheWalk() {
        let projects = ["shop", "Dante IDE"]
        #expect(CompanionForeman.parse("Yes.", projects: projects) == .approve)
        #expect(CompanionForeman.parse("nope", projects: projects) == .decline)
        #expect(CompanionForeman.parse("What's the status?", projects: projects) == .status)
        #expect(CompanionForeman.parse("say that again", projects: projects) == .repeatLast)
        #expect(CompanionForeman.parse("switch to dante ide", projects: projects) == .switchProject("Dante IDE"))
        #expect(CompanionForeman.parse("start a job to fix the flaky login test", projects: projects) == .startJob("Fix the flaky login test"))
        #expect(CompanionForeman.parse("Why is the build red?", projects: projects) == .ask("Why is the build red"))
        #expect(CompanionForeman.parse("  ", projects: projects) == .cancel)
    }
}
