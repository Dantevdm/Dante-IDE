import DanteKit
import Foundation
import Observation

/// Keeps a window's compose services up while the project is open (`ServiceRecovery`):
/// every 20 seconds it restarts a crashed or long-unhealthy service, a few times at most,
/// and applies a changed compose file to what's running. On by default, per project on this Mac.
@MainActor @Observable
final class ServiceKeeper {
    struct Event: Identifiable, Equatable {
        let id = UUID()
        var date: Date
        var text: String
        var failed = false
    }

    /// What it did, newest last, for the Services page.
    private(set) var events: [Event] = []
    var isOn: Bool {
        didSet { if let key { UserDefaults.standard.set(isOn, forKey: key) } }
    }

    private var root: URL?
    private var key: String?
    private var attempts: [ServiceRecovery.Attempt] = []
    private var unhealthySince: [String: Date] = [:]
    private var gaveUp: Set<String> = []
    private var stoppedByYou: Set<String> = []
    /// The compose file's text when the running services were last brought up to date.
    private var composeText: String?
    private var watcher: Task<Void, Never>?

    init() { isOn = true }

    /// Starts watching a local project; a remote one's services run on its host.
    func watch(_ root: URL?, remote: Bool) {
        watcher?.cancel()
        self.root = root
        events = []
        attempts = []
        unhealthySince = [:]
        gaveUp = []
        stoppedByYou = []
        composeText = nil
        guard let root, !remote else { key = nil; return }
        key = "keepsServicesUp." + root.path
        isOn = UserDefaults.standard.object(forKey: key!) as? Bool ?? true
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self, !Task.isCancelled else { return }
                await self.check()
            }
        }
    }

    /// The project closed: stop watching it.
    func stop() {
        watcher?.cancel()
        watcher = nil
        root = nil
        key = nil
    }

    /// You stopped these from Dante (all of them when empty): leave them down.
    func youStopped(_ services: [String], all: [String]) {
        stoppedByYou.formUnion(services.isEmpty ? all : services)
    }

    /// You started these: watch them again, with a clean slate.
    func youStarted(_ services: [String], all: [String]) {
        let names = Set(services.isEmpty ? all : services)
        stoppedByYou.subtract(names)
        gaveUp.subtract(names)
        attempts.removeAll { names.contains($0.service) }
    }

    func check() async {
        guard isOn, let root, let compose = ComposeFile.load(projectRoot: root) else { return }
        guard case .success(let states) = await ContainerState.load(projectRoot: root) else { return }
        let now = Date()
        for state in states {
            if state.health == "unhealthy" { unhealthySince[state.service] = unhealthySince[state.service] ?? now } else { unhealthySince[state.service] = nil }
        }
        let text = try? String(contentsOf: compose.url, encoding: .utf8)
        let anyRunning = states.contains { $0.state == "running" }
        if composeText == nil || !anyRunning { composeText = text }
        let actions = ServiceRecovery.plan(states: states, services: compose.services.map(\.name), attempts: attempts,
                                           unhealthySince: unhealthySince, stoppedByYou: stoppedByYou, gaveUp: gaveUp,
                                           composeChanged: text != nil && text != composeText, now: now)
        for action in actions {
            switch action {
            case .restart(let service, let reason):
                attempts.append(.init(service: service, date: now))
                guard let command = ServiceRecovery.command(for: action, states: states, stoppedByYou: stoppedByYou) else { continue }
                let result = await Shell.run(command, in: root)
                // A restarted service gets its full grace again before it counts as unhealthy.
                unhealthySince[service] = nil
                note(result.status == 0 ? "Brought \(service) back: \(reason.lowercasedFirst)." : "Couldn’t restart \(service): \(Self.lastLine(result.stderr.isEmpty ? result.stdout : result.stderr))", failed: result.status != 0)
            case .giveUp(let service, let reason):
                gaveUp.insert(service)
                note("Left \(service) down: \(reason.lowercasedFirst). Its logs say why.", failed: true)
            case .apply(let reason):
                composeText = text
                guard let command = ServiceRecovery.command(for: action, states: states, stoppedByYou: stoppedByYou) else { continue }
                let result = await Shell.run(command, in: root)
                note(result.status == 0 ? "\(reason), so the running services were updated to match." : "\(reason), but updating the services failed: \(Self.lastLine(result.stderr.isEmpty ? result.stdout : result.stderr))",
                     failed: result.status != 0)
            }
        }
    }

    private func note(_ text: String, failed: Bool = false) {
        events.append(Event(date: .now, text: text, failed: failed))
        if events.count > 20 { events.removeFirst() }
    }

    private static func lastLine(_ output: String) -> String {
        output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "no output"
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
