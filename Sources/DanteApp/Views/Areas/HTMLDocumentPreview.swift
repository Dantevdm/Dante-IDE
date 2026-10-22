import DanteKit
import SwiftUI
import WebKit

/// Local HTML slides and reports, rendered inside Dante with no browser association needed.
struct HTMLDocumentPreview: View {
    let url: URL
    let root: URL
    let rules: ClaudeRules
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                EmptyState(symbol: "exclamationmark.triangle", title: "Couldn't preview this HTML", message: error) {
                    Button("Try again") { self.error = nil }.buttonStyle(DanteButtonStyle())
                }
            } else {
                HTMLWeb(url: url, root: root, rules: rules, error: $error)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HTMLWeb: NSViewRepresentable {
    let url: URL
    let root: URL
    let rules: ClaudeRules
    @Binding var error: String?

    func makeCoordinator() -> Coordinator { Coordinator(error: $error) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(Assets(root: root, rules: rules), forURLScheme: "dante-preview")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        guard context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url
        var target = URLComponents()
        target.scheme = "dante-preview"
        target.host = "project"
        target.path = "/" + ProposedChange.relativePath(of: url, in: root)
        if let target = target.url { web.load(URLRequest(url: target)) }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: URL?
        let error: Binding<String?>
        init(error: Binding<String?>) { self.error = error }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.scheme == "dante-preview" ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError failure: any Error) {
            error.wrappedValue = failure.localizedDescription
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError failure: any Error) {
            error.wrappedValue = failure.localizedDescription
        }
    }

    final class Assets: NSObject, WKURLSchemeHandler {
        let root: URL
        let rules: ClaudeRules
        init(root: URL, rules: ClaudeRules) { self.root = root; self.rules = rules }
        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            do {
                guard let url = task.request.url, url.host == "project" else { throw URLError(.badURL) }
                let file = try ProjectFileOpen.asset(String(url.path.dropFirst()), root: root, rules: rules)
                let data = try Data(contentsOf: file)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Type": MotionRuntime.mimeType(for: file.path) + (MotionRuntime.isText(file.path) ? "; charset=utf-8" : ""),
                    "Content-Security-Policy": ProjectFileOpen.contentPolicy,
                    "Cache-Control": "no-store",
                ])!
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
            } catch { task.didFailWithError(error) }
        }
        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }
}
