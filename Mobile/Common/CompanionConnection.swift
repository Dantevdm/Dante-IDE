import Foundation
import Observation
import UIKit

/// The WebSocket to the paired Mac: answers its challenge with the key's proof, keeps the
/// latest snapshot, reports what changed to the foreman, and reconnects (1 s, 2 s, 4 s… up to
/// 30 s) until the Mac refuses the device or it's unpaired.
@MainActor @Observable
final class CompanionConnection {
    enum Status: Equatable {
        case idle
        case connecting
        case connected
        /// Can't reach the Mac; trying again.
        case offline(String)
        /// The Mac said no: a new key, or the versions differ. Pair again.
        case refused(String)
    }

    private(set) var status: Status = .idle
    private(set) var snapshot: CompanionSnapshot?
    private(set) var pairing: CompanionPairing?
    /// The last request the Mac couldn't carry out.
    private(set) var failure: String?
    private(set) var naturalVoiceAvailable = false
    private(set) var voiceFailure: String?
    @ObservationIgnored private var voiceAvailabilityKnown = false

    /// What changed in each new snapshot, for the voice loop.
    @ObservationIgnored var onEvents: ([CompanionForeman.Event], CompanionSnapshot) -> Void = { _, _ in }
    /// What became of a request: ok, and the Mac's sentence.
    @ObservationIgnored var onResult: (Bool, String) -> Void = { _, _ in }
    @ObservationIgnored var onApprovalModeChanged: (CompanionApprovalMode) -> Void = { _ in }
    /// Everyone else who follows the Mac: notifications and the Lock Screen's Live Activity.
    /// Called with the snapshot, whether it's connected, and what the foreman noticed.
    @ObservationIgnored var observers: [(CompanionSnapshot?, Bool, [CompanionForeman.Event]) -> Void] = []
    @ObservationIgnored private var approvalRequests: [String: CompanionApprovalMode] = [:]

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var attempts = 0
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var healthDeadline: Task<Void, Never>?
    @ObservationIgnored private var pingID: UUID?
    @ObservationIgnored private var speechRequests: [String: CheckedContinuation<Data?, Never>] = [:]
    @ObservationIgnored private var exploreRequests: [String: CheckedContinuation<ServerMessage?, Never>] = [:]

    func connect(_ pairing: CompanionPairing) {
        self.pairing = pairing
        wanted = true
        attempts = 0
        open()
    }

    func disconnect() {
        finishSpeechRequests()
        wanted = false
        retry?.cancel()
        stopHealthChecks()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        status = .idle
    }

    /// Unpaired: back to the pairing screen.
    func forget() {
        pairing = nil
        snapshot = nil
    }

    /// After coming back to the foreground: reconnect now rather than at the next retry.
    func resume() {
        guard wanted else { return }
        if status == .connected, let socket {
            ping(socket)
            return
        }
        guard status != .connecting else { return }
        retry?.cancel()
        open()
    }

