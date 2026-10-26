import SwiftUI

/// Dante on the iPhone and iPad (docs/plans/walk-and-work.md): the voice in your ear on a
/// walk, and the agents' waiting steps, jobs and replies at a glance. The Mac does the work.
@main
struct CompanionApp: App {
    @State private var connection: CompanionConnection
    @State private var voice: VoiceLoop
    @State private var explorer: Explorer
    @State private var notices: Notices
    @State private var glance: LiveGlance
    /// A pairing link opened while already paired, waiting to be confirmed.
    @State private var offered: CompanionPairing?
    @Environment(\.scenePhase) private var phase

    init() {
        let connection = CompanionConnection()
        _connection = State(initialValue: connection)
        _voice = State(initialValue: VoiceLoop(connection: connection))
        _explorer = State(initialValue: Explorer(connection: connection))
        _notices = State(initialValue: Notices(connection: connection))
        _glance = State(initialValue: LiveGlance(connection: connection))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if connection.pairing == nil {
                    PairView(connection: connection)
                } else if UIDevice.current.userInterfaceIdiom == .pad {
                    PadRoot(connection: connection, voice: voice, explorer: explorer)
                } else {
                    PhoneHome(connection: connection, voice: voice, explorer: explorer)
                }
            }
            .tint(Palette.accent)
            .task {
                // A tapped notification opens its project.
                notices.onOpen = { project in voice.focus = project }
                #if DEBUG
                // Simulator testing of the Lock Screen: a made-up waiting step as a Live Activity
                // and a notification, with no Mac (`SIMCTL_CHILD_DANTE_GLANCE_DEMO=1`).
                if ProcessInfo.processInfo.environment["DANTE_GLANCE_DEMO"] == "1" {
                    let demo = CompanionSnapshot(server: "Studio", projects: [
                        .init(id: "/home/me/shop", name: "shop", lead: "Claude", working: true, lastReply: "", jobs: [], approvals: [
                            .init(id: "demo", job: nil, from: "Main conversation", title: "Run go test ./...", detail: "go test ./..."),
                        ]),
                    ])
                    glance.update(CompanionGlance.make(demo, connected: true), server: demo.server)
                    await notices.demo(demo)
                }
                // Simulator testing: `SIMCTL_CHILD_DANTE_PAIR_LINK=<link> xcrun simctl launch …`
                // (an unsigned build can't keep the pairing in the Keychain).
                if let link = ProcessInfo.processInfo.environment["DANTE_PAIR_LINK"], let url = URL(string: link),
                   let pairing = CompanionPairing(url: url) {
                    connection.connect(pairing)
                    return
                }
                #endif
                if let pairing = PairingStore.load() { connection.connect(pairing) }
            }
            // The Camera app hands the scanned code over as a link. Unpaired, it pairs at once;
            // paired, it asks first, so a stray link can't move the phone to another Mac.
            .onOpenURL { url in
                guard let pairing = CompanionPairing(url: url) else { return }
                if connection.pairing == nil { connection.pair(with: pairing) } else { offered = pairing }
            }
            .alert("Pair with \(offered?.name ?? "this Mac")?", isPresented: Binding(get: { offered != nil }, set: { if !$0 { offered = nil } })) {
                Button("Pair") {
                    if let offered { connection.pair(with: offered) }
                    offered = nil
                }
                Button("Cancel", role: .cancel) { offered = nil }
            } message: {
                Text("This phone will stop talking to the Mac it's paired with now.")
            }
            .onChange(of: phase) { _, phase in
                if phase == .active {
                    connection.resume()
                    voice.resumeWalking()
                }
            }
            .onChange(of: connection.pairing == nil) { _, unpaired in
                if unpaired { glance.endNow() }
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
