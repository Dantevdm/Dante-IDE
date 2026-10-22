import AVKit
import DanteKit
import Quartz
import SwiftUI

/// A tab for a file that isn't text: PDFs, images, Word files, audio and video, and
/// whatever Quick Look can show. Anything else gets a card saying what it is.
struct FileViewer: View {
    @Environment(\.theme) private var theme
    let session: Session
    let document: EditorDocument
    @State private var showsLooker = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(theme.line.color).frame(height: 1)
            content
                .id(document.diskVersion)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsLooker, document.kind == .image {
                LookerBar(session: session, url: document.url) { showsLooker = false }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.3), value: showsLooker)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(document.kind.title)
                .font(.dante(size: 12, weight: .medium))
                .foregroundStyle(theme.text2.color)
            if let size {
                Text(size).font(.dante(size: 12)).foregroundStyle(theme.text3.color)
            }
            Spacer(minLength: 8)
            // Icons only when the pane is too narrow for the labels.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions }
                HStack(spacing: 8) { actions }.labelStyle(.iconOnly)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(theme.panel.color)
    }

    @ViewBuilder
    private var actions: some View {
        if document.kind == .image {
            Button { showsLooker.toggle() } label: {
                Label("Ask Looker", systemImage: "text.viewfinder")
            }
            .buttonStyle(DanteButtonStyle(primary: showsLooker))
            .fixedSize()
            .help("Ask a vision model on this Mac about the image: nothing leaves it")
        }
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([document.url])
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        .buttonStyle(DanteButtonStyle())
        .fixedSize()
        Button {
            NSWorkspace.shared.open(document.url)
        } label: {
            Label(openTitle, systemImage: "arrow.up.forward.app")
        }
        .buttonStyle(DanteButtonStyle())
        .fixedSize()
        .help("Open the file in the app macOS uses for it")
    }

    @ViewBuilder
    private var content: some View {
        switch document.kind {
        case .pdf:
            FilePreview(url: document.url, kind: .pdf)
        case .image:
            FilePreview(url: document.url, kind: .image)
        case .document:
            FilePreview(url: document.url, kind: .document)
        case .media:
            MediaPlayer(url: document.url)
        case .quickLook:
            QuickLookPreview(url: document.url)
        case .binary, .text:
            EmptyState(symbol: "doc.zipper", title: "\(document.name) isn’t text") {
                EmptyView()
            }
            .padding(28)
        }
    }

    private var size: String? {
        guard let bytes = try? document.url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var openTitle: String {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: document.url) else { return "Open" }
        return "Open in \(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""))"
    }
}

/// Audio or video, with the system's playback controls.
private struct MediaPlayer: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .task(id: url) { player = AVPlayer(url: url) }
            .onDisappear { player?.pause() }
    }
}

/// Quick Look's own preview: spreadsheets, slides, fonts, archives.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

/// Questions about an image for Looker, answered by a vision model on this Mac.
private struct LookerBar: View {
    @Environment(\.theme) private var theme
    let session: Session
    let url: URL
    let close: () -> Void
    @State private var question = "Describe this and read out any text, especially errors."
    @State private var answer: String?
    @State private var model: String?
    @State private var missing: String?
    @State private var running = false
    @State private var started = Date()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.viewfinder").foregroundStyle(theme.amber.color)
                    .symbolEffect(.pulse, isActive: running)
                Text("Looker").font(.dante(size: 12.5, weight: .semibold)).foregroundStyle(theme.text.color)
                if let model { Text(model).font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color) }
                Spacer()
                IconButton(symbol: "xmark", label: "Close Looker", size: 10, action: close)
            }
            if let missing {
                VStack(alignment: .leading, spacing: 6) {
                    Text(missing).font(.dante(size: 12)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                    LinkButton("Type the command in the terminal") {
                        session.showsTerminal = true
                        session.typeInTerminal("ollama pull \(Looker.suggestedModel)")
                    }
                }
            } else {
                HStack(spacing: 8) {
                    TextField("What should Looker look for?", text: $question)
                        .textFieldStyle(.plain)
                        .font(.dante(size: 12.5))
                        .focused($focused)
                        .onSubmit(ask)
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? theme.accentLine.color : theme.line.color))
                    Button(running ? "Looking…" : "Ask", action: ask)
                        .buttonStyle(DanteButtonStyle(primary: true))
                        .disabled(running || model == nil || question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if running {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text("Reading the image · \(Int(context.date.timeIntervalSince(started))) s")
                            .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).monospacedDigit()
                    }
                } else if let answer {
                    ScrollView {
                        MarkdownText(text: answer)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .transition(.opacity)
                }
            }
        }
        .padding(14)
        .background(theme.panel.color)
        .overlay(alignment: .top) { Rectangle().fill(theme.line.color).frame(height: 1) }
        .task {
            let installed = await Ollama().models() ?? []
            model = Looker.model(installed: installed, chosen: Preferences.shared.lookerModel.isEmpty ? nil : Preferences.shared.lookerModel)
            if model == nil { missing = installed.isEmpty ? "Looker needs Ollama running on this Mac with a vision model: ollama pull \(Looker.suggestedModel)" : Looker.missingReason(installed: installed) }
            focused = true
        }
    }

    private func ask() {
        guard let model, !running else { return }
        running = true
        started = Date()
        let question = question
        let url = url
        let project = session.workspace?.url.lastPathComponent ?? ""
        Task {
            let result: Result<OllamaReply, Error> = await Task.detached {
                do {
                    let image = try Looker.prepare(try Data(contentsOf: url))
                    return .success(try await Ollama().look(model: model, images: [image], question: question))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let reply):
                answer = reply.text
                AgentLedger.standard.append(AgentJob(kind: Looker.kind, provider: .local, model: model, project: project,
                                                     promptTokens: reply.promptTokens, outputTokens: reply.outputTokens, seconds: reply.seconds,
                                                     requestedBy: "you", title: String(question.prefix(60)), gist: AgentJob.gist(of: reply.text)))
            case .failure(let error):
                answer = "Looker couldn’t read it: \(error.localizedDescription)"
            }
            running = false
        }
    }
}
