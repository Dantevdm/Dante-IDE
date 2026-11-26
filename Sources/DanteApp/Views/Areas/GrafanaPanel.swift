import AppKit
import CryptoKit
import DanteKit
import SwiftUI
import WebKit

/// Health › Grafana: the project's own Grafana inside Dante, a tab per dashboard the repo
/// provisions. The sign-in is kept per project on this Mac (its own website data store), and
/// the view keeps to that Grafana: other links open in the browser.
struct GrafanaPanel: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let grafana: GrafanaSetup

    /// Nil until the first answer.
    @State private var running: Bool?
    @State private var dashboard: String?
    @State private var focused = false
    @State private var reloads = 0

    private var dashboardKey: String { "grafana.dashboard." + workspace.url.path }
    private var chosen: GrafanaSetup.Dashboard? { grafana.dashboards.first { $0.uid == dashboard } }
    private var url: URL { grafana.url(for: chosen, dark: theme.isDark, focused: focused) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            switch running {
            case nil:
                Card {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for Grafana on port \(String(grafana.port))…").font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
                    }
                }
            case false?:
                notRunning
            case true?:
                GrafanaWeb(url: url, grafana: grafana, store: Self.storeID(for: workspace.url), reloads: reloads)
                    .frame(maxWidth: .infinity)
                    .frame(height: 760)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line.color))
                if !grafana.anonymous {
                    Text("Sign in with the Grafana account the project sets up (often in .env). Dante remembers it for this project on this Mac.")
                        .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                }
            }
        }
        .task(id: grafana.port) {
            dashboard = UserDefaults.standard.string(forKey: dashboardKey)
            while !Task.isCancelled {
                let up = await Self.answers(grafana)
                guard !Task.isCancelled else { return }
                if up != running { running = up }
                try? await Task.sleep(for: .seconds(up ? 30 : 4))
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    tab("All dashboards", selected: dashboard == nil || chosen == nil) { choose(nil) }
                    ForEach(grafana.dashboards) { board in
                        tab(board.title, selected: chosen?.uid == board.uid) { choose(board.uid) }
                    }
                }
                .padding(2)
                .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 7))
            }
            Spacer(minLength: 8)
            if chosen != nil {
                Toggle("Panels only", isOn: $focused)
                    .toggleStyle(.checkbox)
                    .font(.dante(size: 12))
                    .foregroundStyle(theme.text2.color)
                    .help("Hide Grafana's menus and show only the dashboard (Grafana's kiosk mode). Press Esc inside it to bring them back.")
            }
            IconButton(symbol: "arrow.clockwise", label: "Reload") { reloads += 1 }
            IconButton(symbol: "safari", label: "Open in the browser") { NSWorkspace.shared.open(grafana.url(for: chosen, dark: theme.isDark)) }
        }
    }

    private var notRunning: some View {
        Card("Grafana isn’t running") {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(grafana.composeFile) runs Grafana on port \(String(grafana.port))\(grafana.dashboards.isEmpty ? "" : " with \(grafana.dashboards.count) dashboard\(grafana.dashboards.count == 1 ? "" : "s") from the repo"). Start it and it appears here.")
                    .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
                    .fixedSize(horizontal: false, vertical: true)
                Text(grafana.startCommand)
                    .font(.dante(size: 12, design: .monospaced))
                    .foregroundStyle(theme.text.color)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(theme.codeBackground.color, in: RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 8) {
                    Button { session.runInNewTerminal(grafana.startCommand, title: "Grafana") } label: {
                        Label("Start it", systemImage: "play.fill")
                    }
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .help("Runs the command in a terminal tab of its own")
                    Button { Task { running = await Self.answers(grafana) } } label: { Label("Check again", systemImage: "arrow.clockwise") }
                        .buttonStyle(DanteButtonStyle())
                }
            }
        }
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.dante(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? theme.text.color : theme.text2.color)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(selected ? theme.card.color : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func choose(_ uid: String?) {
        dashboard = uid
        UserDefaults.standard.set(uid, forKey: dashboardKey)
    }

    /// Grafana's health route answers (it needs no sign-in).
    nonisolated static func answers(_ grafana: GrafanaSetup) async -> Bool {
        var request = URLRequest(url: grafana.baseURL.appending(path: "api/health"), timeoutInterval: 3)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse).map { $0.statusCode < 500 } ?? false
    }

    /// One website data store per project, so a sign-in stays with its project.
    static func storeID(for root: URL) -> UUID {
        let digest = Array(SHA256.hash(data: Data(("grafana:" + root.standardizedFileURL.path).utf8)))
        let bytes = (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                     digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15])
        return UUID(uuid: bytes)
    }
}

private struct GrafanaWeb: NSViewRepresentable {
    let url: URL
    let grafana: GrafanaSetup
    let store: UUID
    let reloads: Int

    func makeCoordinator() -> Coordinator { Coordinator(grafana: grafana) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: store)
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.underPageBackgroundColor = .clear
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.grafana = grafana
        if context.coordinator.loaded != url {
            context.coordinator.loaded = url
            context.coordinator.reloads = reloads
            web.load(URLRequest(url: url))
        } else if context.coordinator.reloads != reloads {
            context.coordinator.reloads = reloads
            web.reload()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var grafana: GrafanaSetup
        var loaded: URL?
        var reloads = 0
        init(grafana: GrafanaSetup) { self.grafana = grafana }

        /// Grafana's own pages load here; a link elsewhere opens in the browser.
        @MainActor
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if ["about", "blob", "data"].contains(url.scheme ?? "") || grafana.owns(url) { return .allow }
            if action.targetFrame?.isMainFrame ?? true, ["http", "https"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }

        /// A link meant for a new window: Grafana's stays here, others go to the browser.
        @MainActor
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url {
                if grafana.owns(url) { webView.load(URLRequest(url: url)) } else if ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            }
            return nil
        }
    }
}
