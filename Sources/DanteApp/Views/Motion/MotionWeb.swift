import AppKit
import DanteEditor
import DanteKit
import WebKit

/// Serves a motion scene to WebKit under `dante-motion://piece/`: the piece's own folder, the
/// fonts bundled with Dante under `_dante/fonts/`, its libraries under `_dante/lib/` (pages get
/// their import map), and the project's images, models and data
/// under `_dante/project/` (never env files, keys or the rules' `never` paths).
final class MotionSchemeHandler: NSObject, WKURLSchemeHandler {
    let folder: URL
    let projectRoot: URL
    let refused: (String) -> Bool

    init(folder: URL, projectRoot: URL, refused: @escaping (String) -> Bool) {
        self.folder = folder
        self.projectRoot = projectRoot
        self.refused = refused
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let path = MotionRuntime.safe(url.path) else {
            return task.didFailWithError(URLError(.badURL))
        }
        let file: URL?
        if path.hasPrefix(MotionLibrary.path) {
            file = Self.libraries?.appending(path: String(path.dropFirst(MotionLibrary.path.count)))
        } else if path.hasPrefix(MotionRuntime.fontsPath) {
            file = DanteFonts.folder?.appending(path: String(path.dropFirst(MotionRuntime.fontsPath.count)))
        } else if path.hasPrefix(MotionRuntime.projectPath) {
            let relative = String(path.dropFirst(MotionRuntime.projectPath.count))
            let ext = (relative as NSString).pathExtension.lowercased()
            let name = (relative as NSString).lastPathComponent.lowercased()
            file = MotionRuntime.servedExtensions.contains(ext) && !name.hasPrefix(".env") && !refused(relative)
                ? projectRoot.appending(path: relative) : nil
        } else {
            file = folder.appending(path: path.isEmpty ? "index.html" : path)
        }
        guard let file, var data = try? Data(contentsOf: file) else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
            task.didReceive(response)
            task.didReceive(Data("Not found".utf8))
            return task.didFinish()
        }
        if ["html", "htm"].contains(file.pathExtension.lowercased()), let html = String(data: data, encoding: .utf8) {
            data = Data(MotionLibrary.addingImportMap(to: html).utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": MotionRuntime.mimeType(for: file.path), "Content-Length": "\(data.count)",
            "Cache-Control": "no-store", "Access-Control-Allow-Origin": "*",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    /// three.js, hairline and Open Peeps, bundled with the app.
    static let libraries = ResourceBundles.url(bundle: "Dante_DanteApp", path: "MotionLib")
}

/// Messages from the scene's runtime: ready, time, paused and errors.
final class MotionMessages: NSObject, WKScriptMessageHandler {
    let handle: @MainActor ([String: Any]) -> Void

    init(handle: @escaping @MainActor ([String: Any]) -> Void) {
        self.handle = handle
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { handle(body) }
    }
}

/// Everything a scene needs to load: where it is, how it looks, what it shows.
struct MotionSource: Equatable {
    var folder: URL
    var projectRoot: URL
    var piece: MotionPiece
    var brand: BrandKit
    /// `data.json`, read as JSON.
    var dataJSON: Data?
    /// Bumped to reload after the files change.
    var revision = 0

    static func == (a: MotionSource, b: MotionSource) -> Bool {
        a.folder == b.folder && a.piece == b.piece && a.brand == b.brand && a.dataJSON == b.dataJSON && a.revision == b.revision
    }

    var data: Any? { dataJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) } }

    /// Reads the piece in `folder`.
    static func load(folder: URL, projectRoot: URL, files: [String], projectName: String, revision: Int) -> MotionSource {
        let manifest = (try? String(contentsOf: folder.appending(path: MotionPiece.manifestName), encoding: .utf8)) ?? ""
        let piece = MotionPiece.parse(manifest, fallbackTitle: folder.lastPathComponent)
        let read = { (path: String) in try? String(contentsOf: projectRoot.appending(path: path), encoding: .utf8) }
        let brand = BrandKit.load(name: projectName, files: files, read: read)
        let data = try? Data(contentsOf: folder.appending(path: MotionData.fileName))
        return MotionSource(folder: folder, projectRoot: projectRoot, piece: piece, brand: brand, dataJSON: data, revision: revision)
    }

    /// A web view set up for this piece, laid out at the design size × `zoom`.
    @MainActor
    func makeWebView(mode: MotionRuntime.Mode, pixelRatio: Double, refused: @escaping (String) -> Bool, messages: MotionMessages?) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(MotionSchemeHandler(folder: folder, projectRoot: projectRoot, refused: refused), forURLScheme: MotionRuntime.scheme)
        configuration.suppressesIncrementalRendering = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: MotionRuntime.script(piece: piece, brand: brand, data: data, mode: mode, pixelRatio: pixelRatio),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let messages { controller.add(messages, name: "dante") }
        configuration.userContentController = controller
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: piece.width, height: piece.height), configuration: configuration)
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .black
        return web
    }

    var url: URL { URL(string: "\(MotionRuntime.scheme)://piece/\(piece.scene)")! }
}
