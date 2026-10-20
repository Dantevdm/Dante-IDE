import AppKit
import DanteKit
import SwiftUI
import WebKit

/// A motion piece in Docs: the scene playing on a dark stage, a timeline of its beats and
/// narration, renders to 1080p or 4K, and asking the agent for changes at this moment.
struct MotionView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    /// The manifest's project path.
    let path: String
    @State private var player = MotionPlayer()
    @State private var ask = ""
    @FocusState private var askFocused: Bool

    private var folderPath: String { (path as NSString).deletingLastPathComponent }
    private var folder: URL { workspace.url.appending(path: folderPath) }
    /// The piece's files' revision: reloads when the agent writes them.
    private var revisionKey: String {
        let files = workspace.files.filter { $0.hasPrefix(folderPath + "/") && !$0.contains("/renders/") }
        let stamp = files.compactMap { try? workspace.url.appending(path: $0).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970 }.max() ?? 0
        return "\(path)#\(workspace.revision)#\(stamp)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.line.color).frame(height: 1)
            ZStack {
                Color.black
                MotionStageHost(player: player)
                    .aspectRatio(CGFloat(player.source?.piece.width ?? 16) / CGFloat(player.source?.piece.height ?? 9), contentMode: .fit)
                    .opacity(player.ready ? 1 : 0)
                    .animation(.easeOut(duration: 0.35), value: player.ready)
                if !player.ready, player.errors.isEmpty {
                    ProgressView().controlSize(.small).tint(.white)
                }
                if player.showsCaptions, let caption = player.caption {
                    VStack {
                        Spacer()
                        Text(caption)
                            .font(.dante(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(.bottom, 22).padding(.horizontal, 40)
                            .transition(.opacity.combined(with: .offset(y: 6)))
                            .id(caption)
                    }
                    .animation(.snappy, value: caption)
                    .allowsHitTesting(false)
                }
                if let rendering = player.rendering {
                    RenderProgress(quality: rendering.quality, progress: rendering.progress) { player.cancelRender() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { player.togglePlay() }
            if !player.errors.isEmpty { errorBanner }
            if let message = player.renderError { notice(message, symbol: "exclamationmark.triangle.fill", tint: theme.amber.color) }
            if let file = player.lastRender, player.rendering == nil { renderedBanner(file) }
            Rectangle().fill(theme.line.color).frame(height: 1)
            MotionTimeline(player: player)
                .padding(.horizontal, 16).padding(.top, 10)
            askBar
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(theme.ground.color)
        .task(id: revisionKey) {
            player.load(MotionSource.load(folder: folder, projectRoot: workspace.url, files: workspace.files, projectName: workspace.name, revision: workspace.revision),
                        refused: session.motionRefused)
        }
        .onDisappear { player.stop() }
        .background {
            // Space plays, arrows step a deck's slides.
            Button("") { player.togglePlay() }.keyboardShortcut(.space, modifiers: []).hidden().disabled(askFocused)
            Button("") { player.step(true) }.keyboardShortcut(.rightArrow, modifiers: []).hidden().disabled(askFocused)
            Button("") { player.step(false) }.keyboardShortcut(.leftArrow, modifiers: []).hidden().disabled(askFocused)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: player.source?.piece.kind == .deck ? "rectangle.on.rectangle.angled" : "film.stack")
                .font(.dante(size: 14)).foregroundStyle(theme.accent.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.source?.piece.title ?? folder.lastPathComponent).font(.dante(size: 14, weight: .semibold)).foregroundStyle(theme.text.color).lineLimit(1)
                if let piece = player.source?.piece {
                    Text("\(piece.kind.title) · \(Self.clock(piece.duration)) · \(piece.width)×\(piece.height) · \(piece.fps) fps\(piece.narration.isEmpty ? "" : " · \(piece.narration.count) lines narrated")")
                        .font(.dante(size: 11)).foregroundStyle(theme.text3.color).lineLimit(1)
                }
            }
            Spacer()
            if player.speakingNarration {
                Label("Voicing narration", systemImage: "waveform").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }
            Toggle(isOn: $player.showsCaptions) { Image(systemName: "captions.bubble") }
                .toggleStyle(.button).buttonStyle(.plain).foregroundStyle(player.showsCaptions ? theme.accent.color : theme.text3.color)
                .help("Show the narration as captions while it plays")
            IconButton(symbol: "paintpalette", label: "Brand kit") { session.writeBrandKit() }
                .help("Open .dante/brand.yaml: the colours, fonts, logo, motion and voice every piece uses (written from the project’s own styles the first time)")
            IconButton(symbol: "arrow.triangle.2.circlepath", label: "Refresh project data") { Task { await session.refreshMotionData(folder: folderPath) } }
                .help("Rebuild data.json from the code as it is now: the system map, infrastructure and numbers the scene draws")
                .disabled(player.source?.piece.data.isEmpty ?? true)
            IconButton(symbol: "chevron.left.forwardslash.chevron.right", label: "Open the scene in Code") {
                session.open(file: folder.appending(path: player.source?.piece.scene ?? "index.html"))
            }
            Menu {
                ForEach(MotionRenderer.Quality.allCases) { quality in
                    Button("Render \(quality.rawValue) MP4") { player.render(quality) }
                }
            } label: {
                Label("Render", systemImage: "film")
            }
            .menuStyle(.button)
            .buttonStyle(DanteButtonStyle(primary: true))
            .fixedSize()
            .disabled(player.rendering != nil || !player.ready)
            .help("Render every frame offline into an MP4 with the narration, in renders/ beside the scene")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var errorBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(theme.red.color)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(player.errors.prefix(3), id: \.self) { error in
                    Text(error).font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text.color).lineLimit(2).textSelection(.enabled)
                }
            }
            Spacer()
            Button {
                session.changeMotion(folder: folderPath, ask: "The scene reports these errors; fix them:\n" + player.errors.joined(separator: "\n"), at: player.time)
            } label: {
                ClaudeLabel("Ask \(session.agentName) to fix")
            }
            .buttonStyle(DanteButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(theme.red.color.opacity(0.08))
    }

    private func notice(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.dante(size: 12)).foregroundStyle(theme.text.color)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(tint.opacity(0.08))
    }

    private func renderedBanner(_ file: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.green.color)
            Text("Rendered \(file.lastPathComponent)").font(.dante(size: 12)).foregroundStyle(theme.text.color)
            Spacer()
            Button("Play") { NSWorkspace.shared.open(file) }.buttonStyle(DanteButtonStyle())
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }.buttonStyle(DanteButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(theme.green.color.opacity(0.08))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var askBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars").foregroundStyle(theme.accent.color)
            TextField("Ask \(session.agentName) to change it at \(Self.clock(player.time))…", text: $ask, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.dante(size: 13))
                .lineLimit(1...4)
                .focused($askFocused)
                .onSubmit(send)
            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.dante(size: 18)) }
                .buttonStyle(.plain)
                .foregroundStyle(ask.trimmingCharacters(in: .whitespaces).isEmpty ? theme.text3.color : theme.accent.color)
                .disabled(ask.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(theme.card.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(askFocused ? theme.accent.color.opacity(0.6) : theme.line.color))
    }

    private func send() {
        let text = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        player.pause()
        session.changeMotion(folder: folderPath, ask: text, at: player.time)
        ask = ""
    }

    static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, Int((seconds - Double(whole)) * 10))
    }
}

