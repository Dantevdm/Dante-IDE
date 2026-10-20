import DanteKit
import SwiftUI

/// The Map's Infra view: how a change is delivered (the pipelines, stage by stage) and where
/// it runs (the cloud resources by tier), drawn as one architecture picture with the traffic
/// flowing through it. The agent in charge explains, reviews or writes what's missing.
struct InfraView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let infra: Infrastructure
    @Binding var selected: String?

    var body: some View {
        if infra.isEmpty {
            EmptyState(symbol: "cloud", title: "No pipelines or infrastructure found",
                       message: "Dante reads CloudFormation, SAM, Terraform and ARM templates, and Azure DevOps, GitHub Actions and GitLab pipelines.") {
                HStack(spacing: 8) {
                    GenerateMenu(session: session, infra: infra, kind: .pipeline)
                    GenerateMenu(session: session, infra: infra, kind: .infrastructure)
                }
            }
        } else {
            InfraSummary(infra: infra)
            StoryCard(session: session, infra: infra)
            InfraCanvas(infra: infra, selected: $selected)
        }
    }
}

// MARK: Colours and icons

extension Infrastructure.Tier {
    func hue(_ theme: Theme) -> Color {
        switch self {
        case .edge: theme.syntax.keyword.color
        case .compute: theme.amber.color
        case .data: theme.accent.color
        case .messaging: theme.syntax.type.color
        case .registry: theme.syntax.function.color
        case .security: theme.red.color
        case .network: theme.syntax.type.color
        case .observability: theme.green.color
        case .other: theme.text3.color
        }
    }

    var symbol: String {
        switch self {
        case .edge: "globe"
        case .compute: "cpu"
        case .data: "cylinder.split.1x2"
        case .messaging: "tray.2"
        case .registry: "archivebox"
        case .security: "lock.shield"
        case .network: "network"
        case .observability: "waveform.path.ecg"
        case .other: "cube"
        }
    }
}

extension Infrastructure.Provider {
    var symbol: String {
        switch self {
        case .aws, .google: "cloud"
        case .azure: "cloud.fill"
        case .other: "cloud"
        }
    }
}

// MARK: Summary and story

private struct InfraSummary: View {
    @Environment(\.theme) private var theme
    let infra: Infrastructure

    var body: some View {
        let stages = infra.pipelines.reduce(0) { $0 + $1.stages.count }
        let stats: [(String, String, String)] = [
            ("\(infra.pipelines.count)", infra.pipelines.count == 1 ? "pipeline" : "pipelines", Set(infra.pipelines.map(\.system)).sorted().joined(separator: ", ")),
            ("\(stages)", stages == 1 ? "stage" : "stages", infra.pipelines.flatMap(\.branches).first.map { "from \($0)" } ?? ""),
            ("\(infra.stacks.count)", infra.stacks.count == 1 ? "stack" : "stacks", Set(infra.stacks.map(\.tool)).sorted().joined(separator: ", ")),
            ("\(infra.resources.filter { !$0.isOutside }.count)", "resources", infra.provider == .other ? "" : infra.provider.rawValue),
            ("\(infra.environments.count)", infra.environments.count == 1 ? "environment" : "environments", infra.environments.joined(separator: ", ")),
        ]
        HStack(spacing: 10) {
            ForEach(stats, id: \.1) { value, label, note in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(value).font(.dante(size: 20, weight: .semibold)).foregroundStyle(theme.text.color)
                        Text(label).font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                    }
                    Text(note.isEmpty ? " " : note).font(.dante(size: 11)).foregroundStyle(theme.text3.color).lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.card.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.line.color))
            }
        }
    }
}

