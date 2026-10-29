import SwiftUI

/// The Mac's screen, live, over everything on the iPad: a small window in a corner to begin
/// with (drag it to another corner, pinch or use − and + to resize it), full screen with a tap,
/// closed with ×, and opened again from the sidebar or the Wall. Both sizes have Talk and
/// Stop, which halts every agent and job on the Mac. Frames are asked for only while it's open.
struct MacScreenOverlay: ViewModifier {
    let connection: CompanionConnection
    let voice: VoiceLoop
    var active = true
    @AppStorage("macScreenOpen") private var open = true
    @AppStorage("macScreenWidth") private var width: Double = 360
    @AppStorage("macScreenCorner") private var corner = Corner.bottomTrailing
    @State private var full = false
    @State private var drag: CGSize = .zero
    @State private var pinch: CGFloat = 1

    enum Corner: String {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
        var alignment: Alignment {
            switch self {
            case .topLeading: .topLeading
            case .topTrailing: .topTrailing
            case .bottomLeading: .bottomLeading
            case .bottomTrailing: .bottomTrailing
            }
        }
        var unitPoint: UnitPoint {
            switch self {
            case .topLeading: .topLeading
            case .topTrailing: .topTrailing
            case .bottomLeading: .bottomLeading
            case .bottomTrailing: .bottomTrailing
            }
        }
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: corner.alignment) {
                if active, open, !full, connection.pairing != nil {
                    small.padding(20).offset(drag)
                        .transition(.scale(scale: 0.6, anchor: corner.unitPoint).combined(with: .opacity))
                }
            }
            .overlay {
                if active, open, full { fullScreen.transition(.opacity) }
            }
            .animation(.spring(duration: 0.45, bounce: 0.25), value: open)
            .animation(.spring(duration: 0.45, bounce: 0.2), value: full)
            // A Hands step to answer brings the screen back, since that's where it's answered.
            .onChange(of: HandsStrip.waiting(connection)?.1.id) { _, step in if step != nil, active { open = true } }
            .environment(\.showsMacScreen, MacScreenToggle(isOpen: open) { open = true })
    }

    // MARK: Small

    private var small: some View {
        let shown = min(max(width * pinch, 220), 900)
        return VStack(spacing: 0) {
            LiveScreen(connection: connection, width: 1200)
                .frame(width: shown, height: shown * 10 / 16)
                .onTapGesture(count: 2) { withAnimation(.snappy) { full = true } }
            HandsStrip(connection: connection, compact: true)
            HStack(spacing: 8) {
                TalkButton(voice: voice, compact: true)
                StopAllButton(connection: connection, compact: true)
                Spacer(minLength: 0)
                Button { width = max(220, width - 80) } label: { Image(systemName: "minus") }
                Button { width = min(900, width + 80) } label: { Image(systemName: "plus") }
                Button { withAnimation(.snappy) { full = true } } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .accessibilityLabel("Full screen")
                Button { open = false } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close the Mac’s screen")
            }
            .buttonStyle(.borderless)
            .font(.body.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(width: shown)
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        .gesture(
            DragGesture()
                .onChanged { drag = $0.translation }
                .onEnded { value in
                    // Snap to the corner nearest where it was let go.
                    let right = corner == .topTrailing || corner == .bottomTrailing
                    let bottom = corner == .bottomLeading || corner == .bottomTrailing
                    let goesRight = right ? value.translation.width > -250 : value.translation.width > 250
                    let goesDown = bottom ? value.translation.height > -200 : value.translation.height > 200
                    withAnimation(.snappy) {
                        corner = goesDown ? (goesRight ? .bottomTrailing : .bottomLeading) : (goesRight ? .topTrailing : .topLeading)
                        drag = .zero
                    }
                }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { pinch = $0.magnification }
                .onEnded { value in
                    width = min(max(width * value.magnification, 220), 900)
                    pinch = 1
                }
        )
    }

    // MARK: Full screen

    private var fullScreen: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            ZoomableScreen(connection: connection)
                .ignoresSafeArea()
            VStack(spacing: 12) {
            HandsStrip(connection: connection, compact: false)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
                .padding(.horizontal, 20)
            HStack(spacing: 14) {
                TalkButton(voice: voice, compact: false)
                Spacer()
                StopAllButton(connection: connection, compact: false)
                Button { withAnimation(.snappy) { full = false } } label: {
                    Label("Smaller", systemImage: "arrow.down.right.and.arrow.up.left").labelStyle(.iconOnly)
                        .font(.title2).frame(width: 52, height: 52)
                }
                .buttonStyle(.bordered).tint(.white)
                Button { full = false; open = false } label: {
                    Label("Close", systemImage: "xmark").labelStyle(.iconOnly).font(.title2).frame(width: 52, height: 52)
                }
                .buttonStyle(.bordered).tint(.white)
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
            .padding(20)
            }
        }
        .statusBarHidden()
    }
}

