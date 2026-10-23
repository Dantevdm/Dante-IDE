import SwiftUI

/// The morning update the Mac wrote: projects, pipelines, important mail and today's meetings,
/// each with its summary and items. Shows the kept copy at once and asks the Mac for a new one.
struct TodayView: View {
    let connection: CompanionConnection
    let voice: VoiceLoop
    @State private var loading = false
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let briefing = connection.briefing {
                    header(briefing)
                    ForEach(briefing.sections) { section in
                        if !section.summary.isEmpty || !section.items.isEmpty || section.problem != nil { SectionCard(section: section) }
                    }
                } else if loading {
                    ProgressView("Your Mac is gathering it…").frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    ContentUnavailableView("No update yet", systemImage: "sun.horizon",
                                           description: Text(problem ?? "Ask for your morning update, or pull to make one."))
                }
                if let problem, connection.briefing != nil {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Palette.text3)
                }
            }
            .padding(16)
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Today")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { voice.briefing() } label: { Label("Read Aloud", systemImage: "speaker.wave.2") }
                    .disabled(connection.status != .connected && connection.briefing == nil)
            }
        }
        .refreshable { await load(fresh: true) }
        .task {
            if (connection.briefing.map { Date.now.timeIntervalSince($0.date) > 300 }) ?? true { await load(fresh: false) }
        }
    }

    private func header(_ briefing: Briefing) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(color(briefing.status)).frame(width: 10, height: 10)
                Text(briefing.greeting).font(.largeTitle.weight(.semibold)).foregroundStyle(Palette.text)
            }
            HStack(spacing: 6) {
                Text(briefing.date.formatted(date: .complete, time: .shortened))
                if loading { ProgressView().controlSize(.mini) }
            }
            .font(.subheadline).foregroundStyle(Palette.text3)
        }
    }

    private func load(fresh: Bool) async {
        loading = true
        defer { loading = false }
        switch await connection.requestBriefing(fresh: fresh) {
        case .success: problem = nil
        case .failure(let failure): problem = failure.message
        }
    }
}

struct SectionCard: View {
    let section: Briefing.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(section.kind.title, systemImage: section.kind.symbol)
                .font(.subheadline.weight(.semibold)).foregroundStyle(color(section.status))
            if !section.summary.isEmpty { Text(section.summary).font(.body).foregroundStyle(Palette.text) }
            if let problem = section.problem { Text(problem).font(.footnote).foregroundStyle(Palette.text3) }
            ForEach(section.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(color(item.status)).frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.text)
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail).font(.footnote).foregroundStyle(Palette.text2).lineLimit(3)
                        }
                    }
                    Spacer(minLength: 0)
                    if let time = item.time {
                        Text(time, style: Calendar.current.isDateInToday(time) ? .time : .date).font(.caption).foregroundStyle(Palette.text3)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line))
    }
}

func color(_ status: Briefing.Status) -> Color {
    switch status {
    case .bad: Palette.red
    case .attention: Palette.amber
    case .good: Palette.green
    case .quiet: Palette.text3
    }
}
