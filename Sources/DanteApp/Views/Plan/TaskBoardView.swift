import DanteKit
import SwiftUI

/// The phase's tasks in four columns. Drag a card between columns to change its state.
struct TaskBoardView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let phase: String
    let addTask: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Tasks").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text.color)
                Text("Phase: \(phase)").font(.system(size: 12)).foregroundStyle(theme.text3.color)
                Spacer()
                Button(".dante/tasks.yaml") { session.open(file: workspace.tasks.url) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.accent.color)
                    .disabled(!FileManager.default.fileExists(atPath: workspace.tasks.url.path))
            }

            if let error = workspace.tasks.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.red.color)
            }

            HStack(alignment: .top, spacing: 12) {
                ForEach(TaskState.allCases) { state in
                    TaskColumn(session: session, workspace: workspace, phase: phase, state: state, addTask: addTask)
                }
            }
        }
    }
}

private struct TaskColumn: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let phase: String
    let state: TaskState
    let addTask: () -> Void
    @State private var isTargeted = false

    var body: some View {
        let tasks = workspace.tasks.tasks(in: phase, state: state)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(state.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text2.color)
                Text("\(tasks.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color)
                Spacer()
            }
            .padding(.horizontal, 4)

            ForEach(tasks) { task in
                TaskCard(session: session, workspace: workspace, task: task)
                    .draggable(task.id)
            }

            if tasks.isEmpty {
                if state == .ready, workspace.tasks.loadError == nil {
                    Button(action: addTask) {
                        Label("New task", systemImage: "plus")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.text3.color)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(theme.line2.color, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(height: 56)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isTargeted ? theme.accentTint.color : theme.panel.color)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isTargeted ? theme.accentLine.color : theme.line.color)
        )
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            do {
                try workspace.tasks.move(id, to: state)
                return true
            } catch {
                session.errorMessage = "Couldn’t update tasks.yaml: \(error.localizedDescription)"
                return false
            }
        } isTargeted: { isTargeted = $0 }
    }
}

private struct TaskCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let task: PlanTask
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(task.id).font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(theme.text3.color)
                if task.claude == true {
                    Label("with Claude", systemImage: "sparkle")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.accent.color)
                }
                Spacer(minLength: 0)
            }
            Text(MarkdownText.attributed(task.title, theme: theme))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(task.state == .done ? theme.text2.color : theme.text.color)
                .fixedSize(horizontal: false, vertical: true)
            if let spec = task.spec {
                Label(spec, systemImage: "doc.text")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.text3.color)
                    .lineLimit(1)
            }
            if let note = task.note {
                Text(note).font(.system(size: 11)).foregroundStyle(theme.text3.color).lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(hovering ? theme.line2.color : theme.line.color))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menu }
    }

    @ViewBuilder
    private var menu: some View {
        if session.claude != nil {
            Button("Work on This with Claude") { workOnWithClaude() }
            Divider()
        }
        Menu("Move To") {
            ForEach(TaskState.allCases.filter { $0 != task.state }) { state in
                Button(state.title) { attempt { try workspace.tasks.move(task.id, to: state) } }
            }
        }
        if let spec = task.spec {
            Button("Open Spec") { session.open(file: workspace.danteFolder.appending(path: spec)) }
        }
        Divider()
        Button("Delete Task", role: .destructive) { attempt { try workspace.tasks.delete(task.id) } }
    }

    private func workOnWithClaude() {
        attempt {
            try workspace.tasks.setWorkingWithClaude(task.id, true)
            if task.state == .ready { try workspace.tasks.move(task.id, to: .inProgress) }
        }
        var message = "Let's work on \(task.id): \(task.title)."
        if let spec = task.spec { message += " The spec is .dante/\(spec); read it first." }
        if let note = task.note { message += " Note: \(note)" }
        message += " Propose a short plan before changing any files."
        session.area = .code
        session.askClaude(message)
    }

    private func attempt(_ action: () throws -> Void) {
        do { try action() } catch { session.errorMessage = "Couldn’t update tasks.yaml: \(error.localizedDescription)" }
    }
}

struct NewTaskSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let session: Session
    let workspace: Workspace
    @State private var title = ""
    @State private var phase: String
    @State private var state: TaskState = .ready
    @State private var spec = ""

    init(session: Session, workspace: Workspace, phase: String) {
        self.session = session
        self.workspace = workspace
        _phase = State(initialValue: phase)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New task").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text.color)
            Form {
                TextField("Title", text: $title, prompt: Text("What needs doing?"))
                Picker("Phase", selection: $phase) {
                    ForEach(workspace.lifecycle.phases, id: \.self) { Text($0).tag($0) }
                }
                Picker("State", selection: $state) {
                    ForEach(TaskState.allCases) { Text($0.title).tag($0) }
                }
                TextField("Spec", text: $spec, prompt: Text("specs/feature.md (optional)"))
            }
            .formStyle(.columns)
            Text("Saved to .dante/tasks.yaml as \(workspace.tasks.nextID).")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.text3.color)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(DanteButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Add task") { add() }
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(theme.card.color)
    }

    private func add() {
        do {
            try workspace.tasks.add(title: title.trimmingCharacters(in: .whitespaces), phase: phase, state: state, spec: spec)
            dismiss()
        } catch {
            session.errorMessage = "Couldn’t save the task: \(error.localizedDescription)"
        }
    }
}
