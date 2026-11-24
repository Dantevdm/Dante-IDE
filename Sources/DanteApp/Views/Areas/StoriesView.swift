import DanteKit
import SwiftUI

/// Quality › Stories: the web app's features told step by step as Playwright tests, each step
/// photographed, run as end-to-end tests; when one breaks, why, and what changed since it last
/// passed. Ideas for the stories not yet told come from what the Map understood of the app.
struct StoriesView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    private var model: StoriesModel { session.stories }

    var body: some View {
        AreaPage(eyebrow: nil, title: "Stories", subtitle: "How each feature works, told step by step in a real browser, and checked every time they run. When one breaks, Dante says why.") {
            if model.isRunning {
                Button(role: .destructive) { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(DanteButtonStyle())
            } else if !model.storyFiles.isEmpty {
                Button { model.start(session: session, root: workspace.url) } label: { Label("Run all", systemImage: "play.fill") }
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .disabled(!ready)
                    .help(ready ? "Runs every story against \(model.baseURL ?? "the app")" : "Set up first: see the card below")
            }
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                if let problem = model.problem {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.amber.color)
                        Text(problem).font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !model.loaded {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else if model.apps.isEmpty {
                    EmptyState(symbol: "film.stack", title: "No web app found",
                               message: "Stories walk through a web front-end in a real browser. The Map found none in this project: no React, Vue, Svelte, Angular or similar app with a package.json.") { EmptyView() }
                } else {
                    setupCard
                    if model.isRunning { runningLine }
                    if let id = model.openFeature, let feature = model.features.first(where: { $0.id == id }) {
                        StoryDetail(session: session, workspace: workspace, feature: feature)
                    } else {
                        summary
                        featureGrid
                    }
                    ideasCard
                }
            }
            .animation(.snappy(duration: 0.25), value: model.openFeature)
        }
        .task(id: workspace.revision) { await model.load(session: session, workspace: workspace) }
    }

    private var ready: Bool { model.hasKit && model.hasPlaywright && model.listening == true }

    // MARK: Setup

    private var setupCard: some View {
        Card("The app", spacing: 10) {
            if model.apps.count > 1 {
                HStack(spacing: 6) {
                    ForEach(model.apps) { app in
                        Button { model.appID = app.id; Task { await model.refresh(root: workspace.url) } } label: {
                            Chip(text: app.name, symbol: "macwindow", selected: model.app?.id == app.id)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isRunning)
                    }
                }
            }
            if let target = model.target {
                check(ok: model.listening == true, waiting: model.listening == nil || model.starting,
                      title: model.listening == true ? "\(target.name) answers at localhost:\(target.port)"
                          : model.starting ? "Starting \(target.name)…" : "Nothing answers at localhost:\(target.port) yet",
                      detail: model.listening == true ? "The port came from \(target.portSource)." : "Stories need the app running: `\(target.command)`.") {
                    if model.listening != true, !model.starting {
                        Button("Start it") { model.startApp(session: session) }.buttonStyle(DanteButtonStyle())
                            .help("Runs \(target.command) in a terminal tab of its own and waits for the port")
                    }
                    Button { Task { await model.refresh(root: workspace.url) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Check again")
                }
                check(ok: model.hasPlaywright, title: model.hasPlaywright ? "Playwright is installed" : "Playwright isn’t installed in \(target.name)",
                      detail: model.hasPlaywright ? "Stories run in Chromium through the app’s own copy." : "It adds @playwright/test to the app and downloads Chromium, so you run it yourself.") {
                    if !model.hasPlaywright {
                        Button("Type the install command") { session.typeInTerminal(StoryKit.installCommand(frontend: target.folder, tool: target.tool)) }
                            .buttonStyle(DanteButtonStyle())
                            .help("Types it into the terminal for you to read and run")
                    }
                }
                check(ok: model.hasKit && !model.kitOutdated,
                      title: model.hasKit ? (model.kitOutdated ? "The story kit has an update" : "Stories live in \(model.folder ?? "stories")/") : "Stories aren’t set up yet",
                      detail: model.hasKit ? "\(model.storyFiles.count) stor\(model.storyFiles.count == 1 ? "y" : "ies") · its own playwright.config.ts and dante-story.ts, which records every step."
                          : "Writes \(model.folder ?? "stories")/playwright.config.ts and dante-story.ts: their own settings, so the app’s other tests stay as they are.") {
                    if !model.hasKit || model.kitOutdated {
                        Button(model.hasKit ? "Update" : "Set up stories") { model.setUp(root: workspace.url) }.buttonStyle(DanteButtonStyle())
                    }
                }
            }
        }
    }

    private func check<Actions: View>(ok: Bool, waiting: Bool = false, title: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if waiting { ProgressView().controlSize(.mini) }
                else { Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(ok ? theme.green.color : theme.amber.color) }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.dante(size: 13, weight: .medium)).foregroundStyle(theme.text.color)
                Text(detail).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            actions()
        }
    }

    // MARK: Summary and features

    private var runningLine: some View {
        let run = model.run
        return HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(runningText(run)).font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
            Spacer()
            if let last = run?.output.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                Text(last.trimmingCharacters(in: .whitespaces)).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color).lineLimit(1)
            }
        }
    }

    private func runningText(_ run: TestRun?) -> String {
        guard let run else { return "Starting…" }
        let done = run.passed + run.failed
        return done == 0 ? "Opening the browser…" : "\(done) scenario\(done == 1 ? "" : "s") told, \(run.failed) broke"
    }

    @ViewBuilder private var summary: some View {
        let all = model.features.flatMap(\.scenarios)
        if !all.isEmpty {
            let broke = all.count { $0.status == .failed }
            let last = all.compactMap(\.date).max()
            HStack(spacing: 10) {
                Image(systemName: broke == 0 ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .foregroundStyle(broke == 0 ? theme.green.color : theme.red.color)
                Text(broke == 0 ? "All \(all.count) scenarios in \(model.features.count) stories went as told."
                     : "\(broke) of \(all.count) scenarios broke. Open one to see where and why.")
                    .font(.dante(size: 14, weight: .medium)).foregroundStyle(theme.text.color)
                Spacer()
                if let last {
                    Text("Ran \(last.formatted(.relative(presentation: .named)))").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                }
            }
        }
    }

    @ViewBuilder private var featureGrid: some View {
        let features = model.features
        let untold = model.storyFiles.filter { file in !features.contains { $0.file == file } }
        if !features.isEmpty || !untold.isEmpty {
            CardGrid(minimum: 340) {
                ForEach(features) { feature in
                    StoryFeatureCard(session: session, workspace: workspace, feature: feature)
                }
                ForEach(untold, id: \.self) { file in
                    Card(StoryReport.featureName(file: file)) {
                        Text("Not run yet.").font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
                        HStack {
                            Button("Run it") { model.start(session: session, root: workspace.url, files: [file]) }
                                .buttonStyle(DanteButtonStyle()).disabled(!ready || model.isRunning)
                            LinkButton((file as NSString).lastPathComponent) { session.open(file: workspace.url.appending(path: file)) }
                        }
                    }
                }
            }
        } else if model.hasKit {
            EmptyState(symbol: "film.stack", title: "No stories yet", message: "Pick the stories to tell below and ask \(session.agentName) to write them.") { EmptyView() }
        }
    }

    // MARK: Ideas

    @ViewBuilder private var ideasCard: some View {
        @Bindable var model = model
        if !model.ideas.isEmpty, model.openFeature == nil {
            Card(model.storyFiles.isEmpty ? "Stories to tell" : "More stories to tell") {
                HStack(spacing: 8) {
                    Text("\(session.agentName) writes the chosen ones")
                        .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                    Button("Ask \(session.agentName) to write \(model.chosenIdeas.count)") { askToWrite() }
                        .buttonStyle(DanteButtonStyle(primary: true))
                        .disabled(model.chosenIdeas.isEmpty || model.target == nil)
                        .help("Sets up the kit if needed, then hands \(session.agentName) what Dante understood of the app and asks for the stories")
                }
            } content: {
                Text("Read from the app’s screens, what they call and what’s on them. Each comes with the scenarios worth simulating.")
                    .font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.ideas) { idea in
                        ideaRow(idea)
                        if idea.id != model.ideas.last?.id { Divider().overlay(theme.line.color) }
                    }
                }
            }
        }
    }

    private func ideaRow(_ idea: StoryIdea) -> some View {
        let chosen = model.chosenIdeas.contains(idea.id)
        return Button {
            if chosen { model.chosenIdeas.remove(idea.id) } else { model.chosenIdeas.insert(idea.id) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: chosen ? "checkmark.square.fill" : "square").foregroundStyle(chosen ? theme.accent.color : theme.text3.color)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(idea.title).font(.dante(size: 13, weight: .medium)).foregroundStyle(theme.text.color)
                        Text(idea.file).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color)
                    }
                    Text(idea.summary).font(.dante(size: 12)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        ForEach(idea.scenarios, id: \.self) { kind in
                            Text(kind.title).font(.dante(size: 10.5)).foregroundStyle(theme.text2.color)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.track.color.opacity(0.6)))
                        }
                        if !idea.calls.isEmpty {
                            Text("· calls \(idea.calls.count)").font(.dante(size: 10.5)).foregroundStyle(theme.text3.color)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func askToWrite() {
        if !model.hasKit || model.kitOutdated { model.setUp(root: workspace.url) }
        guard let brief = model.writeBrief(session: session) else { return }
        let count = model.chosenIdeas.count
        session.askClaude("Write \(count) front-end stor\(count == 1 ? "y" : "ies") for \(model.app?.name ?? "the web app") in \(model.folder ?? "stories")/.", instructions: brief)
    }
}

