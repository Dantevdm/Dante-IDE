import AppKit
import DanteEditor
import DanteKit
import SwiftUI

/// Ship › Deploy: the project on DigitalOcean's App Platform. Sign in through the browser,
/// let Dante write the app spec, deploy (building images here when the code isn't on a git
/// host App Platform reads), then watch deployments, health, metrics and logs, with security
/// findings and recommendations for the whole set-up.
struct DeployView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    @State private var confirmingDelete = false
    @State private var rollbackTarget: DODeployment?

    private var model: DeployModel { session.deploy }

    var body: some View {
        AreaPage(eyebrow: "DigitalOcean", title: model.app?.name ?? "Deploy", subtitle: subtitle) {
            actions
        } content: {
            if let problem = model.problem {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(problem).font(.dante(size: 12.5)).foregroundStyle(theme.amber.color).fixedSize(horizontal: false, vertical: true)
                    if problem.contains("Sign out and sign in again") {
                        Button("Sign in again") { model.problem = nil; model.signInAgain() }.buttonStyle(DanteButtonStyle(primary: true))
                    }
                }
            }
            if !model.signedIn {
                SignInCard(model: model)
            }
            if model.stage != nil || model.deployProblem != nil {
                DeployProgressCard(session: session, workspace: workspace)
            }
            if let app = model.app {
                LiveCard(session: session, app: app, rollbackTarget: $rollbackTarget)
                if !model.health.isEmpty || app.spec?.components.isEmpty == false {
                    ComponentsCard(session: session, model: model, app: app)
                }
                LogsCard(session: session, app: app)
            } else {
                PlanCard(session: session, workspace: workspace)
            }
            AdviceCard(session: session, workspace: workspace)
        }
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.environment["DANTE_DEPLOY_DEMO"] == "1" else { return }
            try? await Task.sleep(for: .seconds(1.5))
            model.showDemo(workspace: workspace)
        }
        #endif
        .task(id: workspace.revision) {
            await model.load(workspace: workspace)
        }
        .task(id: model.app?.id) {
            // While the page is open, look again every minute (every five seconds while deploying is `watch`).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard model.signedIn, model.linkedAppID != nil else { continue }
                await model.refresh()
                model.analyse(workspace: workspace)
            }
        }
        .onChange(of: model.health) { model.analyse(workspace: workspace) }
        .onChange(of: model.app?.updated) { model.analyse(workspace: workspace) }
        .sheet(isPresented: Binding(get: { model.wizardStep != nil || model.stage == .confirming || model.stage == .needsSecrets }, set: { if !$0 { model.closeWizard() } })) {
            DeploySheet(session: session, workspace: workspace).environment(\.theme, theme)
        }
        .confirmationDialog("Delete \(model.app?.name ?? "the app") from DigitalOcean?", isPresented: $confirmingDelete) {
            Button("Delete \(model.app?.name ?? "app")", role: .destructive) { model.delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The site stops and the app is removed, with any dev database it made. Images in the registry stay. This can’t be undone.")
        }
        .confirmationDialog("Roll back to this deployment?", isPresented: Binding(get: { rollbackTarget != nil }, set: { if !$0 { rollbackTarget = nil } })) {
            Button("Roll back") { if let target = rollbackTarget { model.rollback(to: target) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("App Platform puts back that deployment's build as it was. Pushes won’t deploy until you deploy again.")
        }
    }

    private var subtitle: String? {
        guard model.app == nil else { return nil }
        return "Deploy this project to App Platform and keep an eye on it: deployments, health, logs, and what to fix."
    }

    @ViewBuilder private var actions: some View {
        if model.signedIn {
            if let app = model.app {
                Menu {
                    Button("Open in DigitalOcean") { NSWorkspace.shared.open(URL(string: "https://cloud.digitalocean.com/apps/\(app.id)")!) }
                    Button("Unlink from this project") { model.unlink() }
                    Button("Sign out of DigitalOcean") { model.signOut() }
                    Divider()
                    Button("Delete app…", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).fixedSize()
                Button {
                    Task { await model.refresh(); model.analyse(workspace: workspace) }
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .buttonStyle(DanteButtonStyle())
                .disabled(model.loading)
            }
            Button { model.openWizard() } label: {
                Label(model.app == nil ? "Deploy…" : "Deploy again…", systemImage: "icloud.and.arrow.up")
            }
            .buttonStyle(DanteButtonStyle(primary: true))
            .disabled((model.spec ?? model.plan?.spec)?.components.isEmpty != false || model.isDeploying || model.stage == .checking)
            .help("Walks through the source, region, sizes, variables, database, domains and alerts, saves them to \(DOAppSpec.path), prices it and asks before anything is made")
        }
    }
}

// MARK: Signing in

private struct SignInCard: View {
    @Environment(\.theme) private var theme
    let model: DeployModel

    var body: some View {
        Card("DigitalOcean", accent: true) {
            Text("Sign in with your DigitalOcean account to deploy and watch the app. DigitalOcean’s page opens in your browser, where you’re already signed in; you choose the team and press Authorize there. Dante keeps the sign-in in the Keychain and asks only for App Platform, the container registry, metrics and reading databases.")
                .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { model.signIn() } label: {
                    if model.signingIn {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Waiting for the browser…") }
                    } else {
                        Label("Sign in with DigitalOcean", systemImage: "person.badge.key")
                    }
                }
                .buttonStyle(DanteButtonStyle(primary: true))
                .disabled(model.signingIn)
                if let problem = model.signInProblem {
                    Text(problem).font(.dante(size: 12)).foregroundStyle(theme.amber.color)
                }
            }
        }
    }
}

// MARK: Before the first deploy

private struct PlanCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    private var model: DeployModel { session.deploy }

    var body: some View {
        Card(model.specText == nil ? "What Dante would deploy" : "The app spec") {
            if model.specText != nil {
                LinkButton("Open \(DOAppSpec.path)") { session.open(file: workspace.url.appending(path: DOAppSpec.path)) }
            }
        } content: {
            if let problem = model.specProblem {
                Text("\(DOAppSpec.path) can’t be read: \(problem)").font(.dante(size: 12.5)).foregroundStyle(theme.red.color)
            }
            let spec = model.spec ?? model.plan?.spec
            if let spec, !spec.components.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(spec.components.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Rectangle().fill(theme.line.color).frame(height: 1) }
                        ComponentPlanRow(kind: item.kind, component: item.component)
                    }
                    ForEach(spec.databases ?? [], id: \.name) { database in
                        Rectangle().fill(theme.line.color).frame(height: 1)
                        HStack(spacing: 10) {
                            Image(systemName: "cylinder.split.1x2").foregroundStyle(theme.text3.color).frame(width: 18)
                            Text(database.name).font(.dante(size: 13, weight: .medium)).foregroundStyle(theme.text.color)
                            Text(database.production == true ? "Managed \(database.engine ?? "")" : "Dev \(database.engine ?? "") database")
                                .font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                        }
                        .padding(.vertical, 7)
                    }
                }
            } else if model.specText == nil {
                Text("Dante didn’t find an app to deploy: no Dockerfile, no app it recognises and no folder of HTML. Ask \(session.agentName) to add a Dockerfile, then come back.")
                    .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
            }
            if model.specText == nil, let plan = model.plan {
                VStack(alignment: .leading, spacing: 4) {
                    Text("From \(plan.source.label)\(plan.source.isGitHost ? ", branch \(model.branch): pushes deploy by themselves" : "").")
                    ForEach(plan.notes, id: \.self) { Text($0) }
                }
                .font(.dante(size: 12)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                ForEach(plan.gaps, id: \.self) { gap in
                    Label(gap, systemImage: "exclamationmark.triangle").font(.dante(size: 12)).foregroundStyle(theme.amber.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if plan.source.isGitHost {
                    Text("App Platform needs to be allowed to read the repository. If it isn’t yet, the deploy says so and offers the page to connect it.")
                        .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Picker("Region", selection: Binding(get: { model.region }, set: { model.setRegion($0, workspace: workspace) })) {
                        ForEach(DeployFormat.regions, id: \.code) { Text($0.city).tag($0.code) }
                    }
                    .fixedSize()
                    .help("Where the app runs. Pick the one nearest the people who use it")
                    Spacer()
                    Button { model.writeSpec(session: session, workspace: workspace) } label: {
                        Label("Write \(DOAppSpec.path)", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(DanteButtonStyle(primary: model.signedIn))
                    .disabled(plan.spec.components.isEmpty)
                    .help("Writes the spec into the project to review and commit; nothing is sent until you deploy")
                }
            }
            if model.signedIn {
                HStack(spacing: 8) {
                    if !model.apps.isEmpty {
                        Text("Already on DigitalOcean?").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                        Menu("Use an existing app") {
                            ForEach(model.apps) { app in
                                Button(app.name + (app.liveURL.map { " · " + ($0.host ?? "") } ?? "")) { model.link(app) }
                            }
                        }
                        .fixedSize()
                    }
                    Spacer()
                    Text("Signed in\(model.person.map { " as " + $0.label } ?? "")").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                    LinkButton("Sign out") { model.signOut() }
                }
            }
        }
    }
}

private struct ComponentPlanRow: View {
    @Environment(\.theme) private var theme
    let kind: DOAppSpec.Kind
    let component: DOAppSpec.Component

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: kind == .staticSite ? "doc.richtext" : kind == .service ? "server.rack" : "gearshape.2")
                .foregroundStyle(theme.text3.color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(component.name).font(.dante(size: 13, weight: .medium)).foregroundStyle(theme.text.color)
                    Text(kind.title).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                }
                Text(component.sourceLabel + (component.sourceDir.map { " · \($0)/" } ?? ""))
                    .font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text2.color).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if kind == .staticSite {
                Text("Free").font(.dante(size: 11.5)).foregroundStyle(theme.green.color)
            } else {
                Text([component.httpPort.map { "port \($0)" }, component.instanceSizeSlug.map(DeployFormat.size)].compactMap { $0 }.joined(separator: " · "))
                    .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            }
        }
        .padding(.vertical, 7)
    }
}

