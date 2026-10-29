import SwiftUI

/// The iPad: the Mac's rail on the left (Home, Map, Quality, Ship, Agents and Docs; Code stays
/// on the Mac) for the chosen project, with Today and the Wall above it. The sidebar folds
/// away with its button, leaving the page full width.
struct PadRoot: View {
    let connection: CompanionConnection
    let voice: VoiceLoop
    let explorer: Explorer
    @AppStorage("padPlace") private var place: Place = .home
    @AppStorage("padProject") private var chosen = ""
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var settings = false
    @State private var wall = ProcessInfo.processInfo.environment["DANTE_WALL"] == "1"

    enum Place: String, Hashable {
        case today, home, map, tests, security, ship, talk, activity, docs
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: Binding(get: { place }, set: { if let new = $0 { place = new } })) {
                Section { projectPicker }
                Section {
                    row(.today, "Today", "sun.horizon")
                    Button { wall = true } label: { Label("Wall", systemImage: "rectangle.inset.filled").foregroundStyle(Palette.text) }
                    MacScreenRow()
                }
                Section(project?.name ?? "Project") {
                    row(.home, "Home", "house")
                    row(.map, "Map", "point.3.connected.trianglepath.dotted")
                }
                Section("Quality") {
                    row(.tests, "Tests", "checkmark.seal")
                    row(.security, "Security", "lock.shield")
                }
                Section("Ship") {
                    row(.ship, "Release", "shippingbox")
                }
                Section("Agents") {
                    row(.talk, "Talk and jobs", "bubble.left.and.text.bubble.right", badge: connection.snapshot?.waiting ?? 0)
                    row(.activity, "Activity", "sparkles")
                }
                Section {
                    row(.docs, "Docs", "book")
                }
                Section {
                    Button { settings = true } label: {
                        Label("Style and settings", systemImage: "paintpalette").foregroundStyle(Palette.text)
                    }
                    if DataSaver.shared.onMobileData {
                        Label("Mobile data · \(DataSaver.shared.usedText)", systemImage: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(Palette.amber)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .lookBackground()
            .navigationTitle(connection.pairing?.name ?? "Dante")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            Group {
                // Talk and jobs is the phone's screen, which brings its own stack.
                if place == .talk { PhoneHome(connection: connection, voice: voice, explorer: explorer) } else { NavigationStack { detail } }
            }
            .id((project?.id ?? "") + place.rawValue)
        }
        .macScreen(connection, voice: voice, active: !wall)
        .waitingPrompt(connection, active: !wall)
        .sheet(isPresented: $settings) { StyleSettings() }
        .fullScreenCover(isPresented: $wall) {
            WallView(connection: connection, voice: voice) { wall = false }
                .macScreen(connection, voice: voice)
                .waitingPrompt(connection)
        }
        .onChange(of: project?.id) { voice.focus = project?.id }
    }

    @ViewBuilder private var detail: some View {
        if place == .today {
            TodayView(connection: connection, voice: voice)
        } else if let project {
            switch place {
            case .home: PlaceView(connection: connection, project: project.id, kind: .home, open: open)
            case .tests: PlaceView(connection: connection, project: project.id, kind: .tests)
            case .security: PlaceView(connection: connection, project: project.id, kind: .security)
            case .ship: PlaceView(connection: connection, project: project.id, kind: .ship)
            case .activity: PlaceView(connection: connection, project: project.id, kind: .activity)
            case .map: MapPlace(explorer: explorer, project: project.id)
            case .docs: LibraryView(explorer: explorer, project: project.id, name: project.name)
            case .today, .talk: EmptyView()
            }
        } else {
            ContentUnavailableView("No projects on your Mac", systemImage: "folder",
                                   description: Text(connection.status == .connected ? "Open one in Dante and it shows here." : "Connecting to your Mac…"))
        }
    }

    /// The chosen project, else the first open one, else the most recent.
    private var project: (id: String, name: String, isOpen: Bool)? {
        explorer.projects.first { $0.id == chosen } ?? explorer.projects.first
    }

    private var projectPicker: some View {
        Menu {
            ForEach(explorer.projects, id: \.id) { candidate in
                Button {
                    chosen = candidate.id
                } label: {
                    Label(candidate.name, systemImage: candidate.id == project?.id ? "checkmark" : candidate.isOpen ? "folder.fill" : "folder")
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project?.name ?? "No project").font(.headline).foregroundStyle(Palette.text).lineLimit(1)
                    Text(project.map { $0.isOpen ? "Open on the Mac" : "Recent" } ?? "").font(.caption).foregroundStyle(Palette.text3)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Palette.text3)
            }
        }
    }

    private func row(_ target: Place, _ title: String, _ symbol: String, badge: Int = 0) -> some View {
        Label(title, systemImage: symbol)
            .badge(badge)
            .tag(target)
    }

    private func open(_ kind: CompanionPlace.Kind) {
        switch kind {
        case .home: place = .home
        case .tests: place = .tests
        case .security: place = .security
        case .ship: place = .ship
        case .activity: place = .activity
        }
    }
}
