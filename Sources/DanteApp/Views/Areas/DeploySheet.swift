import DanteKit
import SwiftUI

/// The deploy wizard: where the code comes from, the region, each component's size and
/// scaling, variables, the database, domains and alerts. Those six steps edit
/// `.do/app.yaml`; leaving them saves it and prices the deploy, then secrets and a review
/// that shows where the code goes, whose bill it lands on and what it costs before the one
/// deliberate click that deploys.
struct DeploySheet: View {
    typealias Step = DeployModel.WizardStep
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: Session
    let workspace: Workspace
    @State private var shown = false
    @State private var newDomain = ""
    @State private var forward = true
    private var model: DeployModel { session.deploy }

    private var step: Step { model.wizardStep ?? (model.stage == .needsSecrets ? .secrets : .review) }

    var body: some View {
        HStack(spacing: 0) {
            rail.frame(width: 214)
            Rectangle().fill(theme.line.color).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                stepHeader.padding(.horizontal, 26).padding(.top, 22).padding(.bottom, 14)
                ScrollView {
                    stepContent
                        .id(step)
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                                                         removal: .opacity))
                        .padding(.horizontal, 26).padding(.bottom, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                footer
            }
            .background(theme.panel.color)
        }
        .frame(width: 860, height: 640)
        .background(theme.card.color)
        .onAppear {
            if reduceMotion { shown = true } else { withAnimation(.spring(duration: 0.55, bounce: 0.2)) { shown = true } }
        }
    }

    private func go(to target: Step) {
        forward = target > step
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.32)) { model.goBack(to: target) }
    }

    // MARK: The rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(theme.accentTint.color)
                    Image(systemName: "icloud.and.arrow.up").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent.color)
                }
                .frame(width: 34, height: 34)
                .scaleEffect(shown ? 1 : 0.6).opacity(shown ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.app == nil ? "Deploy" : "Deploy again").font(.dante(size: 14, weight: .semibold)).foregroundStyle(theme.text.color)
                    Text(model.setup?.name ?? model.spec?.name ?? "").font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color).lineLimit(1)
                }
            }
            .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 14)
            // Whose bill it lands on comes first: the consent page picks a team, often a company's.
            if let team = model.person?.team, !team.isEmpty {
                chip("building.2", "\(team) team", strong: true).padding(.horizontal, 16).padding(.bottom, 12)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Step.allCases, id: \.self) { item in railRow(item) }
            }
            .padding(.horizontal, 8)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 2) {
                let cost = step >= .secrets ? (model.proposal?.appCost ?? model.estimate) : model.setupEstimate
                Text(cost.map { $0 == 0 ? "Free" : String(format: "$%.2f", $0) } ?? "—")
                    .font(.dante(size: 20, weight: .semibold)).foregroundStyle(theme.text.color)
                    .contentTransition(.numericText(value: cost ?? 0))
                    .animation(reduceMotion ? nil : .snappy, value: cost)
                let cluster = (model.setup?.databases ?? []).contains(where: \.isManaged)
                Text(cost.map { $0 > 0 ? "a month, billed by the second" + (cluster ? ", plus the cluster’s own bill" : "") : "on App Platform" } ?? "sizes not loaded yet")
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.dante(size: 11)).foregroundStyle(theme.text3.color)
            }
            .padding(16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Steps before Secrets can always be gone back to; Secrets and Review once priced.
    private func reachable(_ item: Step) -> Bool {
        item < .secrets ? !model.isDeploying : (item == .secrets ? model.stage != nil : model.stage == .confirming)
    }

    private func railRow(_ item: Step) -> some View {
        let current = item == step, done = item < step
        return Button { if reachable(item), !current { go(to: item) } } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().fill(current ? theme.accent.color : done ? theme.accentTint.color : .clear)
                    Circle().strokeBorder(current || done ? theme.accent.color : theme.line2.color, lineWidth: 1.2)
                    if done {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.accent.color)
                    } else {
                        Text("\(item.rawValue + 1)").font(.dante(size: 10.5, weight: .semibold))
                            .foregroundStyle(current ? theme.onAccent.color : theme.text3.color)
                    }
                }
                .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.dante(size: 12.5, weight: current ? .semibold : .medium))
                        .foregroundStyle(current ? theme.text.color : reachable(item) ? theme.text2.color : theme.text3.color)
                    if let summary = summary(item) {
                        Text(summary).font(.dante(size: 11)).foregroundStyle(theme.text3.color).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(current ? theme.accentTint.color.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .snappy, value: step)
    }

    /// One line under each step saying what's chosen.
    private func summary(_ item: Step) -> String? {
        guard let setup = model.setup ?? model.spec.map({ DOSetup(spec: $0, region: model.region) }) else { return nil }
        switch item {
        case .source:
            let gitParts = setup.parts.filter { $0.branch != nil }
            if let branch = gitParts.first?.branch { return "\(gitParts.first?.sourceLabel.split(separator: " ").first ?? "git") · \(branch)" }
            return model.builds.isEmpty ? setup.parts.first?.sourceLabel : "Built on this Mac"
        case .region: return DeployFormat.city(setup.region)
        case .parts:
            let count = setup.parts.count
            return "\(count) part\(count == 1 ? "" : "s")"
        case .variables:
            let count = setup.parts.reduce(0) { $0 + $1.variables.count }
            return count == 0 ? "None" : "\(count) variable\(count == 1 ? "" : "s")"
        case .data:
            guard !setup.databases.isEmpty else { return "None" }
            return setup.databases.map { $0.isManaged ? ($0.cluster ?? "Managed") : "Dev database" }.joined(separator: ", ")
        case .reach:
            let alerts = setup.alerts.count + setup.watches.count
            return (setup.domains.first ?? "Default address") + (alerts > 0 ? " · \(alerts) alert\(alerts == 1 ? "" : "s")" : "")
        case .secrets:
            guard model.stage != nil, model.stage != .checking else { return nil }
            let left = model.needed.filter { (model.typedSecrets[$0.id] ?? "").isEmpty }.count
            return left == 0 ? "Ready" : "\(left) to fill"
        case .review: return nil
        }
    }

    // MARK: The step

    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.resizing != nil && step == .parts ? "RESIZE" : "STEP \(step.rawValue + 1) OF \(Step.allCases.count)").font(.dante(size: 10.5, weight: .semibold)).tracking(0.7).foregroundStyle(theme.accent.color)
            Text(headline).font(.dante(size: 19, weight: .semibold)).foregroundStyle(theme.text.color)
            Text(explanation).font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
        }
        .id(step)
    }

    private var headline: String {
        switch step {
        case .source: "Where the code comes from"
        case .region: "Where it runs"
        case .parts: model.resizing.map { "How big \($0) is" } ?? "How big each part is"
        case .variables: "What each part is told"
        case .data: "Where the data lives"
        case .reach: "Domains and alerts"
        case .secrets: "Secrets"
        case .review: model.app == nil ? "Ready to deploy" : "Ready to deploy again"
        }
    }

    private var explanation: String {
        switch step {
        case .source: "App Platform builds from a branch on your git host, or runs images Dante builds here and pushes to the registry."
        case .region: "Pick the region nearest the people who use the app: every request travels there and back."
        case .parts: model.resizing == nil ? "Sizes, how many copies run, and how App Platform checks each part is healthy." : "The app is updated in place: the database and its data stay, and the other parts keep their sizes. You see the new price before anything changes."
        case .variables: "Environment variables per part. Secrets get their values when you deploy; DigitalOcean keeps them encrypted."
        case .data: "A dev database to try things, or a managed cluster with backups for real data."
        case .reach: "Your own address for the app, and what DigitalOcean emails the team about."
        case .secrets: "Values the spec leaves out. They go once to DigitalOcean and Dante doesn’t keep them."
        case .review: "Nothing has been made yet. Look it over; Deploy is the step that spends money."
        }
    }

    @ViewBuilder private var stepContent: some View {
        if let binding = setupBinding {
            switch step {
            case .source: sourceStep(binding)
            case .region: regionStep(binding)
            case .parts: partsStep(binding)
            case .variables: variablesStep(binding)
            case .data: dataStep(binding)
            case .reach: reachStep(binding)
            case .secrets: secretsStep
            case .review: review
            }
        } else if step == .secrets {
            secretsStep
        } else {
            review
        }
    }

    private var setupBinding: Binding<DOSetup>? {
        guard model.setup != nil else { return nil }
        return Binding(get: { model.setup ?? DOSetup(spec: DOAppSpec(name: ""), region: "") }, set: { model.setup = $0 })
    }

    // MARK: Source

    private func sourceStep(_ setup: Binding<DOSetup>) -> some View {
        let gitParts = setup.wrappedValue.parts.indices.filter { setup.wrappedValue.parts[$0].branch != nil }
        let first = gitParts.first.map { setup.wrappedValue.parts[$0] }
        return VStack(alignment: .leading, spacing: 18) {
            field("App name", help: model.app == nil ? "Lowercase letters, digits and dashes. It names the app and its first address." : "The live app keeps its name.") {
                if model.app == nil {
                    TextField("shop", text: setup.name).textFieldStyle(.roundedBorder).font(.dante(size: 13, design: .monospaced)).frame(maxWidth: 280)
                } else {
                    Text(setup.wrappedValue.name).font(.dante(size: 13, design: .monospaced)).foregroundStyle(theme.text.color)
                }
            }
            if let first {
                box {
                    HStack(spacing: 10) {
                        icon("arrow.triangle.branch")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(first.sourceLabel).font(.dante(size: 13, weight: .medium)).foregroundStyle(theme.text.color)
                            Text("\(gitParts.count) part\(gitParts.count == 1 ? "" : "s") build\(gitParts.count == 1 ? "s" : "") from it").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                        }
                        Spacer()
                    }
                    divider
                    HStack(spacing: 10) {
                        Text("Branch").font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).frame(width: 110, alignment: .leading)
                        TextField("main", text: Binding(get: { first.branch ?? "" }, set: { value in
                            for index in gitParts { setup.wrappedValue.parts[index].branch = value }
                        }))
                        .textFieldStyle(.roundedBorder).font(.dante(size: 12.5, design: .monospaced)).frame(maxWidth: 240)
                        if first.branch != model.branch {
                            Button("Use \(model.branch)") { for index in gitParts { setup.wrappedValue.parts[index].branch = model.branch } }
                                .buttonStyle(DanteButtonStyle())
                                .help("The branch checked out here")
                        }
                        Spacer()
                    }
                    divider
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Deploy when I push").font(.dante(size: 12.5)).foregroundStyle(theme.text.color)
                            Text("Each push to the branch builds and deploys by itself.").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                        }
                        Spacer()
                        Toggle("Deploy when I push", isOn: Binding(get: { first.deploysOnPush }, set: { value in
                            for index in gitParts { setup.wrappedValue.parts[index].deploysOnPush = value }
                        }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
                if model.unpushed > 0 {
                    note("arrow.up.circle", "\(model.unpushed) commit\(model.unpushed == 1 ? " isn’t" : "s aren’t") pushed yet. App Platform builds what’s on the host.", tone: .warn)
                }
                if model.dirty { note("pencil.circle", "Uncommitted changes aren’t included.", tone: .warn) }
            }
            if setup.wrappedValue.parts.contains(where: { $0.branch == nil }) {
                box {
                    HStack(alignment: .top, spacing: 10) {
                        icon("laptopcomputer")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Built on this Mac").font(.dante(size: 13, weight: .medium)).foregroundStyle(theme.text.color)
                            Text("Parts without a git host are images: Dante builds them with Docker for linux/amd64 and pushes them to the team’s container registry before deploying.")
                                .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Text("To switch between a git host and building here, change the components’ source in \(DOAppSpec.path).")
                .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
        }
    }

    // MARK: Region

    private func regionStep(_ setup: Binding<DOSetup>) -> some View {
        let locked = model.app != nil
        let suggested = DeployFormat.suggestedRegion(for: TimeZone.current.identifier)
        return VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(DeployFormat.regions, id: \.code) { region in
                    let chosen = setup.wrappedValue.region == region.code
                    Button { withAnimation(.snappy) { setup.wrappedValue.region = region.code } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: region.symbol).font(.system(size: 15)).foregroundStyle(chosen ? theme.accent.color : theme.text3.color).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(region.city).font(.dante(size: 13, weight: chosen ? .semibold : .medium)).foregroundStyle(theme.text.color)
                                Text(region.code + (region.code == suggested ? " · nearest your time zone" : "")).font(.dante(size: 11)).foregroundStyle(region.code == suggested ? theme.accent.color : theme.text3.color)
                            }
                            Spacer()
                            if chosen { Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent.color).transition(.scale.combined(with: .opacity)) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(chosen ? theme.accentTint.color : theme.card.color))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(chosen ? theme.accentLine.color : theme.line.color))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(locked && !chosen)
                    .opacity(locked && !chosen ? 0.45 : 1)
                }
            }
            if locked {
                note("lock", "The live app stays in \(DeployFormat.region(setup.wrappedValue.region)). Dante doesn’t move a running app; to run somewhere else, make a new app there.", tone: .info)
            }
        }
    }

    // MARK: Components

    private func partsStep(_ setup: Binding<DOSetup>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Resize… shows only the component it was opened on.
            ForEach(setup.wrappedValue.parts.indices.filter { model.resizing == nil || setup.wrappedValue.parts[$0].name == model.resizing }, id: \.self) { index in
                partCard(setup.parts[index])
            }
        }
    }

    private func partCard(_ part: Binding<DOSetup.Part>) -> some View {
        let value = part.wrappedValue
        return box {
            HStack(spacing: 10) {
                icon(symbol(for: value.kind))
                VStack(alignment: .leading, spacing: 1) {
                    Text(value.name).font(.dante(size: 13.5, weight: .semibold)).foregroundStyle(theme.text.color)
                    Text(value.kind == .job ? DeployFormat.job(model.spec?.jobs?.first { $0.name == value.name }?.kind) : value.kind.title)
                        .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                }
                Spacer()
                if let cost = partPrice(value) {
                    Text(cost == 0 ? "Free" : String(format: "$%.2f / mo", cost)).font(.dante(size: 12.5, weight: .semibold))
                        .foregroundStyle(cost == 0 ? theme.green.color : theme.text.color)
                        .contentTransition(.numericText(value: cost))
                }
            }
            if value.kind == .staticSite {
                divider
                Text("Served from DigitalOcean’s CDN, so there’s no size to pick. The first three static sites are free.")
                    .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true)
            } else {
                divider
                row("Size") {
                    sizeMenu(part)
                }
                if value.runsAlways {
                    row("Copies") {
                        Picker("", selection: Binding(get: { value.autoscale != nil }, set: { scales in
                            var changed = part.wrappedValue
                            changed.autoscale = scales ? .init(minimum: max(1, value.instances), maximum: max(2, value.instances * 2)) : nil
                            // Only dedicated CPU scales: move to the cheapest one with at least this much memory.
                            if scales, !DOSetup.scales(value.size), let dedicated = dedicatedSize(atLeast: value.size) { changed.size = dedicated }
                            withAnimation(.snappy) { part.wrappedValue = changed }
                        })) {
                            Text("Fixed").tag(false)
                            Text("Scale by CPU").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .help("App Platform adds and removes copies by CPU use; only on dedicated-CPU sizes")
                        if let scale = value.autoscale {
                            Stepper("\(scale.minimum) to \(scale.maximum)", value: Binding(get: { scale.maximum }, set: { part.wrappedValue.autoscale?.maximum = max($0, scale.minimum) }), in: 1...20)
                                .font(.dante(size: 12.5)).fixedSize()
                        } else {
                            Stepper("\(value.instances)", value: part.instances, in: 1...20).font(.dante(size: 12.5)).fixedSize()
                        }
                    }
                    if let scale = value.autoscale {
                        row("") {
                            Stepper("At least \(scale.minimum)", value: Binding(get: { scale.minimum }, set: { part.wrappedValue.autoscale?.minimum = min($0, scale.maximum) }), in: 1...20)
                                .font(.dante(size: 12.5)).fixedSize()
                            Stepper("Aim for \(scale.cpuPercent)% CPU", value: Binding(get: { scale.cpuPercent }, set: { part.wrappedValue.autoscale?.cpuPercent = $0 }), in: 20...90, step: 5)
                                .font(.dante(size: 12.5)).fixedSize()
                        }
                        if !DOSetup.scales(value.size) {
                            note("exclamationmark.triangle", "Scaling by CPU needs a dedicated-CPU size. Pick one above.", tone: .warn)
                        }
                    }
                }
                if value.kind == .service {
                    row("Port") {
                        TextField("8080", value: part.port, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 90)
                        Text("Health check").font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).padding(.leading, 10)
                        TextField("/health", text: Binding(get: { value.healthPath ?? "" }, set: { part.wrappedValue.healthPath = $0.isEmpty ? nil : $0 }))
                            .textFieldStyle(.roundedBorder).font(.dante(size: 12.5, design: .monospaced)).frame(maxWidth: 180)
                            .help("A path that answers 200 when the part is ready. Without one App Platform only checks the port is open.")
                    }
                }
                row("Run") {
                    TextField(value.kind == .job ? "the job’s command" : "the image’s own command", text: Binding(get: { value.runCommand ?? "" }, set: { part.wrappedValue.runCommand = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder).font(.dante(size: 12.5, design: .monospaced))
                }
            }
        }
    }

    private func sizeMenu(_ part: Binding<DOSetup.Part>) -> some View {
        let value = part.wrappedValue
        let current = model.sizes.first { $0.slug == value.size }
        return Menu {
            ForEach([false, true], id: \.self) { dedicated in
                Section(dedicated ? "Dedicated CPU · can scale by itself" : "Shared CPU") {
                    ForEach(model.sizes.filter { $0.isDedicated == dedicated }.sorted { ($0.monthly ?? 0) < ($1.monthly ?? 0) }) { size in
                        Button("\(DeployFormat.size(size.slug)) · \(size.monthly.map { String(format: "$%.0f", $0) } ?? "")") {
                            withAnimation(.snappy) { part.wrappedValue.size = size.slug }
                        }
                    }
                }
            }
        } label: {
            Text("\(current?.isDedicated == true ? "Dedicated" : "Shared") · \(DeployFormat.size(value.size))")
        }
        .fixedSize()
        .disabled(model.sizes.isEmpty)
        .help(model.sizes.isEmpty ? "Sign in to DigitalOcean to see the sizes and prices" : "Shared CPU borrows idle time on a busy machine; dedicated CPU is yours alone")
    }

    private func dedicatedSize(atLeast slug: String) -> String? {
        let memory = model.sizes.first { $0.slug == slug }?.memoryGB ?? 0
        return model.sizes.filter { $0.isDedicated && ($0.memoryGB ?? 0) >= memory }.min { ($0.monthly ?? .infinity) < ($1.monthly ?? .infinity) }?.slug
    }

    private func partPrice(_ part: DOSetup.Part) -> Double? {
        if part.kind == .staticSite { return 0 }
        if part.kind == .job, model.spec?.jobs?.first(where: { $0.name == part.name })?.kind?.uppercased().hasSuffix("_DEPLOY") == true { return nil }
        guard let monthly = model.sizes.first(where: { $0.slug == part.size })?.monthly else { return nil }
        return monthly * Double(part.autoscale?.minimum ?? part.instances)
    }

    // MARK: Variables

    private func variablesStep(_ setup: Binding<DOSetup>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(setup.wrappedValue.parts.indices, id: \.self) { index in
                let part = setup.parts[index]
                box {
                    HStack(spacing: 10) {
                        icon(symbol(for: part.wrappedValue.kind))
                        Text(part.wrappedValue.name).font(.dante(size: 13.5, weight: .semibold)).foregroundStyle(theme.text.color)
                        Spacer()
                        Button { withAnimation(.snappy) { part.wrappedValue.variables.append(.init(key: "")) } } label: {
                            Label("Add", systemImage: "plus")
                        }
                        .buttonStyle(DanteButtonStyle())
                    }
                    if part.wrappedValue.variables.isEmpty {
                        Text("No variables.").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                    }
                    ForEach(part.wrappedValue.variables.indices, id: \.self) { at in
                        divider
                        variableRow(part.variables[at], database: boundDatabase(part.wrappedValue.variables[at], in: setup.wrappedValue)) {
                            withAnimation(.snappy) { _ = part.wrappedValue.variables.remove(at: at) }
                        }
                    }
                }
            }
        }
    }

    /// The database a secret is filled from when it deploys (`DOSpecSend.databaseField`), so
    /// it isn't shown as something to type.
    private func boundDatabase(_ variable: DOSetup.Variable, in setup: DOSetup) -> String? {
        guard variable.isSecret, DOSpecSend.databaseField(variable.key) != nil else { return nil }
        return (setup.databases.first { $0.engine == "PG" } ?? setup.databases.first)?.name
    }

    private func variableRow(_ variable: Binding<DOSetup.Variable>, database: String?, remove: @escaping () -> Void) -> some View {
        let value = variable.wrappedValue
        return HStack(spacing: 8) {
            TextField("NAME", text: variable.key).textFieldStyle(.roundedBorder).font(.dante(size: 12, design: .monospaced)).frame(width: 200)
            if value.isBound || database != nil {
                HStack(spacing: 5) {
                    Image(systemName: "cylinder.split.1x2").font(.system(size: 10.5))
                    Text("from the \(database ?? databaseName(value.value)) database").font(.dante(size: 12))
                }
                .foregroundStyle(theme.green.color)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.greenTint.color))
                Spacer()
            } else if value.isSecret {
                Text("asked for when you deploy").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                Spacer()
            } else {
                TextField("value", text: variable.value).textFieldStyle(.roundedBorder).font(.dante(size: 12, design: .monospaced))
            }
            if !value.isBound && database == nil {
                Toggle(isOn: variable.isSecret) { Image(systemName: value.isSecret ? "lock.fill" : "lock.open") }
                    .toggleStyle(.button).help(value.isSecret ? "A secret: encrypted, asked for at deploy" : "Make it a secret")
            }
            Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove the variable")
        }
    }

    // MARK: Database

    @ViewBuilder private func dataStep(_ setup: Binding<DOSetup>) -> some View {
        if setup.wrappedValue.databases.isEmpty {
            box {
                HStack(spacing: 10) {
                    icon("cylinder.split.1x2")
                    Text("The spec has no database. If the app needs one, ask \(session.agentName) to add it to \(DOAppSpec.path), or add a `databases:` entry yourself.")
                        .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(setup.wrappedValue.databases.indices, id: \.self) { index in
                    storeChoice(setup.databases[index], wasManaged: model.setupStart?.databases.first { $0.name == setup.wrappedValue.databases[index].name }?.isManaged ?? false)
                }
            }
        }
    }

    private func storeChoice(_ store: Binding<DOSetup.Store>, wasManaged: Bool) -> some View {
        let value = store.wrappedValue
        let fitting = model.clusters.filter { $0.specEngine == value.engine }
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle(value.name, trailing: value.engine == "PG" ? "Postgres" : value.engine)
            HStack(alignment: .top, spacing: 10) {
                choiceCard(chosen: !value.isManaged, symbol: "flask", title: "Dev database", price: "$7 a month",
                           lines: ["512 MB, made with the app", "No backups or standby", "Reached with its password from anywhere", "Few connections"]) {
                    withAnimation(.snappy) { store.wrappedValue.cluster = nil }
                }
                choiceCard(chosen: value.isManaged, symbol: "externaldrive.badge.checkmark", title: "Managed cluster", price: "billed with the cluster",
                           lines: ["Daily backups, point-in-time restore", "Standby nodes if you add them", "Trusted sources: only your app", "Sized for real traffic"]) {
                    withAnimation(.snappy) { store.wrappedValue.cluster = fitting.first?.name ?? "" }
                }
            }
            if value.isManaged {
                box {
                    HStack(spacing: 10) {
                        Text("Cluster").font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).frame(width: 80, alignment: .leading)
                        if fitting.isEmpty {
                            Text(model.clusters.isEmpty ? "The team has no clusters yet." : "None of the team’s clusters run \(value.engine).")
                                .font(.dante(size: 12.5)).foregroundStyle(theme.amber.color)
                        } else {
                            Picker("", selection: Binding(get: { value.cluster ?? "" }, set: { store.wrappedValue.cluster = $0 })) {
                                if (value.cluster ?? "").isEmpty { Text("Pick one").tag("") }
                                ForEach(fitting) { cluster in
                                    Text("\(cluster.name) · \(cluster.region ?? "") · \(cluster.size ?? "")").tag(cluster.name)
                                }
                            }
                            .labelsHidden().fixedSize()
                        }
                        Spacer()
                        LinkButton("Make one on DigitalOcean") { NSWorkspace.shared.open(URL(string: "https://cloud.digitalocean.com/databases/new")!) }
                    }
                }
                if !wasManaged, model.app != nil {
                    note("exclamationmark.triangle", "Data in the dev database doesn’t move across. Dump it first (pg_dump from the Console), then load it into the cluster.", tone: .warn)
                }
                note("lock.shield", "Under the cluster’s Trusted sources, allow only this app, so nothing else on the internet can reach it.", tone: .info)
            }
        }
    }

    private func choiceCard(chosen: Bool, symbol: String, title: String, price: String, lines: [String], choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(chosen ? theme.accent.color : theme.text3.color)
                    Spacer()
                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle").foregroundStyle(chosen ? theme.accent.color : theme.line2.color)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.dante(size: 13.5, weight: .semibold)).foregroundStyle(theme.text.color)
                    Text(price).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(lines, id: \.self) { line in
                        Text("· " + line).font(.dante(size: 11.5)).foregroundStyle(theme.text2.color)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(chosen ? theme.accentTint.color : theme.card.color))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(chosen ? theme.accentLine.color : theme.line.color))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Domains and alerts

    private func reachStep(_ setup: Binding<DOSetup>) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Domains", trailing: nil)
                box {
                    if let live = model.app?.liveURL?.host {
                        HStack(spacing: 8) {
                            Image(systemName: "globe").foregroundStyle(theme.text3.color)
                            Text(live).font(.dante(size: 12.5, design: .monospaced)).foregroundStyle(theme.text2.color)
                            Spacer()
                            Text("always on").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                        }
                    }
                    ForEach(Array(setup.wrappedValue.domains.enumerated()), id: \.offset) { index, domain in
                        if index > 0 || model.app?.liveURL != nil { divider }
                        HStack(spacing: 8) {
                            Image(systemName: index == 0 ? "star.fill" : "arrow.turn.down.right").font(.system(size: 11)).foregroundStyle(theme.accent.color)
                            Text(domain).font(.dante(size: 12.5, design: .monospaced)).foregroundStyle(theme.text.color)
                            Text(index == 0 ? "primary" : "alias").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                            Spacer()
                            Button { withAnimation(.snappy) { _ = setup.wrappedValue.domains.remove(at: index) } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    if !setup.wrappedValue.domains.isEmpty || model.app?.liveURL != nil { divider }
                    HStack(spacing: 8) {
                        TextField("app.example.com", text: $newDomain).textFieldStyle(.roundedBorder).font(.dante(size: 12.5, design: .monospaced))
                            .onSubmit { addDomain(setup) }
                        Button("Add domain") { addDomain(setup) }.buttonStyle(DanteButtonStyle()).disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if !setup.wrappedValue.domains.isEmpty {
                    Text("After the deploy, add a CNAME record for each domain pointing at the app’s ondigitalocean.app address at your DNS provider. DigitalOcean then issues the certificate.")
                        .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Email the team when", trailing: nil)
                box {
                    ForEach(Array(DOSetup.appAlerts.enumerated()), id: \.offset) { index, alert in
                        if index > 0 { divider }
                        alertToggle(alert.title, isOn: Binding(get: { setup.wrappedValue.alerts.contains(alert.rule) }, set: { on in
                            if on { setup.wrappedValue.alerts.insert(alert.rule) } else { setup.wrappedValue.alerts.remove(alert.rule) }
                        }))
                    }
                    if setup.wrappedValue.parts.contains(where: \.runsAlways) {
                        ForEach(DOSetup.Watch.allCases, id: \.self) { watch in
                            divider
                            alertToggle(watch.title + " on any service", isOn: Binding(get: { setup.wrappedValue.watches.contains(watch) }, set: { on in
                                if on { setup.wrappedValue.watches.insert(watch) } else { setup.wrappedValue.watches.remove(watch) }
                            }))
                        }
                    }
                }
            }
        }
    }

    private func addDomain(_ setup: Binding<DOSetup>) {
        let domain = newDomain.trimmingCharacters(in: .whitespaces).lowercased()
        guard !domain.isEmpty, !setup.wrappedValue.domains.contains(domain) else { return }
        withAnimation(.snappy) { setup.wrappedValue.domains.append(domain) }
        newDomain = ""
    }

    private func alertToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.dante(size: 12.5)).foregroundStyle(theme.text.color)
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    // MARK: Secrets

    @ViewBuilder private var secretsStep: some View {
        if model.stage == .checking {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading the spec, checking the registry and pricing it…").font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
            }
            .padding(.top, 8)
        } else if let problem = model.deployProblem {
            VStack(alignment: .leading, spacing: 10) {
                note("exclamationmark.octagon", problem, tone: .stop)
                Button("Try again") { model.prepare(workspace: workspace) }.buttonStyle(DanteButtonStyle())
            }
        } else if model.databaseBindings.isEmpty && model.needed.isEmpty {
            box {
                HStack(spacing: 10) {
                    icon("checkmark.shield")
                    Text("Nothing to fill: every secret already has its value on DigitalOcean, or the app has none.")
                        .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            secrets
        }
    }

    // MARK: Review

    private var review: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 6) {
                if let name = model.spec?.name { chip("app.badge", name) }
                chip("globe.europe.africa", DeployFormat.region(model.spec?.region ?? model.region))
                if let team = model.person?.team, !team.isEmpty { chip("building.2", "\(team) team", strong: true) }
            }
            DeployRoute(nodes: routeSources, region: model.spec?.region ?? model.region, isNew: model.app == nil)
                .modifier(Arrival(shown: shown, index: 0))
            components.modifier(Arrival(shown: shown, index: 1))
            notes.modifier(Arrival(shown: shown, index: 2))
        }
    }

    /// Where the code comes from: this Mac and the registry for images built here, the git
    /// host for components App Platform builds itself.
    private var routeSources: [DeployRoute.Source] {
        var sources: [DeployRoute.Source] = []
        let components = model.spec?.components.map(\.component) ?? []
        let hosts: [(String, DOAppSpec.RepoSource?)] = [("GitHub", components.compactMap(\.github).first),
                                                        ("GitLab", components.compactMap(\.gitlab).first),
                                                        ("Bitbucket", components.compactMap(\.bitbucket).first)]
        for (host, repo) in hosts {
            if let repo { sources.append(.init(steps: [.init(symbol: "arrow.triangle.branch", title: host, detail: repo.branch ?? "main")])) }
        }
        if let git = components.compactMap(\.git).first {
            sources.append(.init(steps: [.init(symbol: "arrow.triangle.branch", title: "git", detail: git.branch ?? "main")]))
        }
        if !model.builds.isEmpty {
            let registry = model.registryInUse ?? model.registryToMake ?? "registry"
            sources.append(.init(steps: [
                .init(symbol: "laptopcomputer", title: "This Mac", detail: "Docker build"),
                .init(symbol: "shippingbox", title: registry, detail: model.registryToMake != nil ? "new · free" : "registry", warn: model.registryFull != nil),
            ]))
        }
        if sources.isEmpty, components.contains(where: { $0.image != nil }) {
            sources.append(.init(steps: [.init(symbol: "shippingbox", title: "Registry", detail: "images")]))
        }
        return sources
    }

    private var components: some View {
        let spec = model.spec
        let items = spec?.components ?? []
        let databases = spec?.databases ?? []
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("What runs", trailing: "\(items.count + databases.count) part\(items.count + databases.count == 1 ? "" : "s")")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                // Ids by name: the two lists share one grid, so offsets would collide.
                ForEach(Array(items.enumerated()), id: \.element.component.name) { index, item in
                    let count = item.component.autoscaling.map { "\($0.minInstanceCount ?? 1)–\($0.maxInstanceCount ?? 1)" } ?? ((item.component.instanceCount ?? 1) > 1 ? "\(item.component.instanceCount ?? 1)" : nil)
                    PartTile(symbol: symbol(for: item.kind), name: item.component.name, kind: item.kind == .job ? DeployFormat.job(item.component.kind) : item.kind.title,
                             detail: item.kind == .staticSite ? "CDN" : DeployFormat.size(item.component.instanceSizeSlug ?? DOPlan.smallestService) + (count.map { " × \($0)" } ?? ""),
                             price: price(item.kind, item.component), source: item.component.sourceDir.map { $0 + "/" })
                        .modifier(Arrival(shown: shown, index: 2 + index))
                }
                ForEach(Array(databases.enumerated()), id: \.element.name) { index, database in
                    PartTile(symbol: "cylinder.split.1x2", name: database.name, kind: database.production == true ? "Database" : "Dev database",
                             detail: [database.engine == "PG" ? "Postgres" : database.engine, database.version].compactMap { $0 }.joined(separator: " "),
                             price: database.production == true ? nil : 7, source: database.production == true ? database.clusterName : "no backups")
                        .modifier(Arrival(shown: shown, index: 2 + items.count + index))
                }
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let full = model.registryFull { note("exclamationmark.octagon", full, tone: .stop) }
            if model.source.isGitHost {
                if model.unpushed > 0 {
                    note("arrow.up.circle", "\(model.unpushed) commit\(model.unpushed == 1 ? " isn’t" : "s aren’t") pushed yet. App Platform builds what’s on \(model.branch) on the host.", tone: .warn)
                }
                if model.dirty { note("pencil.circle", "Uncommitted changes aren’t included.", tone: .warn) }
            }
            if let registry = model.registryToMake {
                note("shippingbox", "Makes a container registry, \(registry), on the free Starter plan (500 MB).", tone: .info)
            }
            if model.app == nil, let team = model.person?.team, !team.isEmpty {
                note("building.2", "Goes on the \(team) team’s bill. For another team, sign out and pick it when you sign in.", tone: .info)
            }
        }
    }

    private var secrets: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                sectionTitle("Secrets", trailing: nil)
                Spacer()
                let fillable = model.envMatches.filter { model.typedSecrets[$0.key] != $0.value }.count
                if fillable > 0 {
                    Button { withAnimation(.snappy) { model.fillFromEnv() } } label: {
                        Label("Fill \(fillable) from .env", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(DanteButtonStyle())
                    .help("Copies the values in the project’s .env files (and what mise sets) into the fields. Nothing is sent until you deploy.")
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(model.databaseBindings.enumerated()), id: \.offset) { index, bound in
                    if index > 0 { divider }
                    HStack(spacing: 10) {
                        keyLabel(bound.needed.key, symbol: "link", tint: theme.green.color)
                        HStack(spacing: 5) {
                            Image(systemName: "cylinder.split.1x2").font(.system(size: 10.5))
                            Text("from the \(databaseName(bound.binding)) database").font(.dante(size: 12))
                        }
                        .foregroundStyle(theme.green.color)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.greenTint.color))
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                ForEach(Array(model.needed.enumerated()), id: \.element.id) { index, needed in
                    if index > 0 || !model.databaseBindings.isEmpty { divider }
                    let filled = !(model.typedSecrets[needed.id] ?? "").isEmpty
                    HStack(spacing: 10) {
                        keyLabel(needed.key, symbol: filled ? "lock.fill" : "lock.open", tint: filled ? theme.accent.color : theme.text3.color)
                        SecureField("for \(needed.component ?? "the app")", text: Binding(get: { model.typedSecrets[needed.id] ?? "" }, set: {
                            // A focused field hands a filled value straight back; only a real edit drops the tag.
                            guard $0 != model.typedSecrets[needed.id] ?? "" else { return }
                            model.typedSecrets[needed.id] = $0
                            model.filledFromEnv.remove(needed.id)
                        }))
                        .textFieldStyle(.roundedBorder)
                        if model.filledFromEnv.contains(needed.id) {
                            Text(".env").font(.dante(size: 10.5, weight: .medium)).foregroundStyle(theme.accent.color)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 5).fill(theme.accentTint.color))
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.card.color))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.line.color))
            if !model.filledFromEnv.isEmpty {
                note("exclamationmark.triangle", "Filled from this Mac’s .env: development values. Production usually needs its own, above all encryption and signing keys, since what you send protects real data.", tone: .warn)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            if let problem = model.setupProblem, step < .secrets {
                Label(problem, systemImage: "exclamationmark.triangle").font(.dante(size: 12)).foregroundStyle(theme.red.color).lineLimit(2)
            } else if step == .reach || (model.resizing != nil && step == .parts) || (step < .reach && model.setupChanged && model.specText != nil) {
                Text(model.setupChanged ? "Your choices are saved to \(DOAppSpec.path) when you go on." : "\(DOAppSpec.path) is unchanged.")
                    .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            } else if step == .secrets, !model.needed.isEmpty {
                let left = model.needed.filter { (model.typedSecrets[$0.id] ?? "").isEmpty }.count
                Text(left == 0 ? "All set." : "\(left) secret\(left == 1 ? "" : "s") to fill")
                    .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
                    .contentTransition(.numericText(value: Double(left)))
                    .animation(.snappy, value: left)
            } else if step == .review {
                Text(model.proposal?.appCost == nil ? "Estimated from the sizes" : "DigitalOcean’s own price")
                    .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            }
            Spacer()
            Button("Cancel") { model.closeWizard() }.buttonStyle(DanteButtonStyle()).keyboardShortcut(.cancelAction)
            if step > .source, model.setup != nil || step == .review, !(model.resizing != nil && step == .parts) {
                Button("Back") { go(to: model.resizing != nil && step == .secrets ? .parts : Step(rawValue: step.rawValue - 1) ?? .source) }
                    .buttonStyle(DanteButtonStyle())
                    .disabled(model.stage == .checking || (step == .secrets && model.setup == nil))
            }
            switch step {
            case .reach, .parts where model.resizing != nil:
                Button(model.setupChanged ? "Save and price" : "Price it") {
                    forward = true
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.32)) { model.saveSetup(workspace: workspace) }
                }
                .buttonStyle(DanteButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                .help("Writes the choices into \(DOAppSpec.path), then checks it and asks DigitalOcean for the price. Nothing is made yet.")
            case .secrets:
                if model.stage == .confirming {
                    Button("Next") { go(to: .review) }.buttonStyle(DanteButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") {
                        forward = true
                        withAnimation(.snappy) { model.secretsEntered() }
                    }
                    .buttonStyle(DanteButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(model.stage != .needsSecrets || model.needed.contains { (model.typedSecrets[$0.id] ?? "").isEmpty })
                }
            case .review:
                // No Return shortcut: this spends money, so only a deliberate click deploys.
                Button { model.confirm(workspace: workspace) } label: {
                    Label(model.app == nil ? "Deploy" : "Deploy again", systemImage: "icloud.and.arrow.up")
                }
                .buttonStyle(DanteButtonStyle(primary: true))
                .disabled(model.stage != .confirming || model.registryFull != nil)
            default:
                Button("Next") { go(to: Step(rawValue: step.rawValue + 1) ?? .review) }
                    .buttonStyle(DanteButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 13)
        .background(theme.card.color)
        .overlay(alignment: .top) { Rectangle().fill(theme.line.color).frame(height: 1) }
    }

    // MARK: Pieces

    private var divider: some View { Rectangle().fill(theme.line.color).frame(height: 1) }

    private func box<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11).fill(theme.card.color))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(theme.line.color))
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).frame(width: 80, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func field<Content: View>(_ label: String, help: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(label, trailing: nil)
            content()
            Text(help).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
        }
    }

    private func icon(_ symbol: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(theme.accentTint.color)
            Image(systemName: symbol).font(.system(size: 13.5, weight: .medium)).foregroundStyle(theme.accent.color)
        }
        .frame(width: 30, height: 30)
    }

    private func keyLabel(_ key: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(tint).frame(width: 14)
                .contentTransition(.symbolEffect(.replace))
            Text(key).font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text.color).lineLimit(1).truncationMode(.middle)
        }
        .frame(width: 230, alignment: .leading)
    }

    private func sectionTitle(_ title: String, trailing: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title.uppercased()).font(.dante(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(theme.text3.color)
            if let trailing { Text(trailing).font(.dante(size: 11)).foregroundStyle(theme.text3.color) }
        }
    }

    private func chip(_ symbol: String, _ text: String, strong: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(text).font(.dante(size: 11.5, weight: strong ? .semibold : .regular)).lineLimit(1)
        }
        .foregroundStyle(strong ? theme.accent.color : theme.text2.color)
        .padding(.horizontal, 8).padding(.vertical, 3.5)
        .background(RoundedRectangle(cornerRadius: 6).fill(strong ? theme.accentTint.color : theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(strong ? theme.accentLine.color : theme.line.color))
    }

    private enum Tone { case info, warn, stop }

    private func note(_ symbol: String, _ text: String, tone: Tone) -> some View {
        let tint: Color = switch tone {
        case .info: theme.text2.color
        case .warn: theme.amber.color
        case .stop: theme.red.color
        }
        return HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(tint)
            Text(text).font(.dante(size: 12.5)).foregroundStyle(tone == .info ? theme.text2.color : theme.text.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(tone == .info ? theme.card.color : tint.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(tone == .info ? theme.line.color : tint.opacity(0.35)))
    }

    private func symbol(for kind: DOAppSpec.Kind) -> String {
        switch kind {
        case .service: "server.rack"
        case .staticSite: "doc.richtext"
        case .worker: "gearshape.2"
        case .job: "clock.arrow.circlepath"
        }
    }

    private func price(_ kind: DOAppSpec.Kind, _ component: DOAppSpec.Component) -> Double? {
        if kind == .staticSite { return 0 }
        // A job run around a deploy is billed for the seconds it runs, not a month.
        if kind == .job, component.kind?.uppercased().hasSuffix("_DEPLOY") == true { return nil }
        let slug = component.instanceSizeSlug ?? DOPlan.smallestService
        let count = component.autoscaling?.minInstanceCount ?? component.instanceCount ?? 1
        return model.sizes.first { $0.slug == slug }?.monthly.map { $0 * Double(count) }
    }

    private func databaseName(_ binding: String) -> String {
        String(binding.drop { $0 != "{" }.dropFirst().prefix { $0 != "." })
    }
}