enum DeployFormat {
    /// A job by when it runs.
    static func job(_ kind: String?) -> String {
        switch kind?.uppercased() {
        case "PRE_DEPLOY": "Job · before each deploy"
        case "POST_DEPLOY": "Job · after each deploy"
        case "FAILED_DEPLOY": "Job · when a deploy fails"
        default: "Job"
        }
    }

    /// "ams" → "Amsterdam (ams)": DigitalOcean's region codes mean little on their own.
    static func region(_ code: String) -> String {
        regions.first { $0.code == code }.map { "\($0.city) (\(code))" } ?? code
    }

    static func city(_ code: String) -> String {
        regions.first { $0.code == code }?.city ?? code
    }

    /// App Platform's regions, with a globe turned to their side of the world.
    static let regions: [(code: String, city: String, symbol: String)] = [
        ("ams", "Amsterdam", "globe.europe.africa"), ("fra", "Frankfurt", "globe.europe.africa"), ("lon", "London", "globe.europe.africa"),
        ("nyc", "New York", "globe.americas"), ("tor", "Toronto", "globe.americas"), ("atl", "Atlanta", "globe.americas"),
        ("sfo", "San Francisco", "globe.americas"), ("sgp", "Singapore", "globe.asia.australia"), ("blr", "Bangalore", "globe.asia.australia"),
        ("syd", "Sydney", "globe.asia.australia"),
    ]

