import AppKit
import DanteKit
import SwiftUI

/// One story opened: its scenarios as tabs, the chosen one's storyboard (a picture per step),
/// and when it broke, why (with the step as it looked when it last passed), the code to open
/// and the agent to ask.
struct StoryDetail: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let feature: StoryFeature
    @State private var playing: StoryScenario?

    private var model: StoriesModel { session.stories }
    private var scenario: StoryScenario? { feature.scenarios.first { $0.id == model.openScenario } ?? feature.scenarios.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            tabs
            if let scenario {
                meta(scenario)
                if let diagnosis = model.diagnoses[scenario.id] { why(scenario, diagnosis) }
                storyboard(scenario)
            }
        }
        .sheet(item: $playing) { scenario in
            StoryPlayer(scenario: scenario) { playing = nil }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { model.openFeature = nil } label: { Label("All stories", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
            Text(feature.name).font(.dante(size: 20, weight: .semibold)).foregroundStyle(theme.text.color)
            if let about = feature.about {
                Text(about).font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).lineLimit(1)
            }
            Spacer()
            LinkButton((feature.file as NSString).lastPathComponent) { session.open(file: workspace.url.appending(path: feature.file)) }
            Button { model.start(session: session, root: workspace.url, files: [feature.file]) } label: { Label("Run this story", systemImage: "play.fill") }
                .buttonStyle(DanteButtonStyle())
                .disabled(model.isRunning || model.listening != true || !model.hasPlaywright)
        }
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(feature.scenarios) { item in
                    Button { model.openScenario = item.id } label: {
                        HStack(spacing: 6) {
                            StoryStatusDot(status: item.status)
                            Text(item.title).font(.dante(size: 12.5))
                            Text(item.kind.title).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color)
                        }
                        .foregroundStyle(theme.text.color)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(item.id == scenario?.id ? theme.accent.color.opacity(0.12) : theme.card.color))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(item.id == scenario?.id ? theme.accent.color : theme.line.color))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func meta(_ scenario: StoryScenario) -> some View {
        HStack(spacing: 10) {
            Text(scenario.status == .passed ? "Went as told" : scenario.status == .failed ? "Broke" : "Didn’t run")
                .font(.dante(size: 13, weight: .semibold))
                .foregroundStyle(scenario.status == .passed ? theme.green.color : scenario.status == .failed ? theme.red.color : theme.text3.color)
            Text([scenario.steps.isEmpty ? nil : "\(scenario.steps.count) steps",
                  scenario.duration.map { String(format: "%.1f s", $0) },
                  scenario.viewport.map { "phone size \($0)" },
                  scenario.date.map { "ran " + $0.formatted(.relative(presentation: .named)) }].compactMap { $0 }.joined(separator: " · "))
                .font(.dante(size: 12)).foregroundStyle(theme.text3.color)
            Spacer()
            if scenario.steps.contains(where: { $0.shot != nil }) {
                Button { playing = scenario } label: { Label("Play", systemImage: "play.rectangle") }
                    .buttonStyle(DanteButtonStyle())
                    .help("Shows the steps one after another, with their captions")
            }
            if let video = scenario.video, FileManager.default.fileExists(atPath: video) {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: video)) } label: { Label("Video", systemImage: "film") }
                    .buttonStyle(DanteButtonStyle())
                    .help("The browser’s recording of the whole scenario")
            }
            if let trace = scenario.trace, FileManager.default.fileExists(atPath: trace) {
                Button { openTrace(trace) } label: { Label("Trace", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                    .buttonStyle(DanteButtonStyle())
                    .help("Every action, call and page state in Playwright’s trace viewer, on this Mac")
            }
            Button { model.start(session: session, root: workspace.url, scenarios: [scenario]) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(DanteButtonStyle())
                .disabled(model.isRunning || model.listening != true)
                .help("Run this scenario again")
        }
    }

    // MARK: Why it broke

    private func why(_ scenario: StoryScenario, _ diagnosis: StoryDiagnosis) -> some View {
        let before = diagnosis.step.flatMap { index in model.passes[scenario.id]?.steps.first { $0.index == index } }
        let now = diagnosis.step.flatMap { index in scenario.steps.first { $0.index == index } }
        return Card(nil, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "stethoscope").foregroundStyle(theme.red.color).font(.dante(size: 15))
                VStack(alignment: .leading, spacing: 6) {
                    Text(diagnosis.headline).font(.dante(size: 14, weight: .semibold)).foregroundStyle(theme.text.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(diagnosis.blame.title).font(.dante(size: 11, weight: .medium))
                        .foregroundStyle(diagnosis.blame == .app ? theme.red.color : diagnosis.blame == .setup ? theme.text2.color : theme.amber.color)
                    ForEach(diagnosis.details, id: \.self) { line in
                        Text(line).font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let handler = diagnosis.handler {
                LinkButton("Open \((handler.file as NSString).lastPathComponent):\(handler.line), which serves the call") {
                    session.open(file: workspace.url.appending(path: handler.file), line: handler.line)
                }
            }
            if !diagnosis.changed.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Changed since it last passed\(model.passes[scenario.id].map { " (" + $0.date.formatted(.relative(presentation: .named)) + ")" } ?? "")")
                        .font(.dante(size: 11.5, weight: .medium)).foregroundStyle(theme.text3.color)
                    ForEach(diagnosis.changed.prefix(8), id: \.self) { file in
                        LinkButton(file) { session.open(file: workspace.url.appending(path: file)) }
                    }
                }
            }
            if !diagnosis.serverLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("The server’s log").font(.dante(size: 11.5, weight: .medium)).foregroundStyle(theme.text3.color)
                    ForEach(diagnosis.serverLines, id: \.self) { line in
                        Text(line).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text2.color).textSelection(.enabled)
                    }
                }
            }
            if now?.shot != nil {
                HStack(alignment: .top, spacing: 12) {
                    if let before, before.shot != nil {
                        labelled("When it last passed", StoryShot(path: before.shot, height: 150))
                    }
                    labelled("Now", StoryShot(path: now?.shot, height: 150, broken: true))
                }
            }
            HStack(spacing: 8) {
                Button { askToFix(scenario, diagnosis) } label: { Label("Ask \(session.agentName) to fix it", systemImage: "wand.and.stars") }
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .help("Hands over the story, where it broke, Dante’s reading and the picture; \(session.agentName) decides whether the app or the story should change")
                if let line = scenario.failedStep.flatMap({ _ in scenario.issues.first?.line }) {
                    LinkButton("Open the story at line \(line)") { session.open(file: workspace.url.appending(path: scenario.file), line: line) }
                }
            }
        }
    }

    private func labelled(_ title: String, _ shot: StoryShot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.dante(size: 11)).foregroundStyle(theme.text3.color)
            Button { if let path = shot.path { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } } label: { shot }.buttonStyle(.plain)
        }
    }

    private func askToFix(_ scenario: StoryScenario, _ diagnosis: StoryDiagnosis) {
        let rerun = model.rerunCommand(files: [scenario.file], grep: scenario.title)
        let brief = StoryDiagnosis.brief(scenario, diagnosis: diagnosis, rerun: rerun)
        session.askClaude("The story “\(scenario.feature) › \(scenario.title)” broke: \(diagnosis.headline)", instructions: brief)
    }

    // MARK: Storyboard

    private func storyboard(_ scenario: StoryScenario) -> some View {
        Group {
            if scenario.steps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No steps were recorded: the story doesn’t use story.step from dante-story.ts, or it broke before the first.")
                        .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
                    ForEach(scenario.issues.prefix(2), id: \.message) { issue in
                        Text(issue.message).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text2.color).textSelection(.enabled)
                    }
                }
            } else {
                CardGrid(minimum: 260) {
                    ForEach(scenario.steps) { step in
                        stepCard(step)
                    }
                }
            }
        }
    }

    private func stepCard(_ step: StoryScenario.Step) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { if let shot = step.shot { NSWorkspace.shared.open(URL(fileURLWithPath: shot)) } } label: {
                StoryShot(path: step.shot, height: 160, broken: !step.passed).frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .help("Open the picture")
            HStack(alignment: .top, spacing: 8) {
                Text("\(step.index)")
                    .font(.dante(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.onAccent.color)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(step.passed ? theme.green.color : theme.red.color))
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title).font(.dante(size: 13, weight: .medium)).foregroundStyle(theme.text.color).fixedSize(horizontal: false, vertical: true)
                    Text([step.url.flatMap { URLComponents(string: $0)?.path }, step.ms > 0 ? "\(step.ms) ms" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color)
                }
            }
            if let error = step.error {
                Text(error.split(separator: "\n").prefix(4).joined(separator: "\n"))
                    .font(.dante(size: 10.5, design: .monospaced)).foregroundStyle(theme.red.color).lineLimit(4).textSelection(.enabled)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(step.passed ? theme.line.color : theme.red.color.opacity(0.6)))
    }

    private func openTrace(_ trace: String) {
        let folder = URL(fileURLWithPath: trace).deletingLastPathComponent().path
        let command = """
        d=\(Shell.quote(folder)); while [ ! -x "$d/node_modules/.bin/playwright" ] && [ "$d" != / ]; do d=$(dirname "$d"); done; \
        "$d/node_modules/.bin/playwright" show-trace \(Shell.quote(trace))
        """
        session.runInNewTerminal(command, title: "Trace")
    }
}

