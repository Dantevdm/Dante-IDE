import DanteKit
import SwiftUI

/// The Plan area: lifecycle phases, what "ready" and "done" mean in each, and the task board.
struct PlanView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    @State private var selectedPhase: String?
    @State private var isAddingTask = false

    private var lifecycle: Lifecycle { workspace.lifecycle }

    private var phase: String {
        if let selectedPhase, lifecycle.phases.contains(selectedPhase) { return selectedPhase }
        return lifecycle.currentIndex.map { lifecycle.phases[$0] } ?? lifecycle.phases.first ?? "Build"
    }

    private var phaseIndex: Int { lifecycle.phases.firstIndex(of: phase) ?? 0 }

    var body: some View {
        HStack(spacing: 0) {
            PhaseList(workspace: workspace, selected: phase) { selectedPhase = $0 }
                .frame(width: 228)
            Rectangle().fill(theme.line.color).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !lifecycle.hasSpec { NoSpecBanner(session: session, workspace: workspace, phase: phase) }
                    header
                    Checklists(session: session, workspace: workspace, phase: phase)
                    TaskBoardView(session: session, workspace: workspace, phase: phase) { isAddingTask = true }
                }
                .padding(28)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.ground.color)
        .sheet(isPresented: $isAddingTask) {
            NewTaskSheet(session: session, workspace: workspace, phase: phase)
                .environment(\.theme, theme)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Phase \(String(format: "%02d", phaseIndex + 1)) of \(lifecycle.phases.count)\(phaseIndex == lifecycle.currentIndex ? " · current" : "")")
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(phase).font(.system(size: 28, weight: .semibold)).foregroundStyle(theme.text.color)
                Spacer()
                Button {
                    isAddingTask = true
                } label: {
                    Label("New task", systemImage: "plus")
                }
                .buttonStyle(DanteButtonStyle())
                .disabled(workspace.tasks.loadError != nil)
                phaseButton
            }
            Text(workspace.phaseDocs[phase.lowercased()]?.summary.nonEmpty ?? PhaseDoc.parse(PhaseDoc.template(for: phase)).summary)
                .font(.system(size: 13.5))
                .foregroundStyle(theme.text2.color)
                .frame(maxWidth: 640, alignment: .leading)
        }
    }

    @ViewBuilder
    private var phaseButton: some View {
        if phaseIndex == lifecycle.currentIndex {
            if phaseIndex + 1 < lifecycle.phases.count {
                let next = lifecycle.phases[phaseIndex + 1]
                Button("Move to \(next)") { setPhase(next) }
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .help("Phases are guidance: moving on never locks anything")
            }
        } else {
            Button("Make \(phase) current") { setPhase(phase) }
                .buttonStyle(DanteButtonStyle(primary: true))
        }
    }

    private func setPhase(_ phase: String) {
        do {
            try workspace.setCurrentPhase(phase)
            selectedPhase = phase
        } catch {
            session.errorMessage = "Couldn’t update project.yaml: \(error.localizedDescription)"
        }
    }
}

// MARK: Phase list

private struct PhaseList: View {
    @Environment(\.theme) private var theme
    let workspace: Workspace
    let selected: String
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow("Lifecycle").padding(.horizontal, 10).padding(.bottom, 8)
            ForEach(Array(workspace.lifecycle.phases.enumerated()), id: \.offset) { index, phase in
                PhaseRow(index: index, phase: phase, status: status(index, phase), isSelected: phase == selected) { select(phase) }
            }
            Spacer()
            Text("Phases organise work, docs and Claude’s context. They never lock you out: work on anything, any time.")
                .font(.system(size: 11))
                .foregroundStyle(theme.text3.color)
                .padding(10)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 10)
        .background(theme.panel.color)
    }

    private func status(_ index: Int, _ phase: String) -> PhaseRow.Status {
        guard let current = workspace.lifecycle.currentIndex else { return .planned }
        if index < current { return .done }
        if index == current {
            let count = workspace.tasks.count(in: phase)
            return .current(done: count.done, total: count.total)
        }
        return .planned
    }
}

private struct PhaseRow: View {
    enum Status { case done, current(done: Int, total: Int), planned }

    @Environment(\.theme) private var theme
    let index: Int
    let phase: String
    let status: Status
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(String(format: "%02d", index + 1))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.text3.color)
                Text(phase)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent || isSelected ? theme.text.color : theme.text2.color)
                Spacer()
                statusLabel
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? theme.accentTint.color : (hovering ? theme.raised.color : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var isCurrent: Bool {
        if case .current = status { true } else { false }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .done:
            Label("Done", systemImage: "checkmark")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.green.color)
        case .current(let done, let total):
            Text(total == 0 ? "Now" : "\(done)/\(total)")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(theme.onAccent.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(theme.accent.color))
        case .planned:
            Text("Planned").font(.system(size: 10.5)).foregroundStyle(theme.text3.color)
        }
    }
}