    /// The region nearest a time zone, roughly: App Platform has none in Africa or South
    /// America, so those go to Europe and the US east coast.
    static func suggestedRegion(for timeZone: String) -> String {
        let area = timeZone.split(separator: "/").first.map(String.init) ?? ""
        switch area {
        case "Europe":
            return ["London", "Dublin", "Lisbon"].contains { timeZone.hasSuffix($0) } ? "lon" : (["Amsterdam", "Brussels", "Paris"].contains { timeZone.hasSuffix($0) } ? "ams" : "fra")
        case "Africa": return "ams"
        case "America":
            if ["Los_Angeles", "Vancouver", "Phoenix", "Denver", "Tijuana"].contains(where: { timeZone.hasSuffix($0) }) { return "sfo" }
            if ["Toronto", "Montreal", "Halifax"].contains(where: { timeZone.hasSuffix($0) }) { return "tor" }
            return "nyc"
        case "Asia":
            return ["Kolkata", "Calcutta", "Colombo", "Karachi", "Dhaka", "Dubai"].contains { timeZone.hasSuffix($0) } ? "blr" : "sgp"
        case "Australia", "Pacific": return "syd"
        default: return "fra"
        }
    }

    /// "apps-s-1vcpu-0.5gb" → "1 vCPU · 0.5 GB".
    static func size(_ slug: String) -> String {
        let parts = slug.split(separator: "-")
        guard parts.count >= 4 else { return slug }
        let cpu = parts[2].replacingOccurrences(of: "vcpu", with: " vCPU"), memory = parts[3].replacingOccurrences(of: "gb", with: " GB")
        return "\(cpu) · \(memory)"
    }