private struct StoryCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let infra: Infrastructure

    var body: some View {
        let story = InfraStory(infra)
        Card("How it works") {
            HStack(spacing: 8) {
                if infra.pipelines.isEmpty { GenerateMenu(session: session, infra: infra, kind: .pipeline) }
                if infra.stacks.isEmpty { GenerateMenu(session: session, infra: infra, kind: .infrastructure) }
                Menu {
                    Button("Explain how a change reaches production") { session.askClaude(InfraPrompt.explain(infra)) }
                    Button("Review it: security, tagging, cost and reliability") { session.askClaude(InfraPrompt.review(infra)) }
                    Divider()
                    Button("Write an architecture document with a diagram") { session.askClaude(InfraPrompt.document(infra)) }
                } label: {
                    ClaudeLabel("Ask \(session.agentName)")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(story.lines, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: line.symbol)
                            .font(.dante(size: 11, weight: .semibold))
                            .foregroundStyle(theme.accent.color)
                            .frame(width: 22, height: 22)
                            .background(theme.accentTint.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.title).font(.dante(size: 12, weight: .semibold)).foregroundStyle(theme.text.color)
                            Text(line.text).font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

/// Writes what's missing with the agent in charge: a pipeline or the infrastructure as code.
private struct GenerateMenu: View {
    enum Kind { case pipeline, infrastructure }
    let session: Session
    let infra: Infrastructure
    let kind: Kind

    var body: some View {
        Menu {
            switch kind {
            case .pipeline:
                ForEach(["Azure DevOps", "GitHub Actions", "GitLab CI"], id: \.self) { system in
                    Button(system) { session.askClaude(InfraPrompt.pipeline(system, infra)) }
                }
            case .infrastructure:
                ForEach(["CloudFormation", "Terraform", "Bicep"], id: \.self) { tool in
                    Button(tool) { session.askClaude(InfraPrompt.infrastructure(tool, infra)) }
                }
            }
        } label: {
            ClaudeLabel(kind == .pipeline ? "Write a pipeline" : "Write the infrastructure")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Ask \(session.agentName) to write it for this project; you approve each file")
    }
}

/// What the agent is asked, with what Dante already found so it starts from the facts.
enum InfraPrompt {
    static func facts(_ infra: Infrastructure) -> String {
        guard !infra.isEmpty else { return "Dante found no pipelines or infrastructure templates in the repo." }
        var lines = ["What Dante found:"]
        for pipeline in infra.pipelines {
            lines.append("- \(pipeline.system) pipeline \(pipeline.file): " + pipeline.stages.map(\.name).joined(separator: " → "))
        }
        for stack in infra.stacks {
            lines.append("- \(stack.tool) stack \(stack.name) (\(stack.files.joined(separator: ", "))): " + infra.resources.filter { $0.stack == stack.id }.map { "\($0.name) [\($0.service)]" }.joined(separator: ", "))
        }
        if !infra.dockerfiles.isEmpty { lines.append("- Dockerfiles: " + infra.dockerfiles.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    static func explain(_ infra: Infrastructure) -> String {
        "Explain how a change in this project reaches production: the pipelines and what each stage does, how the image is built and where it goes, how the database is migrated, how the infrastructure is deployed, and how a request reaches the app. Point at the files. Don't print any secret values.\n\n" + facts(infra)
    }

    static func review(_ infra: Infrastructure) -> String {
        "Review this project's infrastructure and pipelines, read-only: security (IAM scope, security groups, encryption, secrets handling), tagging, cost, reliability (health checks, rollbacks, alarms) and anything that differs between environments. Follow any standards documented in the repo. List findings by importance with the file and line, and suggest fixes, but don't change anything yet. Don't print any secret values.\n\n" + facts(infra)
    }

    static func document(_ infra: Infrastructure) -> String {
        "Write docs/infrastructure.md: how this project is built, delivered and run, with a Mermaid diagram of the pipeline stages and the cloud resources and how traffic flows through them, one short section per stack, and the environments. Keep it accurate to the files; don't include secret values.\n\n" + facts(infra)
    }

    static func pipeline(_ system: String, _ infra: Infrastructure) -> String {
        "Write a \(system) pipeline for this project: build and test each app, build the container image(s) from the existing Dockerfiles (or add them), push them to the registry, run database migrations if the project has them, and deploy to the infrastructure below, with a non-production and a production stage (production behind an approval). Keep secrets in the pipeline's secret store, never in the file. Explain each stage briefly.\n\n" + facts(infra)
    }

    static func infrastructure(_ tool: String, _ infra: Infrastructure) -> String {
        "Write \(tool) for running this project in the cloud: the apps as containers behind a load balancer with health checks, the database, the image registry, logs, and least-privilege roles, with parameters per environment (non-prod and prod). Put it under infrastructure/. Don't invent account IDs or secrets; leave them as parameters. Explain the design briefly.\n\n" + facts(infra)
    }
}

// MARK: The picture

private struct FrameKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct InfraCanvas: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let infra: Infrastructure
    @Binding var selected: String?

    static let nodeWidth: CGFloat = 196

    private var mainTiers: [Infrastructure.Tier] {
        Infrastructure.Tier.allCases.filter { tier in tier.isMain && infra.resources.contains { $0.tier == tier } }
    }

    private var supportTiers: [Infrastructure.Tier] {
        Infrastructure.Tier.allCases.filter { tier in !tier.isMain && infra.resources.contains { $0.tier == tier } }
    }

    /// Resources nothing on the edge leads into: where users arrive.
    private var entrances: [Infrastructure.Resource] {
        infra.resources.filter { r in r.tier == .edge && !infra.links.contains { $0.to == r.id && infra.resource($0.from)?.tier == .edge } }
    }

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 26) {
                if !infra.pipelines.isEmpty { delivery }
                if !infra.resources.isEmpty { cloud }
            }
            .padding(24)
            .backgroundPreferenceValue(FrameKey.self) { anchors in
                GeometryReader { proxy in
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                        Canvas { context, _ in
                            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                            draw(in: &context, frames: anchors.mapValues { proxy[$0] }, time: time)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panel.color)
        .background(DotGrid(color: theme.line2.color, spacing: 16))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line.color))
    }

    // MARK: Delivery

    private var delivery: some View {
        VStack(alignment: .leading, spacing: 12) {
            BandTitle(symbol: "arrow.triangle.branch", title: "Delivery", note: Set(infra.pipelines.map(\.system)).sorted().joined(separator: " · "))
            ForEach(infra.pipelines) { pipeline in
                HStack(alignment: .center, spacing: 40) {
                    SourceNode(pipeline: pipeline)
                        .anchorPreference(key: FrameKey.self, value: .bounds) { ["source:" + pipeline.id: $0] }
                    ForEach(pipeline.stages) { stage in
                        let id = pipeline.id + "#" + stage.id
                        StageNode(stage: stage, state: state(id)) { toggle(id) }
                            .anchorPreference(key: FrameKey.self, value: .bounds) { [id: $0] }
                    }
                }
            }
        }
    }

    // MARK: Cloud

    private var cloud: some View {
        VStack(alignment: .leading, spacing: 14) {
            BandTitle(symbol: infra.provider.symbol, title: infra.provider == .other ? "Cloud" : infra.provider.rawValue + " cloud",
                      note: infra.stacks.map(\.name).joined(separator: " · "))
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 46) {
                    if !entrances.isEmpty {
                        UsersNode().anchorPreference(key: FrameKey.self, value: .bounds) { ["users": $0] }
                    }
                    ForEach(mainTiers, id: \.self) { tier in tierPanel(tier) }
                }
                if !supportTiers.isEmpty {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(supportTiers, id: \.self) { tier in tierPanel(tier) }
                    }
                }
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.card.color.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.line2.color, style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])))
        }
    }

    private func tierPanel(_ tier: Infrastructure.Tier) -> some View {
        let hue = tier.hue(theme)
        let members = infra.resources.filter { $0.tier == tier }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: tier.symbol).font(.dante(size: 10, weight: .semibold))
                Text(tier.title.uppercased()).font(.dante(size: 10.5, weight: .semibold)).tracking(0.8)
                Text("\(members.count)").font(.dante(size: 10.5, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 5).background(hue.opacity(0.14), in: Capsule())
            }
            .foregroundStyle(hue)
            ForEach(members) { resource in
                ResourceNode(resource: resource, hue: hue, state: state(resource.id)) { toggle(resource.id) }
                    .anchorPreference(key: FrameKey.self, value: .bounds) { [resource.id: $0] }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hue.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hue.opacity(0.28)))
    }

    // MARK: Selection

    enum NodeState { case normal, selected, related, dimmed }

    private func toggle(_ id: String) {
        withAnimation(.snappy(duration: 0.2)) { selected = selected == id ? nil : id }
    }

    private func related(_ id: String) -> Set<String> {
        var ids: Set<String> = [id]
        for link in infra.links + infra.deploys where link.from == id || link.to == id { ids.insert(link.from); ids.insert(link.to) }
        return ids
    }

    private func state(_ id: String) -> NodeState {
        guard let selected else { return .normal }
        if selected == id { return .selected }
        return related(selected).contains(id) ? .related : .dimmed
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, frames: [String: CGRect], time: Double) {
        let highlight = selected.map(related) ?? []
        // Pipeline order: source → stages, along each stage's dependencies.
        for pipeline in infra.pipelines {
            for (index, stage) in pipeline.stages.enumerated() {
                let to = pipeline.id + "#" + stage.id
                let froms = stage.dependsOn.isEmpty ? [index == 0 ? "source:" + pipeline.id : pipeline.id + "#" + pipeline.stages[index - 1].id]
                    : stage.dependsOn.map { pipeline.id + "#" + $0 }
                for from in froms {
                    guard let a = frames[from], let b = frames[to] else { continue }
                    stroke(curve(a, b), color: theme.accent.color, width: 1.6, dash: [6, 6], phase: -time * 22, in: &context)
                }
            }
        }
        // Users into the edge.
        if let users = frames["users"] {
            for entrance in entrances {
                guard let b = frames[entrance.id] else { continue }
                let path = curve(users, b)
                stroke(path, color: theme.text3.color, width: 1.4, dash: [4, 6], phase: -time * 18, in: &context)
                pulse(path, time: time, color: entrance.tier.hue(theme), in: &context)
            }
        }
        // Between resources: traffic along the main tiers flows, support links are quiet.
        for link in infra.links {
            guard let from = infra.resource(link.from), let to = infra.resource(link.to), let a = frames[link.from], let b = frames[link.to] else { continue }
            let lit = highlight.contains(link.from) && highlight.contains(link.to) && selected != nil
            let dimmed = selected != nil && !lit
            let path = curve(a, b)
            let traffic = from.tier.isMain && to.tier.isMain
            let color = lit ? theme.accent.color : (traffic ? to.tier.hue(theme) : theme.line2.color)
            stroke(path, color: color.opacity(dimmed ? 0.25 : traffic ? 0.85 : 0.9), width: lit ? 2.2 : traffic ? 1.7 : 1.2,
                   dash: link.declared ? [] : [5, 4], phase: 0, in: &context)
            arrowhead(path, at: b, color: color.opacity(dimmed ? 0.25 : 1), in: &context)
            if traffic, !dimmed { pulse(path, time: time + Double(abs(link.from.hashValue % 7)) * 0.21, color: to.tier.hue(theme), in: &context) }
            if lit || (traffic && selected == nil) { label(link.label, on: path, in: &context) }
        }
        // What each stage changes: faint until a stage or its target is selected.
        for link in infra.deploys {
            guard let a = frames[link.from], let b = frames[link.to] else { continue }
            let lit = selected != nil && (selected == link.from || selected == link.to)
            let path = drop(a, b)
            stroke(path, color: theme.accent.color.opacity(lit ? 0.95 : 0.22), width: lit ? 1.8 : 1, dash: [3, 5], phase: lit ? -time * 26 : 0, in: &context)
            if lit {
                arrowhead(path, at: b, color: theme.accent.color, in: &context)
                label(link.label, on: path, in: &context)
            }
        }
    }

    /// Side to side when one is beside the other, else top to bottom.
    private func curve(_ a: CGRect, _ b: CGRect) -> Path {
        var path = Path()
        if b.minX >= a.maxX - 4 {
            let start = CGPoint(x: a.maxX, y: a.midY), end = CGPoint(x: b.minX - 2, y: b.midY)
            let bend = max((end.x - start.x) / 2, 24)
            path.move(to: start)
            path.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y), control2: CGPoint(x: end.x - bend, y: end.y))
        } else if b.maxX <= a.minX + 4 {
            let start = CGPoint(x: a.minX, y: a.midY), end = CGPoint(x: b.maxX + 2, y: b.midY)
            let bend = max((start.x - end.x) / 2, 24)
            path.move(to: start)
            path.addCurve(to: end, control1: CGPoint(x: start.x - bend, y: start.y), control2: CGPoint(x: end.x + bend, y: end.y))
        } else {
            let down = b.midY > a.midY
            let start = CGPoint(x: a.midX, y: down ? a.maxY : a.minY), end = CGPoint(x: b.midX, y: down ? b.minY - 2 : b.maxY + 2)
            let bend = max(abs(end.y - start.y) / 2, 18)
            path.move(to: start)
            path.addCurve(to: end, control1: CGPoint(x: start.x, y: start.y + (down ? bend : -bend)), control2: CGPoint(x: end.x, y: end.y + (down ? -bend : bend)))
        }
        return path
    }

    /// From a stage down into the cloud.
    private func drop(_ a: CGRect, _ b: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: a.midX, y: a.maxY), end = CGPoint(x: b.midX, y: b.minY - 2)
        let bend = max((end.y - start.y) / 2, 30)
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: start.x, y: start.y + bend), control2: CGPoint(x: end.x, y: end.y - bend))
        return path
    }

    private func stroke(_ path: Path, color: Color, width: CGFloat, dash: [CGFloat], phase: Double, in context: inout GraphicsContext) {
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash, dashPhase: CGFloat(phase)))
    }

    /// A small glowing packet travelling along the path.
    private func pulse(_ path: Path, time: Double, color: Color, in context: inout GraphicsContext) {
        let progress = CGFloat((time / 2.4).truncatingRemainder(dividingBy: 1))
        guard progress > 0.02, let point = path.trimmedPath(from: 0, to: progress).currentPoint else { return }
        let fade = min(1, min(progress, 1 - progress) * 6)
        context.fill(Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)), with: .color(color.opacity(0.18 * fade)))
        context.fill(Path(ellipseIn: CGRect(x: point.x - 2.6, y: point.y - 2.6, width: 5.2, height: 5.2)), with: .color(color.opacity(fade)))
    }

    private func arrowhead(_ path: Path, at target: CGRect, color: Color, in context: inout GraphicsContext) {
        guard let end = path.currentPoint, let before = path.trimmedPath(from: 0, to: 0.97).currentPoint else { return }
        let angle = atan2(end.y - before.y, end.x - before.x)
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - 7 * cos(angle - 0.45), y: end.y - 7 * sin(angle - 0.45)))
        head.addLine(to: CGPoint(x: end.x - 7 * cos(angle + 0.45), y: end.y - 7 * sin(angle + 0.45)))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }

    private func label(_ text: String, on path: Path, in context: inout GraphicsContext) {
        guard let point = path.trimmedPath(from: 0, to: 0.5).currentPoint else { return }
        let resolved = context.resolve(Text(text).font(.dante(size: 9.5, weight: .medium)).foregroundColor(theme.text2.color))
        let size = resolved.measure(in: CGSize(width: 200, height: 20))
        let box = CGRect(x: point.x - size.width / 2 - 5, y: point.y - size.height / 2 - 2, width: size.width + 10, height: size.height + 4)
        context.fill(Path(roundedRect: box, cornerRadius: box.height / 2), with: .color(theme.card.color))
        context.stroke(Path(roundedRect: box, cornerRadius: box.height / 2), with: .color(theme.line.color), lineWidth: 0.8)
        context.draw(resolved, at: point)
    }
}