extension View {
    func macScreen(_ connection: CompanionConnection, voice: VoiceLoop, active: Bool = true) -> some View {
        modifier(MacScreenOverlay(connection: connection, voice: voice, active: active))
    }
}

/// Lets the sidebar and the Wall open the screen again once it's closed.
struct MacScreenToggle {
    var isOpen = true
    var show: () -> Void = {}
}

extension EnvironmentValues {
    @Entry var showsMacScreen = MacScreenToggle()
}

/// The screen, asked for again as soon as each frame arrives (about two a second over the
/// tailnet), scaled to fit.
struct LiveScreen: View {
    let connection: CompanionConnection
    var width = 1600
    @State private var image: UIImage?
    @State private var stale = false

    var body: some View {
        ZStack {
            Color.black
            if DataSaver.shared.holdsScreen {
                VStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right").font(.title2)
                    Text("On mobile data the live screen uses a few MB a minute.").font(.callout).multilineTextAlignment(.center)
                    Button("Watch anyway") { DataSaver.shared.screenApproved = true }.buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(16)
            } else if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text(connection.status == .connected ? "Looking at your Mac…" : "Not connected to your Mac").font(.callout)
                }
                .foregroundStyle(.white.opacity(0.7))
            }
        }
        .overlay(alignment: .topLeading) {
            if stale, image != nil {
                Label("Not updating", systemImage: "pause.circle").font(.caption.weight(.medium))
                    .padding(6).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(8)
            }
        }
        .task(id: "\(width)|\(DataSaver.shared.holdsScreen)") {
            while !Task.isCancelled, !DataSaver.shared.holdsScreen {
                // On mobile data, smaller frames and fewer of them.
                let saving = DataSaver.shared.onMobileData
                if connection.status == .connected, let data = await connection.screen(width: saving ? min(width, 800) : width),
                   let picture = UIImage(data: data) {
                    image = picture
                    stale = false
                } else {
                    stale = true
                    try? await Task.sleep(for: .seconds(1))
                }
                try? await Task.sleep(for: .milliseconds(saving ? 1500 : 150))
            }
        }
    }
}

/// Full screen: pinch to zoom in on part of the Mac's screen, drag to look around, double-tap
/// to fit it again.
private struct ZoomableScreen: View {
    let connection: CompanionConnection
    @State private var scale: CGFloat = 1
    @State private var settled: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var moved: CGSize = .zero

    var body: some View {
        LiveScreen(connection: connection, width: 2200)
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnifyGesture()
                    .onChanged { scale = min(max(settled * $0.magnification, 1), 5) }
                    .onEnded { _ in
                        settled = scale
                        if scale == 1 { withAnimation(.snappy) { offset = .zero; moved = .zero } }
                    }
                    .simultaneously(with: DragGesture()
                        .onChanged { value in
                            guard scale > 1 else { return }
                            offset = CGSize(width: moved.width + value.translation.width, height: moved.height + value.translation.height)
                        }
                        .onEnded { _ in moved = offset })
            )
            .onTapGesture(count: 2) {
                withAnimation(.snappy) {
                    scale = 1
                    settled = 1
                    offset = .zero
                    moved = .zero
                }
            }
    }
}

/// Push to talk to the agent in charge, as on the Wall.
struct TalkButton: View {
    let voice: VoiceLoop
    let compact: Bool

