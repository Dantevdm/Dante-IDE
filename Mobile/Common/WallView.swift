import SwiftUI

/// The iPad on the wall: a clock, the morning update and what the agents are doing, kept on
/// screen all day. "Hey Dante" (when on) asks anything hands-free; the update refreshes every
/// fifteen minutes and dims at night.
struct WallView: View {
    let connection: CompanionConnection
    let voice: VoiceLoop
    let close: () -> Void
    @AppStorage("wallListens") private var listens = false
    @Environment(\.showsMacScreen) private var macScreen
    @State private var problem: String?

    var body: some View {
        TimelineView(.everyMinute) { context in
            GeometryReader { geometry in
                let wide = geometry.size.width > geometry.size.height && geometry.size.width > 900
                let gutter: CGFloat = wide ? 32 : 20
                VStack(alignment: .leading, spacing: 20) {
                    if wide {
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 24) {
                                clock(context.date, size: 120).arrive(0)
                                agents.arrive(1).frame(maxHeight: .infinity, alignment: .top)
                            }
                            .frame(width: geometry.size.width * 0.34)
                            cards(columns: 2).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                clock(context.date, size: 96)
                                agents
                                cards(columns: 1)
                            }
                        }
                    }
                    voiceBar
                }
                .padding(gutter)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background {
            Group { if Looks.shared.look.isPlain { WallBackdrop() } else { LookBackdrop() } }.ignoresSafeArea()
        }
            .overlay(alignment: .topTrailing) {
                Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title) }
                    .foregroundStyle(Palette.text3).padding(20)
                    .accessibilityLabel("Leave the wall")
            }
            // Dimmed between ten at night and six in the morning.
            .opacity(Self.isNight(context.date) ? 0.4 : 1)
            .animation(.easeInOut(duration: 2), value: Self.isNight(context.date))
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            Dreams.shared.wallShowing = true
            voice.setWakeWord(listens)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            Dreams.shared.wallShowing = false
            voice.setWakeWord(false)
        }
        .onChange(of: listens) { voice.setWakeWord(listens) }
        // Starts again when the connection comes up, so the first update isn't lost.
        .task(id: connection.status == .connected) {
            guard connection.status == .connected else { return }
            while !Task.isCancelled {
                if case .failure(let failure) = await connection.requestBriefing() { problem = failure.message } else { problem = nil }
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    static func isNight(_ date: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= 22 || hour < 6
    }

    /// The time, the day, and how things stand in one word and a colour.
    private func clock(_ now: Date, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(now, format: .dateTime.hour().minute())
                .font(.system(size: size, weight: .thin, design: .rounded)).monospacedDigit()
                .foregroundStyle(Palette.text)
                .lineLimit(1).minimumScaleFactor(0.5)
                .contentTransition(.numericText(countsDown: false))
                .animation(.spring(duration: 0.8), value: now)
            Text(now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.title).foregroundStyle(Palette.text2)
            if let briefing = connection.briefing {
                HStack(spacing: 10) {
                    PulseDot(color: color(briefing.status), size: 14, pulsing: briefing.status == .bad || briefing.status == .attention)
                    Text(briefing.greeting).font(.title2.weight(.semibold)).foregroundStyle(Palette.text)
                }
                .padding(.top, 8)
                Text("Updated \(briefing.date, format: .dateTime.hour().minute())").font(.subheadline).foregroundStyle(Palette.text3)
            }
            if connection.status != .connected {
                Label("Can’t reach your Mac", systemImage: "wifi.slash").font(.subheadline).foregroundStyle(Palette.amber)
            } else if let problem {
                Text(problem).font(.subheadline).foregroundStyle(Palette.text3).lineLimit(2)
            }
        }
    }

    /// The update's sections as equal cards filling the space: projects, pipelines, mail, today.
    @ViewBuilder private func cards(columns: Int) -> some View {
        if let briefing = connection.briefing {
            let shown = briefing.sections.filter { !$0.summary.isEmpty || $0.problem != nil || !$0.items.isEmpty
                || $0.kind == .pipelines && !(briefing.pipelines ?? []).isEmpty }
            if columns == 1 {
                VStack(spacing: 16) { ForEach(Array(shown.enumerated()), id: \.element.id) { card($1, pipelines: briefing.pipelines ?? []).arrive($0 + 1) } }
            } else {
                let rows = stride(from: 0, to: shown.count, by: 2).map { Array(shown[$0..<min($0 + 2, shown.count)]) }
                VStack(spacing: 16) {
                    ForEach(rows.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(Array(rows[index].enumerated()), id: \.element.id) { column, section in
                                card(section, pipelines: briefing.pipelines ?? []).frame(maxHeight: .infinity, alignment: .top).arrive(1 + index * 2 + column)
                            }
                            if rows[index].count == 1 { Color.clear.frame(maxWidth: .infinity) }
                        }
                        .frame(maxHeight: .infinity)
                    }
                }
            }
        } else {
            ContentUnavailableView("Your Mac is writing the update", systemImage: "sun.horizon")
                .frame(maxWidth: .infinity, minHeight: 240)
        }
    }

    private func card(_ section: Briefing.Section, pipelines: [Briefing.Pipeline]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(section.kind.title, systemImage: section.kind.symbol)
                .font(.title3.weight(.semibold)).foregroundStyle(color(section.status))
            if !section.summary.isEmpty {
                Text(section.summary).font(.title3).foregroundStyle(Palette.text)
                    .lineLimit(section.kind == .projects ? 5 : 3).minimumScaleFactor(0.8)
            } else if let problem = section.problem {
                Text(problem).font(.body).foregroundStyle(Palette.text2).lineLimit(3)
            }
            if section.kind == .pipelines, !pipelines.isEmpty {
                ForEach(pipelines.prefix(5)) { pipeline in WallPipeline(pipeline: pipeline) }
            } else {
                ForEach(section.items.prefix(4)) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(color(item.status)).frame(width: 8, height: 8)
                        Text(item.title).font(.body).foregroundStyle(Palette.text2).lineLimit(1)
                        Spacer(minLength: 6)
                        if let time = item.time {
                            Text(time, format: Calendar.current.isDateInToday(time) ? .dateTime.hour().minute() : .dateTime.day().month())
                                .font(.subheadline).foregroundStyle(Palette.text3)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 22).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(section.status == .bad ? Palette.red.opacity(0.4) : Palette.line))
    }

    /// What the agents are doing now, and what waits on you, a project a row.
    private var agents: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Agents", systemImage: "sparkles").font(.title3.weight(.semibold)).foregroundStyle(Palette.accent)
            let projects = connection.snapshot?.projects ?? []
            if projects.isEmpty {
                Text("No projects open on your Mac.").font(.title3).foregroundStyle(Palette.text2)
            }
            ForEach(projects, id: \.id) { project in
                let running = project.jobs.filter { [.starting, .working].contains($0.state) }.count
                HStack(alignment: .top, spacing: 12) {
                    PulseDot(color: !project.approvals.isEmpty ? Palette.amber : project.working ? Palette.accent : Palette.text3.opacity(0.5),
                             size: 12, pulsing: project.working || !project.approvals.isEmpty)
                        .padding(.top, 8)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(project.name).font(.title3.weight(.semibold)).foregroundStyle(Palette.text).lineLimit(1)
                        Text(line(project, running: running)).font(.body)
                            .foregroundStyle(project.approvals.isEmpty ? Palette.text2 : Palette.amber)
                        if project.working, !project.lastReply.isEmpty {
                            Text(project.lastReply.suffix(140)).font(.subheadline).foregroundStyle(Palette.text3).lineLimit(2)
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 22).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Palette.line))
    }

    private func line(_ project: CompanionSnapshot.Project, running: Int) -> String {
        var parts: [String] = []
        if !project.approvals.isEmpty { parts.append("\(project.approvals.count) waiting on you") }
        if project.working { parts.append("\(project.lead) is working") }
        if running > 0 { parts.append("\(running) job\(running == 1 ? "" : "s") running") }
        return parts.isEmpty ? "Quiet" : parts.joined(separator: " · ")
    }

    /// The microphone: Hey Dante on or off, what's being heard, and what Dante is saying.
    private var voiceBar: some View {
        HStack(spacing: 14) {
            Button { voice.talk() } label: {
                Image(systemName: voice.state == .listening || voice.wakeCommand != nil ? "waveform" : "mic.fill")
                    .font(.title2).frame(width: 56, height: 56)
                    .background(Circle().fill(Palette.accent)).foregroundStyle(Palette.onAccent)
            }
            .accessibilityLabel("Talk")
            Text(caption).font(.title3).foregroundStyle(Palette.text2).lineLimit(2)
            Spacer()
            if !macScreen.isOpen {
                Button { macScreen.show() } label: { Label("Mac screen", systemImage: "display") }.font(.body)
            }
            Toggle("Hey Dante", isOn: $listens).toggleStyle(.button).font(.body)
                .help("Listen for “Hey Dante” while the wall is up. Speech is recognised on this iPad; nothing is sent until you say it.")
        }
    }

    private var caption: String {
        if let command = voice.wakeCommand { return command.isEmpty ? "Listening…" : command }
        switch voice.state {
        case .listening: return voice.heard.isEmpty ? "Listening…" : voice.heard
        case .sending: return voice.heard
        case .speaking: return voice.lastSpoken
        case .idle:
            if let problem = voice.problem { return problem }
            return voice.isWaitingForWakeWord ? "Say “Hey Dante, give me my morning update”" : "Tap to talk"
        }
    }
}

