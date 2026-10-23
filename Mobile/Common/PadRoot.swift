import SwiftUI

/// The iPad: projects, then the chosen one's library, then what's open in it. With nothing
/// open the right side is Home (talk, approvals, jobs), as on the phone.
struct PadRoot: View {
    let connection: CompanionConnection
    let voice: VoiceLoop
    let explorer: Explorer
    @State private var project: String?
    @State private var entry: CompanionLibrary.Entry?
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $project) {
                Section {
                    Button {
                        entry = nil
                    } label: {
                        Label("Home", systemImage: "house").foregroundStyle(entry == nil ? Palette.accent : Palette.text)
                    }
                }
                Section("Projects") {
                    ForEach(explorer.projects, id: \.id) { project in
                        Label(project.name, systemImage: project.isOpen ? "folder.fill" : "folder").tag(project.id)
                    }
                }
            }
            .navigationTitle(connection.pairing?.name ?? "Dante")
        } content: {
            if let project, let name = explorer.projects.first(where: { $0.id == project })?.name {
                LibraryView(explorer: explorer, project: project, name: name, selection: $entry)
            } else {
                ContentUnavailableView("Choose a project", systemImage: "folder", description: Text("Its docs, pictures and diagrams, drawn by your Mac."))
            }
        } detail: {
            if let entry, let project {
                NavigationStack { PageView(explorer: explorer, project: project, entry: entry) }.id(project + entry.path)
            } else {
                PhoneHome(connection: connection, voice: voice, explorer: explorer)
            }
        }
        .onChange(of: project) { entry = nil }
        .onChange(of: connection.snapshot?.projects.map(\.id)) {
            if project == nil { project = explorer.projects.first?.id }
        }
    }
}
