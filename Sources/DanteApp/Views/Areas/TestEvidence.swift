import AppKit
import DanteKit
import SwiftUI

/// What a Playwright test left behind: its screenshots as pictures, and its video and trace
/// to open. Playwright clears its output folder at the start of each run, so files from an
/// earlier run may be gone.
struct TestEvidence: View {
    @Environment(\.theme) private var theme
    let session: Session
    let attachments: [TestResult.Attachment]

    var body: some View {
        let present = attachments.filter { FileManager.default.fileExists(atPath: $0.path) }
        let screenshots = present.filter { $0.kind == .screenshot }
        VStack(alignment: .leading, spacing: 8) {
            if !screenshots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(screenshots, id: \.path) { shot in
                            Button { session.open(file: URL(fileURLWithPath: shot.path)) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Thumbnail(path: shot.path)
                                    Text(shot.project.map { "\($0) · \(shot.name)" } ?? shot.name)
                                        .font(.dante(size: 10.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Open the screenshot")
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                ForEach(present.filter { $0.kind == .video }, id: \.path) { video in
                    Button { session.open(file: URL(fileURLWithPath: video.path)) } label: {
                        Label("Video\(video.project.map { " · \($0)" } ?? "")", systemImage: "play.rectangle")
                    }
                    .buttonStyle(DanteButtonStyle())
                    .help("Watch what the browser did")
                }
                ForEach(present.filter { $0.kind == .trace }, id: \.path) { trace in
                    Button { openTrace(trace) } label: {
                        Label("Trace\(trace.project.map { " · \($0)" } ?? "")", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    .buttonStyle(DanteButtonStyle())
                    .help("Step through every action, network call and DOM snapshot in Playwright's trace viewer, which runs on this Mac")
                }
            }
            if present.count < attachments.count {
                Text(present.isEmpty ? "The screenshots and recordings from this run are gone: Playwright clears them when tests run again."
                     : "Some files from this run are gone: Playwright clears them when tests run again.")
                    .font(.dante(size: 11)).foregroundStyle(theme.text3.color)
            }
        }
    }

    /// Opens Playwright's own trace viewer from the project's install, in a terminal tab.
    private func openTrace(_ trace: TestResult.Attachment) {
        let folder = URL(fileURLWithPath: trace.path).deletingLastPathComponent().path
        let command = """
        d=\(Shell.quote(folder)); while [ ! -x "$d/node_modules/.bin/playwright" ] && [ "$d" != / ]; do d=$(dirname "$d"); done; \
        "$d/node_modules/.bin/playwright" show-trace \(Shell.quote(trace.path))
        """
        session.runInNewTerminal(command, title: "Trace")
    }
}

private struct Thumbnail: View {
    @Environment(\.theme) private var theme
    let path: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.track.color.opacity(0.5))
            }
        }
        .frame(height: 120)
        .frame(maxWidth: 220)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.line.color))
        .task(id: path) {
            let path = path
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: URL(fileURLWithPath: path)) }.value
            image = data.flatMap(NSImage.init(data:))
        }
    }
}