    var body: some View {
        Button { voice.talk() } label: {
            HStack(spacing: 8) {
                Image(systemName: voice.state == .listening ? "waveform" : "mic.fill")
                    .symbolEffect(.variableColor, isActive: voice.state == .listening)
                if !compact { Text(caption).lineLimit(1) }
            }
            .font(compact ? .body.weight(.semibold) : .title3.weight(.semibold))
            .padding(.horizontal, compact ? 10 : 18).frame(minHeight: compact ? 34 : 52)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.accent))
            .foregroundStyle(Palette.onAccent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Talk")
    }

    private var caption: String {
        switch voice.state {
        case .listening: voice.heard.isEmpty ? "Listening…" : voice.heard
        case .sending: "Sending…"
        case .speaking: "Speaking"
        case .idle: "Talk"
        }
    }
}

/// Stops every agent and job on the Mac, and any Hands step, after a confirmation tap.
struct StopAllButton: View {
    let connection: CompanionConnection
    let compact: Bool
    @State private var armed = false

    var body: some View {
        Button {
            if armed {
                connection.stopAll()
                armed = false
            } else {
                armed = true
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    armed = false
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "stop.fill")
                if !compact || armed { Text(armed ? "Tap to stop all" : "Stop all") }
            }
            .font(compact ? .body.weight(.semibold) : .title3.weight(.semibold))
            .padding(.horizontal, compact ? 10 : 18).frame(minHeight: compact ? 34 : 52)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.red))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop every agent on the Mac")
    }
}

/// The sidebar's way back to the screen once it's closed.
struct MacScreenRow: View {
    @Environment(\.showsMacScreen) private var toggle

    var body: some View {
        Button(action: toggle.show) {
            Label(toggle.isOpen ? "Mac screen is open" : "Show the Mac’s screen", systemImage: "display")
                .foregroundStyle(toggle.isOpen ? Palette.text3 : Palette.text)
        }
        .disabled(toggle.isOpen)
    }
}

/// Hands on the live screen: the step waiting for you with Allow and Decline, or what Hands
/// are doing, and Stop Hands (the kill switch on the Mac). Nothing when Hands are idle.
struct HandsStrip: View {
    let connection: CompanionConnection
    let compact: Bool

    /// The first Hands step waiting in any project.
    static func waiting(_ connection: CompanionConnection) -> (CompanionSnapshot.Project, CompanionSnapshot.Approval)? {
        guard let snapshot = connection.snapshot else { return nil }
        for project in snapshot.projects {
            if let approval = project.approvals.first(where: \.isHands) { return (project, approval) }
        }
        return nil
    }

    var body: some View {
        let waiting = Self.waiting(connection)
        let hands = connection.snapshot?.hands
        if waiting != nil || hands != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.point.up.left.fill").foregroundStyle(waiting == nil ? Palette.accent : Palette.amber)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(waiting.map { "\($0.0.lead) wants to: \($0.1.title)" } ?? "\(hands?.agent ?? "The agent"): \(hands?.step ?? "")")
                            .font(compact ? .subheadline.weight(.semibold) : .headline)
                            .foregroundStyle(compact ? Palette.text : .white)
                            .lineLimit(2)
                        if waiting != nil, !compact { Text(waiting?.0.name ?? "").font(.caption).foregroundStyle(.white.opacity(0.7)) }
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    if let (project, approval) = waiting {
                        Button("Decline") { connection.answer(approval, project: project.id, allow: false) }
                            .buttonStyle(.bordered).tint(Palette.red)
                        Button("Allow") { connection.answer(approval, project: project.id, allow: true) }
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer(minLength: 0)
                    Button { connection.stopHands() } label: { Label("Stop Hands", systemImage: "stop.circle.fill") }
                        .buttonStyle(.bordered).tint(Palette.red)
                }
                .font(compact ? .subheadline.weight(.semibold) : .body.weight(.semibold))
            }
            .padding(.horizontal, compact ? 10 : 16).padding(.vertical, compact ? 8 : 12)
            .background(compact ? Palette.accentTint : .clear)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
