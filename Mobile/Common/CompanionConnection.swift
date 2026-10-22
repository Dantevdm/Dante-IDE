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

    /// What changed in each new snapshot, for the voice loop.
    @ObservationIgnored var onEvents: ([CompanionForeman.Event], CompanionSnapshot) -> Void = { _, _ in }
    /// What became of a request: ok, and the Mac's sentence.
    @ObservationIgnored var onResult: (Bool, String) -> Void = { _, _ in }

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var attempts = 0
    @ObservationIgnored private var retry: Task<Void, Never>?

    func connect(_ pairing: CompanionPairing) {
        self.pairing = pairing
        wanted = true
        attempts = 0
        open()
    }

    func disconnect() {
        wanted = false
        retry?.cancel()
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
        guard wanted, status != .connected, status != .connecting else { return }
        retry?.cancel()
        open()
    }

    private func open() {
        guard let pairing else { return }
        socket?.cancel(with: .goingAway, reason: nil)
        status = .connecting
        let socket = URLSession.shared.webSocketTask(with: pairing.socketURL)
        socket.maximumMessageSize = 4 << 20
        self.socket = socket
        socket.resume()
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
            self.snapshot = snapshot
        case .snapshot(let next):
            let events = CompanionForeman.events(from: snapshot, to: next)
            snapshot = next
            if !events.isEmpty { onEvents(events, next) }
        case .refused(let reason):
            refuse(reason)
        case .result(_, let ok, let message):
            failure = ok ? nil : message
            onResult(ok, message)
        }
    }

    private func refuse(_ reason: String) {
        wanted = false
        status = .refused(reason)
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func lost() {
        socket = nil
        guard wanted else { return }
        let name = pairing?.name ?? "your Mac"
        status = .offline("Can’t reach \(name). Is Tailscale on here and on the Mac, and is Dante open?")
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
        socket.send(.string(text)) { _ in }
    }

    // MARK: Requests

    func ask(_ text: String, project: String, job: String? = nil, spoken: Bool) {
        send(.ask(id: UUID().uuidString, project: project, job: job, text: text, spoken: spoken))
    }

    func answer(_ approval: CompanionSnapshot.Approval, project: String, allow: Bool, note: String? = nil, answers: [String: String]? = nil) {
        send(.answer(id: UUID().uuidString, project: project, approval: approval.id, allow: allow, note: note, answers: answers))
    }

    func startJob(_ brief: String, project: String, awayMinutes: Int?) {
        send(.startJob(id: UUID().uuidString, project: project, brief: brief, awayMinutes: awayMinutes))
    }

    func stop(project: String, job: String? = nil) {
        send(.stop(id: UUID().uuidString, project: project, job: job))
    }
}
