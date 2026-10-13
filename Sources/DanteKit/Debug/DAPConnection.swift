import Foundation
import Network

/// A running debug adapter and the channel to it: its stdin and stdout, or a TCP connection
/// to the address it announces. Messages use the same Content-Length framing as LSP.
@MainActor
final class DAPConnection {
    struct StartError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// A whole DAP message from the adapter.
    var onMessage: ((JSONValue) -> Void)?
    /// A line the adapter (or, over TCP, the program) printed outside the protocol.
    var onText: ((String, _ isError: Bool) -> Void)?
    /// The channel closed; the adapter's last error output, if any.
    var onClose: ((String?) -> Void)?

    private let process = Process()
    private var input: FileHandle?
    private var socket: NWConnection?
    private var decoder = LSPFraming.Decoder()
    private var errorTail: [String] = []
    private var closed = false

    /// Starts the adapter and, for a TCP adapter, waits for its address and connects.
    static func open(_ adapter: DebugAdapter, executable: URL, root: URL, environment: [String: String]) async throws -> DAPConnection {
        let connection = DAPConnection()
        try await connection.start(adapter, executable: executable, root: root, environment: environment)
        return connection
    }

    private func start(_ adapter: DebugAdapter, executable: URL, root: URL, environment: [String: String]) async throws {
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable
        process.arguments = Array(adapter.command.dropFirst())
        process.currentDirectoryURL = root
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let (bytes, bytesContinuation) = AsyncStream.makeStream(of: Data.self)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; bytesContinuation.finish() } else { bytesContinuation.yield(data) }
        }
        let (errors, errorsContinuation) = AsyncStream.makeStream(of: Data.self)
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; errorsContinuation.finish() } else { errorsContinuation.yield(data) }
        }
        process.terminationHandler = { _ in
            bytesContinuation.finish()
            errorsContinuation.finish()
        }
        try process.run()

        Task { [weak self] in
            for await line in Self.lines(errors) {
                guard let self else { return }
                errorTail = Array((errorTail + [line]).suffix(8))
                onText?(line, true)
            }
        }

        switch adapter.transport {
        case .stdio:
            input = stdin.fileHandleForWriting
            Task { [weak self] in
                for await data in bytes { self?.receive(data) }
                self?.closeDown()
            }
        case .announcedTCP:
            let (announced, announcedContinuation) = AsyncStream.makeStream(of: (String, Int).self)
            Task { [weak self] in
                var announcedYet = false
                for await line in Self.lines(bytes) {
                    if !announcedYet, let address = DebugAdapter.announcedAddress(in: line) {
                        announcedYet = true
                        announcedContinuation.yield(address)
                        announcedContinuation.finish()
                    } else {
                        self?.onText?(line, false)
                    }
                }
                announcedContinuation.finish()
            }
            var iterator = announced.makeAsyncIterator()
            guard let (host, port) = await iterator.next(), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                process.terminate()
                throw StartError(message: errorTail.last ?? "\(adapter.name) didn’t start.")
            }
            try await connect(host: host, port: endpointPort)
        }
    }

    private func connect(host: String, port: NWEndpoint.Port) async throws {
        let socket = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        self.socket = socket
        let (states, continuation) = AsyncStream.makeStream(of: NWConnection.State.self)
        socket.stateUpdateHandler = { continuation.yield($0) }
        socket.start(queue: .global(qos: .userInitiated))
        for await state in states {
            switch state {
            case .ready:
                continuation.finish()
                receiveFromSocket()
                return
            case .failed(let error), .waiting(let error):
                continuation.finish()
                throw StartError(message: "Couldn’t connect to the debugger: \(error.localizedDescription)")
            case .cancelled:
                continuation.finish()
                throw StartError(message: "The debugger closed the connection.")
            default:
                continue
            }
        }
    }

    private func receiveFromSocket() {
        socket?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty { self.receive(data) }
                if isComplete || error != nil { self.closeDown() } else { self.receiveFromSocket() }
            }
        }
    }

    /// `DANTE_DAP_TRACE=1` prints every message to stderr, for debugging an adapter.
    private static let traces = ProcessInfo.processInfo.environment["DANTE_DAP_TRACE"] == "1"

    private func receive(_ data: Data) {
        for message in decoder.append(data) {
            if Self.traces { FileHandle.standardError.write(Data("DAP ← \(message.jsonLine)\n".utf8)) }
            onMessage?(message)
        }
    }

    func send(_ message: JSONValue) {
        if Self.traces { FileHandle.standardError.write(Data("DAP → \(message.jsonLine)\n".utf8)) }
        let data = LSPFraming.encode(message)
        if let socket {
            socket.send(content: data, completion: .contentProcessed { _ in })
        } else {
            try? input?.write(contentsOf: data)
        }
    }

    /// Ends the channel and the adapter.
    func close() {
        socket?.cancel()
        try? input?.close()
        if process.isRunning { process.terminate() }
        closeDown()
    }

    private func closeDown() {
        guard !closed else { return }
        closed = true
        onClose?(errorTail.isEmpty ? nil : errorTail.joined(separator: "\n"))
    }

    /// Text lines from a byte stream, split on newlines.
    private nonisolated static func lines(_ bytes: AsyncStream<Data>) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                var pending = Data()
                for await chunk in bytes {
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                        pending.removeSubrange(pending.startIndex...newline)
                        pending = Data(pending)
                        continuation.yield(line.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
                    }
                }
                if !pending.isEmpty { continuation.yield(String(decoding: pending, as: UTF8.self)) }
                continuation.finish()
            }
        }
    }
}