/// The scene's web view, scaled to fit with the layout kept at the design size.
private struct MotionStageHost: NSViewRepresentable {
    let player: MotionPlayer

    func makeNSView(context: Context) -> Host {
        let host = Host()
        player.onWebView = { [weak host] web in host?.show(web, width: CGFloat(player.source?.piece.width ?? 1920)) }
        if let web = player.web { host.show(web, width: CGFloat(player.source?.piece.width ?? 1920)) }
        return host
    }

    func updateNSView(_ host: Host, context: Context) {
        if let web = player.web, web.superview !== host { host.show(web, width: CGFloat(player.source?.piece.width ?? 1920)) }
    }

    final class Host: NSView {
        private var web: WKWebView?
        private var designWidth: CGFloat = 1920

        func show(_ web: WKWebView, width: CGFloat) {
            self.web?.removeFromSuperview()
            self.web = web
            designWidth = width
            addSubview(web)
            needsLayout = true
        }

        override func layout() {
            super.layout()
            guard let web, bounds.width > 0 else { return }
            web.frame = bounds
            web.pageZoom = bounds.width / designWidth
        }
    }
}

/// The piece's time: a track with its beats (a deck's stops) and narration lines, a playhead
/// to drag, and the controls.
private struct MotionTimeline: View {
    @Environment(\.theme) private var theme
    let player: MotionPlayer
    @State private var hovering: Double?

