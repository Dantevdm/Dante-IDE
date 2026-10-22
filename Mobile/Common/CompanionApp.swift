import SwiftUI

/// Dante on the iPhone and iPad (docs/plans/walk-and-work.md): the voice in your ear on a
/// walk, and the agents' waiting steps, jobs and replies at a glance. The Mac does the work.
@main
struct CompanionApp: App {
    @State private var connection: CompanionConnection
    @State private var voice: VoiceLoop
    @Environment(\.scenePhase) private var phase

    init() {
        let connection = CompanionConnection()
        _connection = State(initialValue: connection)
        _voice = State(initialValue: VoiceLoop(connection: connection))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if connection.pairing == nil {
                    PairView(connection: connection)
                } else {
                    PhoneHome(connection: connection, voice: voice)
                }
            }
            .tint(Palette.accent)
            .task {
                if let pairing = PairingStore.load() { connection.connect(pairing) }
            }
            .onChange(of: phase) { _, phase in
                if phase == .active { connection.resume() }
            }
        }
    }
}

extension CompanionConnection {
    func pair(with pairing: CompanionPairing) {
        PairingStore.save(pairing)
        connect(pairing)
    }

    func unpair() {
        disconnect()
        PairingStore.clear()
        forget()
    }
}
