import AppKit
import DanteKit
import SwiftUI
import WebKit

/// The Look step's gallery: every animation style and illustration kit as a live tile
/// (MotionLib/gallery/looks.html, drawn with the bundled libraries), in the app's theme.
/// Picks are the "look" and "kit" answers, by name.
struct MotionLookGallery: NSViewRepresentable {
    @Environment(\.theme) private var theme
    var styles: [String]
    var kits: [String]
    var pick: (_ kind: String, _ id: String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if let library = MotionSchemeHandler.libraries {
            configuration.setURLSchemeHandler(MotionSchemeHandler(folder: library.appending(path: "gallery"), projectRoot: library, refused: { _ in true }),
                                              forURLScheme: MotionRuntime.scheme)
        }
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: "window.lookSetup = \(setupJSON);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let coordinator = context.coordinator
        coordinator.pick = pick
        controller.add(MotionMessages { body in
            if let kind = body["kind"] as? String, let id = body["id"] as? String { coordinator.pick?(kind, id) }
        }, name: "looks")
        configuration.userContentController = controller
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.setValue(false, forKey: "drawsBackground")
        web.load(URLRequest(url: URL(string: "\(MotionRuntime.scheme)://piece/looks.html")!))
        coordinator.shown = (ids(styles, in: MotionLooks.styles.map { ($0.id, $0.name) }), ids(kits, in: MotionLooks.kits.map { ($0.id, $0.name) }))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.pick = pick
        let shown = (ids(styles, in: MotionLooks.styles.map { ($0.id, $0.name) }), ids(kits, in: MotionLooks.kits.map { ($0.id, $0.name) }))
        guard shown != context.coordinator.shown else { return }
        context.coordinator.shown = shown
        web.evaluateJavaScript("window.looks && looks.set(\(json(shown.0)), \(json(shown.1)))")
    }

    private func ids(_ names: [String], in table: [(id: String, name: String)]) -> [String] {
        names.compactMap { name in table.first { $0.name == name }?.id }
    }

    private func json(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    private var setupJSON: String {
        var summaries: [String: String] = [:]
        for style in MotionLooks.styles { summaries[style.id] = style.summary }
        for kit in MotionLooks.kits { summaries[kit.id] = kit.summary }
        let colours: [String: String] = [
            "bg": theme.panel.css, "card": theme.card.css, "text": theme.text.css, "text2": theme.text2.css, "text3": theme.text3.css,
            "line": theme.line.css, "accent": theme.accent.css, "accentTint": theme.accentTint.css,
        ]
        return json([
            "theme": colours, "dark": theme.isDark, "summaries": summaries,
            "styles": ids(styles, in: MotionLooks.styles.map { ($0.id, $0.name) }),
            "kits": ids(kits, in: MotionLooks.kits.map { ($0.id, $0.name) }),
        ] as [String: Any])
    }

    final class Coordinator {
        var pick: ((String, String) -> Void)?
        var shown: ([String], [String]) = ([], [])
    }
}
