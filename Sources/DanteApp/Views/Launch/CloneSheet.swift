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

            if let failure {
                Text(failure)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.red.color)
                    .textSelection(.enabled)
                    .lineLimit(6)
            }

            HStack {
                if isCloning {
                    ProgressView().controlSize(.small)
                    Text("Cloning…").font(.system(size: 12)).foregroundStyle(theme.text2.color)
                }
                Spacer()
                Button("Cancel") { dismiss() }
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

    private func clone() {
        guard !isCloning, Git.cloneFolderName(for: repository) != nil else { return }
        isCloning = true
        failure = nil
        Task {
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                let folder = try await Git.clone(repository, into: parent)
                dismiss()
                session.open(folder: folder)
            } catch {
                failure = error.localizedDescription
            }
            isCloning = false
        }
    }
}
