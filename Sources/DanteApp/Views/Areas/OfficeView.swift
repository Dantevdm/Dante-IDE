import AppKit
import DanteKit
import SwiftUI
import WebKit

/// Agents › HQ: the agents' isometric office (MotionLib/hq/office.html), grown from this
/// project's ledger and git history by `AgentOffice`, with whoever is working now at their
/// desks. The page draws; this view feeds it every couple of seconds.
struct OfficeView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    @State private var bridge = OfficeBridge()

    var body: some View {
        OfficeWeb(bridge: bridge)
            .background(theme.ground.color)
            // A new theme restarts the feed, so the page is sent the new colours at once.
            .task(id: "\(workspace.url.path)|\(theme.id)") {
                // What was last seen is read once, so this visit's new milestones are celebrated once.
                let seen = UserDefaults.standard.string(forKey: OfficeBridge.seenKey(workspace.name))
                await bridge.feed(session: session, workspace: workspace, theme: OfficeBridge.colours(theme), seen: seen)
            }
            .onAppear { wire() }
    }

    private func wire() {
        bridge.handle = { [session, workspace] action, body in
            switch action {
            case "ready":
                bridge.last = nil
            case "inbox":
                guard let item = session.inbox.first else { return }
                session.showsClaude = true
                session.showJob(item.job)
            case "seen":
                if let date = body["date"] as? String { UserDefaults.standard.set(date, forKey: OfficeBridge.seenKey(workspace.name)) }
            case "replay":
                Task {
                    let frames = await bridge.timeline(project: workspace.name, root: workspace.url, files: workspace.files.count)
                    bridge.replay(frames)
                }
            default:
                break
            }
        }
    }
}

/// Holds the page and what it was last sent.
@MainActor
final class OfficeBridge {
    weak var web: WKWebView?
    var handle: (String, [String: Any]) -> Void = { _, _ in }
    var last: String?
    /// The Stage's room for the scene, as the page's `office.inset` takes it.
    var inset: [String: Double] = [:] {
        didSet { if inset != oldValue { sendInset() } }
    }
    private(set) var jobs: [AgentJob] = []
    private(set) var commits: [Date] = []
    private var commitsRevision: Int?

    static func seenKey(_ project: String) -> String { "officeSeen." + project }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// This project's jobs from the ledger, and the commit dates once per revision.
    func load(project: String, root: URL, revision: Int) async {
        let ledger = AgentLedger.standard
        jobs = await Task.detached(priority: .utility) { ledger.jobs().filter { $0.project == project } }.value
        guard commitsRevision != revision else { return }
        commitsRevision = revision
        let output = await Shell.run(["git", "log", "-n", "50000", "--format=%ct"], in: root)
        commits = output.stdout.split(separator: "\n").compactMap { Double($0.trimmingCharacters(in: .whitespaces)).map { Date(timeIntervalSince1970: $0) } }
    }

    func timeline(project: String, root: URL, files: Int) async -> [AgentOffice] {
        let jobs = jobs, commits = commits
        return await Task.detached(priority: .userInitiated) {
            AgentOffice.timeline(jobs: jobs, project: project, growth: .init(commits: commits, files: files), frames: 28)
        }.value
    }

    /// The theme's colours for the page's panel, signs and sky; `dark` picks the scene's ground.
    static func colours(_ theme: Theme) -> [String: String] {
        [
            "dark": theme.isDark ? "1" : "", "ground": theme.ground.css, "panel": theme.panel.css, "panelGlass": theme.panel.opacity(0.9).css,
            "raised": theme.raised.css, "card": theme.card.css, "line": theme.line.css, "line2": theme.line2.css,
            "text": theme.text.css, "text2": theme.text2.css, "text3": theme.text3.css, "accent": theme.accent.css, "accentTint": theme.accentTint.css,
        ]
    }

