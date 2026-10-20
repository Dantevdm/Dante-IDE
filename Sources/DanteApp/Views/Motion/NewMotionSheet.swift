import DanteKit
import SwiftUI

/// The Docs library's way in to motion: a card that moves, and the sheet that starts a piece.
struct MotionStudioCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let pieces: [DocLibrary.Doc]
    @State private var creating = false

    var body: some View {
        HStack(spacing: 18) {
            MotionOrbit()
                .frame(width: 120, height: 90)
            VStack(alignment: .leading, spacing: 6) {
                Text("Studio").font(.dante(size: 11, weight: .semibold)).tracking(1.4).textCase(.uppercase).foregroundStyle(theme.accent.color)
                Text("Make something that moves").font(.dante(size: 18, weight: .semibold)).foregroundStyle(theme.text.color)
                Text(pieces.isEmpty
                     ? "Videos, decks and explainers drawn from the real system, in the project’s brand, narrated in Dante’s voice and rendered up to 4K."
                     : "\(pieces.count) piece\(pieces.count == 1 ? "" : "s"). Videos, decks and explainers drawn from the real system, rendered up to 4K.")
                    .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                Button { creating = true } label: { Label("New piece", systemImage: "sparkles") }
                    .buttonStyle(DanteButtonStyle(primary: true))
                Button { session.writeBrandKit() } label: { Label("Brand kit", systemImage: "paintpalette") }
                    .buttonStyle(DanteButtonStyle())
                    .help("Open .dante/brand.yaml: colours, fonts, logo, motion and voice (written from the project’s own styles the first time)")
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [theme.accentTint.color, theme.card.color], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.accentLine.color))
        .sheet(isPresented: $creating) { NewMotionSheet(session: session) }
    }
}