// MARK: Nodes

private struct BandTitle: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let title: String
    let note: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.dante(size: 12, weight: .semibold)).foregroundStyle(theme.text2.color)
            Text(title.uppercased()).font(.dante(size: 11, weight: .semibold)).tracking(1).foregroundStyle(theme.text2.color)
            if !note.isEmpty {
                Text(note).font(.dante(size: 11)).foregroundStyle(theme.text3.color).lineLimit(1)
            }
        }
    }
}

private struct SourceNode: View {
    @Environment(\.theme) private var theme
    let pipeline: Infrastructure.Pipeline

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.dante(size: 10.5, weight: .bold))
                    .foregroundStyle(theme.onAccent.color)
                    .frame(width: 22, height: 22)
                    .background(theme.accent.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(pipeline.name).font(.dante(size: 12.5, weight: .semibold)).foregroundStyle(theme.text.color).lineLimit(1)
                    Text(pipeline.system).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color)
                }
            }
            HStack(spacing: 4) {
                ForEach(pipeline.branches.prefix(3), id: \.self) { branch in
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.dante(size: 10, design: .monospaced))
                        .foregroundStyle(theme.text2.color)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(theme.raised.color, in: Capsule())
                }
                if let environment = pipeline.environment {
                    Text(environment).font(.dante(size: 10, weight: .medium)).foregroundStyle(theme.accent.color)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(theme.accentTint.color, in: Capsule())
                }
            }
        }
        .padding(10)
        .frame(width: 190, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.accentLine.color))
        .help(pipeline.file)
    }
}