/// A feature's card: its scenarios with how they went, and a strip of its happy path's pictures.
struct StoryFeatureCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let feature: StoryFeature

    var body: some View {
        let model = session.stories
        Card(feature.name, spacing: 10) {
            HStack(spacing: 6) {
                if model.running.contains("*") || model.running.contains(feature.file) || feature.scenarios.contains(where: { model.running.contains($0.id) }) {
                    ProgressView().controlSize(.mini)
                }
                Button("Open") { model.openFeature = feature.id; model.openScenario = (feature.scenarios.first { $0.status == .failed } ?? feature.scenarios.first)?.id }
                    .buttonStyle(DanteButtonStyle())
            }
        } content: {
            if let about = feature.about {
                Text(about).font(.dante(size: 12)).foregroundStyle(theme.text2.color).lineLimit(2)
            }
            let lead = feature.scenarios.first { $0.status == .failed } ?? feature.scenarios.first { $0.kind == .happy } ?? feature.scenarios.first
            if let lead, !lead.steps.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(lead.steps) { step in
                            StoryShot(path: step.shot, height: 62, broken: !step.passed)
                                .help("\(step.index). \(step.title)")
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(feature.scenarios) { scenario in
                    Button {
                        model.openFeature = feature.id
                        model.openScenario = scenario.id
                    } label: {
                        HStack(spacing: 7) {
                            StoryStatusDot(status: scenario.status)
                            Text(scenario.title).font(.dante(size: 12.5)).foregroundStyle(theme.text.color).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(scenario.kind.title).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color)
                            if let duration = scenario.duration {
                                Text(String(format: "%.1f s", duration)).font(.dante(size: 10.5, design: .monospaced)).foregroundStyle(theme.text3.color)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if let broken = feature.scenarios.first(where: { $0.status == .failed }), let diagnosis = model.diagnoses[broken.id] {
                Text(diagnosis.headline).font(.dante(size: 11.5)).foregroundStyle(theme.red.color).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
    }
}

struct StoryStatusDot: View {
    @Environment(\.theme) private var theme
    let status: TestResult.Status

    var body: some View {
        Circle()
            .fill(status == .passed ? theme.green.color : status == .failed ? theme.red.color : theme.text3.color.opacity(0.5))
            .frame(width: 8, height: 8)
    }
}

/// A step's picture, loaded off the main thread and kept for the session.
struct StoryShot: View {
    @Environment(\.theme) private var theme
    let path: String?
    var height: CGFloat = 120
    var broken = false
    @State private var image: NSImage?

    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.track.color.opacity(0.5))
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay(Image(systemName: "photo").foregroundStyle(theme.text3.color).opacity(path == nil ? 1 : 0))
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(broken ? theme.red.color : theme.line.color, lineWidth: broken ? 2 : 1))
        .task(id: path) {
            guard let path else { image = nil; return }
            if let cached = Self.cache.object(forKey: path as NSString) { image = cached; return }
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: URL(fileURLWithPath: path)) }.value
            if let loaded = data.flatMap(NSImage.init(data:)) {
                Self.cache.setObject(loaded, forKey: path as NSString)
                image = loaded
            }
        }
    }

    /// Pictures change under the same path when a story runs again.
    static func forget() { cache.removeAllObjects() }
}
