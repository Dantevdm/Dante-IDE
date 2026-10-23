import SwiftUI

/// The iPad on the wall: a clock, the morning update and what the agents are doing, kept on
/// screen all day. "Hey Dante" (when on) asks anything hands-free; the update refreshes every
/// fifteen minutes and dims at night.
struct WallView: View {
    let connection: CompanionConnection
    let voice: VoiceLoop
    let close: () -> Void
    @AppStorage("wallListens") private var listens = false
    @State private var problem: String?

    var body: some View {
        TimelineView(.everyMinute) { context in
            GeometryReader { geometry in
                let wide = geometry.size.width > 900
                VStack(alignment: .leading, spacing: 22) {
                    top(context.date)
                    if wide {
                        HStack(alignment: .top, spacing: 18) {
                            sections.frame(maxWidth: .infinity)
                            agents.frame(width: geometry.size.width * 0.3)
                        }
                    } else {
                        sections
                        agents
                    }
                    Spacer(minLength: 0)
                    voiceBar
                }
                .padding(wide ? 40 : 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Palette.background.ignoresSafeArea())
            // Dimmed between ten at night and six in the morning.
            .opacity(Self.isNight(context.date) ? 0.4 : 1)
            .animation(.easeInOut(duration: 2), value: Self.isNight(context.date))
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            voice.setWakeWord(listens)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
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

    private func top(_ now: Date) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(now, format: .dateTime.hour().minute())
                    .font(.system(size: 88, weight: .thin, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Palette.text)
                Text(now, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.title2).foregroundStyle(Palette.text2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if let briefing = connection.briefing {
                    HStack(spacing: 8) {
                        Circle().fill(color(briefing.status)).frame(width: 12, height: 12)
                        Text(briefing.greeting).font(.title2.weight(.semibold)).foregroundStyle(Palette.text)
                    }
                    Text("Updated \(briefing.date, format: .dateTime.hour().minute())").font(.footnote).foregroundStyle(Palette.text3)
                }
                if connection.status != .connected {
                    Label("Can’t reach your Mac", systemImage: "wifi.slash").font(.footnote).foregroundStyle(Palette.amber)
                } else if let problem {
                    Text(problem).font(.footnote).foregroundStyle(Palette.text3)
                }
                Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .foregroundStyle(Palette.text3)
                    .accessibilityLabel("Leave the wall")
            }
        }
    }

    @ViewBuilder private var sections: some View {
        if let briefing = connection.briefing {
            let shown = briefing.sections.filter { !$0.summary.isEmpty || $0.problem != nil }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(shown) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(section.kind.title, systemImage: section.kind.symbol)
                            .font(.headline).foregroundStyle(color(section.status))
                        Text(section.summary.isEmpty ? (section.problem ?? "") : section.summary)
                            .font(.title3).foregroundStyle(Palette.text).lineLimit(6)
                        ForEach(section.items.prefix(3)) { item in
                            HStack(spacing: 8) {
                                Circle().fill(color(item.status)).frame(width: 6, height: 6)
                                Text(item.title).font(.subheadline).foregroundStyle(Palette.text2).lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Palette.card))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.line))
                }
            }
        } else {
            ContentUnavailableView("Your Mac is writing the update", systemImage: "sun.horizon")
                .frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    /// What the agents are doing now, and what waits on you.
    private var agents: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Agents", systemImage: "sparkles").font(.headline).foregroundStyle(Palette.accent)
            let projects = connection.snapshot?.projects ?? []
            if projects.isEmpty {
                Text("No projects open on your Mac.").font(.body).foregroundStyle(Palette.text2)
            }
            ForEach(projects, id: \.id) { project in
                let running = project.jobs.filter { [.starting, .working].contains($0.state) }.count
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.title3.weight(.medium)).foregroundStyle(Palette.text)
                    Text(line(project, running: running)).font(.subheadline)
                        .foregroundStyle(project.approvals.isEmpty ? Palette.text2 : Palette.amber)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.line))
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
