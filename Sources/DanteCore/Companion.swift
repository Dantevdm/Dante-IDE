import CryptoKit
import Foundation

/// What the Mac and the companion app (iPhone and iPad) say to each other over a WebSocket
/// on the tailnet (docs/plans/walk-and-work.md, Devices). The Mac sends a challenge, the
/// device proves it holds the pairing key without sending it, and from then on the Mac sends
/// snapshots of every project's conversations, jobs and waiting approvals, and the device
/// sends messages, answers and new jobs. Builds for macOS and iOS: Foundation and CryptoKit only.
public enum Companion {
    public static let version = 1
    /// Fixed, so the QR code stays valid across launches.
    public static let defaultPort: UInt16 = 47823
}

// MARK: Pairing

/// What the QR code carries: where the Mac listens, its name and the shared key.
/// `dante-companion://pair?v=1&host=100.101.102.103&port=47823&name=Studio&key=…`
public struct CompanionPairing: Codable, Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var name: String
    public var key: String

    public init(host: String, port: UInt16, name: String, key: String) {
        self.host = host
        self.port = port
        self.name = name
        self.key = key
    }

    public static let scheme = "dante-companion"

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: "\(Companion.version)"),
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: "\(port)"),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "key", value: key),
        ]
        return components.url!
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        guard let host = value("host"), let port = value("port").flatMap(UInt16.init), port > 0,
              let key = value("key"), Data(base64URL: key)?.count == 32 else { return nil }
        self.init(host: host, port: port, name: value("name") ?? host, key: key)
    }

    /// Where the device connects.
    public var socketURL: URL {
        let shown = host.contains(":") ? "[\(host)]" : host
        return URL(string: "ws://\(shown):\(port)/companion")!
    }

    /// 32 random bytes, base64url.
    public static func newKey() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64URL
    }
}

// MARK: Proof

/// The key never crosses the wire: the Mac sends a fresh nonce and the device answers with
/// HMAC-SHA256(key, nonce).
public enum CompanionAuth {
    public static func nonce() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64URL
    }

    public static func proof(key: String, nonce: String) -> String {
        guard let secret = Data(base64URL: key) else { return "" }
        let code = HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: SymmetricKey(data: secret))
        return Data(code).base64URL
    }

    /// Compared in constant time (CryptoKit's `isValidAuthenticationCode`).
    public static func verify(_ proof: String, key: String, nonce: String) -> Bool {
        guard let secret = Data(base64URL: key), let code = Data(base64URL: proof), code.count == 32 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: Data(nonce.utf8), using: SymmetricKey(data: secret))
    }
}

// MARK: Address

public enum CompanionAddress {
    /// Tailscale gives each device an address in 100.64.0.0/10 (the carrier-grade NAT range).
    public static func isTailnet(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// The Mac's tailnet address among its interfaces' addresses, if Tailscale is up.
    public static func tailnet(among addresses: [String]) -> String? {
        addresses.first(where: isTailnet)
    }
}

// MARK: Messages

/// The same approval choices as the Mac, scoped to the selected main conversation.
public enum CompanionApprovalMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask, edits, everything
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ask: "Ask me"
        case .edits: "Auto-edit"
        case .everything: "Auto-approve"
        }
    }
}

/// From the Mac.
public enum ServerMessage: Codable, Equatable, Sendable {
    /// First, on every connection.
    case challenge(nonce: String, server: String, version: Int)
    /// The proof was right; everything as it is now.
    case welcome(snapshot: CompanionSnapshot)
    /// The proof was wrong, or the versions don't match. The Mac closes the connection.
    case refused(reason: String)
    /// Whenever anything shown changed.
    case snapshot(snapshot: CompanionSnapshot)
    /// What became of a request (`ClientMessage`'s id).
    case result(id: String, ok: Bool, message: String)
    /// Optional capability: older companions can ignore it.
    case voiceAvailable(available: Bool)
    /// A short WAV utterance, or nil when the device should use its system voice.
    case speech(id: String, audio: Data?)
}