    static func age(_ date: Date?) -> String {
        guard let date else { return "" }
        return date.formatted(.relative(presentation: .named))
    }

    static func money(_ value: Double) -> String {
        value == 0 ? "Free" : String(format: "$%.2f a month", value)
    }
}

// MARK: Deploying

private struct DeployProgressCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    @State private var showsLines = false
    private var model: DeployModel { session.deploy }

    var body: some View {
        Card("Deploying") {
            if model.isDeploying, model.stage != .watching {
                LinkButton("Stop") { model.cancelDeploy() }
            }
        } content: {
            if let problem = model.deployProblem {
                VStack(alignment: .leading, spacing: 8) {
                    Text(problem).font(.dante(size: 12.5)).foregroundStyle(theme.red.color).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    HStack(spacing: 8) {
                        if let connect = model.source.connectURL, DOSource.needsRepositoryAccess(problem) {
                            Button("Let App Platform read the repository") { NSWorkspace.shared.open(connect) }.buttonStyle(DanteButtonStyle(primary: true))
                        }
                        if problem.contains("Sign out and sign in again") {
                            Button("Sign in again") { model.signInAgain() }.buttonStyle(DanteButtonStyle(primary: true))
                        } else {
                            Button("Try again") { model.prepare(workspace: workspace) }.buttonStyle(DanteButtonStyle())
                        }
                        if !problem.contains("Sign out and sign in again") {
                            Button { session.askClaude(DeployBrief.failedDeploy(problem: problem, lines: model.buildLines)) } label: {
                                Label("Ask \(session.agentName) to fix it", systemImage: "wand.and.stars")
                            }
                            .buttonStyle(DanteButtonStyle())
                        }
                        Button("Dismiss") { model.deployProblem = nil }.buttonStyle(DanteButtonStyle())
                    }
                }
            } else if let stage = model.stage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(text(stage)).font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
                }
            }
            if !model.buildLines.isEmpty {
                LinkButton(showsLines ? "Hide the build output" : "Show the build output") { showsLines.toggle() }
                if showsLines || model.deployProblem != nil {
                    PlainLog(text: model.buildLines.suffix(60).joined(separator: "\n")).frame(height: 180)
                }
            }
        }
    }

    private func text(_ stage: DeployModel.Stage) -> String {
        switch stage {
        case .checking: "Checking the spec…"
        case .needsSecrets, .confirming: "Waiting for you to confirm."
        case .registry: "Making the container registry…"
        case .building(let step): step + "…"
        case .sending: "Sending the spec to DigitalOcean…"
        case .watching: "DigitalOcean is deploying it."
        }
    }
}

// MARK: After deploying

