import DanteKit
import SwiftUI

/// The panel under the menu bar's Vine D: the frontmost project's pocket HQ (the orb when no
/// project is open), the mood, and each open project's state.
struct PresencePanel: View {
    @Environment(\.theme) private var theme
    let model: PresenceModel
    let controller: PresenceController

    var body: some View {
        VStack(spacing: 0) {
            if let session = PocketOffice.session {
                PocketOffice(session: session, model: model, controller: controller)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
            } else {
                OrbRepresentable(size: .large)
                    .frame(width: 260, height: 220)
                    .padding(.top, 6)
            }
            Text(model.mood.title)
                .font(.dante(size: 19, weight: .semibold))
                .foregroundStyle(theme.text.color)
            Text(model.presence.line)
                .font(.dante(size: 12.5))
                .foregroundStyle(theme.text2.color)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.top, 3)
            if model.vitality.fatigue > 0.3, !model.vitality.isExhausted(at: .now) {
                Label("Running low on usage", systemImage: "battery.25percent")
                    .font(.dante(size: 11.5))
                    .foregroundStyle(theme.amber.color)
                    .padding(.top, 6)
                    .help("This five-hour window is close to your busiest one")
            }

            if !model.satellites.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.satellites) { satellite in
                        HStack(spacing: 7) {
                            Circle()
                                .fill(satellite.color.color)
                                .frame(width: 7, height: 7)
                            Text(satellite.title)
                                .font(.dante(size: 11.5))
                                .foregroundStyle(theme.text2.color)
                                .lineLimit(1)
                            if case .local = satellite.kind {
                                Text("on this Mac")
                                    .font(.dante(size: 10.5))
                                    .foregroundStyle(theme.text3.color)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }

            HStack(alignment: .top, spacing: 8) {
                TalkButton()
                Button { controller.openStage() } label: {
                    Label("Stage", systemImage: "tv")
                }
                .buttonStyle(DanteButtonStyle())
                .help("Open the Stage: Dante full screen. Esc or “minimise” leaves it.")
            }
            .padding(.top, 12)

            if !model.presence.sources.isEmpty {
                VStack(spacing: 2) {
                    ForEach(model.presence.sources) { source in
                        row(source)
                    }
                }
                .padding(8)
                .background(theme.card.color, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.line.color))
                .padding(.horizontal, 14)
                .padding(.top, 16)
            }
        }
        .padding(.bottom, 14)
        .frame(width: 320)
    }

    private func row(_ source: PresenceSource) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color(source.mood))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.project)
                    .font(.dante(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.text.color)
                Text(source.status)
                    .font(.dante(size: 11.5))
                    .foregroundStyle(theme.text3.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if source.claude == .working {
                Button("Stop") { controller.stop(source.id) }
                    .buttonStyle(DanteButtonStyle())
            }
            Button(source.mood == .needsYou ? "Review" : "Open") { controller.show(source.id) }
                .buttonStyle(DanteButtonStyle(primary: source.mood == .needsYou))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { controller.show(source.id) }
    }

    private func color(_ mood: PresenceMood) -> Color {
        switch mood {
        case .needsYou: theme.amber.color
        case .acting, .thinking, .listening: theme.accent.color
        case .done: theme.green.color
        case .trouble: theme.red.color
        case .idle, .asleep: theme.text3.color
        }
    }
}

/// Starts and stops listening, and says why it can't.
private struct TalkButton: View {
    @Environment(\.theme) private var theme

    var body: some View {
        let voice = VoiceController.shared
        VStack(spacing: 6) {
            Button {
                voice.toggle()
            } label: {
                Label(voice.state == .listening ? "Send" : "Talk", systemImage: voice.state == .listening ? "arrow.up.circle.fill" : "mic.fill")
            }
            .buttonStyle(DanteButtonStyle(primary: voice.state == .listening))
            .help("Talk to Claude (\(VoiceController.keyLabel) from anywhere). It sends when you pause.")
            if case .unavailable(let reason) = voice.state {
                Text(reason)
                    .font(.dante(size: 11.5))
                    .foregroundStyle(theme.amber.color)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
        }
    }
}

/// An `OrbView` in SwiftUI, following the presence's mood.
struct OrbRepresentable: NSViewRepresentable {
    var size: OrbView.Size
    var framesPerSecond = 60

    func makeNSView(context: Context) -> OrbView {
        let view = OrbView(size: size)
        view.framesPerSecond = framesPerSecond
        PresenceController.shared.attach(view)
        view.wake()
        return view
    }

    func updateNSView(_ view: OrbView, context: Context) {
        if view.framesPerSecond != framesPerSecond { view.framesPerSecond = framesPerSecond }
    }
}

/// The frontmost project's Agent HQ in miniature: the scene only, the brain showing the mood
/// and whoever is at work at their desks. A click opens HQ in the project's window.
private struct PocketOffice: View {
    @Environment(\.theme) private var theme
    let session: Session
    let model: PresenceModel
    let controller: PresenceController
    @State private var bridge = OfficeBridge()

    /// The window that was main most recently, else any with a project.
    static var session: Session? {
        if let session = ActiveProject.shared.session, session.workspace != nil { return session }
        return Sessions.all.first { $0.workspace != nil }
    }

    var body: some View {
        OfficeWeb(bridge: bridge, mode: .pocket)
            .frame(height: 196)
            .background(theme.ground.color)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.line.color))
            .overlay(alignment: .topLeading) {
                if let workspace = session.workspace {
                    Text(workspace.name)
                        .font(.dante(size: 11, weight: .medium))
                        .foregroundStyle(theme.text2.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(theme.panel.color.opacity(0.85), in: Capsule())
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .help("Agent HQ: click to open it")
            .accessibilityLabel("Agent HQ")
            .task(id: theme.id) {
                guard let workspace = session.workspace else { return }
                bridge.handle = { [session, controller] action, _ in
                    switch action {
                    case "ready": bridge.last = nil
                    case "open": controller.openOffice(session)
                    default: break
                    }
                }
                await bridge.feed(session: session, workspace: workspace, theme: OfficeBridge.colours(theme), seen: nil) { [model] in
                    model.mood.rawValue
                }
            }
    }
}