    /// Feeds the page until cancelled: the ledger every 6 s, the office every 2 s, with whoever
    /// is at work now and, for the pocket office, the presence's mood.
    func feed(session: Session, workspace: Workspace, theme: [String: String], seen: String?, mood: @escaping @MainActor () -> String? = { nil }) async {
        var loadedAt = Date.distantPast
        while !Task.isCancelled {
            if Date().timeIntervalSince(loadedAt) > 6 {
                await load(project: workspace.name, root: workspace.url, revision: workspace.revision)
                loadedAt = Date()
            }
            let office = AgentOffice.build(jobs: jobs, project: workspace.name, growth: .init(commits: commits, files: workspace.files.count))
            push(office: office, live: session.officeWorkers(), ambience: AgentOffice.ambience(hour: Calendar.current.component(.hour, from: .now)),
                 theme: theme, seen: seen, mood: mood())
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func push(office: AgentOffice, live: [OfficeWorker], ambience: String, theme: [String: String], seen: String?, mood: String? = nil) {
        guard let web, let officeJSON = try? Self.encoder.encode(office), let liveJSON = try? Self.encoder.encode(live),
              let themeJSON = try? JSONSerialization.data(withJSONObject: theme, options: .sortedKeys) else { return }
        let themeText = String(decoding: themeJSON, as: UTF8.self)
        let payload = "{\"office\":\(String(decoding: officeJSON, as: UTF8.self)),\"live\":\(String(decoding: liveJSON, as: UTF8.self)),\"ambience\":\"\(ambience)\",\"theme\":\(themeText),\"seen\":\(seen.map { "\"\($0)\"" } ?? "null"),\"mood\":\(mood.map { "\"\($0)\"" } ?? "null")}"
        // The office's own clock changes every push; only send when something else did.
        var still = office
        still.now = .distantPast
        let key = (try? Self.encoder.encode(still)).map { String(decoding: $0, as: UTF8.self) + String(decoding: liveJSON, as: UTF8.self) + ambience + themeText + (mood ?? "") }
        guard key != last else { return }
        last = key
        web.evaluateJavaScript("window.office && office.set(\(payload))")
    }

    /// Sent again when the page says it's ready.
    func sendInset() {
        guard let web, !inset.isEmpty, let json = try? JSONSerialization.data(withJSONObject: inset, options: .sortedKeys) else { return }
        web.evaluateJavaScript("window.office && office.inset(\(String(decoding: json, as: UTF8.self)))")
    }

    func replay(_ frames: [AgentOffice]) {
        guard let web, let json = try? Self.encoder.encode(frames) else { return }
        web.evaluateJavaScript("window.office && office.replay(\(String(decoding: json, as: UTF8.self)))")
    }
}

struct OfficeWeb: NSViewRepresentable {
    /// HQ itself, the menu bar panel's pocket office (only the scene; a click opens HQ), or
    /// the Stage's (the scene with its signs, inside the room the Stage leaves it).
    enum Mode: String {
        case page = "", pocket, stage
    }

    let bridge: OfficeBridge
    var mode = Mode.page

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if let library = MotionSchemeHandler.libraries {
            configuration.setURLSchemeHandler(MotionSchemeHandler(folder: library.appending(path: "hq"), projectRoot: library, refused: { _ in true }),
                                              forURLScheme: MotionRuntime.scheme)
        }
        let controller = WKUserContentController()
        if mode != .page {
            controller.addUserScript(WKUserScript(source: "window.OFFICE_MODE = '\(mode.rawValue)'", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let bridge = bridge
        controller.add(MotionMessages { body in
            guard let action = body["action"] as? String else { return }
            bridge.handle(action, body)
        }, name: "office")
        configuration.userContentController = controller
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.setValue(false, forKey: "drawsBackground")
        web.load(URLRequest(url: URL(string: "\(MotionRuntime.scheme)://piece/office.html")!))
        bridge.web = web
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        bridge.web = web
    }
}

extension Session {
    /// Everyone working in this window, for HQ: the main conversation and each open job's.
    func officeWorkers() -> [OfficeWorker] {
        guard let workspace else { return [] }
        func tools(_ claude: ClaudeSession) -> [ToolActivity] {
            claude.items.compactMap { if case .tool(let tool) = $0.content { tool } else { nil } }
        }
        var workers: [OfficeWorker] = []
        if let claude {
            workers += OfficeWorker.from(tools: tools(claude), working: claude.state == .working, lead: claude.engine.title, root: workspace.url)
        }
        for job in jobs.open {
            guard let claude = jobs.sessions[job.id] else { continue }
            workers += OfficeWorker.from(tools: tools(claude), working: claude.state == .working, lead: claude.engine.title,
                                         root: job.worktreeURL, job: job.title)
        }
        return workers
    }
}
