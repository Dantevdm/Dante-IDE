import DanteKit
import SwiftUI

/// The Plan area: lifecycle phases, what "ready" and "done" mean in each, and the task board.
struct PlanView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    @State private var isAddingTask = false

    private var lifecycle: Lifecycle { workspace.lifecycle }

    private var phase: String {
        if let selected = session.planPhase, lifecycle.phases.contains(selected) { return selected }
        return lifecycle.currentIndex.map { lifecycle.phases[$0] } ?? lifecycle.phases.first ?? "Build"
    }

    private var phaseIndex: Int { lifecycle.phases.firstIndex(of: phase) ?? 0 }

    var body: some View {
        HStack(spacing: 0) {
            PhaseList(workspace: workspace, selected: phase) { session.planPhase = $0 }
                .frame(width: 228)
            Rectangle().fill(theme.line.color).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !lifecycle.hasSpec { NoSpecBanner(session: session, workspace: workspace, phase: phase) }
                    header
                    Checklists(session: session, workspace: workspace, phase: phase)
                    ClaudeRulesCard(session: session, workspace: workspace)
                    TaskBoardView(session: session, workspace: workspace, phase: phase) { isAddingTask = true }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(workspace.phaseDocs[phase.lowercased()]?.summary.nonEmpty ?? PhaseDoc.parse(workspace.lifecycle.phaseDocTemplate(phase)).summary)
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
            session.planPhase = phase
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
                Text("Dante can work out the stack, lifecycle and phase, and Claude can fill in the summary, checklists and tasks for you to review.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text2.color)
            }
            Spacer()
            Button("Set up…") { session.offerSetup(force: true) }
                .buttonStyle(DanteButtonStyle(primary: true))
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

// MARK: Claude rules

/// "What Claude may propose here": the `claude:` rules from project.yaml.
private struct ClaudeRulesCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    var body: some View {
        let rules = workspace.claudeRules
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("What Claude may propose", systemImage: "sparkle")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.text.color)
                Spacer()
                Button(".dante/project.yaml") { session.open(file: workspace.danteFolder.appending(path: "project.yaml")) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.accent.color)
                    .disabled(!workspace.lifecycle.hasSpec)
            }
            if rules.isEmpty {
                Text("No rules yet. Add a `claude:` block to project.yaml with `propose`, `flag` and `never` lists of folders and globs. Claude is still asked before every change.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text2.color)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    column("Changes to", rules.propose.isEmpty ? ["anywhere"] : rules.propose, color: theme.green.color)
                    column("Flag first", rules.flag, color: theme.amber.color)
                    column("Never", rules.never, color: theme.red.color)
                }
                Text("You apply every change. Flagged paths are called out in the diff; never-paths are refused before you see them, reads included.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.text3.color)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line.color))
    }

    private func column(_ title: String, _ patterns: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.text2.color)
            }
            if patterns.isEmpty {
                Text("—").font(.system(size: 11.5)).foregroundStyle(theme.text3.color)
            }
            FlowChips(items: patterns)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small monospaced chips that wrap onto new lines.
private struct FlowChips: View {
    @Environment(\.theme) private var theme
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.text.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.raised.color))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(theme.line.color))
            }
        }
    }
}

/// Lays children out left to right, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
