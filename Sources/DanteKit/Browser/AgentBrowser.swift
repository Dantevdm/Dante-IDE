import AppKit
import Foundation
import WebKit

/// The agents' own browser: WebKit in a window nobody sees, inside the `dante mcp` process, so
/// each conversation and job has one of its own and never uses the person's. Its storage is
/// private and forgotten when the process ends (no cookies or sign-ins from anywhere else), and
/// the page only moves within `BrowserHosts`. Needs the main run loop: `dante mcp` runs it.
@MainActor
public final class AgentBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    public struct Failure: Error, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    public let hosts: BrowserHosts
    /// Where screenshots are kept for the person (Application Support/Dante/browser/<project>).
    public let shots: URL
    private let web: WKWebView
    private let window: NSWindow
    private var loading: CheckedContinuation<Void, Never>?
    private var loadError: String?
    private var started = false
    private var waits = 0
    /// The main page's HTTP status.
    public private(set) var status: Int?
    /// Pages refused by `hosts` and dialogs the page showed, since they were last told.
    private var notes: [String] = []
    private var shotCount = 0

    public static let defaultSize = CGSize(width: 1280, height: 800)
    static let timeout: Duration = .seconds(20)

    public init(hosts: BrowserHosts, shots: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        self.hosts = hosts
        self.shots = shots
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: BrowserScripts.watch, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let frame = NSRect(origin: .zero, size: Self.defaultSize)
        web = WKWebView(frame: frame, configuration: configuration)
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: Self.defaultSize), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.contentView = web
        web.navigationDelegate = self
        web.uiDelegate = self
        web.customUserAgent = nil
    }

    public nonisolated static func shotsFolder(project: String) -> URL {
        URL.applicationSupportDirectory.appending(path: "Dante/browser/\(project.replacingOccurrences(of: "/", with: "-"))", directoryHint: .isDirectory)
    }

    // MARK: Actions

    public func open(_ url: URL) async throws -> String {
        guard hosts.allows(url) else { throw Failure(message: hosts.refusal(url)) }
        status = nil
        loadError = nil
        await waitForLoad { web.load(URLRequest(url: url)) }
        if let loadError { throw Failure(message: "Couldn’t open \(url.absoluteString): \(loadError)") }
        await settle()
        return try await read()
    }

    public func back() async throws -> String {
        guard web.canGoBack else { throw Failure(message: "There’s no page to go back to.") }
        await waitForLoad { web.goBack() }
        await settle()
        return try await read()
    }

    /// The page now, as the agent reads it.
    public func read() async throws -> String {
        guard web.url != nil else { throw Failure(message: "No page is open yet; use browser_open first.") }
        let json = try await web.evaluateJavaScript(BrowserScripts.report) as? String ?? ""
        guard let report = try? JSONDecoder().decode(BrowserReport.self, from: Data(json.utf8)) else {
            throw Failure(message: "Couldn’t read the page.")
        }
        return takeNotes() + report.rendered(status: status)
    }

    public func click(_ ref: Int) async throws -> String {
        try await act(BrowserScripts.click(ref), done: "Clicked \(ref).")
    }

    public func type(_ ref: Int, text: String, submit: Bool) async throws -> String {
        try await act(BrowserScripts.type(ref, text: text, submit: submit), done: submit ? "Typed into \(ref) and submitted." : "Typed into \(ref).")
    }

    public func resize(width: Int, height: Int) async throws -> String {
        let size = CGSize(width: min(max(width, 320), 2560), height: min(max(height, 400), 1600))
        window.setContentSize(size)
        web.frame = NSRect(origin: .zero, size: size)
        await settle()
        return web.url == nil ? "The viewport is \(Int(size.width))×\(Int(size.height))." : try await read()
    }

    /// A picture of the viewport, or the whole page up to 10,000 points tall. Kept as a PNG in
    /// `shots`; the agent gets a JPEG.
    public func screenshot(fullPage: Bool) async throws -> (file: URL, jpeg: String) {
        guard web.url != nil else { throw Failure(message: "No page is open yet; use browser_open first.") }
        let viewport = web.frame.size
        if fullPage, let height = try? await web.evaluateJavaScript(BrowserScripts.pageHeight) as? Double, height > viewport.height {
            let tall = CGSize(width: viewport.width, height: min(height, 10_000))
            window.setContentSize(tall)
            web.frame = NSRect(origin: .zero, size: tall)
            try? await Task.sleep(for: .milliseconds(400))
        }
        defer {
            if web.frame.size != viewport {
                window.setContentSize(viewport)
                web.frame = NSRect(origin: .zero, size: viewport)
            }
        }
        let image = try await web.takeSnapshot(configuration: nil)
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw Failure(message: "Couldn’t take a screenshot.")
        }
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        shotCount += 1
        let file = shots.appending(path: "\(Self.stamp.string(from: Date()))-\(shotCount).png")
        try png.write(to: file)
        return (file, try Looker.prepare(png))
    }

    /// Removes screenshots older than a week.
    public nonisolated static func tidy(_ folder: URL, now: Date = Date()) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "png" {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(date) > 7 * 24 * 3600 { try? FileManager.default.removeItem(at: file) }
        }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    // MARK: Waiting

    private func act(_ script: String, done: String) async throws -> String {
        guard web.url != nil else { throw Failure(message: "No page is open yet; use browser_open first.") }
        started = false
        let answer = try await web.evaluateJavaScript(script) as? String ?? ""
        guard answer == "ok" else { throw Failure(message: answer.isEmpty ? "That didn’t work on this page." : answer) }
        // A click may start a page load, change the route or just redraw.
        try? await Task.sleep(for: .milliseconds(150))
        if started || web.isLoading {
            await waitForLoad {}
        }
        await settle()
        return done + "\n\n" + (try await read())
    }

    private func waitForLoad(_ start: () -> Void) async {
        waits += 1
        let wait = waits
        await withCheckedContinuation { continuation in
            loading?.resume()
            loading = continuation
            start()
            Task { [weak self] in
                try? await Task.sleep(for: Self.timeout)
                guard let self, self.waits == wait, let waiting = self.loading else { return }
                self.loadError = self.loadError ?? "it took more than 20 seconds"
                self.loading = nil
                waiting.resume()
            }
            // A load that finished before the wait began (or a page from the back cache)
            // reports nothing more.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, self.waits == wait, !self.web.isLoading, let waiting = self.loading else { return }
                self.loading = nil
                waiting.resume()
            }
        }
    }

    /// Lets scripts render after a load or a click: until nothing loads, then a moment more.
    private func settle() async {
        for _ in 0..<50 where web.isLoading { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(400))
    }

    private func finish(_ error: String?) {
        if let error { loadError = error }
        loading?.resume()
        loading = nil
    }

    private func takeNotes() -> String {
        defer { notes = [] }
        return notes.isEmpty ? "" : notes.map { "Note: \($0)" }.joined(separator: "\n") + "\n\n"
    }

    // MARK: WebKit

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        let main = navigationAction.targetFrame?.isMainFrame ?? true
        if main, !hosts.allows(url) {
            notes.append("The page tried to go to \(url.absoluteString), outside the hosts the browser may visit, so it stayed put.")
            return .cancel
        }
        return .allow
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame { status = (navigationResponse.response as? HTTPURLResponse)?.statusCode }
        return .allow
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        started = true
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(nil)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(Self.describe(error))
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(Self.describe(error))
    }

    /// target=_blank and window.open load here instead.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                        windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, hosts.allows(url) { webView.load(URLRequest(url: url)) }
        return nil
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        notes.append("The page showed an alert: “\(message)”.")
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        notes.append("The page asked “\(message)”; the browser answered OK.")
        return true
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                        initiatedByFrame frame: WKFrameInfo) async -> String? {
        notes.append("The page asked for text (“\(prompt)”); the browser left it empty.")
        return nil
    }

    static func describe(_ error: any Error) -> String? {
        let error = error as NSError
        // A load replaced by another (a redirect done in script, a second click) isn't a failure.
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return nil }
        if error.domain == "WebKitErrorDomain", error.code == 102 { return nil }
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCannotConnectToHost {
            return "nothing is answering there. Is the app running?"
        }
        return error.localizedDescription
    }
}