private struct StageNode: View {
    @Environment(\.theme) private var theme
    let stage: Infrastructure.Stage
    let state: InfraCanvas.NodeState
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: stage.kind.symbol)
                        .font(.dante(size: 11, weight: .semibold))
                        .foregroundStyle(theme.accent.color)
                        .frame(width: 24, height: 24)
                        .background(theme.accentTint.color, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(stage.name).font(.dante(size: 12.5, weight: .semibold)).foregroundStyle(theme.text.color).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let environment = stage.environment {
                            Text(environment).font(.dante(size: 10)).foregroundStyle(theme.text3.color).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                // The steps as a row of icons, each with its title on hover.
                HStack(spacing: 4) {
                    ForEach(Array(stage.steps.prefix(8).enumerated()), id: \.offset) { _, step in
                        Image(systemName: step.kind.symbol)
                            .font(.dante(size: 9.5))
                            .foregroundStyle(theme.text2.color)
                            .frame(width: 20, height: 20)
                            .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .help(step.title + (step.detail.isEmpty ? "" : "\n" + step.detail))
                    }
                    if stage.steps.count > 8 {
                        Text("+\(stage.steps.count - 8)").font(.dante(size: 10)).foregroundStyle(theme.text3.color)
                    }
                }
            }
            .padding(10)
            .frame(width: 196, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(state == .selected ? theme.accentTint.color : theme.card.color))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(state == .selected ? theme.accent.color : (hovering || state == .related ? theme.accentLine.color : theme.line2.color), lineWidth: state == .selected ? 1.6 : 1))
            .shadow(color: theme.accent.color.opacity(state == .selected ? 0.25 : 0), radius: 10)
            .opacity(state == .dimmed ? 0.4 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct UsersNode: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "person.2.fill")
                .font(.dante(size: 16))
                .foregroundStyle(theme.text2.color)
                .frame(width: 46, height: 46)
                .background(theme.card.color, in: Circle())
                .overlay(Circle().strokeBorder(theme.line2.color))
            Text("Users").font(.dante(size: 11, weight: .medium)).foregroundStyle(theme.text2.color)
        }
    }
}