private struct LiveCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let app: DOApp
    @Binding var rollbackTarget: DODeployment?
    @State private var showsAll = false
    private var model: DeployModel { session.deploy }

    var body: some View {
        Card(nil, accent: app.current?.phase.isRunning == true) {
            HStack(alignment: .center, spacing: 14) {
                PhaseDot(phase: app.current?.phase ?? .unknown)
                VStack(alignment: .leading, spacing: 3) {
                    if let url = app.liveURL {
                        Button { NSWorkspace.shared.open(url) } label: {
                            HStack(spacing: 5) {
                                Text(url.host ?? url.absoluteString).font(.dante(size: 15, weight: .semibold))
                                Image(systemName: "arrow.up.right").font(.dante(size: 11))
                            }
                            .foregroundStyle(theme.accent.color)
                        }
                        .buttonStyle(.plain)
                        .help("Open the live site")
                    } else {
                        Text("No address yet").font(.dante(size: 15, weight: .semibold)).foregroundStyle(theme.text2.color)
                    }
                    Text([app.current?.phase.title, app.region.map { "in " + DeployFormat.region($0) }, model.person.map { $0.label }].compactMap { $0 }.joined(separator: " · "))
                        .font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                }
                Spacer()
                if app.current?.phase.isRunning == true {
                    Button("Cancel deployment") { model.cancelRunning() }.buttonStyle(DanteButtonStyle())
                }
            }
            // An app that has never gone live has no current deployment; its newest one says why.
            let latest = app.current ?? model.deployments.first
            if let running = latest, running.phase.isRunning || running.phase == .error {
                StepTrack(deployment: running)
            }
            if let failed = latest, failed.phase == .error, let failure = failed.failure {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(theme.red.color)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Failed at \(failure.place)").font(.dante(size: 12.5, weight: .semibold)).foregroundStyle(theme.text.color)
                        Text(failure.message).font(.dante(size: 12)).foregroundStyle(theme.text2.color).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button {
                        model.logKind = .build
                        model.loadLogs()
                        session.askClaude(DeployBrief.failedDeployment(app: app, failure: failure, logs: model.logText))
                    } label: { Label("Ask \(session.agentName) to fix it", systemImage: "wand.and.stars") }
                    .buttonStyle(DanteButtonStyle())
                }
            }
            if !model.deployments.isEmpty {
                Rectangle().fill(theme.line.color).frame(height: 1)
                let shown = showsAll ? model.deployments : Array(model.deployments.prefix(5))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { deployment in
                        DeploymentRow(deployment: deployment, isLive: deployment.id == app.active?.id) {
                            rollbackTarget = deployment
                        }
                    }
                }
                if model.deployments.count > 5 {
                    LinkButton(showsAll ? "Show fewer" : "All \(model.deployments.count) deployments") { showsAll.toggle() }
                }
            }
        }
    }
}

private struct PhaseDot: View {
    @Environment(\.theme) private var theme
    let phase: DODeployment.Phase
    @State private var pulse = false

    var body: some View {
        let color = phase == .active ? theme.green.color : phase == .error ? theme.red.color : phase.isRunning ? theme.accent.color : theme.text3.color
        ZStack {
            if phase.isRunning {
                Circle().stroke(color.opacity(0.5), lineWidth: 2).frame(width: 22, height: 22).scaleEffect(pulse ? 1.4 : 0.8).opacity(pulse ? 0 : 1)
            }
            Circle().fill(color).frame(width: 12, height: 12)
        }
        .frame(width: 26, height: 26)
        .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true } }
    }
}

/// The deployment's steps (build, deploy…) as chips joined by a line, like the pipeline lanes.
private struct StepTrack: View {
    @Environment(\.theme) private var theme
    let deployment: DODeployment

    var body: some View {
        let steps = deployment.progress?.steps ?? []
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index > 0 { Rectangle().fill(step.isDone || step.isRunning ? theme.accent.color.opacity(0.6) : theme.line.color).frame(width: 18, height: 2) }
                HStack(spacing: 5) {
                    Image(systemName: step.isDone ? "checkmark.circle.fill" : step.isError ? "xmark.circle.fill" : step.isRunning ? "circle.dotted" : "circle")
                        .foregroundStyle(step.isDone ? theme.green.color : step.isError ? theme.red.color : step.isRunning ? theme.accent.color : theme.text3.color)
                        .symbolEffect(.pulse, isActive: step.isRunning)
                    Text(step.title).font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(step.isRunning ? theme.accentTint.color : theme.raised.color))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(step.isRunning ? theme.accentLine.color : theme.line.color))
            }
            Spacer(minLength: 0)
        }
    }
}

private struct DeploymentRow: View {
    @Environment(\.theme) private var theme
    let deployment: DODeployment
    let isLive: Bool
    let rollBack: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(isLive ? "Live" : deployment.phase.title).font(.dante(size: 12, weight: isLive ? .semibold : .regular))
                .foregroundStyle(isLive ? theme.green.color : theme.text2.color).frame(width: 110, alignment: .leading)
            Text(deployment.causeText).font(.dante(size: 12)).foregroundStyle(theme.text2.color).lineLimit(1)
            if let commit = deployment.commit {
                Text(String(commit.prefix(7))).font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color)
            }
            Spacer(minLength: 8)
            Text(DeployFormat.age(deployment.created)).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            if !isLive, deployment.phase == .superseded {
                LinkButton("Roll back to this", action: rollBack)
            }
        }
        .padding(.vertical, 5)
    }

    private var color: Color {
        switch deployment.phase {
        case .active: theme.green.color
        case .error: theme.red.color
        case .canceled, .superseded, .unknown: theme.text3.color
        default: theme.accent.color
        }
    }
}

