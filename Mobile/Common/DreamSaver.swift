import SwiftUI
import UIKit

/// Which scene the splash and the screensaver show, and when the screensaver comes on.
/// Shuffle picks a different one each time; the screensaver also changes scene every half hour.
@MainActor @Observable
final class Dreams {
    static let shared = Dreams()

    /// A dream, or nil to shuffle.
    var splash: Dream? {
        didSet { UserDefaults.standard.set(splash?.rawValue ?? "shuffle", forKey: "splashDream") }
    }
    var screensaver: Dream? {
        didSet { UserDefaults.standard.set(screensaver?.rawValue ?? "shuffle", forKey: "screensaverDream") }
    }
    /// Minutes without a touch before the screensaver; 0 for never.
    var idleMinutes: Int {
        didSet { UserDefaults.standard.set(idleMinutes, forKey: "screensaverMinutes") }
    }
    /// Comes on over the Wall too, which otherwise stays as it is.
    var overWall: Bool {
        didSet { UserDefaults.standard.set(overWall, forKey: "screensaverOverWall") }
    }
    /// Set by the Wall while it's on screen.
    var wallShowing = false
    /// What the Mac did since the screensaver came on, for its "while you were away" list.
    private(set) var noted: [CompanionTicker.Noted] = []

    func note(_ events: [CompanionForeman.Event]) {
        guard !events.isEmpty else { return }
        noted = Array((noted + events.map { CompanionTicker.Noted($0, at: .now) }).suffix(CompanionTicker.maxNoted))
    }

    func forgetNoted() { noted = [] }

    static let idleChoices = [0, 2, 5, 10, 15, 30]

    private init() {
        let defaults = UserDefaults.standard
        splash = defaults.string(forKey: "splashDream").flatMap(Dream.init)
        screensaver = defaults.string(forKey: "screensaverDream").flatMap(Dream.init)
        idleMinutes = defaults.object(forKey: "screensaverMinutes") as? Int ?? 5
        overWall = defaults.bool(forKey: "screensaverOverWall")
    }

    /// The splash's scene this launch: the chosen one, or a different one from last time.
    func splashDream() -> Dream {
        #if DEBUG
        if let forced = ProcessInfo.processInfo.environment["DANTE_SPLASH"].flatMap(Dream.init) { return forced }
        #endif
        if let splash { return splash }
        return Self.shuffle(after: UserDefaults.standard.string(forKey: "lastSplashDream").flatMap(Dream.init), key: "lastSplashDream")
    }

    func screensaverDream(after last: Dream? = nil) -> Dream {
        screensaver ?? Self.shuffle(after: last, key: nil)
    }

    private static func shuffle(after last: Dream?, key: String?) -> Dream {
        let pick = Dream.allCases.filter { $0 != last }.randomElement() ?? .garden
        if let key { UserDefaults.standard.set(pick.rawValue, forKey: key) }
        return pick
    }

    static func idleTitle(_ minutes: Int) -> String { minutes == 0 ? "Never" : "\(minutes) min" }
}

/// Watches for touches anywhere in the app's window and puts the screensaver up in a window of
/// its own (above sheets and alerts) once nothing has touched it for a while. A touch, or a
/// step that starts waiting for an answer, takes it down. While the device charges the app
/// keeps the screen on, so the screensaver gets its turn; on battery the device's own
/// Auto-Lock still wins.
@MainActor
final class IdleWatcher: NSObject, UIGestureRecognizerDelegate {
    static let shared = IdleWatcher()

    private var lastTouch = Date.now
    private weak var watched: UIWindow?
    private var saver: UIWindow?
    private var loop: Task<Void, Never>?
    private var connection: CompanionConnection?
    private var waitingSeen = 0

    func watch(_ window: UIWindow, connection: CompanionConnection) {
        if self.connection !== connection {
            // Only what happens while the screensaver is up goes on its list.
            connection.observers.append { [weak self] _, _, events in
                guard self?.saver != nil else { return }
                Dreams.shared.note(events)
            }
        }
        self.connection = connection
        guard watched !== window else { return }
        watched = window
        let recogniser = TouchSpotter { [weak self] in self?.touched() }
        recogniser.delegate = self
        window.addGestureRecognizer(recogniser)
        UIDevice.current.isBatteryMonitoringEnabled = true
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.check()
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["DANTE_SCREENSAVER"] != nil {
            Task {
                try? await Task.sleep(for: .seconds(1))
                self.show()
                // With the demo data, something to say for "while you were away".
                if let project = connection.snapshot?.projects.first {
                    Dreams.shared.note([.replied(project: project.id, job: nil, text: "The order export now streams rows, so big shops stay fast. Tests pass.")])
                    if let job = project.jobs.first { Dreams.shared.note([.jobChanged(project: project.id, job)]) }
                }
            }
        }
        #endif
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    private func touched() {
        lastTouch = .now
        if saver != nil { hide() }
    }

    private var waitingCount: Int {
        connection?.snapshot?.projects.reduce(0) { $0 + $1.approvals.count } ?? 0
    }

    private func check() {
        let dreams = Dreams.shared
        let charging = [.charging, .full].contains(UIDevice.current.batteryState)
        // Keep the screen on while charging (or on the Wall), so there's time to dream.
        let keepAwake = dreams.wallShowing || (charging && dreams.idleMinutes > 0)
        if UIApplication.shared.isIdleTimerDisabled != keepAwake { UIApplication.shared.isIdleTimerDisabled = keepAwake }

        let waiting = waitingCount
        defer { waitingSeen = waiting }
        if saver != nil {
            if waiting > waitingSeen { hide() }
            return
        }
        guard dreams.idleMinutes > 0, !dreams.wallShowing || dreams.overWall,
              UIApplication.shared.applicationState == .active,
              Date.now.timeIntervalSince(lastTouch) >= Double(dreams.idleMinutes) * 60 else { return }
        show()
    }

    private func show() {
        guard saver == nil, let scene = watched?.windowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        Dreams.shared.forgetNoted()
        guard let connection else { return }
        let host = UIHostingController(rootView: DreamSaverView(dream: Dreams.shared.screensaverDream(), connection: connection) { [weak self] in self?.touched() })
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.alpha = 0
        window.isHidden = false
        saver = window
        UIView.animate(withDuration: 2.5) { window.alpha = 1 }
    }

    private func hide() {
        guard let window = saver else { return }
        saver = nil
        lastTouch = .now
        UIView.animate(withDuration: 0.6, animations: { window.alpha = 0 }) { _ in window.isHidden = true }
    }
}

/// Sees every touch without taking it: it fails as soon as a touch begins.
private final class TouchSpotter: UIGestureRecognizer {
    let spotted: @MainActor () -> Void