private struct ResourceNode: View {
    @Environment(\.theme) private var theme

    let resource: Infrastructure.Resource
    let hue: Color
    let state: InfraCanvas.NodeState
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: resource.symbol)
                    .font(.dante(size: 14, weight: .medium))
                    .foregroundStyle(hue)
                    .frame(width: 34, height: 34)
                    .background(LinearGradient(colors: [hue.opacity(0.22), hue.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(hue.opacity(0.35)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(Breakable.camel(resource.name)).font(.dante(size: 12, weight: .semibold)).foregroundStyle(theme.text.color).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(resource.service).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                    if !resource.stack.isEmpty {
                        Text(resource.stack).font(.dante(size: 9.5, design: .monospaced)).foregroundStyle(theme.text3.color.opacity(0.85)).lineLimit(1).truncationMode(.middle)
                    } else if resource.isOutside {
                        Text("outside the templates").font(.dante(size: 9.5)).foregroundStyle(theme.text3.color.opacity(0.85))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(width: InfraCanvas.nodeWidth, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(state == .selected ? theme.accentTint.color : theme.card.color))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(state == .selected ? theme.accent.color : (hovering || state == .related ? hue.opacity(0.7) : theme.line2.color),
                              style: StrokeStyle(lineWidth: state == .selected ? 1.6 : 1, dash: resource.isOutside ? [4, 3] : [])))
            .shadow(color: hue.opacity(state == .selected || hovering ? 0.22 : 0), radius: 8)
            .opacity(state == .dimmed ? 0.38 : 1)
            .scaleEffect(hovering ? 1.02 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.16), value: hovering)
        .help("\(resource.type)\n\(resource.file)")
    }
}

// MARK: Inspector

struct InfraInspector: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let infra: Infrastructure
    let id: String
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Eyebrow(resource.map { $0.tier.title } ?? "Pipeline stage")
                    Spacer()
                    IconButton(symbol: "xmark", label: "Close", size: 10, action: close)
                }
                if let resource { resourceBody(resource) } else if let (pipeline, stage) = stage { stageBody(pipeline, stage) }
            }
            .padding(20)
        }
        .background(theme.panel.color)
    }

    private var resource: Infrastructure.Resource? { infra.resource(id) }

    private var stage: (Infrastructure.Pipeline, Infrastructure.Stage)? {
        for pipeline in infra.pipelines {
            if let stage = pipeline.stages.first(where: { pipeline.id + "#" + $0.id == id }) { return (pipeline, stage) }
        }
        return nil
    }

    @ViewBuilder private func resourceBody(_ resource: Infrastructure.Resource) -> some View {
        let hue = resource.tier.hue(theme)
        HStack(spacing: 10) {
            Image(systemName: resource.symbol).font(.dante(size: 16)).foregroundStyle(hue)
                .frame(width: 38, height: 38).background(hue.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(resource.name).font(.dante(size: 17, weight: .semibold)).foregroundStyle(theme.text.color)
                Text(resource.service).font(.dante(size: 12)).foregroundStyle(theme.text3.color)
            }
        }
        VStack(alignment: .leading, spacing: 0) {
            row("Type", resource.isOutside ? "Not in the templates: the pipeline reaches it" : resource.type, mono: !resource.isOutside)
            if !resource.stack.isEmpty, let stack = infra.stacks.first(where: { $0.id == resource.stack }) {
                row("Stack", "\(stack.name) · \(stack.tool)" + (stack.environments.isEmpty ? "" : " · " + stack.environments.joined(separator: ", ")))
            }
            let out = infra.links.filter { $0.from == resource.id }.compactMap { link in infra.resource(link.to).map { "\(link.label) \($0.name)" } }
            let into = infra.links.filter { $0.to == resource.id }.compactMap { link in infra.resource(link.from).map { "\($0.name) \(link.label) it" } }
            if !out.isEmpty { row("Uses", out.joined(separator: "\n")) }
            if !into.isEmpty { row("Used by", into.joined(separator: "\n")) }
            let deployedBy = infra.deploys.filter { $0.to == resource.id }.compactMap { link in stageName(link.from).map { "\($0) \(link.label)" } }
            if !deployedBy.isEmpty { row("Changed by", deployedBy.joined(separator: "\n")) }
        }
        if !resource.isOutside {
            Button { session.open(file: workspace.url.appending(path: resource.file), line: resource.line ?? 1) } label: {
                Label("Open \((resource.file as NSString).lastPathComponent)", systemImage: "doc.text").frame(maxWidth: .infinity)
            }
            .buttonStyle(DanteButtonStyle())
        }
        Button {
            session.askClaude("Explain \(resource.name) (\(resource.type)) in \(resource.file)\(resource.line.map { ":\($0)" } ?? ""): what it's for, how it's configured per environment, what it connects to, and anything risky about it. Don't print secret values.")
        } label: {
            ClaudeLabel("Ask \(session.agentName) about it").frame(maxWidth: .infinity)
        }
        .buttonStyle(DanteButtonStyle(primary: true))
    }

    @ViewBuilder private func stageBody(_ pipeline: Infrastructure.Pipeline, _ stage: Infrastructure.Stage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(stage.name).font(.dante(size: 17, weight: .semibold)).foregroundStyle(theme.text.color)
            Text("\(pipeline.name) · \(pipeline.system)").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
        }
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow("Steps")
            ForEach(Array(stage.steps.enumerated()), id: \.offset) { _, step in
                Button {
                    session.open(file: workspace.url.appending(path: pipeline.file), line: step.line ?? stage.line ?? 1)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: step.kind.symbol).font(.dante(size: 10)).foregroundStyle(theme.accent.color)
                            .frame(width: 20, height: 20).background(theme.accentTint.color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title).font(.dante(size: 12, weight: .medium)).foregroundStyle(theme.text.color)
                            if !step.detail.isEmpty {
                                Text(step.detail).font(.dante(size: 10.5, design: .monospaced)).foregroundStyle(theme.text3.color).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        VStack(alignment: .leading, spacing: 0) {
            if !stage.jobs.isEmpty { row("Jobs", stage.jobs.joined(separator: ", ")) }
            if let environment = stage.environment { row("Environment", environment) }
            if !stage.dependsOn.isEmpty { row("After", stage.dependsOn.compactMap { dep in pipeline.stages.first { $0.id == dep }?.name }.joined(separator: ", ")) }
            let changes = infra.deploys.filter { $0.from == id }.compactMap { link in infra.resource(link.to).map { "\(link.label): \($0.name)" } }
            if !changes.isEmpty { row("Changes", changes.joined(separator: "\n")) }
        }
        Button {
            session.askClaude("Walk me through the \(stage.name) stage of \(pipeline.file): each step, what it needs (service connections, variables, secrets by name only), what it changes, and how it fails or rolls back.")
        } label: {
            ClaudeLabel("Ask \(session.agentName) about it").frame(maxWidth: .infinity)
        }
        .buttonStyle(DanteButtonStyle(primary: true))
    }

    private func stageName(_ id: String) -> String? {
        for pipeline in infra.pipelines {
            if let stage = pipeline.stages.first(where: { pipeline.id + "#" + $0.id == id }) { return "\(stage.name) (\(pipeline.name))" }
        }
        return nil
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Rectangle().fill(theme.line.color).frame(height: 1)
            Text(label).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).padding(.top, 6)
            Text(value)
                .font(.dante(size: 12.5, design: mono ? .monospaced : .default))
                .foregroundStyle(theme.text.color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.bottom, 8)
        }
    }
}