/// Fades and lifts a piece in, a beat after the one before it.
private struct Arrival: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let shown: Bool
    let index: Int

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.15).delay(Double(index) * 0.06), value: shown)
    }
}

/// One part of the app: what it is, its size and what it costs.
private struct PartTile: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let name: String
    let kind: String
    let detail: String
    let price: Double?
    let source: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(theme.accentTint.color)
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(theme.accent.color)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name).font(.dante(size: 13, weight: .semibold)).foregroundStyle(theme.text.color).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(price.map { $0 == 0 ? "Free" : String(format: "$%.0f", $0) } ?? "")
                        .font(.dante(size: 12, weight: .semibold))
                        .foregroundStyle(price == 0 ? theme.green.color : theme.text.color)
                }
                Text(kind + " · " + detail).font(.dante(size: 11.5)).foregroundStyle(theme.text2.color).lineLimit(1)
                if let source { Text(source).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color).lineLimit(1).truncationMode(.middle) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.line.color))
    }
}

/// Where the code travels: each source (a git host, or this Mac and the registry) on its own
/// lane, joining App Platform in the region, with pulses running along the links.
struct DeployRoute: View {
    struct Step: Hashable {
        var symbol: String
        var title: String
        var detail: String
        var warn = false
    }

    struct Source: Hashable {
        var steps: [Step]
    }

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let nodes: [Source]
    let region: String
    let isNew: Bool