    init(_ spotted: @escaping @MainActor () -> Void) {
        self.spotted = spotted
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        spotted()
        state = .failed
    }
}

/// Finds the window the app's views are in, for `IdleWatcher`.
struct IdleWatching: UIViewRepresentable {
    let connection: CompanionConnection

    func makeUIView(context: Context) -> Probe { Probe(connection: connection) }
    func updateUIView(_ view: Probe, context: Context) {}

    final class Probe: UIView {
        let connection: CompanionConnection
        init(connection: CompanionConnection) {
            self.connection = connection
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError() }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { IdleWatcher.shared.watch(window, connection: connection) }
        }
    }
}

/// The screensaver: a scene drawing itself over ten minutes, the time in a corner, and a new
/// scene every half hour when shuffling. The time drifts a little so nothing sits still.
struct DreamSaverView: View {
    @State var dream: Dream
    let connection: CompanionConnection
    let dismiss: () -> Void
    @State private var started = Date.now

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            DreamCanvas(dream: dream, start: started, build: 600)
                .id(dream)
                .transition(.opacity)
            TimelineView(.everyMinute) { context in
                let drift = Double(Calendar.current.component(.minute, from: context.date))
                let night = DreamSky.forced ?? DreamSky.night(at: context.date)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 64, weight: .thin, design: .rounded))
                    Text(context.date, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.title3.weight(.medium))
                    Text(dream.title).font(.footnote).opacity(0.6)
                }
                .foregroundStyle(night > 0.5 ? Color.white.opacity(0.85) : Color.black.opacity(0.7))
                .shadow(color: (night > 0.5 ? Color.black : Color.white).opacity(0.35), radius: 8)
                .padding(.leading, 40 + sin(drift / 9) * 18)
                .padding(.bottom, 40 + cos(drift / 7) * 14)
            }
            TickerCard(ticker: CompanionTicker.make(connection.snapshot, connected: connection.status == .connected, noted: Dreams.shared.noted))
                .frame(maxWidth: 420)
                .environment(\.colorScheme, (DreamSky.forced ?? DreamSky.night(at: .now)) > 0.5 ? .dark : .light)
                .padding(36)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task {
            guard Dreams.shared.screensaver == nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30 * 60))
                withAnimation(.easeInOut(duration: 4)) {
                    dream = Dreams.shared.screensaverDream(after: dream)
                    started = .now
                }
            }
        }
        #if DEBUG
        .onAppear {
            if let forced = ProcessInfo.processInfo.environment["DANTE_SCREENSAVER"].flatMap(Dream.init) {
                dream = forced
                // A number after the name starts it that many seconds into its build: `city:400`.
            }
            if let raw = ProcessInfo.processInfo.environment["DANTE_SCREENSAVER"], let colon = raw.firstIndex(of: ":"),
               let name = Dream(rawValue: String(raw[..<colon])), let seconds = Double(raw[raw.index(after: colon)...]) {
                dream = name
                started = .now.addingTimeInterval(-seconds)
            }
        }
        #endif
    }
}

/// The Mac at a glance over a scene: what's going on now, and what happened while you were
/// away, on frosted glass so it reads by day and night.
struct TickerCard: View {
    let ticker: CompanionTicker
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            ForEach(ticker.now) { row($0) }
            if !ticker.since.isEmpty, !compact {
                Text("While you were away").font(.caption.weight(.semibold)).textCase(.uppercase)
                    .foregroundStyle(.secondary).padding(.top, 4)
                ForEach(ticker.since) { row($0) }
            }
        }
        .padding(compact ? 12 : 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.spring(duration: 0.6), value: ticker)
    }

    private func row(_ line: CompanionTicker.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol(line.kind)).foregroundStyle(tint(line.kind))
                .symbolEffect(.pulse, isActive: line.kind == .working)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(line.title).font((compact ? Font.subheadline : .body).weight(.medium)).lineLimit(1)
                    if let at = line.at {
                        Spacer(minLength: 6)
                        Text(at, style: .relative).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if let detail = line.detail, !detail.isEmpty, !compact {
                    Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func symbol(_ kind: CompanionTicker.Line.Kind) -> String {
        switch kind {
        case .working: "circle.dotted.circle"
        case .waiting: "hand.raised.fill"
        case .done: "checkmark.circle.fill"
        case .trouble: "exclamationmark.triangle.fill"
        case .quiet: "moon.zzz.fill"
        }
    }

    private func tint(_ kind: CompanionTicker.Line.Kind) -> Color {
        switch kind {
        case .working: .blue
        case .waiting: .orange
        case .done: .green
        case .trouble: .red
        case .quiet: .secondary
        }
    }
}
