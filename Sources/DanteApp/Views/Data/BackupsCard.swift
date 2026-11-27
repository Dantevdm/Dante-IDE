import AppKit
import DanteKit
import SwiftUI

/// SQL Server's backups for the Data overview: `.bak` files in the project and in the server's
/// container, each with Restore…, plus Restore from a file… and Back up now….
struct BackupsCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let connection: DatabaseConnection
    private var model: DataModel { session.data }

    var body: some View {
        Card("Backups") {
            VStack(alignment: .leading, spacing: 10) {
                if !model.canRestore(connection) {
                    Text("Restoring copies the backup into the server’s Docker container, and \(connection.name) isn’t in one Dante knows. Restore it on the server itself.")
                        .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                } else {
                    let found = model.backups(for: connection)
                    if found.isEmpty {
                        Text("No .bak files in the project or the container’s backup folder.")
                            .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
                    }
                    ForEach(found) { backup in row(backup) }
                    status
                    HStack(spacing: 8) {
                        Button("Restore from a file…", action: chooseFile).buttonStyle(DanteButtonStyle())
                            .help("Pick a .bak anywhere on this Mac. Dante copies it into the container and restores it.")
                        Button("Back up now…", action: backUp).buttonStyle(DanteButtonStyle())
                            .help("A copy-only backup of \(connection.database), saved where you choose. It leaves the server’s own backup chain alone.")
                            .disabled(isWorking)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .task(id: connection.id) { await model.loadContainerBackups(for: connection) }
    }

    private var isWorking: Bool {
        if case .working = model.backupStatus[connection.id] { return true }
        return false
    }

    private func row(_ backup: DatabaseBackup) -> some View {
        HStack(spacing: 10) {
            Image(systemName: backup.place.isContainer ? "shippingbox" : "archivebox")
                .font(.dante(size: 14)).foregroundStyle(theme.accent.color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(backup.name).font(.dante(size: 12.5, design: .monospaced)).foregroundStyle(theme.text.color).lineLimit(1)
                Text([backup.location, backup.bytes.map(DataFormat.bytes), backup.modified.map { $0.formatted(.relative(presentation: .named)) }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.dante(size: 11)).foregroundStyle(theme.text3.color).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Restore…") { Task { await model.prepareRestore(backup, on: connection) } }
                .buttonStyle(DanteButtonStyle())
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.backupStatus[connection.id] {
        case .working(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.dante(size: 12)).foregroundStyle(theme.text2.color)
            }
        case .done(let text, let url):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.green.color)
                Text(text).font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                LinkButton("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        case .failed(let text):
            Text(text).font(.dante(size: 12)).foregroundStyle(theme.red.color).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case nil:
            EmptyView()
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "bak") ?? .data]
        panel.message = "Choose a SQL Server backup to restore into \(connection.name)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.prepareRestore(DatabaseBackup(place: .file(url)), on: connection) }
    }

    private func backUp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where the backup of \(connection.database) goes."
        if let root = model.root {
            let beside = model.backups(for: connection).compactMap { backup -> URL? in
                if case .project(let path) = backup.place { return root.appending(path: path).deletingLastPathComponent() }
                return nil
            }.first
            panel.directoryURL = beside ?? root
        }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await model.backUp(connection, to: folder) }
    }
}

extension DatabaseBackup.Place {
    var isContainer: Bool { if case .container = self { true } else { false } }
}

/// Restoring a backup: what it holds, the database it becomes (warning when that replaces
/// one), whether `sa` takes it over, then the restore itself.
struct RestoreSheet: View {
    @Environment(\.theme) private var theme
    let session: Session
    private var model: DataModel { session.data }

    var body: some View {
        if let draft = model.restoring {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").font(.dante(size: 16)).foregroundStyle(theme.accent.color)
                    Text("Restore \(draft.backup.name)").font(.dante(size: 16, weight: .semibold)).foregroundStyle(theme.text.color).lineLimit(1)
                }
                content(draft)
                HStack {
                    Spacer()
                    switch draft.stage {
                    case .done, .failed:
                        Button("Close") { model.restoring = nil }.buttonStyle(DanteButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    default:
                        Button("Cancel") { model.restoring = nil }.buttonStyle(DanteButtonStyle()).keyboardShortcut(.cancelAction)
                            .disabled(draft.stage == .restoring)
                        Button(draft.replaces ? "Replace \(draft.database)" : "Restore") { Task { await model.restore() } }
                            .buttonStyle(DanteButtonStyle(primary: true))
                            .disabled(draft.stage != .ready || draft.database.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .padding(22)
            .frame(width: 520)
            .background(theme.panel.color)
        }
    }

    @ViewBuilder
    private func content(_ draft: DataModel.RestoreDraft) -> some View {
        switch draft.stage {
        case .reading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(draft.backup.place.isContainer ? "Reading the backup…" : "Copying it into the container and reading it…")
                    .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
            }
        case .failed(let message):
            Text(message).font(.dante(size: 12.5)).foregroundStyle(theme.red.color).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case .done(let message):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.green.color)
                Text(message).font(.dante(size: 12.5)).foregroundStyle(theme.text.color)
            }
        case .ready, .restoring:
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    fact("Holds", draft.header.database.map { "The \($0) database" } ?? "A database")
                    if let server = draft.header.server { fact("From", server) }
                    if let finished = draft.header.finished { fact("Taken", finished) }
                    if let version = draft.header.version { fact("Made by", version) }
                    fact("Files", draft.files.map { "\($0.logicalName) (\($0.type == "L" ? "log" : "data"))" }.joined(separator: ", "))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Restore as").font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                    TextField("Database", text: Binding(get: { model.restoring?.database ?? "" }, set: { model.restoring?.database = $0 }))
                        .textFieldStyle(.roundedBorder).font(.dante(size: 12.5, design: .monospaced))
                        .disabled(draft.stage == .restoring)
                }
                Toggle(isOn: Binding(get: { model.restoring?.makeSaOwner ?? true }, set: { model.restoring?.makeSaOwner = $0 })) {
                    Text("Make sa the owner").font(.dante(size: 12.5)).foregroundStyle(theme.text.color)
                }
                .toggleStyle(.checkbox)
                .help("A backup from another server keeps that server’s owner, which this one doesn’t know: Service Broker and query notifications stop working until sa owns it.")
                if draft.replaces {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.amber.color)
                        Text("\(draft.connection.name) already has \(draft.database). Restoring replaces it and everything in it, and puts out anything connected to it, your app included. It can’t be undone.")
                            .font(.dante(size: 12)).foregroundStyle(theme.text.color).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.amber.color.opacity(0.1)))
                }
                if draft.stage == .restoring {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Restoring \(draft.database)…").font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
                    }
                }
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.dante(size: 12)).foregroundStyle(theme.text3.color).frame(width: 70, alignment: .leading)
            Text(value).font(.dante(size: 12.5)).foregroundStyle(theme.text.color).textSelection(.enabled).lineLimit(2)
        }
    }
}
