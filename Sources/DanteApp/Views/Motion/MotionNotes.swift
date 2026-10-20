import DanteKit
import SwiftUI

/// Under a motion piece: what Dante's lint finds in the scene (each opens its line), and a
/// critique by the other agent, its notes at their moments, to send back to the maker.
struct MotionNotes: View {
    @Environment(\.theme) private var theme
    let session: Session
    let player: MotionPlayer
    /// The version on show, when there are several.
    let version: MotionVersion?
    let folderPath: String
    @State private var chosen: Set<String> = []

    private var folder: URL? { player.source?.folder }
    private var maker: String { version?.maker ?? player.source?.piece.maker ?? "" }
    private var state: MotionCritiqueState? { folder.flatMap { session.motionCritiques[$0] } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                lint
                critique
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.panel.color)
    }

    // MARK: Lint

    private var lint: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Eyebrow("Lint")
                Spacer()
                if !player.lint.isEmpty {
                    Button {
                        session.changeMotion(folder: folderPath, ask: "Dante's lint found these in the scene; fix them:\n" + player.lint.map { "- " + $0.message }.joined(separator: "\n"),
                                             at: nil, version: version)
                    } label: {
                        ClaudeLabel("Ask \(fixer) to fix \(player.lint.count == 1 ? "it" : "them")")
                    }
                    .buttonStyle(DanteButtonStyle())
                }
            }
            if player.lint.isEmpty {
                Label("Nothing found: no timers, wall-clock time, CSS animation, network loads or colours outside the brand.", systemImage: "checkmark.circle")
                    .font(.dante(size: 12)).foregroundStyle(theme.text2.color)
            }
            ForEach(player.lint, id: \.self) { finding in
                Button {
                    if let folder = player.source?.folder { session.open(file: folder.appending(path: finding.file), line: max(1, finding.line)) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: finding.breaksRender ? "exclamationmark.triangle.fill" : "paintpalette")
                            .foregroundStyle(finding.breaksRender ? theme.amber.color : theme.text3.color)
                        Text(finding.message).font(.dante(size: 12)).foregroundStyle(theme.text.color).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(finding.breaksRender ? "Breaks frame-accurate renders: open the line" : "Taste: open the line")
            }
        }
    }

    // MARK: Critique

    private var critic: AgentEngine? { session.motionCritic(for: version ?? player.source.map { MotionVersion(folder: $0.folder, root: $0.projectRoot, maker: $0.piece.maker, job: nil, jobTitle: nil) }) }
    /// Who makes the changes: the version's maker, else whoever is in charge.
    private var fixer: String { version?.job != nil ? maker : session.agentName }

    @ViewBuilder
    private var critique: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow("Critique")
                Spacer()
                if let critic, state?.isRunning != true, let source = player.source {
                    Button {
                        Task { await session.critiqueMotion(source: source, maker: maker) }
                    } label: {
                        Label(state == nil ? "Ask \(critic.title) for a critique" : "Again", systemImage: "eye")
                    }
                    .buttonStyle(DanteButtonStyle())
                    .help("\(critic.title) looks at stills of every beat and reads the scene, as a motion designer who didn’t make it. Read-only: it changes nothing.")
                }
            }
            switch state {
            case nil:
                Text(critic == nil ? "A critique needs Claude Code or Codex on this Mac."
                     : "\(critic!.title) looks at a contact sheet of the beats and the scene, and says what to fix, what to polish and what to keep.")
                    .font(.dante(size: 12)).foregroundStyle(theme.text3.color)
            case .running(let name, let since):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text("\(name) is looking at the frames… \(Int(context.date.timeIntervalSince(since)))s")
                            .font(.dante(size: 12)).foregroundStyle(theme.text2.color).monospacedDigit()
                    }
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").font(.dante(size: 12)).foregroundStyle(theme.amber.color)
            case .done(let critique):
                done(critique)
            }
        }
    }

    private func done(_ critique: MotionCritique.Critique) -> some View {
        let actionable = critique.notes.filter { $0.kind != .good }
        return VStack(alignment: .leading, spacing: 8) {
            if let summary = critique.summary {
                Text(summary).font(.dante(size: 12.5)).foregroundStyle(theme.text.color).textSelection(.enabled)
            }
            ForEach(critique.notes) { note in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if note.kind != .good {
                        Toggle("", isOn: Binding(get: { !chosen.contains(note.id) }, set: { keep in if keep { chosen.remove(note.id) } else { chosen.insert(note.id) } }))
                            .toggleStyle(.checkbox).labelsHidden()
                            .help("Send this note")
                    } else {
                        Image(systemName: "hand.thumbsup").foregroundStyle(theme.green.color).frame(width: 14)
                    }
                    Text(note.kind.rawValue)
                        .font(.dante(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(color(note.kind))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(color(note.kind).opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                    if let time = note.time {
                        Button(MotionCritique.clock(time)) { player.pause(); player.go(time) }
                            .buttonStyle(.plain)
                            .font(.dante(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.accent.color)
                            .help("Go to this moment")
                    }
                    Text(note.text).font(.dante(size: 12)).foregroundStyle(theme.text.color).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
            if !actionable.isEmpty {
                let sending = actionable.filter { !chosen.contains($0.id) }
                Button {
                    session.changeMotion(folder: folderPath, ask: MotionCritique.request(sending + critique.notes.filter { $0.kind == .good }, critic: critique.critic),
                                         at: nil, version: version)
                } label: {
                    ClaudeLabel("Send \(sending.count) \(sending.count == 1 ? "note" : "notes") to \(fixer)")
                }
                .buttonStyle(DanteButtonStyle(primary: true))
                .disabled(sending.isEmpty)
            }
        }
    }

    private func color(_ kind: MotionCritique.Note.Kind) -> Color {
        switch kind {
        case .fix: theme.amber.color
        case .polish: theme.accent.color
        case .good: theme.green.color
        }
    }
}