    static let laneHeight: CGFloat = 46
    static let laneSpacing: CGFloat = 10
    static let linkWidth: CGFloat = 54

    var body: some View {
        let lanes = max(nodes.count, 1)
        let height = CGFloat(lanes) * Self.laneHeight + CGFloat(lanes - 1) * Self.laneSpacing
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Self.laneSpacing) {
                ForEach(Array(nodes.enumerated()), id: \.offset) { _, source in
                    HStack(spacing: 0) {
                        ForEach(Array(source.steps.enumerated()), id: \.offset) { index, step in
                            if index > 0 { links(from: [0.5], width: 34, height: Self.laneHeight) }
                            node(step)
                        }
                    }
                    .frame(height: Self.laneHeight)
                }
            }
            .fixedSize()
            links(from: (0..<lanes).map { (CGFloat($0) * (Self.laneHeight + Self.laneSpacing) + Self.laneHeight / 2) / height },
                  width: Self.linkWidth, height: height)
            destination.frame(height: max(height, 58))
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.line.color))
    }

    private func node(_ step: Step) -> some View {
        HStack(spacing: 8) {
            Image(systemName: step.symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(step.warn ? theme.red.color : theme.text2.color).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title).font(.dante(size: 12, weight: .semibold)).foregroundStyle(theme.text.color).lineLimit(1)
                Text(step.detail).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).frame(height: Self.laneHeight)
        .fixedSize(horizontal: true, vertical: false)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.raised.color))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(step.warn ? theme.red.color.opacity(0.5) : theme.line.color))
    }

    private var destination: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let phase = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
            HStack(spacing: 10) {
                ZStack {
                    Circle().strokeBorder(theme.accent.color.opacity(0.35 * (1 - phase)), lineWidth: 1.5)
                        .scaleEffect(1 + phase * 0.55)
                    Circle().fill(theme.accentTint.color)
                    Image(systemName: "globe.europe.africa.fill").font(.system(size: 17)).foregroundStyle(theme.accent.color)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("App Platform").font(.dante(size: 12.5, weight: .semibold)).foregroundStyle(theme.text.color)
                    Text(DeployFormat.region(region) + (isNew ? " · new app" : "")).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 11).fill(theme.accentTint.color.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(theme.accentLine.color))
        }
    }

    /// Curves from each start (a fraction of the height) to the middle of the right edge,
    /// with a pulse running along each.
    private func links(from starts: [CGFloat], width: CGFloat, height: CGFloat) -> some View {
        let accent = theme.accent.color, line = theme.line2.color
        return TimelineView(.animation(paused: reduceMotion)) { context in
            let time = reduceMotion ? 0.35 : context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let end = CGPoint(x: size.width, y: size.height / 2)
                for (index, fraction) in starts.enumerated() {
                    let start = CGPoint(x: 0, y: size.height * fraction)
                    let c1 = CGPoint(x: size.width * 0.55, y: start.y), c2 = CGPoint(x: size.width * 0.45, y: end.y)
                    var path = Path()
                    path.move(to: start)
                    path.addCurve(to: end, control1: c1, control2: c2)
                    canvas.stroke(path, with: .color(line), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
                    let t = (time / 1.6 + Double(index) * 0.37).truncatingRemainder(dividingBy: 1)
                    let point = Self.bezier(start, c1, c2, end, t)
                    let glow = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
                    canvas.fill(Path(ellipseIn: glow), with: .color(accent.opacity(0.22)))
                    canvas.fill(Path(ellipseIn: glow.insetBy(dx: 2.5, dy: 2.5)), with: .color(accent))
                }
            }
        }
        .frame(width: width, height: height)
    }

    static func bezier(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: Double) -> CGPoint {
        let u = 1 - t
        let x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x
        let y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
        return CGPoint(x: x, y: y)
    }
}
