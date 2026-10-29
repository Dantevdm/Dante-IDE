import Network
import SwiftUI

/// Careful with mobile data. On a cellular connection, a personal hotspot or with Low Data
/// Mode on, the heavy things wait to be asked for: the Mac's live screen, pictures (diagrams,
/// images, PDF pages) that aren't kept on the device yet, and the Mac's natural voice (the
/// device's own voice speaks instead). Places refresh every five minutes instead of every
/// minute. Text, approvals and the update still flow as they are small. "Always load" turns
/// the asking off.
@MainActor @Observable
final class DataSaver {
    static let shared = DataSaver()

    enum Policy: String, CaseIterable, Identifiable {
        case ask, always
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ask: "Ask before heavy things"
            case .always: "Always load everything"
            }
        }
    }

    /// Cellular or a hotspot.
    private(set) var expensive = false
    /// Low Data Mode.
    private(set) var constrained = false
    /// Received on mobile data since the app started.
    private(set) var usedOnMobile = 0
    /// The live screen was asked for on mobile data this session.
    var screenApproved = false
    /// Pictures were asked for on mobile data this session.
    var picturesApproved = false
    var policy: Policy {
        didSet { UserDefaults.standard.set(policy.rawValue, forKey: "dataPolicy") }
    }

    private let monitor = NWPathMonitor()

    private init() {
        policy = UserDefaults.standard.string(forKey: "dataPolicy").flatMap(Policy.init) ?? .ask
        monitor.pathUpdateHandler = Self.onPath(self)
        monitor.start(queue: DispatchQueue(label: "dante.data-saver"))
        #if DEBUG
        // Simulator testing of the prompts (`DANTE_MOBILE_DATA=1`).
        if ProcessInfo.processInfo.environment["DANTE_MOBILE_DATA"] == "1" { expensive = true }
        #endif
    }

    /// Made off the main actor: Network calls it on its own queue.
    nonisolated private static func onPath(_ saver: DataSaver) -> @Sendable (NWPath) -> Void {
        { [weak saver] path in
            let expensive = path.isExpensive, constrained = path.isConstrained
            Task { @MainActor in
                #if DEBUG
                if ProcessInfo.processInfo.environment["DANTE_MOBILE_DATA"] == "1" { return }
                #endif
                saver?.expensive = expensive
                saver?.constrained = constrained
            }
        }
    }

    var onMobileData: Bool { expensive || constrained }
    /// Heavy things wait for a tap.
    var asksFirst: Bool { onMobileData && policy == .ask }
    var holdsScreen: Bool { asksFirst && !screenApproved }
    var holdsPictures: Bool { asksFirst && !picturesApproved }

    func count(_ bytes: Int) {
        if expensive { usedOnMobile += bytes }
    }

    var usedText: String {
        ByteCountFormatter.string(fromByteCount: Int64(usedOnMobile), countStyle: .file)
    }
}

/// What waits for a tap on mobile data: a sentence on what it costs and a button.
struct DataPrompt: View {
    let what: String
    let cost: String
    let load: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right").font(.title2).foregroundStyle(Palette.amber)
            Text("You’re on mobile data").font(.headline).foregroundStyle(Palette.text)
            Text("\(what) \(cost)").font(.subheadline).foregroundStyle(Palette.text2).multilineTextAlignment(.center)
            Button("Load it", action: load).buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(maxWidth: 360)
    }
}
