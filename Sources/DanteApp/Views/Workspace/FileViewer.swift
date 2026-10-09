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

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(theme.line.color).frame(height: 1)
            content
                .id(document.diskVersion)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
            Button {
                Task { await session.attach([document.url]) }
            } label: {
                Label("Ask Claude about this", systemImage: "paperclip")
            }
            .buttonStyle(DanteButtonStyle())
            .fixedSize()
            .help("Attaches the file to your next message to Claude")
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
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(theme.panel.color)
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
            EmptyState(symbol: "doc.zipper", title: "\(document.name) isn’t text",
                       message: "Dante shows text, PDFs, images, documents and media. Open this one in another app, or attach it for Claude.") {
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
