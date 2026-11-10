import DanteKit
import SwiftUI

/// Quality › Bliksem: hammer the running app with load, throw garbage at its routes, or break
/// one of its compose services and time the recovery. Only this Mac and test hosts are hit.
struct BliksemView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    @State private var showsAllRoutes = false

    private var model: BliksemModel { session.bliksem }

    var body: some View {
        @Bindable var model = model
        AreaPage(eyebrow: nil, title: "Bliksem", subtitle: "Hammer it, throw garbage at it, break things, and see what gives. Only this Mac and test hosts are ever hit.") {
            if model.running != nil {
                Button(role: .destructive) { model.stop() } label: { Label(model.running == .chaos ? "Stop and put it back" : "Stop", systemImage: "stop.fill") }
                    .buttonStyle(DanteButtonStyle())
                    .help(model.running == .chaos ? "Ends the run now; the service is put back first" : "Ends the run now")
            } else {
                Button { model.start(session: session, root: workspace.url) } label: { Label(startTitle, systemImage: model.mode.symbol) }
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .disabled(!model.routesLoaded || model.selectedRoutes.isEmpty || model.target.isEmpty || (model.mode == .chaos && model.service == nil))
                    .help(startHelp)
            }
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                modes
                if let problem = model.problem {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.amber.color)
                        Text(problem).font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                    }
                }
                CardGrid(minimum: 360) {
                    targetCard
                    settingsCard
                }
                results
                routesCard
            }
        }
        .task(id: workspace.revision) { await model.load(session: session, workspace: workspace) }
    }

    private var startTitle: String {
        switch model.mode {
        case .load: "Hammer it"
        case .fuzz: "Throw garbage"
        case .chaos: "Break \(model.service ?? "it")"
        }
    }

    private var startHelp: String {
        switch model.mode {
        case .load: "Sends requests from up to \(LoadPlan.standard(peak: model.peakUsers, seconds: model.seconds).peak) users at once for \(model.seconds) s"
        case .fuzz: "Sends \(Fuzz.cases(for: model.selectedRoutes, includeWrites: model.includeWrites, kinds: model.fuzzKinds).count) odd requests, four at a time"
        case .chaos: "Runs a light load, \(model.fault.label.lowercased()) for 20 s, puts it back and times the recovery"
        }
    }

    // MARK: Modes

    private var modes: some View {
        HStack(spacing: 10) {
            ForEach(BliksemModel.Mode.allCases) { mode in
                Button { if model.running == nil { model.mode = mode } } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: mode.symbol).font(.dante(size: 16)).foregroundStyle(model.mode == mode ? theme.accent.color : theme.text3.color)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title).font(.dante(size: 13.5, weight: .semibold)).foregroundStyle(theme.text.color)
                            Text(summary(mode)).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if model.running == mode { ProgressView().controlSize(.small) }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(model.mode == mode ? theme.accent.color.opacity(0.08) : theme.card.color))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(model.mode == mode ? theme.accent.color : theme.line.color, lineWidth: model.mode == mode ? 1.5 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.running != nil && model.running != mode)
            }
        }
    }

    private func summary(_ mode: BliksemModel.Mode) -> String {
        switch mode {
        case .load: "Load: ramp up users, spike, and find where it breaks."
        case .fuzz: "Fuzz: odd, huge and hostile input on every route."
        case .chaos: "Chaos: stop or freeze a service under load, time the recovery."
        }
    }

    // MARK: Target and settings

    private var targetCard: some View {
        @Bindable var model = model
        return Card("Target") {
            TextField("http://localhost:8080", text: $model.target)
                .textFieldStyle(.roundedBorder)
                .font(.dante(size: 13, design: .monospaced))
                .disabled(model.running != nil)
            if model.targetsLive {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "cloud.fill").foregroundStyle(theme.amber.color)
                    Text("The live app on DigitalOcean: real traffic, at most \(LiveLoadTest.maxUsers) users at once, load tests only. Autoscaling may add copies (and cost) while it runs, and people using the app feel it.")
                        .font(.dante(size: 12)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Stop allowing") { model.forgetLive(root: workspace.url) }.buttonStyle(DanteButtonStyle()).disabled(model.running != nil)
                }
            }
            if model.suggestions.isEmpty, model.findingTargets {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Looking for the servers this project runs…").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                }
            } else if model.suggestions.isEmpty {
                Text("Nothing this project runs is listening yet. Start the app (Local › Services or a terminal), or type its address.")
                    .font(.dante(size: 12)).foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true)
            } else {
                FlowChips(items: model.suggestions.map(\.url.absoluteString)) { address in
                    let note = model.suggestions.first { $0.url.absoluteString == address }?.note ?? ""
                    Button { model.target = address } label: {
                        Chip(text: address.replacingOccurrences(of: "http://", with: ""), symbol: "dot.radiowaves.left.and.right", mono: true, selected: model.target == address)
                    }
                    .buttonStyle(.plain)
                    .help("\(address): \(note)")
                    .disabled(model.running != nil)
                }
            }
            Text("Only localhost, .localhost and .test addresses, and hosts under browser: hosts: in .dante/project.yaml.")
                .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var settingsCard: some View {
        @Bindable var model = model
        switch model.mode {
        case .load:
            Card("Load") {
                Stepper(value: $model.peakUsers, in: 1...((model.targetsLive ? LiveLoadTest.maxUsers : Bliksem.maxUsers) / 2), step: model.peakUsers < 10 ? 1 : 5) {
                    settingRow("Users at peak", "\(model.peakUsers), spiking to \(min(model.peakUsers * 2, Bliksem.maxUsers))")
                }
                .disabled(model.running != nil)
                Picker(selection: $model.seconds) {
                    ForEach([30, 60, 120, 300], id: \.self) { Text($0 < 60 ? "\($0) s" : "\($0 / 60) min").tag($0) }
                } label: { settingRow("How long", "") }
                    .pickerStyle(.segmented)
                    .disabled(model.running != nil)
                StagesStrip(plan: LoadPlan.standard(peak: model.peakUsers, seconds: model.seconds), elapsed: model.running == .load ? model.loadTick?.elapsed : nil)
            }
        case .fuzz:
            Card("Garbage") {
                FlowChips(items: FuzzPayload.Kind.allCases.map(\.rawValue)) { raw in
                    let kind = FuzzPayload.Kind(rawValue: raw)!
                    let on = model.fuzzKinds.contains(kind)
                    Button { if on { model.fuzzKinds.remove(kind) } else { model.fuzzKinds.insert(kind) } } label: {
                        Chip(text: kind.label, selected: on)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.running != nil)
                }
                Text("Probes read, never write: no DROP, DELETE or UPDATE is ever sent. Bodies go only to write routes, and only with writes on.")
                    .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true)
            }
        case .chaos:
            Card("Break") {
                if model.services.isEmpty {
                    Text("No compose service of this project is running. Start them in Local › Services, then come back.")
                        .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                    LinkButton("Open Services") { session.area = .environments }
                } else {
                    Picker(selection: Binding(get: { model.service ?? "" }, set: { model.service = $0 })) {
                        ForEach(model.services, id: \.self) { Text($0).tag($0) }
                    } label: { settingRow("Service", "") }
                        .disabled(model.running != nil)
                    Picker(selection: $model.fault) {
                        ForEach(ChaosFault.allCases) { Text($0.label).tag($0) }
                    } label: { settingRow("How", "") }
                        .pickerStyle(.segmented)
                        .disabled(model.running != nil)
                    Text(model.fault.explanation + " Only this project’s own services, and only when you press the button.")
                        .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func settingRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
            if !value.isEmpty { Text(value).font(.dante(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color) }
        }
    }

    // MARK: Routes

    private var routesCard: some View {
        @Bindable var model = model
        let routes = model.routes
        let shown = showsAllRoutes ? routes : Array(routes.prefix(10))
        return Card("Routes") {
            HStack(spacing: 10) {
                Text("\(model.selectedRoutes.count) of \(routes.count)").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                Toggle("Include writes", isOn: $model.includeWrites)
                    .toggleStyle(.checkbox).font(.dante(size: 12))
                    .disabled(model.running != nil)
                    .help("Also send POST, PUT, PATCH and DELETE. They can change the data in whatever the app is connected to")
                Button("All") { model.chosen = Set(routes.map(\.id)) }.buttonStyle(DanteButtonStyle()).disabled(model.running != nil)
                Button("None") { model.chosen = [] }.buttonStyle(DanteButtonStyle()).disabled(model.running != nil)
            }
        } content: {
            if !model.routesLoaded {
                Text("Reading the routes from the code…").font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
            } else if routes.isEmpty {
                Text("No routes found in the code. Bliksem takes the API's routes from the Map; a project whose server Dante can't read gets no routes yet.")
                    .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
            } else {
                if model.includeWrites, routes.contains(where: { !$0.isRead }) {
                    Text("Writes are on: these requests can create, change and delete data. Point Bliksem at a throwaway database.")
                        .font(.dante(size: 12)).foregroundStyle(theme.amber.color)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, route in
                        if index > 0 { Rectangle().fill(theme.line.color).frame(height: 1) }
                        routeRow(route)
                    }
                }
                if routes.count > 10 {
                    LinkButton(showsAllRoutes ? "Show fewer" : "Show all \(routes.count) routes") { showsAllRoutes.toggle() }
                }
            }
        }
    }

    private func routeRow(_ route: BliksemRoute) -> some View {
        let usable = route.isRead || model.includeWrites
        let on = model.chosen.contains(route.id) && usable
        let stats = model.mode == .load ? model.loadTick?.routes.first { $0.route == route.id } : nil
        return Button {
            guard model.running == nil, usable else { return }
            if model.chosen.contains(route.id) { model.chosen.remove(route.id) } else { model.chosen.insert(route.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? theme.accent.color : theme.text3.color)
                Text(route.method).font(.dante(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(route.isRead ? theme.green.color : theme.amber.color).frame(width: 52, alignment: .leading)
                Text(route.path).font(.dante(size: 12.5, design: .monospaced)).foregroundStyle(usable ? theme.text.color : theme.text3.color).lineLimit(1)
                Spacer(minLength: 8)
                if let stats {
                    Text("\(stats.requests.formatted()) · \(stats.usual) · p95 \(BliksemStats.time(stats.p95))")
                        .font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(stats.failures > 0 ? theme.red.color : theme.text3.color)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(usable ? "Sent as \(route.method) \(route.samplePath)" : "A write: turn on Include writes to send it")
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        switch model.mode {
        case .load: loadResults
        case .fuzz: fuzzResults
        case .chaos: chaosResults
        }
    }

    @ViewBuilder
    private var loadResults: some View {
        if let tick = model.loadTick, let plan = model.loadPlan {
            Card(model.running == .load ? "\(tick.stage) · \(tick.users) users" : "Last run") {
                if model.running == nil, model.loadSummary != nil { askButton }
            } content: {
                let summary = model.loadSummary ?? LoadSummary.make([], timeline: tick.timeline, duration: tick.elapsed)
                if let done = model.loadSummary {
                    Text(done.verdict).font(.dante(size: 14, weight: .semibold))
                        .foregroundStyle(done.breakingPoint == nil && done.requests > 0 ? theme.green.color : theme.red.color)
                }
                figures(tick.timeline, summary: model.loadSummary)
                BliksemChart(timeline: tick.timeline, duration: plan.duration, breaking: (model.loadSummary?.breakingPoint ?? BliksemStats.breakingPoint(tick.timeline))?.second,
                             bands: [], live: model.running == .load)
                    .frame(height: 190)
                if summary.requests == 0, model.running == nil {
                    Text("Nothing answered. Check the target is the API and that it's running.").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                }
            }
        }
    }

    private func figures(_ timeline: [BliksemSecond], summary: LoadSummary?) -> some View {
        let requests = timeline.reduce(0) { $0 + $1.requests }
        let failures = timeline.reduce(0) { $0 + $1.failures }
        let recent = timeline.suffix(3)
        let rate = summary.map { Int($0.rate.rounded()) } ?? (recent.isEmpty ? 0 : recent.reduce(0) { $0 + $1.requests } / recent.count)
        return HStack(spacing: 22) {
            figure("Requests", requests.formatted())
            figure(summary == nil ? "Now" : "A second", "\(rate)/s")
            figure("p50", BliksemStats.time(summary?.p50 ?? recent.last?.p50 ?? 0))
            figure("p95", BliksemStats.time(summary?.p95 ?? recent.last?.p95 ?? 0))
            if let summary { figure("p99", BliksemStats.time(summary.p99)) }
            figure("Failed", requests == 0 ? "—" : String(format: "%.1f%%", Double(failures) / Double(requests) * 100), bad: failures > 0)
        }
    }

    private func figure(_ title: String, _ value: String, bad: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.dante(size: 11)).foregroundStyle(theme.text3.color)
            Text(value).font(.dante(size: 17, weight: .semibold, design: .monospaced)).foregroundStyle(bad ? theme.red.color : theme.text.color)
                .contentTransition(.numericText())
        }
    }

    @ViewBuilder
    private var fuzzResults: some View {
        if let progress = model.fuzzProgress {
            Card(model.fuzzDone ? "\(progress.findings.count) problem\(progress.findings.count == 1 ? "" : "s") found" : "Throwing garbage…") {
                if model.fuzzDone, !progress.findings.isEmpty { askButton }
            } content: {
                if !model.fuzzDone {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    Text("\(progress.done) of \(progress.total) requests").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                }
                if progress.findings.isEmpty {
                    if model.fuzzDone {
                        Label("Every route took the garbage without crashing, leaking or hanging.", systemImage: "checkmark.seal.fill")
                            .font(.dante(size: 13, weight: .medium)).foregroundStyle(theme.green.color)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(progress.findings.enumerated()), id: \.element.id) { index, finding in
                            if index > 0 { Rectangle().fill(theme.line.color).frame(height: 1) }
                            FuzzFindingRow(finding: finding)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var chaosResults: some View {
        if let tick = model.chaosTick, let plan = model.chaosPlan {
            Card(model.running == .chaos ? "\(tick.phase.rawValue) · \(plan.service)" : "Last run") {
                if model.running == nil, model.chaosOutcome?.analysis != nil { askButton }
            } content: {
                if let analysis = model.chaosOutcome?.analysis {
                    let good: Bool = switch analysis.verdict {
                    case .rodeItOut: true
                    case .recovered(let s): s < 10
                    case .stayedBroken: false
                    }
                    Text(analysis.story(service: plan.service, fault: plan.fault)).font(.dante(size: 14, weight: .semibold))
                        .foregroundStyle(good ? theme.green.color : theme.amber.color).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 22) {
                        figure("Normal p95", BliksemStats.time(analysis.baselineP95))
                        figure("Failed while broken", String(format: "%.0f%%", analysis.outageFailing * 100), bad: analysis.outageFailing > 0)
                        if let first = analysis.firstFailure { figure("First failure", String(format: "%.1f s in", first)) }
                        switch analysis.verdict {
                        case .recovered(let s): figure("Recovered", String(format: "%.0f s after", s))
                        case .stayedBroken: figure("Recovered", "no", bad: true)
                        case .rodeItOut: figure("Recovered", "never fell")
                        }
                    }
                }
                let times = tick.times
                BliksemChart(timeline: tick.timeline, duration: max(tick.elapsed, (times?.ended ?? 0), plan.baseline + plan.outage + 10),
                             breaking: nil, bands: times.map { [(from: $0.broke, to: $0.restored, label: "broken")] } ?? [], live: model.running == .chaos)
                    .frame(height: 170)
            }
        }
    }

    private var askButton: some View {
        Button { session.askClaude(brief) } label: { Label("Ask \(session.agentName) to fix it", systemImage: "wand.and.stars") }
            .buttonStyle(DanteButtonStyle(primary: true))
            .help("Sends what Bliksem found, with the routes and figures, to the agent in charge")
    }

    /// What the agent gets: the run's figures and findings, plainly.
    private var brief: String {
        var lines: [String] = []
        switch model.mode {
        case .load:
            guard let summary = model.loadSummary else { return "" }
            lines.append("Bliksem load test against \(model.target): \(summary.verdict)")
            lines.append("\(summary.requests) requests over \(Int(summary.seconds)) s, up to \(summary.peakUsers) users; p50 \(BliksemStats.time(summary.p50)), p95 \(BliksemStats.time(summary.p95)), p99 \(BliksemStats.time(summary.p99)); \(summary.failures) failed.")
            lines.append("Slowest and failing routes:")
            for route in (model.loadTick?.routes ?? []).prefix(8) {
                lines.append("- \(route.route): \(route.requests) requests, mostly \(route.usual), p95 \(BliksemStats.time(route.p95)), \(route.failures) failed")
            }
            lines.append("Find why these routes slow down or fail under load (queries, missing indexes, pools, locks, N+1 calls) and fix the causes.")
        case .fuzz:
            lines.append("Bliksem fuzzed the API at \(model.target). It found:")
            for finding in model.fuzzProgress?.findings ?? [] {
                lines.append("- [\(finding.severity.label)] \(finding.route): \(finding.problem.title.lowercased()) (sent \(finding.sent), got \(finding.answer)\(finding.evidence.map { ": \($0)" } ?? ""))")
            }
            lines.append("Find each handler, validate its input and fix the cause; don't just catch the error.")
        case .chaos:
            guard let plan = model.chaosPlan, let analysis = model.chaosOutcome?.analysis else { return "" }
            lines.append("Bliksem chaos test: \(analysis.story(service: plan.service, fault: plan.fault))")
            lines.append("Failures while it was down: " + analysis.answers.prefix(4).map { "\($0.text) ×\($0.count)" }.joined(separator: ", "))
            lines.append("Make the app cope with \(plan.service) going away: timeouts, retries with backoff, reconnecting pools, health checks and clear errors instead of hangs.")
        }
        return lines.joined(separator: "\n")
    }
}

/// One fuzz finding: what broke, on which route, with what.
private struct FuzzFindingRow: View {
    @Environment(\.theme) private var theme
    let finding: FuzzFinding

    var body: some View {
        let color: Color = switch finding.severity {
        case .critical, .high: theme.red.color
        case .medium: theme.amber.color
        case .low: theme.text3.color
        }
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Chip(text: finding.severity.label, color: color, selected: true)
                Text(finding.problem.title).font(.dante(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
                Text(finding.route).font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text2.color).lineLimit(1)
                Spacer(minLength: 6)
                if finding.count > 1 { Text("×\(finding.count)").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color) }
            }
            Text("Sent \(finding.sent) → \(finding.answer)").font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color).lineLimit(1)
            if let evidence = finding.evidence {
                Text(evidence).font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text2.color).lineLimit(2)
            }
            Text(finding.problem.advice).font(.dante(size: 11.5)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 9)
    }
}

/// The plan's stages as a strip, filled up to where the run is.
private struct StagesStrip: View {
    @Environment(\.theme) private var theme
    let plan: LoadPlan
    let elapsed: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            HStack(spacing: 2) {
                ForEach(Array(plan.stages.enumerated()), id: \.offset) { index, stage in
                    let before = plan.stages.prefix(index).reduce(0) { $0 + $1.seconds }
                    let share = elapsed.map { min(max(($0 - before) / max(stage.seconds, 1), 0), 1) } ?? 0
                    VStack(alignment: .leading, spacing: 3) {
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(theme.track.color)
                            RoundedRectangle(cornerRadius: 3).fill(index == 2 ? theme.red.color : theme.accent.color)
                                .frame(width: max(0, (width * stage.seconds / max(plan.duration, 1) - 2) * share))
                        }
                        .frame(height: 6)
                        Text("\(stage.name) \(stage.from == stage.to ? "\(stage.to)" : "\(stage.from)→\(stage.to)")")
                            .font(.dante(size: 10.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading).clipped()
                    }
                    .frame(width: max(0, width * stage.seconds / max(plan.duration, 1) - 2))
                }
            }
        }
        .frame(height: 24)
    }
}

/// Requests a second as bars (red where they failed), the 95th percentile as a line, the
/// users as a faint area, a breaking point as a red rule, and bands for a chaos outage. While
/// live, the newest bar pulses like the Map's links.
struct BliksemChart: View {
    @Environment(\.theme) private var theme
    let timeline: [BliksemSecond]
    let duration: Double
    let breaking: Int?
    let bands: [(from: Double, to: Double, label: String)]
    let live: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !live)) { context in
            let pulse = live ? (sin(context.date.timeIntervalSinceReferenceDate * 5) + 1) / 2 : 0
            Canvas { canvas, size in draw(&canvas, size: size, pulse: pulse) }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 14) {
                legend(theme.accent.color, "requests/s")
                legend(theme.amber.color, "p95")
                legend(theme.text3.color.opacity(0.5), "users")
                if breaking != nil { legend(theme.red.color, "breaking point") }
            }
            .padding(.leading, 4)
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 4)
            Text(text).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color)
        }
    }

    private func draw(_ canvas: inout GraphicsContext, size: CGSize, pulse: Double) {
        let top: CGFloat = 22, bottom: CGFloat = 16
        let height = size.height - top - bottom
        let span = max(duration, Double(timeline.count), 1)
        let step = size.width / span
        let maxRate = Double(max(timeline.map(\.requests).max() ?? 1, 1))
        let maxP95 = max(timeline.map(\.p95).max() ?? 0, 0.2)
        let maxUsers = Double(max(timeline.map(\.users).max() ?? 1, 1))
        func x(_ t: Double) -> CGFloat { CGFloat(t) * step }

        // The baseline and seconds.
        canvas.fill(Path(CGRect(x: 0, y: top + height, width: size.width, height: 1)), with: .color(theme.line.color))
        for band in bands {
            let rect = CGRect(x: x(band.from), y: top, width: max(x(band.to) - x(band.from), 2), height: height)
            canvas.fill(Path(rect), with: .color(theme.red.color.opacity(0.08)))
            canvas.draw(Text(band.label).font(.dante(size: 10)).foregroundStyle(theme.red.color), at: CGPoint(x: rect.midX, y: top + 8))
        }

        // Users, faint.
        if timeline.count > 1 {
            var area = Path()
            area.move(to: CGPoint(x: x(0), y: top + height))
            for second in timeline { area.addLine(to: CGPoint(x: x(Double(second.second) + 0.5), y: top + height - CGFloat(Double(second.users) / maxUsers) * height * 0.9)) }
            area.addLine(to: CGPoint(x: x(Double(timeline.count)), y: top + height))
            area.closeSubpath()
            canvas.fill(area, with: .color(theme.text3.color.opacity(0.1)))
        }

        // Requests a second.
        for second in timeline {
            let total = CGFloat(Double(second.requests) / maxRate) * height
            let failed = CGFloat(Double(second.failures) / maxRate) * height
            let rect = CGRect(x: x(Double(second.second)) + step * 0.15, y: top + height - total, width: max(step * 0.7, 1), height: total)
            let newest = live && second.second == timeline.last?.second
            canvas.fill(Path(roundedRect: rect, cornerRadius: min(2, step * 0.2)), with: .color(theme.accent.color.opacity(newest ? 0.45 + 0.4 * pulse : 0.55)))
            if failed > 0 {
                canvas.fill(Path(CGRect(x: rect.minX, y: top + height - failed, width: rect.width, height: failed)), with: .color(theme.red.color.opacity(0.85)))
            }
        }

        // The 95th percentile.
        let timed = timeline.filter { $0.requests > 0 }
        if timed.count > 1 {
            var line = Path()
            for (index, second) in timed.enumerated() {
                let point = CGPoint(x: x(Double(second.second) + 0.5), y: top + height - CGFloat(second.p95 / maxP95) * height * 0.95)
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            canvas.stroke(line, with: .color(theme.amber.color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            if live, let last = timed.last {
                let point = CGPoint(x: x(Double(last.second) + 0.5), y: top + height - CGFloat(last.p95 / maxP95) * height * 0.95)
                let radius = 3 + 4 * pulse
                canvas.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)), with: .color(theme.amber.color.opacity(0.35 * (1 - pulse) + 0.15)))
                canvas.fill(Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)), with: .color(theme.amber.color))
            }
            canvas.draw(Text("p95 up to \(BliksemStats.time(maxP95))").font(.dante(size: 10)).foregroundStyle(theme.amber.color),
                        at: CGPoint(x: size.width - 4, y: top + 4), anchor: .topTrailing)
        }

        if let breaking {
            let bx = x(Double(breaking))
            canvas.fill(Path(CGRect(x: bx, y: top, width: 1.5, height: height)), with: .color(theme.red.color))
            canvas.draw(Text("broke here").font(.dante(size: 10, weight: .semibold)).foregroundStyle(theme.red.color), at: CGPoint(x: bx + 4, y: top + height - 4), anchor: .bottomLeading)
        }

        canvas.draw(Text("\(Int(maxRate))/s").font(.dante(size: 10)).foregroundStyle(theme.text3.color), at: CGPoint(x: 2, y: top + 4), anchor: .topLeading)
        canvas.draw(Text("\(Int(span)) s").font(.dante(size: 10)).foregroundStyle(theme.text3.color), at: CGPoint(x: size.width - 2, y: size.height), anchor: .bottomTrailing)
    }
}
