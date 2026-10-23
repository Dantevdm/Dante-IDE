import DanteCore
import Foundation
import Network

/// The Mac's end of the companion connection: a WebSocket listener on the tailnet address only
/// (`CompanionAddress`), which challenges every connection, accepts devices that prove they
/// hold the pairing key, sends them the latest `CompanionSnapshot` whenever it changes, and
/// hands their messages to `onMessage`. Everything runs on one serial queue; the callbacks
/// are called there, so the app hops to the main actor itself.
public final class CompanionServer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case listening(host: String, port: UInt16)
        case failed(String)
    }

    /// A device that proved itself, for the Settings list.
    public struct Device: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var since: Date
    }

    /// Only touched on `queue`.
    private final class Client: @unchecked Sendable {
        let id = UUID().uuidString
        let connection: NWConnection
        let nonce = CompanionAuth.nonce()
        var device: String?
        var since = Date()
        var lastReceived = ContinuousClock.now
        init(_ connection: NWConnection) { self.connection = connection }
    }

    public static let maximumClients = 8
    /// A connection that hasn't proved itself by then is closed.
    public static let helloTimeout: TimeInterval = 10

    private let queue = DispatchQueue(label: "dev.dante.ide.companion")
    private let key: String
    private let name: String
    private let host: String
    private let port: UInt16
    private var listener: NWListener?
    private var clients: [String: Client] = [:]
    private var latest: CompanionSnapshot
    private var naturalVoiceAvailable = false
    private var heartbeat: DispatchSourceTimer?
    private let heartbeatInterval: TimeInterval
    private let heartbeatTimeout: TimeInterval
    private let onState: @Sendable (State) -> Void
    private let onDevices: @Sendable ([Device]) -> Void
    private let onMessage: @Sendable (_ device: String, ClientMessage) -> Void

    /// `port` 0 picks a free one (tests); the app passes `Companion.defaultPort`.
    public init(host: String, port: UInt16, name: String, key: String,
                onState: @escaping @Sendable (State) -> Void,
                onDevices: @escaping @Sendable ([Device]) -> Void = { _ in },
                onMessage: @escaping @Sendable (_ device: String, ClientMessage) -> Void,
                heartbeatInterval: TimeInterval = 15, heartbeatTimeout: TimeInterval = 45) {
        self.host = host
        self.port = port
        self.name = name
        self.key = key
        self.latest = CompanionSnapshot(server: name, projects: [])
        self.onState = onState
        self.onDevices = onDevices
        self.onMessage = onMessage
        self.heartbeatInterval = max(0.05, heartbeatInterval)
        self.heartbeatTimeout = max(self.heartbeatInterval * 2, heartbeatTimeout)
    }

    public func start() {
        queue.async { self.listen() }
    }

    public func stop() {
        queue.async {
            self.heartbeat?.cancel()
            self.heartbeat = nil
            self.listener?.cancel()
            self.listener = nil
            for client in self.clients.values { client.connection.cancel() }
            self.clients = [:]
            self.onDevices([])
            self.onState(.stopped)
        }
    }

    /// Sends the snapshot to every device when it differs from the last one.
    public func publish(_ snapshot: CompanionSnapshot) {
        queue.async {
            guard snapshot != self.latest else { return }
            self.latest = snapshot
            for client in self.clients.values where client.device != nil {
                self.send(.snapshot(snapshot: snapshot), to: client)
            }
        }
    }

    /// Tells one device what became of its request.
    public func reply(to device: String, id: String, ok: Bool, message: String) {
        queue.async {
            guard let client = self.clients[device], client.device != nil else { return }
            self.send(.result(id: id, ok: ok, message: message), to: client)
        }
    }

    // MARK: Listening

    public func setNaturalVoiceAvailable(_ available: Bool) {
        queue.async {
            guard self.naturalVoiceAvailable != available else { return }
            self.naturalVoiceAvailable = available
            for client in self.clients.values where client.device != nil {
                self.send(.voiceAvailable(available: available), to: client)
            }
        }
    }

    public func speech(to device: String, id: String, audio: Data?) {
        queue.async {
            guard let client = self.clients[device], client.device != nil else { return }
            self.send(.speech(id: id, audio: audio), to: client)
        }
    }

    private func listen() {
        onState(.starting)
        let socket = NWProtocolWebSocket.Options()
        socket.autoReplyPing = true
        socket.maximumMessageSize = 1 << 20
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(socket, at: 0)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch {
            onState(.failed("Couldn’t listen on \(host):\(port): \(error.localizedDescription)"))
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready: self.onState(.listening(host: self.host, port: listener?.port?.rawValue ?? self.port))
            case .failed(let error): self.onState(.failed(Self.explain(error, port: self.port)))
            case .cancelled: break
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler { [weak self] in self?.checkConnections() }
        heartbeat = timer
        timer.resume()
    }

    /// Reap vanished phones so they don't hold the Mac awake indefinitely. WebSocket
    /// control frames need no wire-protocol change and don't create snapshot events.
    private func checkConnections() {
        for client in Array(clients.values) where client.device != nil {
            guard client.lastReceived.duration(to: .now) < .seconds(heartbeatTimeout) else {
                drop(client)
                continue
            }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
            // Network delivers pong acknowledgements here, rather than as normal
            // receiveMessage payloads. Count them as proof the phone is still alive.
            metadata.setPongHandler(queue) { [weak self, weak client] error in
                guard let self, let client, self.clients[client.id] != nil else { return }
                if error != nil { self.drop(client) } else { client.lastReceived = .now }
            }
            let context = NWConnection.ContentContext(identifier: "heartbeat", metadata: [metadata])
            client.connection.send(content: Data(), contentContext: context, isComplete: true,
                                   completion: .contentProcessed { [weak self] error in
                if error != nil { self?.drop(client) }
            })
        }
    }

    private static func explain(_ error: NWError, port: UInt16) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE { return "Port \(port) is in use by another app." }
        if case .posix(let code) = error, code == .EADDRNOTAVAIL { return "That address isn’t this Mac’s any more. Is Tailscale still connected?" }
        return error.localizedDescription
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < Self.maximumClients else {
            connection.cancel()
            return
        }
        let client = Client(connection)
        clients[client.id] = client
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            guard self.clients[client.id] != nil else { return }
            switch state {
            case .ready:
                self.send(.challenge(nonce: client.nonce, server: self.name, version: Companion.version), to: client)
                self.receive(client)
            case .failed, .cancelled:
                self.drop(client)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.helloTimeout) { [weak self] in
            if client.device == nil { self?.refuse(client, "No hello in time.") }
        }
    }

    private func receive(_ client: Client) {
        client.connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            guard self.clients[client.id] != nil else { return }
            if error != nil {
                self.drop(client)
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            client.lastReceived = .now
            if metadata?.opcode == .close {
                self.drop(client)
                return
            }
            if let data, !data.isEmpty, metadata?.opcode == .text || metadata?.opcode == .binary {
                self.handle(data, from: client)
            }
            if self.clients[client.id] != nil { self.receive(client) }
        }
    }

    private func handle(_ data: Data, from client: Client) {
        guard let message = CompanionCoding.decode(ClientMessage.self, from: data) else {
            if client.device == nil { refuse(client, "That isn’t Dante’s companion protocol.") }
            return
        }
        guard client.device != nil else {
            guard case .hello(let device, let proof, let version) = message else {
                refuse(client, "Say hello first.")
                return
            }
            guard version == Companion.version else {
                refuse(client, version < Companion.version ? "Update the companion app." : "Update Dante on the Mac.")
                return
            }
            guard CompanionAuth.verify(proof, key: key, nonce: client.nonce) else {
                refuse(client, "This device isn’t paired with this Mac. Scan the code in Dante’s Settings again.")
                return
            }
            client.device = device.isEmpty ? "Device" : String(device.prefix(60))
            client.since = Date()
            send(.welcome(snapshot: latest), to: client)
            send(.voiceAvailable(available: naturalVoiceAvailable), to: client)
            reportDevices()
            return
        }
        if case .hello = message { return }
        onMessage(client.id, message)
    }

    private func send(_ message: ServerMessage, to client: Client, then: (@Sendable () -> Void)? = nil) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "companion", metadata: [metadata])
        client.connection.send(content: CompanionCoding.encode(message), contentContext: context, isComplete: true,
                               completion: .contentProcessed { _ in then?() })
    }

    private func refuse(_ client: Client, _ reason: String) {
        guard clients[client.id] != nil else { return }
        let connection = client.connection
        send(.refused(reason: reason), to: client) { connection.cancel() }
        clients[client.id] = nil
    }

    private func drop(_ client: Client) {
        guard clients.removeValue(forKey: client.id) != nil else { return }
        client.connection.cancel()
        if client.device != nil { reportDevices() }
    }

    private func reportDevices() {
        onDevices(clients.values.compactMap { client in
            client.device.map { Device(id: client.id, name: $0, since: client.since) }
        }.sorted { $0.since < $1.since })
    }
}

// MARK: Key and address

/// The pairing key, in the Keychain. A new key unpairs every device.
public enum CompanionKey {
    static let service = "dev.dante.ide.companion"
    static let account = "pairing"

    public static func current() -> String {
        if let key = read() { return key }
        return renew()
    }

    @discardableResult
    public static func renew() -> String {
        let key = CompanionPairing.newKey()
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrLabel as String] = "Dante: companion pairing key"
        SecItemAdd(item as CFDictionary, nil)
        return key
    }

    private static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8), Data(base64URL: key)?.count == 32 else { return nil }
        return key
    }
}

extension CompanionAddress {
    /// This Mac's IPv4 addresses, from every interface that's up.
    public static func local() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return [] }
        defer { freeifaddrs(first) }
        var result: [String] = []
        for pointer in sequence(first: start, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }

    /// Where the server listens: `DANTE_COMPANION_HOST` when set (tests, or a LAN at your own
    /// risk), else the tailnet address.
    public static func listening(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let host = environment["DANTE_COMPANION_HOST"], !host.isEmpty { return host }
        return tailnet(among: local())
    }
}
