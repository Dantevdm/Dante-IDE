import DanteKit
import SwiftUI

/// Docs › New › Mind map: a name, and optionally what it's about for the agent to draft from
/// the project. Saved as an XMind file in docs/mindmaps/.
struct NewMindMapSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let session: Session
    @State private var title = "Product ideas"
    @State private var about = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New mind map").font(.dante(size: 17, weight: .semibold)).foregroundStyle(theme.text.color)
            VStack(alignment: .leading, spacing: 6) {
                Text("Central topic").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                TextField("Central topic", text: $title).textFieldStyle(.roundedBorder).font(.dante(size: 13))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("What should it cover? (optional)").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                TextField("In your words, for \(session.agentName) to draft from the project: the branches you want, what to explore…",
                          text: $about, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.dante(size: 13))
                    .lineLimit(3...6)
                    .padding(.trailing, 34)
                    .overlay(alignment: .topTrailing) { DictationButton(text: $about) }
            }
            Text("Saved as \(Session.mindMapPath(for: title, existing: [])), an XMind file that opens in XMind too.")
                .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(DanteButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Create and draft") { create(drafts: true) }
                    .buttonStyle(DanteButtonStyle())
                    .disabled(name.isEmpty)
                    .help("Create it and ask \(session.agentName) to fill it in from the project")
                Button("Create") { create(drafts: false) }
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(theme.panel.color)
    }

    private var name: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func create(drafts: Bool) {
        dismiss()
        session.createMindMap(title: name, drafts: drafts, about: about)
    }
}

extension Session {
    /// `docs/mindmaps/<slug>.xmind`, numbered when taken.
    static func mindMapPath(for title: String, existing: Set<String>) -> String {
        let slug = Diagram.slug(title).isEmpty ? "mind-map" : Diagram.slug(title)
        var path = "\(MindMap.folder)/\(slug).\(MindMap.fileExtension)"
        var number = 2
        while existing.contains(path) {
            path = "\(MindMap.folder)/\(slug)-\(number).\(MindMap.fileExtension)"
            number += 1
        }
        return path
    }

    /// Writes a new map with its central topic and opens it; with `drafts` the agent fills it in.
    func createMindMap(title: String, drafts: Bool, about: String) {
        guard let workspace else { return }
        let path = Self.mindMapPath(for: title, existing: Set(workspace.files))
        let url = workspace.url.appending(path: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try MindMap(title: title).data().write(to: url, options: .withoutOverwriting)
        } catch {
            errorMessage = "Couldn’t create \(path): \(error.localizedDescription)"
            return
        }
        workspace.refreshFileIndex()
        showDoc(path)
        if drafts {
            askClaude(MindMapBrief.draft(path: path, title: title, about: about, command: Self.danteCommand ?? "dante"))
        }
    }
}