private struct ComponentsCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let model: DeployModel
    let app: DOApp

    var body: some View {
        Card("Components") {
            Text("Last hour").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array((app.spec?.components ?? []).enumerated()), id: \.offset) { index, item in
                    if index > 0 { Rectangle().fill(theme.line.color).frame(height: 1) }
                    row(item.kind, item.component)
                }
            }
        }
    }

    private func row(_ kind: DOAppSpec.Kind, _ component: DOAppSpec.Component) -> some View {
        let health = model.health.first { $0.name == component.name }
        return HStack(spacing: 12) {
            Circle().fill(health.map { $0.isHealthy ? theme.green.color : theme.red.color } ?? theme.text3.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(component.name).font(.dante(size: 13, weight: .medium)).foregroundStyle(theme.text.color)
                Text([kind.title, health.flatMap { h in h.replicasDesired.map { "\(h.replicasReady ?? 0) of \($0) ready" } }, component.instanceSizeSlug.map(DeployFormat.size)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            }
            .frame(width: 220, alignment: .leading)
            if kind != .staticSite {
                Meter(label: "CPU", series: model.cpu[component.name], now: health?.cpuUsagePercent)
                Meter(label: "Memory", series: model.memory[component.name], now: health?.memoryUsagePercent)
                if let restarts = model.restarts[component.name], restarts > 0 {
                    Text("\(Int(restarts)) restart\(restarts == 1 ? "" : "s") today").font(.dante(size: 11.5)).foregroundStyle(theme.amber.color)
                }
            }
            Spacer(minLength: 0)
            // A shell inside it, for one-off commands (creating keys, a migration by hand).
            if kind == .service || kind == .worker, app.active != nil {
                if model.openingConsole == component.name {
                    ProgressView().controlSize(.small)
                } else {
                    Button { model.openConsole(component.name, session: session) } label: {
                        Label("Console", systemImage: "terminal")
                    }
                    .buttonStyle(DanteButtonStyle())
                    .help("Opens a shell inside the running \(component.name) in a terminal tab, like DigitalOcean's own Console.")
                }
            }
        }
        .padding(.vertical, 8)
    }
}

/// A percentage now and a sparkline of the last hour.
private struct Meter: View {
    @Environment(\.theme) private var theme
    let label: String
    let series: DOSeries?
    let now: Double?

    var body: some View {
        let value = now ?? series?.last
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color)
                Text(value.map { "\(Int($0.rounded()))%" } ?? "—").font(.dante(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle((value ?? 0) > 85 ? theme.red.color : theme.text.color)
            }
            .frame(width: 52, alignment: .leading)
            Canvas { context, size in
                let points = series?.points ?? []
                guard points.count > 1 else { return }
                let peak = max(points.map(\.1).max() ?? 1, 10)
                var path = Path()
                for (index, point) in points.enumerated() {
                    let x = size.width * CGFloat(index) / CGFloat(points.count - 1)
                    let y = size.height * (1 - CGFloat(point.1 / peak))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(path, with: .color(theme.accent.color), lineWidth: 1.5)
            }
            .frame(width: 90, height: 24)
        }
    }
}

private struct LogsCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let app: DOApp
    private var model: DeployModel { session.deploy }

    var body: some View {
        @Bindable var model = model
        Card("Logs") {
            Picker("", selection: $model.logKind) {
                ForEach(DOClient.LogKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            Picker("", selection: $model.logComponent) {
                Text("Every component").tag(String?.none)
                ForEach((app.spec?.components ?? []).map(\.component.name), id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .fixedSize()
            Button { model.loadLogs() } label: {
                if model.loadingLogs { ProgressView().controlSize(.small) } else { Label("Load", systemImage: "arrow.down.doc") }
            }
            .buttonStyle(DanteButtonStyle())
        } content: {
            if model.logText.isEmpty {
                Text(model.loadingLogs ? "Fetching the logs…"
                     : model.logsLoadedFor != nil ? "No \(model.logKind.title.lowercased()) log lines yet. Press Load again to look for new ones."
                     : "Press Load for the \(model.logKind.title.lowercased()) logs of the \(model.logKind == .run ? "live" : "latest") deployment.")
                    .font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
            } else {
                PlainLog(text: model.logText).frame(height: 260)
            }
        }
        .onChange(of: model.logKind) { if !model.logText.isEmpty || model.logsLoadedFor != nil { model.loadLogs() } }
        .onChange(of: model.logComponent) { if !model.logText.isEmpty || model.logsLoadedFor != nil { model.loadLogs() } }
    }
}

/// Read-only monospaced text that keeps to the bottom, for logs and build output.
struct PlainLog: NSViewRepresentable {
    @Environment(\.theme) private var theme
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: DanteFonts.mono(size: 11, weight: .regular),
            .foregroundColor: NSColor(theme.text2.color),
        ]))
        textView.scrollToEndOfDocument(nil)
    }
}