/// The steps one after another, large, with their captions: how the feature works, as a show.
struct StoryPlayer: View {
    @Environment(\.theme) private var theme
    let scenario: StoryScenario
    let close: () -> Void
    @State private var index = 0
    @State private var paused = false

    private var steps: [StoryScenario.Step] { scenario.steps }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("\(scenario.feature) › \(scenario.title)").font(.dante(size: 14, weight: .semibold)).foregroundStyle(theme.text.color)
                Spacer()
                Button("Done", action: close).buttonStyle(DanteButtonStyle()).keyboardShortcut(.cancelAction)
            }
            if steps.indices.contains(index) {
                let step = steps[index]
                StoryShot(path: step.shot, height: 460, broken: !step.passed)
                    .id(step.id)
                    .transition(.opacity)
                Text(step.title).font(.dante(size: 20, weight: .medium)).foregroundStyle(step.passed ? theme.text.color : theme.red.color)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button { go(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(DanteButtonStyle()).keyboardShortcut(.leftArrow, modifiers: [])
                Button { paused.toggle() } label: { Image(systemName: paused ? "play.fill" : "pause.fill") }.buttonStyle(DanteButtonStyle()).keyboardShortcut(.space, modifiers: [])
                Button { go(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(DanteButtonStyle()).keyboardShortcut(.rightArrow, modifiers: [])
                HStack(spacing: 5) {
                    ForEach(steps.indices, id: \.self) { item in
                        Circle().fill(item == index ? theme.accent.color : steps[item].passed ? theme.text3.color.opacity(0.4) : theme.red.color)
                            .frame(width: 7, height: 7)
                    }
                }
                Text("\(index + 1) of \(steps.count)").font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text3.color)
            }
        }
        .padding(22)
        .frame(minWidth: 760, minHeight: 600)
        .background(theme.ground.color)
        .task(id: paused) {
            while !paused, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2600))
                guard !paused, !Task.isCancelled else { break }
                if index + 1 < steps.count { go(1) } else { paused = true }
            }
        }
    }

    private func go(_ delta: Int) {
        withAnimation(.easeInOut(duration: 0.35)) { index = max(0, min(steps.count - 1, index + delta)) }
    }
}
