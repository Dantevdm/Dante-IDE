import SwiftUI

/// One of the Mac's places for a project (Home, Tests, Security, Ship, Activity), drawn here
/// from the numbers and rows the Mac writes. Kept while the app runs, so going back is instant,
/// and asked for again on opening, every minute and on pull-to-refresh.
struct PlaceView: View {
    let connection: CompanionConnection
    let project: String
    let kind: CompanionPlace.Kind
    var open: (CompanionPlace.Kind) -> Void = { _ in }
    @State private var place: CompanionPlace?
    @State private var problem: String?
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let place {
                    header(place)
                    if kind == .home { AgentsNow(connection: connection, project: project) }
                    if !place.tiles.isEmpty { tiles(place) }
                    if !place.pipelines.isEmpty {
                        Card(title: "Pipelines", symbol: "arrow.triangle.branch") { PipelineList(pipelines: place.pipelines, limit: kind == .home ? 3 : 12) }
                    }
                    ForEach(place.sections) { section in
                        Card(title: section.title, count: section.rows.count + section.more) {
                            if section.rows.isEmpty {
                                Text("\(section.more) more on the Mac.").font(.subheadline).foregroundStyle(Palette.text3)
                            } else {
                                PlaceRows(rows: section.rows)
                                if section.more > 0 { Text("And \(section.more) more on the Mac.").font(.footnote).foregroundStyle(Palette.text3) }
                            }
                        }
                    }
                } else if let problem {
                    ContentUnavailableView {
                        Label("Couldn’t load \(kind.title)", systemImage: "wifi.exclamationmark")
                    } description: { Text(problem) } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else {
                    ProgressView("Asking the Mac…").frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(20)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle(kind.title)
        .toolbar {
            if loading { ToolbarItem(placement: .primaryAction) { ProgressView() } }
        }
        .refreshable { await load() }
        .task(id: project + kind.rawValue) {
            place = PlaceCache.shared.places[project + kind.rawValue]
            problem = nil
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        switch await connection.place(kind, project: project) {
        case .success(let fresh):
            place = fresh
            problem = nil
            PlaceCache.shared.places[project + kind.rawValue] = fresh
        case .failure(let failure):
            if place == nil { problem = failure.message }
        }
    }

    private func header(_ place: CompanionPlace) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(place.project).font(.subheadline.weight(.medium)).foregroundStyle(Palette.text3)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(color(place.status)).frame(width: 10, height: 10)
                Text(place.headline).font(.title2.weight(.semibold)).foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tiles(_ place: CompanionPlace) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            ForEach(place.tiles) { tile in
                Button { if let opens = tile.opens { open(opens) } } label: { TileView(tile: tile) }
                    .buttonStyle(.plain)
                    .disabled(tile.opens == nil)
            }
        }
    }
}

/// Places stay in memory while the app runs, so switching back shows them at once.
@MainActor
final class PlaceCache {
    static let shared = PlaceCache()
    var places: [String: CompanionPlace] = [:]
}

private struct TileView: View {
    let tile: CompanionPlace.Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tile.label).font(.subheadline.weight(.medium)).foregroundStyle(Palette.text3)
                Spacer()
                if tile.opens != nil { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.text3) }
            }
            Text(tile.value).font(.title2.weight(.semibold)).foregroundStyle(tile.status == .quiet ? Palette.text : color(tile.status))
                .lineLimit(1).minimumScaleFactor(0.6)
            if let share = tile.share {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(Palette.line)
                        RoundedRectangle(cornerRadius: 3).fill(tile.status == .quiet ? Palette.accent : color(tile.status))
                            .frame(width: geometry.size.width * min(1, max(0, share)))
                    }
                }
                .frame(height: 6)
            }
            Text(tile.detail ?? " ").font(.caption).foregroundStyle(Palette.text2).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line))
        .contentShape(Rectangle())
    }
}

/// Rows that open when tapped to show the failure, the reason or the fix.
struct PlaceRows: View {
    let rows: [CompanionPlace.Row]
    @State private var open: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().overlay(Palette.line) }
                Button {
                    guard row.expanded != nil else { return }
                    withAnimation(.snappy) { if open.contains(row.id) { open.remove(row.id) } else { open.insert(row.id) } }
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(row.status == .quiet ? Palette.text3.opacity(0.4) : color(row.status)).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).font(.body).foregroundStyle(Palette.text).multilineTextAlignment(.leading)
                                if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(Palette.text3).lineLimit(1) }
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                if let trailing = row.trailing { Text(trailing).font(.caption.weight(.medium)).foregroundStyle(Palette.text2) }
                                if let time = row.time {
                                    Text(time, format: Calendar.current.isDateInToday(time) ? .dateTime.hour().minute() : .dateTime.day().month())
                                        .font(.caption).foregroundStyle(Palette.text3)
                                }
                            }
                            if row.expanded != nil {
                                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(Palette.text3)
                                    .rotationEffect(.degrees(open.contains(row.id) ? 180 : 0))
                            }
                        }
                        if open.contains(row.id), let expanded = row.expanded {
                            Text(expanded)
                                .font(row.monospaced ? .system(.caption, design: .monospaced) : .subheadline)
                                .foregroundStyle(Palette.text2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Palette.background))
                        }
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A titled card, as on the Mac.
struct Card<Content: View>: View {
    let title: String
    var symbol: String?
    var count: Int?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let symbol { Image(systemName: symbol).foregroundStyle(Palette.accent) }
                Text(title).font(.headline).foregroundStyle(Palette.text)
                Spacer()
                if let count, count > 0 { Text("\(count)").font(.subheadline).monospacedDigit().foregroundStyle(Palette.text3) }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line))
    }
}

/// Home's live part, from the snapshot: who's working and what waits on you.
private struct AgentsNow: View {
    let connection: CompanionConnection
    let project: String

    var body: some View {
        if let live = connection.snapshot?.projects.first(where: { $0.id == project }) {
            let running = live.jobs.filter { [.starting, .working].contains($0.state) }.count
            HStack(spacing: 14) {
                Image(systemName: live.working ? "sparkles" : "moon.zzz").font(.title2)
                    .foregroundStyle(live.working ? Palette.accent : Palette.text3)
                    .symbolEffect(.pulse, isActive: live.working)
                VStack(alignment: .leading, spacing: 2) {
                    Text(live.working ? "\(live.lead) is working" : "\(live.lead) is free").font(.headline).foregroundStyle(Palette.text)
                    Text([live.approvals.isEmpty ? nil : "\(live.approvals.count) waiting on you",
                          running > 0 ? "\(running) job\(running == 1 ? "" : "s") running" : nil,
                          live.lastReply.isEmpty ? nil : String(live.lastReply.suffix(160))]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(live.approvals.isEmpty ? Palette.text2 : Palette.amber).lineLimit(2)
                }
                Spacer()
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(live.approvals.isEmpty ? Palette.line : Palette.amber.opacity(0.6)))
        }
    }
}

/// The Map: the system map or the infrastructure, drawn by the Mac.
struct MapPlace: View {
    let explorer: Explorer
    let project: String
    @State private var infrastructure = false

    var body: some View {
        let entry = infrastructure
            ? CompanionLibrary.Entry(path: CompanionPage.Special.infrastructure, title: "Infrastructure", kind: .diagram)
            : CompanionLibrary.Entry(path: CompanionPage.Special.system, title: "System map", kind: .diagram)
        PageView(explorer: explorer, project: project, entry: entry)
            .id(project + entry.path)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Map", selection: $infrastructure) {
                        Text("System").tag(false)
                        Text("Infrastructure").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 280)
                }
            }
    }
}