/// From the device.
public enum ClientMessage: Codable, Equatable, Sendable {
    case hello(device: String, proof: String, version: Int)
    /// A message to a project's main conversation, or to one of its jobs. `spoken` asks for a
    /// reply fit for the ear: short, no code.
    case ask(id: String, project: String, job: String?, text: String, spoken: Bool)
    /// Approves or declines a waiting step (`CompanionSnapshot.Approval.id`); a question is
    /// answered with `answers`, keyed by question.
    case answer(id: String, project: String, approval: String, allow: Bool, note: String?, answers: [String: String]?)
    case startJob(id: String, project: String, brief: String, awayMinutes: Int?)
    /// Stops the conversation's current turn.
    case stop(id: String, project: String, job: String?)
    case speech(id: String, text: String)
    case setApprovals(id: String, project: String, mode: CompanionApprovalMode)
    /// Open one of the Mac's recent projects (`CompanionSnapshot.recent`) in a window.
    case openProject(id: String, project: String)

    public var id: String? {
        switch self {
        case .hello: nil
        case .ask(let id, _, _, _, _), .answer(let id, _, _, _, _, _), .startJob(let id, _, _, _), .stop(let id, _, _), .speech(let id, _), .setApprovals(let id, _, _), .openProject(let id, _): id
        }
    }
}

/// Everything the device shows: each open project with its main conversation, its jobs and
/// what's waiting for an answer.
public struct CompanionSnapshot: Codable, Equatable, Sendable {
    public var server: String
    public var projects: [Project]
    /// Projects opened lately on the Mac but not open now, most recent first: the device can
    /// open one, and a message for one opens it first. Nil from a Mac before this existed.
    public var recent: [Recent]?

    public init(server: String, projects: [Project], recent: [Recent]? = nil) {
        self.server = server
        self.projects = projects
        self.recent = recent
    }

    public struct Recent: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// Where a message goes when no project is chosen: the chosen open one, else the first open
    /// one, else the most recent project, which the Mac opens first.
    public func target(focus: String?) -> (id: String, name: String, isOpen: Bool)? {
        if let project = projects.first(where: { $0.id == focus }) ?? projects.first { return (project.id, project.name, true) }
        if let recent = recent?.first(where: { $0.id == focus }) ?? recent?.first { return (recent.id, recent.name, false) }
        return nil
    }

    public var waiting: Int { projects.reduce(0) { $0 + $1.approvals.count } }

    public struct Project: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        /// "Claude" or "Codex".
        public var lead: String
        public var working: Bool
        /// The main conversation's latest reply.
        public var lastReply: String
        public var jobs: [Job]
        public var approvals: [Approval]
        public var approvalMode: CompanionApprovalMode?

        public init(id: String, name: String, lead: String, working: Bool, lastReply: String, jobs: [Job], approvals: [Approval], approvalMode: CompanionApprovalMode? = nil) {
            self.id = id
            self.name = name
            self.lead = lead
            self.working = working
            self.lastReply = lastReply
            self.jobs = jobs
            self.approvals = approvals
            self.approvalMode = approvalMode
        }
    }

    public struct Job: Codable, Equatable, Sendable, Identifiable {
        public enum State: String, Codable, Sendable {
            case starting, working, waiting, asking, ready, paused, failed, merged, discarded
        }

        public var id: String
        public var title: String
        public var state: State
        /// "Working", "2 waiting", "Failed: …".
        public var label: String
        public var lastReply: String
        /// "Away · 23 min left", when away.
        public var away: String?

        public init(id: String, title: String, state: State, label: String, lastReply: String, away: String? = nil) {
            self.id = id
            self.title = title
            self.state = state
            self.label = label
            self.lastReply = lastReply
            self.away = away
        }
    }

    public struct Approval: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        /// The job it came from, nil for the main conversation.
        public var job: String?
        /// The job's title or "Main conversation".
        public var from: String
        /// "Edit Mailer.swift", "Run go test ./...".
        public var title: String
        /// The diff, the command or the plan, cut to `detailLimit` characters.
        public var detail: String
        public var questions: [Question]
        /// A rule or the security scan flagged it.
        public var note: String?

        public static let detailLimit = 4000

        public init(id: String, job: String?, from: String, title: String, detail: String, questions: [Question] = [], note: String? = nil) {
            self.id = id
            self.job = job
            self.from = from
            self.title = title
            self.detail = detail.count > Self.detailLimit ? String(detail.prefix(Self.detailLimit)) + "\n…" : detail
            self.questions = questions
            self.note = note
        }
    }

    public struct Question: Codable, Equatable, Sendable {
        public var question: String
        public var options: [String]

        public init(question: String, options: [String]) {
            self.question = question
            self.options = options
        }
    }
}

// MARK: Coding

public enum CompanionCoding {
    public static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

extension Data {
    public var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }
}
