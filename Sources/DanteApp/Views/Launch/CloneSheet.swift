import AppKit
import DanteKit
import SwiftUI

struct CloneSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let session: Session

    @State private var repository = ""
    @State private var parent = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Developer")
    @State private var isCloning = false
    @State private var failure: String?
    @State private var progress: Git.CloneProgress?
    @State private var handle: Git.CloneHandle?
    /// git needed a password or key it couldn't ask for; the clone can finish in Terminal.
    @State private var needsCredentials = false
    @State private var waitingOnTerminal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Clone a repository")
                .font(.system(size: 17, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Repository URL").font(.system(size: 12)).foregroundStyle(theme.text2.color)
                TextField("https://github.com/owner/repo.git", text: $repository)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit(clone)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Clone into").font(.system(size: 12)).foregroundStyle(theme.text2.color)
                HStack {
                    Text(destinationDescription)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(theme.text.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…", action: chooseParent).buttonStyle(DanteButtonStyle())
                }
            }

            if isCloning {
                VStack(alignment: .leading, spacing: 6) {
                    if let fraction = progress?.overall {
                        ProgressView(value: fraction).tint(theme.accent.color)
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(theme.accent.color)
                    }
                    HStack(spacing: 6) {
                        Text(progress?.phase ?? "Connecting to \(host)…")
                            .foregroundStyle(theme.text.color)
                        if let detail = progress?.detail, !detail.isEmpty {
                            Text(detail).foregroundStyle(theme.text3.color).lineLimit(1).truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                        if let fraction = progress?.fraction {
                            Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(theme.text2.color)
                        }
                    }
                    .font(.system(size: 12))
                }
            }

            if needsCredentials {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(host) wants you to sign in", systemImage: "key")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.amber.color)
                    Text(waitingOnTerminal
                         ? "Finish the clone in Terminal: git will ask for your password or app password there. Dante opens the project as soon as it’s done."
                         : "git needs a password, app password or SSH key it can’t ask for from here. Clone in Terminal, where it can ask you, and Dante opens the project when it’s done. Saving the password in your keychain or using an SSH URL avoids this next time.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.text2.color)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if waitingOnTerminal {
                            ProgressView().controlSize(.small)
                            Text("Waiting for Terminal…").font(.system(size: 12)).foregroundStyle(theme.text2.color)
                        } else {
                            Button("Clone in Terminal", action: cloneInTerminal).buttonStyle(DanteButtonStyle(primary: true))
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 9).fill(theme.amber.opacity(0.1).color))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.amber.opacity(0.4).color))
            } else if let failure {
                Text(failure)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.red.color)
                    .textSelection(.enabled)
                    .lineLimit(6)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    handle?.cancel()
                    dismiss()
                }
                    .buttonStyle(DanteButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Clone", action: clone)
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCloning || Git.cloneFolderName(for: repository) == nil)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onDisappear { waitingOnTerminal = false }
        .background(theme.card.color)
    }

    private var destinationDescription: String {
        let name = Git.cloneFolderName(for: repository) ?? "…"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = parent.appending(path: name).path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { parent = url }
    }

    private var host: String {
        let trimmed = repository.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: trimmed), let host = url.host() { return host }
        // scp-style: git@host:owner/repo.git
        return trimmed.split(separator: "@").last?.split(separator: ":").first.map(String.init) ?? "The server"
    }

    private var destination: URL? {
        Git.cloneFolderName(for: repository).map { parent.appending(path: $0) }
    }

    private func clone() {
        guard !isCloning, Git.cloneFolderName(for: repository) != nil else { return }
        isCloning = true
        failure = nil
        needsCredentials = false
        progress = nil
        let handle = Git.CloneHandle()
        self.handle = handle
        Task {
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                let folder = try await Git.clone(repository, into: parent, handle: handle) { progress = $0 }
                dismiss()
                session.open(folder: folder)
            } catch is CancellationError {
            } catch {
                let message = error.localizedDescription
                if Git.needsCredentials(message) { needsCredentials = true } else { failure = message }
            }
            isCloning = false
        }
    }

    /// Runs the clone in Terminal, where git can prompt, then opens the folder once the
    /// clone has finished (git removes its lock and writes HEAD's files last).
    private func cloneInTerminal() {
        guard let destination else { return }
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let marker = destination.appending(path: ".git/dante-clone-done")
        let script = """
        #!/bin/zsh
        cd \(quoted(parent.path)) && git clone --progress \(quoted(repository.trimmingCharacters(in: .whitespaces))) \(quoted(destination.lastPathComponent)) && touch \(quoted(marker.path)) && echo && echo "Cloned. Dante is opening it; you can close this window."
        """
        let file = FileManager.default.temporaryDirectory.appending(path: "Dante clone \(destination.lastPathComponent).command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            failure = error.localizedDescription
            return
        }
        NSWorkspace.shared.open(file)
        waitingOnTerminal = true
        Task {
            while waitingOnTerminal {
                try? await Task.sleep(for: .seconds(1))
                if FileManager.default.fileExists(atPath: marker.path) {
                    try? FileManager.default.removeItem(at: marker)
                    try? FileManager.default.removeItem(at: file)
                    waitingOnTerminal = false
                    dismiss()
                    session.open(folder: destination)
                }
            }
        }
    }
}