    var body: some View {
        let duration = max(player.duration, 0.01)
        let piece = player.source?.piece
        HStack(spacing: 12) {
            if piece?.kind == .deck {
                IconButton(symbol: "backward.end.fill", label: "Previous slide", size: 11) { player.step(false) }
            }
            Button { player.togglePlay() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    .font(.dante(size: 13))
                    .frame(width: 30, height: 30)
                    .background(theme.accent.color, in: Circle())
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(!player.ready)
            .help(player.playing ? "Pause (Space)" : "Play (Space)")
            if piece?.kind == .deck {
                IconButton(symbol: "forward.end.fill", label: "Next slide", size: 11) { player.step(true) }
            }
            Text(MotionView.clock(player.time)).font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text.color).frame(width: 52, alignment: .leading)
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.raised.color).frame(height: 6).frame(maxHeight: .infinity)
                    Capsule().fill(theme.accent.color.opacity(0.85)).frame(width: max(6, width * player.time / duration), height: 6).frame(maxHeight: .infinity)
                    // Narration: a bar for each line, as long as it's spoken.
                    if let piece {
                        ForEach(Array(piece.narration.enumerated()), id: \.offset) { index, line in
                            let length = player.narration?.lengths[safe: index] ?? Double(line.text.split(separator: " ").count) / 2.5
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(theme.green.color.opacity(0.75))
                                .frame(width: max(3, width * length / duration), height: 3)
                                .offset(x: width * line.at / duration, y: 11)
                                .help("\(MotionView.clock(line.at)): \(line.text)")
                        }
                        ForEach(piece.stops, id: \.self) { stop in
                            Rectangle().fill(theme.text2.color).frame(width: 2, height: 14)
                                .offset(x: width * stop / duration - 1)
                                .help("Slide stop at \(MotionView.clock(stop))")
                        }
                    }
                    Circle().fill(.white).frame(width: 13, height: 13).shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: width * player.time / duration - 6.5)
                    if let hovering {
                        Text(MotionView.clock(hovering)).font(.dante(size: 10, design: .monospaced)).foregroundStyle(theme.text2.color)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(theme.card.color, in: RoundedRectangle(cornerRadius: 4))
                            .offset(x: min(max(0, width * hovering / duration - 20), width - 44), y: -16)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    player.go(Double(value.location.x / width) * duration)
                })
                .onContinuousHover { phase in
                    if case .active(let point) = phase { hovering = Double(point.x / width) * duration } else { hovering = nil }
                }
            }
            .frame(height: 34)
            Text(MotionView.clock(player.duration)).font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color)
        }
    }
}

/// The render's progress over the stage, with Cancel.
private struct RenderProgress: View {
    @Environment(\.theme) private var theme
    let quality: MotionRenderer.Quality
    let progress: Double
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 5)
                Circle().trim(from: 0, to: progress).stroke(theme.accent.color, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: progress)
                Text("\(Int(progress * 100))%").font(.dante(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
            }
            .frame(width: 76, height: 76)
            Text("Rendering \(quality.rawValue), frame by frame").font(.dante(size: 13, weight: .medium)).foregroundStyle(.white)
            Button("Cancel", action: cancel).buttonStyle(DanteButtonStyle())
        }
        .padding(28)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