    private func open() {
        guard let pairing else { return }
        retry?.cancel()
        stopHealthChecks()
        finishSpeechRequests()
        socket?.cancel(with: .goingAway, reason: nil)
        status = .connecting
        let socket = URLSession.shared.webSocketTask(with: pairing.socketURL)
        socket.maximumMessageSize = 4 << 20
        self.socket = socket
        socket.resume()
        healthDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, self.socket === socket, self.status == .connecting else { return }
            self.lost()
        }
        Task { await receive(on: socket) }
    }

    private func receive(on socket: URLSessionWebSocketTask) async {
        while true {
            let message: URLSessionWebSocketTask.Message
            do { message = try await socket.receive() } catch {
                if socket === self.socket { lost() }
                return
            }
            let data: Data = switch message {
            case .string(let text): Data(text.utf8)
            case .data(let data): data
            @unknown default: Data()
            }
            guard socket === self.socket else { return }
            if let decoded = CompanionCoding.decode(ServerMessage.self, from: data) { handle(decoded) }
        }
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case .challenge(let nonce, _, let version):
            guard let pairing else { return }
            guard version == Companion.version else {
                refuse(version > Companion.version ? "Update this app: the Mac speaks a newer version." : "Update Dante on the Mac.")
                return
            }
            send(.hello(device: UIDevice.current.name, proof: CompanionAuth.proof(key: pairing.key, nonce: nonce), version: Companion.version))
        case .welcome(let snapshot):
            status = .connected
            attempts = 0
            // Steps that came up while the phone was away are new to it too.
            let events = CompanionForeman.events(from: self.snapshot, to: snapshot)
            self.snapshot = snapshot
            startHealthChecks()
            tell(events)
        case .snapshot(let next):
            let events = CompanionForeman.events(from: snapshot, to: next)
            snapshot = next
            if !events.isEmpty { onEvents(events, next) }
            tell(events)
        case .refused(let reason):
            refuse(reason)
        case .library(let id, _), .page(let id, _), .screen(let id, _):
            exploreRequests.removeValue(forKey: id)?.resume(returning: message)
        case .briefing(let id, let briefing):
            self.briefing = briefing
            BriefingStore.save(briefing)
            exploreRequests.removeValue(forKey: id)?.resume(returning: message)
        case .result(let id, let ok, let message):
            if let request = exploreRequests.removeValue(forKey: id) {
                // A library or page the Mac couldn't make (the reader says why), or what became
                // of a drafted reply.
                request.resume(returning: .result(id: id, ok: ok, message: message))
                return
            }
            failure = ok ? nil : message
            if let mode = approvalRequests.removeValue(forKey: id), ok { onApprovalModeChanged(mode) }
            onResult(ok, message)
        case .voiceAvailable(let available):
            naturalVoiceAvailable = available
            voiceAvailabilityKnown = true
        case .speech(let id, let audio):
            if speechRequests[id] != nil, audio == nil { voiceFailure = "The Mac couldn’t generate natural speech." }
            speechRequests.removeValue(forKey: id)?.resume(returning: audio)
        }
    }

    private func tell(_ events: [CompanionForeman.Event]) {
        for observer in observers { observer(snapshot, status == .connected, events) }
    }

    private func refuse(_ reason: String) {
        stopHealthChecks()
        finishSpeechRequests()
        wanted = false
        status = .refused(reason)
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func lost() {
        stopHealthChecks()
        finishSpeechRequests()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        guard wanted else { return }
        let name = pairing?.name ?? "your Mac"
        status = .offline("Can’t reach \(name). Is Tailscale on here and on the Mac, and is Dante open?")
        tell([])
        attempts += 1
        let delay = min(30, 1 << min(attempts - 1, 5))
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.open()
        }
    }

    private func send(_ message: ClientMessage) {
        guard let socket else { return }
        let text = String(decoding: CompanionCoding.encode(message), as: UTF8.self)
        socket.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self, self.socket === socket else { return }
                self.lost()
            }
        }
    }

    // MARK: Connection health

    private func stopHealthChecks() {
        heartbeat?.cancel()
        heartbeat = nil
        healthDeadline?.cancel()
        healthDeadline = nil
        pingID = nil
    }

    private func startHealthChecks() {
        stopHealthChecks()
        guard let socket else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.socket === socket else { return }
                self.ping(socket)
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }

    private func ping(_ socket: URLSessionWebSocketTask) {
        guard pingID == nil, self.socket === socket else { return }
        let id = UUID()
        pingID = id
        healthDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.socket === socket, self.pingID == id else { return }
            self.lost()
        }
        socket.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, self.socket === socket, self.pingID == id else { return }
                self.healthDeadline?.cancel()
                self.healthDeadline = nil
                self.pingID = nil
                if error != nil { self.lost() }
            }
        }
    }

    // MARK: Requests

    private func finishSpeechRequests() {
        approvalRequests.removeAll()
        let exploring = exploreRequests
        exploreRequests.removeAll()
        for request in exploring.values { request.resume(returning: nil) }
        naturalVoiceAvailable = false
        voiceAvailabilityKnown = false
        if !speechRequests.isEmpty { voiceFailure = "The connection to the Mac was interrupted." }
        let pending = speechRequests
        speechRequests.removeAll()
        for request in pending.values { request.resume(returning: nil) }
    }

    func speech(_ text: String) async -> Data? {
        voiceFailure = nil
        // A welcome and its voice capability arrive separately. Also allow a short
        // reconnect after wake before deciding that the phone must speak instead.
        if status != .connected { resume() }
        for _ in 0..<60 {
            if status == .connected, voiceAvailabilityKnown { break }
            guard wanted, !Task.isCancelled else { return nil }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
        }
        guard !Task.isCancelled else { return nil }
        guard status == .connected, naturalVoiceAvailable else {
            voiceFailure = status == .connected ? "Natural voice isn’t available on the Mac." : "The Mac is unreachable; reconnecting."
            return nil
        }
        let id = UUID().uuidString
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                speechRequests[id] = continuation
                send(.speech(id: id, text: text))
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(80)) // Includes a cold model startup.
                    guard let self, let request = self.speechRequests.removeValue(forKey: id) else { return }
                    self.voiceFailure = "The Mac’s natural voice timed out."
                    request.resume(returning: nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.speechRequests.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
    }

    // MARK: Morning update

    /// The last update the Mac made, kept on the device for the wall and offline.
    private(set) var briefing: Briefing? = BriefingStore.load()

    /// Gathering reads git, pipelines and Outlook on the Mac: allow it a minute.
    func requestBriefing(fresh: Bool = false) async -> Result<Briefing, ExploreFailure> {
        switch await explore(timeout: 75, { .briefing(id: $0, fresh: fresh) }) {
        case .briefing(_, let briefing)?: .success(briefing)
        case .result(_, _, let message)?: .failure(.init(message: message))
        default: .failure(.unreachable(status))
        }
    }

    /// Asks the Mac to open a reply in Outlook; returns what to say. Nothing is sent.
    func replyMail(_ reply: MailReply) async -> String {
        switch await explore(timeout: 60, { .replyMail(id: $0, who: reply.who, says: reply.says) }) {
        case .result(_, _, let message)?: message
        default: ExploreFailure.unreachable(status).message
        }
    }

    // MARK: Exploring

    /// What a project has to read and look at. Nil when the Mac can't be reached in time.
    func library(of project: String) async -> Result<CompanionLibrary, ExploreFailure> {
        switch await explore(timeout: 30, { .library(id: $0, project: project) }) {
        case .library(_, let library)?: .success(library)
        case .result(_, _, let message)?: .failure(.init(message: message))
        default: .failure(.unreachable(status))
        }
    }

    /// One page drawn by the Mac. The Map can take a while on a big project.
    func page(_ request: CompanionPageRequest, project: String) async -> Result<CompanionPage, ExploreFailure> {
        switch await explore(timeout: request.path.hasPrefix("dante:") ? 120 : 45, { .page(id: $0, project: project, request: request) }) {
        case .page(_, let page)?: .success(page)
        case .result(_, _, let message)?: .failure(.init(message: message))
        default: .failure(.unreachable(status))
        }
    }

    struct ExploreFailure: Error, Equatable {
        var message: String

        static func unreachable(_ status: Status) -> ExploreFailure {
            ExploreFailure(message: status == .connected ? "The Mac didn’t answer. Is Dante up to date there?" : "Not connected to your Mac.")
        }
    }

    private func explore(timeout: Double, _ message: (String) -> ClientMessage) async -> ServerMessage? {
        guard status == .connected else { return nil }
        let id = UUID().uuidString
        let outgoing = message(id)
        return await withCheckedContinuation { continuation in
            exploreRequests[id] = continuation
            send(outgoing)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.exploreRequests.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
    }

    func ask(_ text: String, project: String, job: String? = nil, spoken: Bool) {
        send(.ask(id: UUID().uuidString, project: project, job: job, text: text, spoken: spoken))
    }

    func answer(_ approval: CompanionSnapshot.Approval, project: String, allow: Bool, note: String? = nil, answers: [String: String]? = nil) {
        send(.answer(id: UUID().uuidString, project: project, approval: approval.id, allow: allow, note: note, answers: answers))
    }

    /// Answers a step from a notification: the app may have just been woken, so it reconnects
    /// first, then checks the step still waits. Returns what happened, to say if it didn't work.
    func answerWhenConnected(approval id: String, project: String, allow: Bool) async -> (ok: Bool, message: String) {
        let started = Date()
        resume()
        // A stale socket only shows itself when its ping fails: give that a moment.
        try? await Task.sleep(for: .milliseconds(400))
        while status != .connected || pingID != nil {
            guard wanted, Date().timeIntervalSince(started) < 12 else {
                return (false, "Couldn’t reach \(pairing?.name ?? "your Mac") to answer. Open Dante to try again.")
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard let approval = snapshot?.projects.first(where: { $0.id == project })?.approvals.first(where: { $0.id == id }) else {
            return (false, "That step was already answered.")
        }
        switch await explore(timeout: 10, { .answer(id: $0, project: project, approval: approval.id, allow: allow, note: nil, answers: nil) }) {
        case .result(_, let ok, let message)?: return (ok, message)
        case nil: return (false, "\(pairing?.name ?? "Your Mac") didn’t confirm the answer. Open Dante to check.")
        default: return (true, "")
        }
    }

    func startJob(_ brief: String, project: String, awayMinutes: Int?) {
        send(.startJob(id: UUID().uuidString, project: project, brief: brief, awayMinutes: awayMinutes))
    }

    func setApprovals(_ mode: CompanionApprovalMode, project: String) {
        guard status == .connected else {
            onResult(false, "I can change that once we’re connected to your Mac.")
            return
        }
        let id = UUID().uuidString
        approvalRequests[id] = mode
        send(.setApprovals(id: id, project: project, mode: mode))
    }

    /// The Mac's screen as a JPEG, while Hands is on there.
    func screen() async -> Data? {
        if case .screen(_, let image)? = await explore(timeout: 8, { .screen(id: $0) }) { return image }
        return nil
    }

    /// Hands' kill switch on the Mac.
    func stopHands() {
        send(.stopHands(id: UUID().uuidString))
    }

    func openProject(_ project: String) {
        send(.openProject(id: UUID().uuidString, project: project))
    }

    func stop(project: String, job: String? = nil) {
        send(.stop(id: UUID().uuidString, project: project, job: job))
    }
}

/// The last morning update, in Caches.
enum BriefingStore {
    static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "briefing.json")
    }

    static func load() -> Briefing? {
        (try? Data(contentsOf: url)).flatMap { CompanionCoding.decode(Briefing.self, from: $0) }
    }

    static func save(_ briefing: Briefing) {
        try? CompanionCoding.encode(briefing).write(to: url, options: .atomic)
    }
}
