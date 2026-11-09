import DanteKit
import SwiftUI

/// The moment a deploy spends money, so it shows where the code goes (a live route, in the
/// Infra view's style), what gets made, whose bill it lands on and what it costs, before the
/// one deliberate click that deploys.
struct DeploySheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: Session
    let workspace: Workspace
    @State private var shown = false
    private var model: DeployModel { session.deploy }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }.frame(height: 520)
            }
            footer
        }
        .frame(width: 600)
        .background(theme.panel.color)
        .onAppear {
            if reduceMotion { shown = true } else { withAnimation(.spring(duration: 0.55, bounce: 0.2)) { shown = true } }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(theme.accentTint.color)
                Image(systemName: "icloud.and.arrow.up").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.accent.color)
            }
            .frame(width: 38, height: 38)
            .scaleEffect(shown ? 1 : 0.6).opacity(shown ? 1 : 0)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.app == nil ? "Deploy to DigitalOcean" : "Deploy \(model.app?.name ?? "") again")
                    .font(.dante(size: 18, weight: .semibold)).foregroundStyle(theme.text.color)
                HStack(spacing: 6) {
                    if let name = model.spec?.name { chip("app.badge", name) }
                    chip("globe.europe.africa", DeployFormat.region(model.spec?.region ?? model.region))
                    // Whose bill it lands on comes first: the consent page picks a team, often a company's.
                    if let team = model.person?.team, !team.isEmpty { chip("building.2", "\(team) team", strong: true) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Body

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            DeployRoute(nodes: routeSources, region: model.spec?.region ?? model.region, isNew: model.app == nil)
                .modifier(Arrival(shown: shown, index: 0))
            components.modifier(Arrival(shown: shown, index: 1))
            notes.modifier(Arrival(shown: shown, index: 2))
            if !model.databaseBindings.isEmpty || !model.needed.isEmpty {
                secrets.modifier(Arrival(shown: shown, index: 3))
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 18)
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
                    PartTile(symbol: symbol(for: item.kind), name: item.component.name, kind: item.kind.title,
                             detail: item.kind == .staticSite ? "CDN" : DeployFormat.size(item.component.instanceSizeSlug ?? DOPlan.smallestService)
                                + ((item.component.instanceCount ?? 1) > 1 ? " × \(item.component.instanceCount ?? 1)" : ""),
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
            } else if !model.needed.isEmpty {
                Text("Sent once to DigitalOcean, which keeps them encrypted. Dante doesn’t save them.")
                    .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        let cost = model.proposal?.appCost ?? model.estimate
        return HStack(alignment: .center, spacing: 12) {
            if model.stage == .checking {
                ProgressView().controlSize(.small)
                Text("Pricing it…").font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
            } else if model.needed.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(cost.map { $0 == 0 ? "Free" : String(format: "$%.2f", $0) } ?? "—")
                            .font(.dante(size: 24, weight: .semibold)).foregroundStyle(theme.text.color)
                            .contentTransition(.numericText(value: cost ?? 0))
                            .animation(reduceMotion ? nil : .snappy, value: cost)
                        if let cost, cost > 0 { Text("a month").font(.dante(size: 12.5)).foregroundStyle(theme.text2.color) }
                    }
                    Text(model.proposal?.appCost == nil ? "Estimated from the sizes · billed by the second" : "DigitalOcean’s price · billed by the second")
                        .font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                }
            } else {
                let left = model.needed.filter { (model.typedSecrets[$0.id] ?? "").isEmpty }.count
                Text(left == 0 ? "All set: Continue prices it." : "\(left) secret\(left == 1 ? "" : "s") to fill")
                    .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
                    .contentTransition(.numericText(value: Double(left)))
                    .animation(.snappy, value: left)
            }
            Spacer()
            Button("Cancel") { model.cancelDeploy() }.buttonStyle(DanteButtonStyle()).keyboardShortcut(.cancelAction)
            if model.needed.isEmpty {
                // No Return shortcut: this spends money, so only a deliberate click deploys.
                Button { model.confirm(workspace: workspace) } label: {
                    Label(model.app == nil ? "Deploy" : "Deploy again", systemImage: "icloud.and.arrow.up")
                }
                .buttonStyle(DanteButtonStyle(primary: true))
                .disabled(model.stage != .confirming || model.registryFull != nil)
            } else {
                Button("Continue") { model.secretsEntered() }
                    .buttonStyle(DanteButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(model.needed.contains { (model.typedSecrets[$0.id] ?? "").isEmpty })
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .background(theme.card.color)
        .overlay(alignment: .top) { Rectangle().fill(theme.line.color).frame(height: 1) }
    }

    // MARK: Pieces

    private var divider: some View { Rectangle().fill(theme.line.color).frame(height: 1).padding(.leading, 12) }

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
        let slug = component.instanceSizeSlug ?? DOPlan.smallestService
        return model.sizes.first { $0.slug == slug }?.monthly.map { $0 * Double(component.instanceCount ?? 1) }
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
