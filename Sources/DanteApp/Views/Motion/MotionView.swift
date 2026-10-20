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
    /// The other version, beside this one while comparing.
    @State private var other = MotionPlayer()
    @State private var ask = ""
    @FocusState private var askFocused: Bool
    /// The version shown: nil for this checkout's.
    @State private var versionFolder: URL?
    @State private var comparing = false
    @State private var showsNotes = false
    @State private var adopting: MotionVersion?

    private var folderPath: String { (path as NSString).deletingLastPathComponent }
    private var folder: URL { workspace.url.appending(path: folderPath) }
    private var versions: [MotionVersion] { session.motionVersions(of: folderPath) }
    /// The version on show, when there are several.
    private var version: MotionVersion? { versions.first { $0.folder == (versionFolder ?? folder) } }
    private var shownFolder: URL { version?.folder ?? folder }
    /// The version compared with the one on show.
    private var compared: MotionVersion? { versions.first { $0.folder != shownFolder } }
    /// The piece's files' revision: reloads when the agent writes them.
    private var revisionKey: String {
        let stamp = Self.stamp(of: shownFolder)
        return "\(path)#\(workspace.revision)#\(stamp)#\(shownFolder.path)#\(comparing ? compared.map { "\($0.folder.path)#\(Self.stamp(of: $0.folder))" } ?? "" : "")"
    }

    /// The newest change to a piece's files, renders aside.
    private static func stamp(of folder: URL) -> Double {
        let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])?.allObjects as? [URL]) ?? []
        return files.filter { !$0.path.contains("/renders/") }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970 }.max() ?? 0
    }

    private func source(of folder: URL, root: URL) -> MotionSource {
        MotionSource.load(folder: folder, projectRoot: root, files: workspace.files, projectName: workspace.name, revision: workspace.revision)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if versions.count > 1 { versionStrip }
            Rectangle().fill(theme.line.color).frame(height: 1)
            HStack(spacing: 2) {
                stage
                if comparing, let compared {
                    ZStack(alignment: .topLeading) {
                        Color.black
                        MotionStageHost(player: other)
                            .aspectRatio(CGFloat(other.source?.piece.width ?? 16) / CGFloat(other.source?.piece.height ?? 9), contentMode: .fit)
                            .opacity(other.ready ? 1 : 0)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        VersionTag(text: compared.label)
                        Color.clear.contentShape(Rectangle()).onTapGesture { togglePlay() }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .background(Color.black)
            if !player.errors.isEmpty { errorBanner }
            if let message = player.renderError { notice(message, symbol: "exclamationmark.triangle.fill", tint: theme.amber.color) }
            if let note = player.exportNote { notice(note, symbol: "info.circle.fill", tint: theme.amber.color) }
            if let file = player.lastRender, player.rendering == nil { renderedBanner(file) }
            if showsNotes {
                Rectangle().fill(theme.line.color).frame(height: 1)
                MotionNotes(session: session, player: player, version: version, folderPath: folderPath)
                    .frame(maxHeight: 240)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Rectangle().fill(theme.line.color).frame(height: 1)
            MotionTimeline(player: player, follower: comparing ? other : nil)
                .padding(.horizontal, 16).padding(.top, 10)
            askBar
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(theme.ground.color)
        .animation(.snappy, value: comparing)
        .animation(.snappy, value: showsNotes)
        .task(id: revisionKey) {
            player.load(source(of: shownFolder, root: version?.root ?? workspace.url), refused: session.motionRefused)
            if comparing, let compared {
                other.muted = true
                other.load(source(of: compared.folder, root: compared.root), refused: session.motionRefused)
                other.go(player.time)
            }
        }
        .onChange(of: path) { versionFolder = nil; comparing = false }
        .onDisappear { player.stop(); other.stop() }
        .background {
            // Space plays, arrows step a deck's slides.
            Button("") { togglePlay() }.keyboardShortcut(.space, modifiers: []).hidden().disabled(askFocused)
            Button("") { step(true) }.keyboardShortcut(.rightArrow, modifiers: []).hidden().disabled(askFocused)
            Button("") { step(false) }.keyboardShortcut(.leftArrow, modifiers: []).hidden().disabled(askFocused)
        }
        .confirmationDialog("Use \(adopting?.label ?? "this") version?", isPresented: Binding(get: { adopting != nil }, set: { if !$0 { adopting = nil } })) {
            Button("Use \(adopting?.label ?? "this") version") {
                if let adopting { session.adoptMotion(adopting, into: folderPath) }
                versionFolder = nil
                comparing = false
            }
        } message: {
            Text("Its files replace the ones in \(folderPath); those go to the Trash. Renders stay.\(adopting?.job != nil ? " The job stays open on the Jobs board until you merge or discard it." : "")")
        }
    }

    private func togglePlay() {
        player.togglePlay()
        guard comparing else { return }
        if player.playing { other.go(player.time); other.play() } else { other.pause(); other.go(player.time) }
    }

    private func step(_ forward: Bool) {
        player.step(forward)
        if comparing { other.pause(); other.go(player.time) }
    }

    /// The versions made of this piece, to switch between, compare, and choose.
    private var versionStrip: some View {
        HStack(spacing: 10) {
            Text("Versions").font(.dante(size: 11, weight: .medium)).foregroundStyle(theme.text3.color)
            HStack(spacing: 2) {
                ForEach(versions) { item in
                    let shown = item.folder == shownFolder
                    Button {
                        versionFolder = item.folder == folder ? nil : item.folder
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(item.maker == "Codex" ? theme.accent.color : theme.claude.color).frame(width: 6, height: 6)
                            Text(item.label).font(.dante(size: 12, weight: shown ? .semibold : .regular))
                            if item.job != nil { Text("job").font(.dante(size: 10)).foregroundStyle(theme.text3.color) }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(shown ? theme.raised.color : .clear, in: Capsule())
                        .foregroundStyle(shown ? theme.text.color : theme.text2.color)
                    }
                    .buttonStyle(.plain)
                    .help(item.job != nil ? "\(item.maker)’s version, still in its job (\(item.jobTitle ?? "a job"))" : "The version in \(ProposedChange.relativePath(of: item.folder, in: workspace.url))")
                }
            }
            .padding(2)
            .background(theme.card.color, in: Capsule())
            Toggle(isOn: $comparing) { Label("Compare", systemImage: "rectangle.split.2x1") }
                .toggleStyle(.button)
                .help("Play both versions side by side, in step")
            Spacer()
            if let version, version.folder != folder {
                Button("Use \(version.label) version") { adopting = version }
                    .buttonStyle(DanteButtonStyle())
                    .help("Copy this version’s files into \(folderPath), replacing what’s there")
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var stage: some View {
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
                    RenderProgress(title: player.renderTitle, progress: rendering.progress) { player.cancelRender() }
                }
                if comparing, let version { VersionTag(text: version.label).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
                if player.rendering == nil {
                    // Over the web view, which would take the click.
                    Color.clear.contentShape(Rectangle()).onTapGesture { togglePlay() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            notesChip
            Toggle(isOn: $player.showsCaptions) { Image(systemName: "captions.bubble") }
                .toggleStyle(.button).buttonStyle(.plain).foregroundStyle(player.showsCaptions ? theme.accent.color : theme.text3.color)
                .help("Show the narration as captions while it plays")
            IconButton(symbol: "paintpalette", label: "Brand kit") { session.writeBrandKit() }
                .help("Open .dante/brand.yaml: the colours, fonts, logo, motion and voice every piece uses (written from the project’s own styles the first time)")
            IconButton(symbol: "arrow.triangle.2.circlepath", label: "Refresh project data") { Task { await session.refreshMotionData(folder: folderPath) } }
                .help("Rebuild data.json from the code as it is now: the system map, infrastructure and numbers the scene draws")
                .disabled(player.source?.piece.data.isEmpty ?? true)
            IconButton(symbol: "chevron.left.forwardslash.chevron.right", label: "Open the scene in Code") {
                session.open(file: shownFolder.appending(path: player.source?.piece.scene ?? "index.html"))
            }
            Button {
                if let source = player.source { player.pause(); session.presentMotion(source) }
            } label: {
                Label("Present", systemImage: "play.display")
            }
            .buttonStyle(DanteButtonStyle())
            .disabled(!player.ready)
            .help(player.source?.piece.kind == .deck
                  ? "Present on the Stage, full screen: each slide holds until you press → or Space (a clicker works too); Esc ends"
                  : "Play it full screen on the Stage; Space pauses, Esc ends")
            Menu {
                Section("Video") {
                    ForEach(MotionRenderer.Quality.allCases) { quality in
                        Button("\(quality.rawValue) MP4, with the narration") { player.render(quality) }
                    }
                }
                Section("Share") {
                    Button("Web page, one file that plays in any browser") { player.exportWebPage() }
                    Button(player.source?.piece.kind == .deck ? "PDF of the slides" : "PDF storyboard, with the narration") { player.exportPDF() }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.button)
            .buttonStyle(DanteButtonStyle(primary: true))
            .fixedSize()
            .disabled(player.rendering != nil || !player.ready)
            .help("Render an MP4 frame by frame, or save a web page or PDF to share, in renders/ beside the scene")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Lint findings and the critique: a count that opens the notes.
    private var notesChip: some View {
        let breaking = player.lint.filter(\.breaksRender).count
        let critique = session.motionCritiques[shownFolder]
        let count = player.lint.count + (critique.flatMap { if case .done(let c) = $0 { c.notes.filter { $0.kind != .good }.count } else { nil } } ?? 0)
        return Button { showsNotes.toggle() } label: {
            HStack(spacing: 4) {
                if critique?.isRunning == true {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: breaking > 0 ? "exclamationmark.triangle.fill" : "text.bubble")
                }
                Text(count == 0 ? "Notes" : "\(count)").font(.dante(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((showsNotes ? theme.accent.color : breaking > 0 ? theme.amber.color : theme.text3.color).opacity(0.14), in: Capsule())
            .foregroundStyle(showsNotes ? theme.accent.color : breaking > 0 ? theme.amber.color : theme.text2.color)
        }
        .buttonStyle(.plain)
        .help("What Dante's lint finds in the scene, and a critique by the other agent")
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
                session.changeMotion(folder: folderPath, ask: "The scene reports these errors; fix them:\n" + player.errors.joined(separator: "\n"), at: player.time, version: version)
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
            Text("Saved \(file.lastPathComponent)").font(.dante(size: 12)).foregroundStyle(theme.text.color)
            Spacer()
            Button(file.pathExtension == "mp4" ? "Play" : "Open") { NSWorkspace.shared.open(file) }.buttonStyle(DanteButtonStyle())
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
        session.changeMotion(folder: folderPath, ask: text, at: player.time, version: version)
        ask = ""
    }

    static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, Int((seconds - Double(whole)) * 10))
    }
}

/// A version's name over its stage while comparing.
private struct VersionTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.dante(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(10)
            .allowsHitTesting(false)
    }
}

/// The scene's web view, scaled to fit with the layout kept at the design size.
struct MotionStageHost: NSViewRepresentable {
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
    /// The other version while comparing: it plays and seeks with this one.
    var follower: MotionPlayer?
    @State private var hovering: Double?

    private func toggle() {
        player.togglePlay()
        guard let follower else { return }
        if player.playing { follower.go(player.time); follower.play() } else { follower.pause(); follower.go(player.time) }
    }

    private func step(_ forward: Bool) {
        player.step(forward)
        follower?.pause()
        follower?.go(player.time)
    }

    var body: some View {
        let duration = max(player.duration, 0.01)
        let piece = player.source?.piece
        HStack(spacing: 12) {
            if piece?.kind == .deck {
                IconButton(symbol: "backward.end.fill", label: "Previous slide", size: 11) { step(false) }
            }
            Button { toggle() } label: {
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
                IconButton(symbol: "forward.end.fill", label: "Next slide", size: 11) { step(true) }
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
                    follower?.go(player.time)
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
    let title: String
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
            Text(title).font(.dante(size: 13, weight: .medium)).foregroundStyle(.white)
            Button("Cancel", action: cancel).buttonStyle(DanteButtonStyle())
        }
        .padding(28)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}


/// A piece presented on the Stage: the scene full screen on black, the narration as captions,
/// and where you are (the slide, or a hairline of progress) kept faint at the bottom.
struct MotionPresentView: View {
    let player: MotionPlayer

    var body: some View {
        ZStack {
            Color.black
            MotionStageHost(player: player)
                .aspectRatio(CGFloat(player.source?.piece.width ?? 16) / CGFloat(player.source?.piece.height ?? 9), contentMode: .fit)
                .opacity(player.ready ? 1 : 0)
                .animation(.easeOut(duration: 0.5), value: player.ready)
            if !player.ready, player.errors.isEmpty {
                ProgressView().controlSize(.regular).tint(.white)
            }
            if let error = player.errors.first {
                Text(error).font(.dante(size: 14, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            if player.showsCaptions, let caption = player.caption {
                VStack {
                    Spacer()
                    Text(caption)
                        .font(.dante(size: 26, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.bottom, 64).padding(.horizontal, 120)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                        .id(caption)
                }
                .animation(.snappy, value: caption)
            }
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    GeometryReader { proxy in
                        Capsule().fill(.white.opacity(0.35))
                            .frame(width: proxy.size.width * player.time / max(0.01, player.duration), height: 2)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .frame(height: 2)
                    if let slide = player.slide {
                        Text("\(slide.index) / \(slide.count)")
                            .font(.dante(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.leading, 16)
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 22)
            }
            .allowsHitTesting(false)
            // The web view would take the clicks; a click (or a clicker) moves on.
            Color.clear.contentShape(Rectangle()).onTapGesture { player.advance(true) }
        }
        .onDisappear { player.stop() }
    }
}
