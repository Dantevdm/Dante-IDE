import AVFoundation
import DanteCore
import Foundation
import Network
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
            .speech(id: "5", text: "Hello from the Mac."),
            .setApprovals(id: "6", project: "p", mode: .everything),
            .openProject(id: "7", project: "r"),
        ]
        for message in messages {
            #expect(CompanionCoding.decode(ClientMessage.self, from: CompanionCoding.encode(message)) == message)
        }
        #expect(messages.compactMap(\.id) == ["1", "2", "3", "4", "5", "6", "7"])
        for message: ServerMessage in [.voiceAvailable(available: true), .speech(id: "5", audio: Data([0, 1, 255])), .speech(id: "6", audio: nil)] {
            #expect(CompanionCoding.decode(ServerMessage.self, from: CompanionCoding.encode(message)) == message)
        }
        let snapshot = CompanionSnapshot(server: "Mac", projects: [
            .init(id: "p", name: "shop", lead: "Claude", working: true, lastReply: "On it.",
                  jobs: [.init(id: "j1", title: "Fix tests", state: .waiting, label: "1 waiting", lastReply: "")],
                  approvals: [.init(id: "main/t1", job: nil, from: "Main conversation", title: "Run go test ./...", detail: "go test ./...")]),
        ])
        let server: ServerMessage = .snapshot(snapshot: snapshot)
        #expect(CompanionCoding.decode(ServerMessage.self, from: CompanionCoding.encode(server)) == server)
        #expect(snapshot.waiting == 1)
    }

    @Test func withNothingOpenMessagesGoToTheMostRecentProject() throws {
        let open = CompanionSnapshot.Project(id: "p", name: "shop", lead: "Claude", working: false, lastReply: "", jobs: [], approvals: [])
        let recent = [CompanionSnapshot.Recent(id: "r1", name: "orders"), .init(id: "r2", name: "billing")]
        #expect(CompanionSnapshot(server: "Mac", projects: [open], recent: recent).target(focus: nil)?.id == "p")
        let empty = CompanionSnapshot(server: "Mac", projects: [], recent: recent)
        #expect(empty.target(focus: nil)?.id == "r1")
        #expect(empty.target(focus: nil)?.isOpen == false)
        #expect(empty.target(focus: "r2")?.name == "billing")
        #expect(CompanionSnapshot(server: "Mac", projects: []).target(focus: nil) == nil)
        // A snapshot from a Mac without recent projects still reads.
        let old = Data(#"{"server":"Mac","projects":[]}"#.utf8)
        #expect(CompanionCoding.decode(CompanionSnapshot.self, from: old)?.recent == nil)
        let message: ServerMessage = .snapshot(snapshot: empty)
        #expect(CompanionCoding.decode(ServerMessage.self, from: CompanionCoding.encode(message)) == message)
        #expect(CompanionForeman.parse("switch to billing", projects: ["shop", "billing"]) == .switchProject("billing"))
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
        #expect(try await Self.read(socket) == .voiceAvailable(available: false))

        try await Self.write(.ask(id: "1", project: "p", job: nil, text: "Status?", spoken: true), to: socket)
        let received = await probe.nextMessage()
        #expect(received == .ask(id: "1", project: "p", job: nil, text: "Status?", spoken: true))

        server.publish(CompanionSnapshot(server: "Test Mac", projects: []))
        guard case .snapshot(let next) = try await Self.read(socket) else { Issue.record("no snapshot"); return }
        #expect(next.projects.isEmpty)
        socket.cancel(with: .goingAway, reason: nil)
        server.stop()
    }

    @Test func naturalAudioTravelsOverThePairedConnection() async throws {
        let key = CompanionPairing.newKey()
        let probe = Probe()
        let server = CompanionServer(host: "127.0.0.1", port: 0, name: "Voice Mac", key: key,
                                     onState: { probe.state($0) }, onMessage: { device, message in probe.message(message, device: device) })
        server.setNaturalVoiceAvailable(true)
        server.start()
        defer { server.stop() }
        let port = try #require(await probe.port())
        let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/companion")!)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        guard case .challenge(let nonce, _, _) = try await Self.read(socket) else { Issue.record("no challenge"); return }
        try await Self.write(.hello(device: "Phone", proof: CompanionAuth.proof(key: key, nonce: nonce), version: Companion.version), to: socket)
        guard case .welcome = try await Self.read(socket) else { Issue.record("no welcome"); return }
        #expect(try await Self.read(socket) == .voiceAvailable(available: true))
        try await Self.write(.speech(id: "voice", text: "Hello."), to: socket)
        #expect(await probe.nextMessage() == .speech(id: "voice", text: "Hello."))
        let device = try #require(probe.deviceID())
        let audio = try #require(CompanionAudio.wav(samples: [0, -1, 1], sampleRate: 24_000))
        server.speech(to: device, id: "voice", audio: audio)
        #expect(try await Self.read(socket) == .speech(id: "voice", audio: audio))
        server.speech(to: device, id: "fallback", audio: nil)
        #expect(try await Self.read(socket) == .speech(id: "fallback", audio: nil))
    }

    @Test func quietPhoneAnswersHeartbeatsAndKeepsReceiving() async throws {
        let key = CompanionPairing.newKey(), probe = Probe()
        let server = CompanionServer(host: "127.0.0.1", port: 0, name: "Mac", key: key,
                                     onState: { probe.state($0) }, onDevices: { probe.devices($0) },
                                     onMessage: { device, message in probe.message(message, device: device) },
                                     heartbeatInterval: 0.1, heartbeatTimeout: 0.8)
        server.start()
        defer { server.stop() }
        let port = try #require(await probe.port())
        let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/companion")!)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        guard case .challenge(let nonce, _, _) = try await Self.read(socket) else { Issue.record("no challenge"); return }
        try await Self.write(.hello(device: "Quiet phone", proof: CompanionAuth.proof(key: key, nonce: nonce), version: Companion.version), to: socket)
        guard case .welcome = try await Self.read(socket) else { Issue.record("no welcome"); return }
        _ = try await Self.read(socket) // voice availability
        // Like the app's receive loop, keep a receive outstanding while idle.
        let incoming = Task { try await Self.read(socket) }
        defer { incoming.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            socket.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        // Longer than the stale-client deadline, with no application messages.
        try await Task.sleep(for: .milliseconds(1400))
        try await Self.write(.ask(id: "alive", project: "p", job: nil, text: "Still here?", spoken: true), to: socket)
        #expect(await probe.nextMessage() == .ask(id: "alive", project: "p", job: nil, text: "Still here?", spoken: true))
        let device = try #require(probe.deviceID())
        server.reply(to: device, id: "alive", ok: true, message: "Still connected.")
        #expect(try await incoming.value == .result(id: "alive", ok: true, message: "Still connected."))
        #expect(probe.connectedDeviceCount() == 1)
    }

    @Test func unresponsivePhoneIsRemovedFromConnectedDevices() async throws {
        let key = CompanionPairing.newKey(), probe = Probe()
        let server = CompanionServer(host: "127.0.0.1", port: 0, name: "Mac", key: key,
                                     onState: { probe.state($0) }, onDevices: { probe.devices($0) },
                                     onMessage: { _, message in probe.message(message) },
                                     heartbeatInterval: 0.1, heartbeatTimeout: 0.5)
        server.start()
        defer { server.stop() }
        let port = try #require(await probe.port())
        let phone = SilentPhone(port: port, key: key)
        phone.start()
        defer { phone.stop() }
        #expect(await probe.waitForDeparture())
        #expect(probe.connectedDeviceCount() == 0)
    }

    @Test func companionWAVHasPlayablePCMAndBounds() throws {
        let data = try #require(CompanionAudio.wav(samples: [-2, 0, 2, .nan], sampleRate: 24_000))
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(data.count == 52)
        let player = try AVAudioPlayer(data: data)
        #expect(player.format.sampleRate == 24_000)
        #expect(player.numberOfChannels == 1)
        let values = data.withUnsafeBytes { bytes in
            (0..<4).map { Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: 44 + $0 * 2, as: Int16.self)) }
        }
        #expect(values == [-32767, 0, 32767, 0])
        #expect(CompanionAudio.wav(samples: [], sampleRate: 24_000) == nil)
        #expect(CompanionAudio.wav(samples: [0], sampleRate: 0) == nil)
        #expect(CompanionAudio.wav(samples: Array(repeating: 0, count: CompanionAudio.maximumBytes / 2), sampleRate: 24_000) == nil)
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
    private var device: String?
    private var connectedDevices = 0
    private var sawDevice = false

    func devices(_ devices: [CompanionServer.Device]) {
        lock.withLock {
            connectedDevices = devices.count
            if !devices.isEmpty { sawDevice = true }
        }
    }

    func connectedDeviceCount() -> Int { lock.withLock { connectedDevices } }

    func waitForDeparture() async -> Bool {
        for _ in 0..<150 {
            if lock.withLock({ sawDevice && connectedDevices == 0 }) { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return false
    }

    func state(_ state: CompanionServer.State) {
        if case .listening(_, let port) = state { lock.withLock { listening = port } }
    }

    func message(_ message: ClientMessage, device: String? = nil) {
        lock.withLock { messages.append(message); self.device = device }
    }

    func deviceID() -> String? { lock.withLock { device } }

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

/// Authenticates normally, but deliberately ignores WebSocket pings to model a
/// suspended or unreachable phone without waiting for the TCP stack to time out.
private final class SilentPhone: @unchecked Sendable {
    private let connection: NWConnection
    private let key: String
    private let queue = DispatchQueue(label: "companion-test-silent-phone")

    init(port: UInt16, key: String) {
        self.key = key
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = false
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        connection = NWConnection(to: .url(URL(string: "ws://127.0.0.1:\(port)/companion")!), using: parameters)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.receive() }
        }
        connection.start(queue: queue)
    }

    func stop() { connection.cancel() }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data, case .challenge(let nonce, _, _) = CompanionCoding.decode(ServerMessage.self, from: data) {
                let hello = ClientMessage.hello(device: "Silent phone", proof: CompanionAuth.proof(key: self.key, nonce: nonce), version: Companion.version)
                let context = NWConnection.ContentContext(identifier: "hello", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
                self.connection.send(content: CompanionCoding.encode(hello), contentContext: context, isComplete: true,
                                     completion: .contentProcessed { _ in })
            }
            self.receive()
        }
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
            "Claude wants to run the tests in shop. Shall I go ahead?",
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
        #expect(CompanionForeman.parse("Auto-approve", projects: projects) == .approvals(.everything))
        #expect(CompanionForeman.parse("Turn off auto approve", projects: projects) == .approvals(.ask))
        #expect(CompanionForeman.parse("auto edit", projects: projects) == .approvals(.edits))
        #expect(CompanionForeman.parse("should we auto approve this?", projects: projects) == .ask("should we auto approve this"))
    }

    @Test func permissionPromptsExplainPurposeWithoutReadingCommands() {
        let read = CompanionSnapshot.Approval(id: "a", job: nil, from: "Main", title: "Run cat Sources/App.swift", detail: "cat Sources/App.swift")
        #expect(CompanionForeman.ask(read, project: "shop", lead: "Codex") == "Codex wants to read a project file in shop. Shall I go ahead?")
        let compound = CompanionSnapshot.Approval(id: "b", job: nil, from: "Main", title: "Run cat a", detail: "cat a; rm b", note: "Run cat a; rm b")
        let spoken = CompanionForeman.ask(compound, project: "shop", lead: "Codex")
        #expect(spoken == "Codex wants to run a project command in shop. This step needs your review. Shall I go ahead?")
        #expect(!spoken.contains("cat"))
    }
}