// MARK: Security and recommendations

private struct AdviceCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    @State private var showsTips = false
    private var model: DeployModel { session.deploy }

    var body: some View {
        let security = model.advice.filter(\.isSecurity)
        let others = model.advice.filter { !$0.isSecurity && $0.severity > .info }
        let tips = model.advice.filter { !$0.isSecurity && $0.severity == .info }
        if model.spec != nil || model.app != nil || !model.advice.isEmpty {
            Card("Security and recommendations") {
                if !model.advice.isEmpty {
                    Button {
                        session.askClaude(DeployBrief.advice(model.advice.filter { $0.severity > .info }, hasFile: model.specText != nil))
                    } label: { Label("Ask \(session.agentName) to fix these", systemImage: "wand.and.stars") }
                    .buttonStyle(DanteButtonStyle())
                    .disabled(model.advice.allSatisfy { $0.severity == .info })
                }
            } content: {
                Text(summary(security: security.count, others: others.count, tips: tips.count))
                    .font(.dante(size: 12.5)).foregroundStyle(security.isEmpty ? theme.green.color : theme.text2.color)
                group("Security", security)
                group("Recommendations", others)
                if !tips.isEmpty {
                    LinkButton(showsTips ? "Hide \(tips.count) tip\(tips.count == 1 ? "" : "s")" : "Show \(tips.count) tip\(tips.count == 1 ? "" : "s")") { showsTips.toggle() }
                    if showsTips { group(nil, tips) }
                }
                Text("Checked: \(DOAppSpec.path), the Dockerfiles\(model.app == nil ? "" : ", the app as it runs, its health and alerts\(model.headers == nil ? "" : ", and the live site’s headers")").")
                    .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            }
        }
    }

    private func summary(security: Int, others: Int, tips: Int) -> String {
        if security == 0 && others == 0 { return "Nothing to fix" + (tips > 0 ? "; a few tips below." : ".") }
        let parts = [security > 0 ? "\(security) security finding\(security == 1 ? "" : "s")" : nil, others > 0 ? "\(others) recommendation\(others == 1 ? "" : "s")" : nil]
        return parts.compactMap { $0 }.joined(separator: " and ") + "."
    }

    @ViewBuilder private func group(_ title: String?, _ items: [DOAdvice]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if let title { Eyebrow(title).padding(.bottom, 4) }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Rectangle().fill(theme.line.color).frame(height: 1) }
                    AdviceRow(item: item)
                }
            }
        }
    }
}

private struct AdviceRow: View {
    @Environment(\.theme) private var theme
    let item: DOAdvice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(item.severity.title).font(.dante(size: 10.5, weight: .semibold)).foregroundStyle(color)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.12)))
                .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.title).font(.dante(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color)
                    if let place = item.place {
                        Text(place).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color)
                    }
                }
                Text(item.detail).font(.dante(size: 12)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                Text(item.fix).font(.dante(size: 12)).foregroundStyle(theme.text.color).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text(item.area.title).font(.dante(size: 11)).foregroundStyle(theme.text3.color)
        }
        .padding(.vertical, 8)
    }

    private var color: Color {
        switch item.severity {
        case .critical, .high: theme.red.color
        case .medium: theme.amber.color
        case .low: theme.accent.color
        case .info: theme.text3.color
        }
    }
}