/// A pipeline on the wall: its mark, name and where, and its stages.
private struct WallPipeline: View {
    let pipeline: Briefing.Pipeline

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: pipeline.isRunning ? "circle.dotted" : pipeline.status == .bad ? "xmark.circle.fill" : pipeline.status == .good ? "checkmark.circle.fill" : "minus.circle")
                .font(.body.weight(.semibold)).foregroundStyle(pipeline.isRunning ? Palette.accent : color(pipeline.status))
            VStack(alignment: .leading, spacing: 1) {
                Text(pipeline.name).font(.body.weight(.medium)).foregroundStyle(Palette.text).lineLimit(1)
                Text([pipeline.project, pipeline.branch].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(Palette.text3).lineLimit(1)
            }
            Spacer(minLength: 6)
            HStack(spacing: 3) {
                ForEach(pipeline.stages.prefix(8)) { stage in
                    RoundedRectangle(cornerRadius: 2).fill(stage.status == .quiet && !stage.active ? Palette.line : color(stage.status)).frame(width: 16, height: 6)
                }
            }
        }
    }
}

/// The wall's ground: slow light drifting behind the cards, and fireflies once the room is dark.
private struct WallBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            GeometryReader { geometry in
                let w = geometry.size.width, h = geometry.size.height
                ZStack {
                    Palette.background
                    Circle().fill(Palette.accentTint).frame(width: w * 0.7).blur(radius: 90)
                        .position(x: w * (0.25 + 0.12 * sin(t / 23)), y: h * (0.3 + 0.1 * cos(t / 29)))
                    Circle().fill(Palette.green.opacity(scheme == .dark ? 0.16 : 0.08)).frame(width: w * 0.6).blur(radius: 100)
                        .position(x: w * (0.78 + 0.1 * cos(t / 31)), y: h * (0.72 + 0.1 * sin(t / 19)))
                    if scheme == .dark { Fireflies(count: 22, brightness: 0.5) }
                }
            }
        }
    }
}