// MARK: Banner

private struct NoSpecBanner: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let phase: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles").foregroundStyle(theme.accent.color)
            VStack(alignment: .leading, spacing: 3) {
                Text("This project has no .dante spec yet").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
                Text("Pick where you are, or let Claude draft the spec from the README, code and history for you to review.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text2.color)
            }
            Spacer()
            Button("Start at \(phase)") {
                do { try workspace.setCurrentPhase(phase) } catch { session.errorMessage = error.localizedDescription }
            }
            .buttonStyle(DanteButtonStyle())
            Button("Ask Claude to draft it") {
                session.askClaude("Set this project up for Dante: read the README, docs, code and git history, then draft .dante/project.yaml (name, summary, lifecycle.current) and a phase doc for the current phase in .dante/phases/. Propose the files for me to review.")
            }
            .buttonStyle(DanteButtonStyle(primary: true))
            .disabled(session.claude == nil)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.accentTint.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.accentLine.color))
    }
}

// MARK: Checklists

private struct Checklists: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let phase: String

    var body: some View {
        if let doc = workspace.phaseDocs[phase.lowercased()] {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Checklists · guidance, never gates").font(.system(size: 11.5)).foregroundStyle(theme.text3.color)
                    Spacer()
                    Button(".dante/phases/\(phase.lowercased()).md") { session.open(file: workspace.phaseDocURL(phase)) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(theme.accent.color)
                }
                HStack(alignment: .top, spacing: 14) {
                    ChecklistCard(title: "Ready to start when", items: doc.readyWhen, extra: nil) { toggle($0) }
                    ChecklistCard(title: "Done when", items: doc.doneWhen, extra: tasksItem) { toggle($0) }
                }
            }
        } else {
            HStack(spacing: 12) {
                Image(systemName: "checklist").foregroundStyle(theme.text3.color)
                Text("No checklist for \(phase) yet. A phase doc says what “ready” and “done” mean here, as plain markdown in .dante/phases/.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.text2.color)
                Spacer()
                Button("Add a starter checklist") {
                    do { try workspace.createPhaseDoc(phase) } catch { session.errorMessage = error.localizedDescription }
                }
                .buttonStyle(DanteButtonStyle())
                Button("Ask Claude to draft it") {
                    session.askClaude("Draft .dante/phases/\(phase.lowercased()).md for this project: a one-paragraph summary of the \(phase) phase, then \"## Ready when\" and \"## Done when\" as markdown checklists (- [ ] item), specific to this codebase.")
                }
                .buttonStyle(DanteButtonStyle(primary: true))
                .disabled(session.claude == nil)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line.color))
        }
    }

    /// "All <phase> tasks done", worked out from the board rather than ticked by hand.
    private var tasksItem: (text: String, done: Bool, detail: String?)? {
        let count = workspace.tasks.count(in: phase)
        guard count.total > 0 else { return nil }
        let open = count.total - count.done
        return ("All \(phase) tasks done", open == 0, open == 0 ? nil : "\(open) open")
    }

    private func toggle(_ item: PhaseDoc.Item) {
        do { try workspace.toggle(item, inPhase: phase) } catch { session.errorMessage = error.localizedDescription }
    }
}

private struct ChecklistCard: View {
    @Environment(\.theme) private var theme
    let title: String
    let items: [PhaseDoc.Item]
    let extra: (text: String, done: Bool, detail: String?)?
    let toggle: (PhaseDoc.Item) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(theme.text.color)
                Spacer()
                Text("\(doneCount)/\(totalCount)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(doneCount == totalCount && totalCount > 0 ? theme.green.color : theme.text3.color)
            }
            if totalCount == 0 {
                Text("Nothing listed").font(.system(size: 12)).foregroundStyle(theme.text3.color)
            }
            ForEach(items) { item in
                Button { toggle(item) } label: {
                    row(item.text, done: item.done, detail: nil)
                }
                .buttonStyle(.plain)
            }
            if let extra {
                row(extra.text, done: extra.done, detail: extra.detail)
                    .help("Worked out from the task board")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line.color))
    }

    private var doneCount: Int { items.count(where: \.done) + (extra?.done == true ? 1 : 0) }
    private var totalCount: Int { items.count + (extra == nil ? 0 : 1) }

    private func row(_ text: String, done: Bool, detail: String?) -> some View {
        HStack(spacing: 9) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(done ? theme.green.color : theme.text3.color)
            Text(MarkdownText.attributed(text, theme: theme))
                .font(.system(size: 12.5))
                .foregroundStyle(done ? theme.text2.color : theme.text.color)
                .strikethrough(done, color: theme.text3.color)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(theme.amber.color)
            }
        }
        .contentShape(Rectangle())
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