/// A small orbit of light: points on tilted rings, nearer ones brighter, trailing as they go.
private struct MotionOrbit: View {
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let accent = theme.accent.color
                for ring in 0..<3 {
                    let radius = CGFloat(18 + ring * 13)
                    let tilt = 0.38 + Double(ring) * 0.12
                    var path = Path()
                    path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius * tilt, width: radius * 2, height: radius * 2 * tilt))
                    canvas.stroke(path, with: .color(accent.opacity(0.18)), lineWidth: 1)
                    for dot in 0..<(3 + ring) {
                        for trail in 0..<6 {
                            let angle = t * (0.9 - Double(ring) * 0.2) + Double(dot) * (2 * .pi / Double(3 + ring)) - Double(trail) * 0.06
                            let depth = (sin(angle) + 1) / 2
                            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius * tilt)
                            let size = (1.2 + 2.4 * depth) * (1 - Double(trail) * 0.14)
                            let alpha = (0.25 + 0.75 * depth) * (1 - Double(trail) / 6)
                            canvas.fill(Path(ellipseIn: CGRect(x: point.x - size, y: point.y - size, width: size * 2, height: size * 2)),
                                        with: .color(accent.opacity(alpha)))
                        }
                    }
                }
                let pulse = 6 + 2 * sin(t * 2)
                canvas.fill(Path(ellipseIn: CGRect(x: center.x - pulse, y: center.y - pulse, width: pulse * 2, height: pulse * 2)),
                            with: .radialGradient(Gradient(colors: [accent, accent.opacity(0)]), center: center, startRadius: 0, endRadius: pulse))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Starting a piece the way a studio does, in four steps: the idea, the look (live tiles for
/// every style and illustration kit), the brief (MotionQuestions, with sensible answers
/// already in), and who makes it (Claude, Codex or both, each its own version) from which data.
struct NewMotionSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let session: Session

    enum Step: Int, CaseIterable {
        case idea, look, brief, makers
        var title: String {
            switch self {
            case .idea: "Idea"
            case .look: "Look"
            case .brief: "Brief"
            case .makers: "Who makes it"
            }
        }
    }

    @State private var step = Step.idea
    @State private var ask = ""
    @State private var title = ""
    @State private var kind: MotionPiece.Kind = .video
    @State private var answers = MotionQuestions.defaults(for: .video)
    @State private var usesSystem = true
    @State private var usesInfra = false
    @State private var usesStats = true
    @State private var available: [AgentEngine] = []
    @State private var makers: Set<AgentEngine> = []
    @State private var starting = false

    private let ideas: [(String, String, MotionPiece.Kind, String)] = [
        ("Anatomy of the system", "The system coming apart into its parts, one beat each: what every part does and how a request travels through them.", .video, "60 s"),
        ("What we shipped", "A launch film for what changed recently: the new features in motion, with the numbers that matter.", .video, "45 s"),
        ("The pitch", "A deck that says what this project is, who it's for and why it's different, ending on the architecture.", .deck, "90 s"),
        ("How a change ships", "An explainer of the path from a commit to production: the pipeline stages, checks and where it runs.", .explainer, "30 s"),
    ]

    /// The brief step leaves out what the look step asks.
    private var briefSections: [MotionQuestions.Section] {
        MotionQuestions.sections.map { section in
            var section = section
            section.questions.removeAll { ["look", "kit"].contains($0.id) }
            return section
        }
    }

    private var trimmedAsk: String { ask.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.line.color)
            Group {
                switch step {
                case .idea: ideaStep
                case .look: lookStep
                case .brief: briefStep
                case .makers: makersStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider().overlay(theme.line.color)
            footer
        }
        .frame(width: 880, height: 680)
        .background(theme.panel.color)
        .task {
            available = session.motionMakers
            let lead = session.claude?.engine ?? .claude
            makers = available.contains(lead) ? [lead] : Set(available.prefix(1))
        }
    }

    // MARK: Frame

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles").foregroundStyle(theme.accent.color)
            Text("New motion piece").font(.dante(size: 16, weight: .semibold)).foregroundStyle(theme.text.color)
            Spacer()
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Button {
                        if item == .idea || !trimmedAsk.isEmpty { withAnimation(.snappy) { step = item } }
                    } label: {
                        HStack(spacing: 6) {
                            ZStack {
                                Circle().fill(item.rawValue <= step.rawValue ? theme.accent.color : theme.raised.color)
                                Text("\(item.rawValue + 1)").font(.dante(size: 10.5, weight: .semibold))
                                    .foregroundStyle(item.rawValue <= step.rawValue ? theme.onAccent.color : theme.text3.color)
                            }
                            .frame(width: 18, height: 18)
                            Text(item.title).font(.dante(size: 12, weight: item == step ? .semibold : .regular))
                                .foregroundStyle(item == step ? theme.text.color : theme.text3.color)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(item == step ? theme.raised.color : .clear, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    if item != Step.allCases.last {
                        Rectangle().fill(item.rawValue < step.rawValue ? theme.accentLine.color : theme.line.color).frame(width: 14, height: 1)
                    }
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(footnote).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(2)
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(DanteButtonStyle()).keyboardShortcut(.cancelAction)
            if step != .idea {
                Button("Back") { withAnimation(.snappy) { step = Step(rawValue: step.rawValue - 1) ?? .idea } }.buttonStyle(DanteButtonStyle())
            }
            if step == .makers {
                Button(action: make) {
                    if starting { ProgressView().controlSize(.small) } else { ClaudeLabel(makers.count > 1 ? "Make both versions" : "Make it") }
                }
                .buttonStyle(DanteButtonStyle(primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedAsk.isEmpty || makers.isEmpty || starting)
            } else {
                Button("Next") { withAnimation(.snappy) { step = Step(rawValue: step.rawValue + 1) ?? .makers } }
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedAsk.isEmpty)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    private var footnote: String {
        switch step {
        case .idea: "Say what it should show and who it's for. The next steps are optional: every question already has a sensible answer."
        case .look: lookSummary
        case .brief: "\(MotionQuestions.answered(answers)) of \(MotionQuestions.all.count) answered. These become BRIEF.md, the piece's brief."
        case .makers: makers.count > 1
            ? "Each makes its own version, one here and one in a job beside it. Compare them in the player and keep the better one."
            : "It writes a storyboard with stills\(MotionQuestions.approvesStoryboard(answers) ? " for you to approve" : ""), builds the scene, then reviews its own frames."
        }
    }

    // MARK: Steps

    private var ideaStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(ideas, id: \.0) { idea in
                    Button {
                        withAnimation(.snappy) {
                            title = idea.0; ask = idea.1; setKind(idea.2)
                            answers["length"] = .init(picked: [idea.3])
                            usesInfra = idea.1.contains("pipeline") || idea.1.contains("production")
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(idea.0).font(.dante(size: 12.5, weight: .semibold)).foregroundStyle(theme.text.color)
                            Text(idea.1).font(.dante(size: 11)).foregroundStyle(theme.text3.color).lineLimit(2).multilineTextAlignment(.leading)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(title == idea.0 ? theme.accentTint.color : theme.raised.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(title == idea.0 ? theme.accentLine.color : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("What should it show, and who is it for?").font(.dante(size: 12, weight: .medium)).foregroundStyle(theme.text2.color)
                TextEditor(text: $ask)
                    .font(.dante(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 120)
                    .background(theme.card.color, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line.color))
            }
            HStack(spacing: 14) {
                TextField("Title", text: $title).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Picker("", selection: Binding(get: { kind }, set: { setKind($0) })) {
                    ForEach(MotionPiece.Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
            }
            question(MotionQuestions.all.first { $0.id == "length" }!, compact: true)
            question(MotionQuestions.all.first { $0.id == "aspect" }!, compact: true)
        }
        .padding(22)
    }

    private var lookStep: some View {
        MotionLookGallery(styles: answers["look"]?.picked ?? [], kits: answers["kit"]?.picked ?? []) { kind, id in
            if kind == "style", let style = MotionLooks.styles.first(where: { $0.id == id }) { pickStyle(style.name) }
            if kind == "kit", let kit = MotionLooks.kits.first(where: { $0.id == id }) { pickKit(kit.name) }
        }
        .padding(.horizontal, 16).padding(.top, 12)
    }

    private var briefStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(briefSections) { section in
                    if !section.questions.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(section.title, systemImage: section.symbol)
                                .font(.dante(size: 11, weight: .semibold)).tracking(1.2).textCase(.uppercase)
                                .foregroundStyle(theme.text3.color)
                            ForEach(section.questions) { question($0, compact: false) }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.card.color, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(theme.line.color))
                    }
                }
            }
            .padding(22)
        }
    }

    private var makersStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Who makes it").font(.dante(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
            if available.isEmpty {
                Text("Motion pieces need Claude Code or Codex on this Mac: Settings › Tools shows how to install them.")
                    .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
            } else {
                HStack(spacing: 12) {
                    ForEach(available) { engine in
                        makerCard(title: engine.title, detail: engine == (session.claude?.engine ?? .claude) ? "In charge: works here, in the main checkout" : "In a job of its own, beside your work",
                                  chosen: makers == [engine]) { makers = [engine] }
                    }
                    if available.count > 1 {
                        makerCard(title: "Both", detail: "Two versions of the same brief, made at once. Keep the better one, or take the best of each.",
                                  chosen: makers.count > 1) { makers = Set(available) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Draws from").font(.dante(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
                Toggle("The system map: parts, routes, tables and how they connect", isOn: $usesSystem)
                Toggle("Infrastructure and pipelines", isOn: $usesInfra)
                Toggle("Numbers: files, languages, tests, commits", isOn: $usesStats)
            }
            .toggleStyle(.checkbox)
            .font(.dante(size: 12.5))
            VStack(alignment: .leading, spacing: 6) {
                Text("The look").font(.dante(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
                Text(lookSummary).font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
            }
            Spacer()
        }
        .padding(22)
    }

    private func makerCard(title: String, detail: String, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.dante(size: 14, weight: .semibold)).foregroundStyle(theme.text.color)
                    Spacer()
                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle").foregroundStyle(chosen ? theme.accent.color : theme.text3.color)
                }
                Text(detail).font(.dante(size: 11.5)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(chosen ? theme.accentTint.color : theme.card.color, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(chosen ? theme.accentLine.color : theme.line.color))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Questions

    @ViewBuilder
    private func question(_ question: MotionQuestions.Question, compact: Bool) -> some View {
        let answer = answers[question.id] ?? .init()
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(question.title).font(.dante(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color)
                if !compact { Text(question.help).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(1) }
            }
            if !question.options.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(question.options, id: \.self) { option in
                        let on = answer.picked.contains(option)
                        Button { toggle(option, in: question) } label: {
                            Text(option).font(.dante(size: 12))
                                .foregroundStyle(on ? theme.text.color : theme.text2.color)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(on ? theme.accentTint.color : theme.raised.color))
                                .overlay(Capsule().strokeBorder(on ? theme.accentLine.color : theme.line.color))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !compact {
                TextField(question.options.isEmpty ? "In your words" : "Or in your words", text: Binding(
                    get: { answers[question.id]?.note ?? "" },
                    set: { answers[question.id, default: .init()].note = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.dante(size: 12))
            }
        }
    }

    private func toggle(_ option: String, in question: MotionQuestions.Question) {
        var answer = answers[question.id] ?? .init()
        if answer.picked.contains(option) {
            answer.picked.removeAll { $0 == option }
        } else {
            answer.picked = question.multiple ? answer.picked + [option] : [option]
        }
        answers[question.id] = answer
    }

    // MARK: Look

    private func pickStyle(_ name: String) {
        var picked = answers["look"]?.picked ?? []
        if picked.contains(name) {
            picked.removeAll { $0 == name }
        } else {
            picked = picked.count < 2 ? picked + [name] : [picked[0], name]
            // Picking a style lifts its ban.
            answers["bans", default: .init()].picked.removeAll { $0 == name }
        }
        answers["look", default: .init()].picked = picked
    }

    private func pickKit(_ name: String) {
        var picked = answers["kit"]?.picked ?? []
        let none = MotionLooks.kits.first { $0.id == "none" }?.name
        if picked.contains(name) {
            picked.removeAll { $0 == name }
        } else {
            picked = name == none ? [name] : picked.filter { $0 != none } + [name]
        }
        answers["kit", default: .init()].picked = picked
    }

    private var lookSummary: String {
        let styles = answers["look"]?.picked ?? []
        let kits = answers["kit"]?.picked ?? []
        let style = switch styles.count {
        case 0: "No style picked: the agent proposes one in the storyboard."
        case 1: "\(styles[0])."
        default: "\(styles[0]), accented with \(styles[1].lowercased())."
        }
        return kits.isEmpty ? style : "\(style) Illustrations: \(kits.joined(separator: ", ").lowercased())."
    }

    // MARK: Make

    private func setKind(_ new: MotionPiece.Kind) {
        guard new != kind else { return }
        let before = MotionQuestions.defaults(for: kind), after = MotionQuestions.defaults(for: new)
        // Answers still at the old kind's default follow the new kind's.
        for (id, value) in after where answers[id] == nil || answers[id] == before[id] { answers[id] = value }
        for (id, value) in before where after[id] == nil && answers[id] == value { answers[id] = nil }
        kind = new
    }

    private func make() {
        starting = true
        let data = (usesSystem ? ["system"] : []) + (usesInfra ? ["infra"] : []) + (usesStats ? ["stats"] : [])
        let chosen = AgentEngine.allCases.filter(makers.contains)
        Task {
            await session.createMotion(ask: trimmedAsk, title: title.trimmingCharacters(in: .whitespaces), kind: kind,
                                       duration: MotionQuestions.length(for: answers) ?? 45, data: data, answers: answers, makers: chosen)
            dismiss()
        }
    }
}
