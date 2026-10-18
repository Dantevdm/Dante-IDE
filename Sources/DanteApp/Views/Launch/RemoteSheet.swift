import DanteKit
import SwiftUI

/// Open Remote…: a folder on another machine, reached with ssh.
struct RemoteSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let session: Session

    @State private var host = ""
    @State private var path = ""
    @State private var opening = RemoteOpening()
    @State private var configHosts: [String] = []
    private let known = RemoteRegistry.known()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Open a remote project")
                    .font(.dante(size: 17, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Host").font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                HStack(spacing: 6) {
                    TextField("devbox, or user@server.example.com", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .font(.dante(size: 13, design: .monospaced))
                    if !configHosts.isEmpty {
                        Menu {
                            Section("From ~/.ssh/config") {
                                ForEach(configHosts, id: \.self) { alias in Button(alias) { host = alias } }
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Hosts from ~/.ssh/config")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Folder on the host").font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                TextField("~/code/shop", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .font(.dante(size: 13, design: .monospaced))
                    .onSubmit(open)
            }

            if !known.isEmpty, !opening.isBusy {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Opened before").font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                    ForEach(known.prefix(4), id: \.mirror) { project in
                        Button {
                            host = project.host
                            path = project.path
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "network").foregroundStyle(theme.text3.color)
                                Text(project.label).foregroundStyle(theme.text.color).lineLimit(1).truncationMode(.middle)
                            }
                            .font(.dante(size: 12, design: .monospaced))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            switch opening.step {
            case .connecting, .copying:
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView().progressViewStyle(.linear).tint(theme.accent.color)
                    Text(opening.step == .connecting ? "Connecting to \(host)…" : "Copying the project from \(host)…")
                        .font(.dante(size: 12))
                        .foregroundStyle(theme.text.color)
                }
            case .failed(let message):
                Text(message)
                    .font(.dante(size: 12))
                    .foregroundStyle(theme.red.color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                Text("Uses your ssh keys or agent; the host needs rsync.")
                    .font(.dante(size: 11.5))
                    .foregroundStyle(theme.text3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(DanteButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Open", action: open)
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(opening.isBusy || host.trimmingCharacters(in: .whitespaces).isEmpty || path.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(theme.card.color)
        .task { configHosts = SSHConfig.hosts() }
    }

    private func open() {
        guard !opening.isBusy else { return }
        Task { await opening.open(host: host, path: path, in: session) }
    }
}
