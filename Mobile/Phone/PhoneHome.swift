import SwiftUI

/// The phone's one screen: which Mac and project, the talk button and walk mode, what's waiting
/// on you, the project's jobs and its latest reply.
struct PhoneHome: View {
    let connection: CompanionConnection
    @Bindable var voice: VoiceLoop
    let explorer: Explorer
    @State private var newJob = false
    @State private var confirmsUnpair = false
    #if DEBUG
    /// Simulator testing: `DANTE_EXPLORE=library` or a page's path opens it once connected.
    @State private var debugPath: String?
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    statusBanner
                    TalkCard(voice: voice)
                    if UIDevice.current.userInterfaceIdiom != .pad, !explorer.projects.isEmpty { exploreCard }
                    if let snapshot = connection.snapshot {
                        if let project = voice.project { approvalControl(project) }
                        let waiting = snapshot.projects.flatMap { project in project.approvals.map { (project, $0) } }
                        if !waiting.isEmpty {
                            SectionTitle("Waiting on you", count: waiting.count)
                            ForEach(waiting, id: \.1.id) { project, approval in
                                ApprovalCard(approval: approval, project: project, showsProject: snapshot.projects.count > 1) { allow, answers in
                                    connection.answer(approval, project: project.id, allow: allow, answers: answers)
                                }
                            }
                        }
                        if let project = voice.project {
                            jobs(project)
                            if !project.lastReply.isEmpty { ReplyCard(project: project) }
                        } else if let recent = snapshot.recent, !recent.isEmpty {
                            RecentCard(recent: recent, server: snapshot.server) { connection.openProject($0.id) }
                        } else {
                            EmptyCard(text: "No projects are open on \(snapshot.server). Open one in Dante and it shows here.")
                        }
                    }
                }
                .padding(16)
            }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle(voice.project?.name ?? connection.pairing?.name ?? "Dante")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { projectMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Unpair This Phone…", systemImage: "link.badge.plus", role: .destructive) { confirmsUnpair = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            #if DEBUG
            .navigationDestination(item: $debugPath) { path in
                if let project = connection.snapshot?.target(focus: voice.focus) {
                    if path == "library" {
                        LibraryView(explorer: explorer, project: project.id, name: project.name)
                    } else {
                        PageView(explorer: explorer, project: project.id, entry: .debug(path))
                    }
                }
            }
            .onChange(of: connection.snapshot == nil) { _, missing in
                if !missing, debugPath == nil, let path = ProcessInfo.processInfo.environment["DANTE_EXPLORE"] { debugPath = path }
            }
            #endif
            .sheet(isPresented: $newJob) {
                if let project = voice.project {
                    NewJobSheet(project: project) { brief, away in connection.startJob(brief, project: project.id, awayMinutes: away) }
                        .presentationDetents([.medium])
                }
            }
            .confirmationDialog("Unpair from \(connection.pairing?.name ?? "the Mac")?", isPresented: $confirmsUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) {
                    voice.setWalking(false)
                    connection.unpair()
                }
            } message: {
                Text("You’ll need to scan the Mac’s code again.")
            }
        }
    }

    /// Reading the project from here: its docs, pictures and the map, drawn by the Mac.
    private var exploreCard: some View {
        let target = connection.snapshot?.target(focus: voice.focus)
        return NavigationLink {
            if let target {
                LibraryView(explorer: explorer, project: target.id, name: target.name)
            } else {
                ExploreProjects(explorer: explorer)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "books.vertical").font(.title2).foregroundStyle(Palette.accent).frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.map { "Explore \($0.name)" } ?? "Explore").font(.headline).foregroundStyle(Palette.text)
                    Text("Docs, pictures, diagrams and the system map, drawn by your Mac").font(.caption).foregroundStyle(Palette.text3)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Palette.text3)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: Palette.controlRadius).fill(Palette.card))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch connection.status {
        case .connected:
            EmptyView()
        case .connecting, .idle:
            Banner(text: "Connecting to \(connection.pairing?.name ?? "your Mac")…", symbol: "antenna.radiowaves.left.and.right", tint: Palette.text3)
        case .offline(let reason):
            Banner(text: reason, symbol: "wifi.exclamationmark", tint: Palette.amber)
        case .refused(let reason):
            VStack(alignment: .leading, spacing: 8) {
                Banner(text: reason, symbol: "lock.trianglebadge.exclamationmark", tint: Palette.red)
                Button("Pair Again") { connection.unpair() }.buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var projectMenu: some View {
        let projects = connection.snapshot?.projects ?? []
        if projects.count > 1 {
            Menu {
                Picker("Project", selection: Binding(get: { voice.project?.id ?? "" }, set: { voice.focus = $0 })) {
                    ForEach(projects) { Text($0.name).tag($0.id) }
                }
            } label: { Image(systemName: "folder") }
        }
    }

    @ViewBuilder
    private func approvalControl(_ project: CompanionSnapshot.Project) -> some View {
        if let mode = project.approvalMode {
            VStack(alignment: .leading, spacing: 8) {
                Text("Approvals").font(.headline).foregroundStyle(Palette.text)
                Picker("Approvals", selection: Binding(get: { project.approvalMode ?? .ask }, set: {
                    connection.setApprovals($0, project: project.id)
                })) {
                    ForEach(CompanionApprovalMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(connection.status != .connected)
                Text(mode == .everything
                     ? "Edits and commands go ahead in this conversation. Questions and flagged steps still wait for you."
                     : "For this project’s main conversation. Jobs keep their own approval rules.")
                    .font(.caption).foregroundStyle(Palette.text3)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: Palette.controlRadius).fill(Palette.card))
        }
    }

    @ViewBuilder
    private func jobs(_ project: CompanionSnapshot.Project) -> some View {
        HStack {
            SectionTitle("Jobs", count: project.jobs.count)
            Spacer()
            Button("New Job", systemImage: "plus") { newJob = true }.font(.subheadline.weight(.medium))
        }
        if project.jobs.isEmpty {
            EmptyCard(text: "No jobs running. A job works on its own branch on the Mac while you carry on.")
        }
        ForEach(project.jobs) { job in
            JobRow(job: job) { connection.stop(project: project.id, job: job.id) }
        }
    }
}

// MARK: Talking

private struct TalkCard: View {
    @Bindable var voice: VoiceLoop

    var body: some View {
        VStack(spacing: 14) {
            Button { voice.talk() } label: {
                ZStack {
                    Circle().fill(fill).frame(width: 112, height: 112)
                    if voice.state == .listening {
                        Circle().stroke(Palette.accent.opacity(0.35), lineWidth: 10).frame(width: 128, height: 128)
                    }
                    Image(systemName: symbol).font(.system(size: 40, weight: .semibold)).foregroundStyle(Palette.onAccent)
                        .symbolEffect(.variableColor.iterative, isActive: voice.state == .listening || voice.state == .speaking)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(voice.state == .listening ? "Send" : "Talk")
            Text(caption).font(.callout).foregroundStyle(Palette.text2).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).lineLimit(4)
            if let problem = voice.problem {
                Text(problem).font(.footnote).foregroundStyle(Palette.red).multilineTextAlignment(.center)
            }
            Divider()
            if voice.walking, !voice.audioRoute.isEmpty {
                Text("Audio: \(voice.audioRoute)").font(.caption).foregroundStyle(Palette.text3)
            }
            if voice.walking {
                Text(voice.headsetControlsReady ? "Headset controls connected" : "Headset controls not connected")
                    .font(.caption).foregroundStyle(voice.headsetControlsReady ? Palette.green : Palette.amber)
                if voice.headsetPresses > 0 {
                    Text("Button presses received: \(voice.headsetPresses)").font(.caption).foregroundStyle(Palette.text3)
                }
                Button("Reconnect controls") { voice.reconnectHeadsetControls() }
                    .font(.caption).buttonStyle(.bordered)
                Text("Control Center should show Dante. Use the play/pause button; volume buttons only change the volume.")
                    .font(.caption).foregroundStyle(Palette.text3)
            }
            Toggle(isOn: Binding(get: { voice.walking }, set: { voice.setWalking($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Walk mode").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.text)
                    Text("Use your Beats or other headset’s play/pause button to talk with the screen locked, and hear replies.")
                        .font(.caption).foregroundStyle(Palette.text3)
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.line))
    }

    private var fill: Color {
        switch voice.state {
        case .listening: Palette.red
        case .sending: Palette.amber
        default: Palette.accent
        }
    }

    private var symbol: String {
        switch voice.state {
        case .listening: "waveform"
        case .sending: "arrow.up"
        case .speaking: "speaker.wave.2.fill"
        case .idle: "mic.fill"
        }
    }

    private var caption: String {
        switch voice.state {
        case .listening: voice.heard.isEmpty ? "Listening…" : voice.heard
        case .sending: voice.heard
        case .speaking: voice.lastSpoken
        case .idle:
            voice.lastSpoken.isEmpty ? "Tap to talk, or use your headset’s play/pause button in Walk mode. Say “status”, “auto-approve”, or ask anything." : voice.lastSpoken
        }
    }
}

// MARK: Pieces

private struct SectionTitle: View {
    let title: String
    let count: Int
    init(_ title: String, count: Int) { self.title = title; self.count = count }

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.headline).foregroundStyle(Palette.text)
            if count > 0 {
                Text("\(count)").font(.caption.weight(.bold)).foregroundStyle(Palette.accent)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Palette.accentTint))
            }
            Spacer()
        }
        .padding(.top, 6)
    }
}

private struct Banner: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol).font(.subheadline).foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.4)))
    }
}

/// No project is open on the Mac: its recent ones, each opened there with a tap. Talking
/// works too: a question goes to the most recent one, which the Mac opens first.
private struct RecentCard: View {
    let recent: [CompanionSnapshot.Recent]
    let server: String
    let open: (CompanionSnapshot.Recent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing open on \(server)").font(.headline).foregroundStyle(Palette.text)
            Text("Open a recent project there, or just ask: it goes to \(recent[0].name).")
                .font(.subheadline).foregroundStyle(Palette.text3)
            ForEach(recent) { project in
                Button { open(project) } label: {
                    HStack {
                        Image(systemName: "folder").foregroundStyle(Palette.accent)
                        Text(project.name).foregroundStyle(Palette.text)
                        Spacer()
                        Text("Open").font(.subheadline.weight(.medium)).foregroundStyle(Palette.accent)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
    }
}

private struct EmptyCard: View {
    let text: String

    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(Palette.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}

private struct ApprovalCard: View {
    let approval: CompanionSnapshot.Approval
    let project: CompanionSnapshot.Project
    let showsProject: Bool
    let answer: (_ allow: Bool, _ answers: [String: String]?) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text([showsProject ? project.name : nil, approval.from].compactMap { $0 }.joined(separator: " · "))
                .font(.caption.weight(.medium)).foregroundStyle(Palette.text3)
            Text(approval.title).font(.body.weight(.semibold)).foregroundStyle(Palette.text)
            if let note = approval.note {
                Label(note, systemImage: "exclamationmark.shield.fill").font(.footnote).foregroundStyle(Palette.amber)
            }
            if !approval.detail.isEmpty {
                Text(approval.detail).font(.system(.caption, design: .monospaced)).foregroundStyle(Palette.text2)
                    .lineLimit(expanded ? nil : 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.background))
                    .onTapGesture { expanded.toggle() }
            }
            if let question = approval.questions.first {
                Text(question.question).font(.subheadline).foregroundStyle(Palette.text)
                ForEach(question.options, id: \.self) { option in
                    Button(option) { answer(true, [question.question: option]) }
                        .buttonStyle(.bordered).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Skip", role: .cancel) { answer(false, nil) }.font(.subheadline)
            } else {
                HStack {
                    Button("Decline") { answer(false, nil) }.buttonStyle(.bordered).tint(Palette.red)
                    Spacer()
                    Button("Approve") { answer(true, nil) }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.amber.opacity(0.5)))
    }
}

private struct JobRow: View {
    let job: CompanionSnapshot.Job
    let stop: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.text).lineLimit(2)
                Text([job.label, job.away].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(Palette.text3)
                if !job.lastReply.isEmpty {
                    Text(job.lastReply.suffix(240)).font(.caption).foregroundStyle(Palette.text2).lineLimit(3)
                }
            }
            Spacer()
            if job.state == .working || job.state == .starting {
                Button("Stop", action: stop).font(.caption.weight(.medium)).buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
    }

    private var color: Color {
        switch job.state {
        case .working, .starting: Palette.accent
        case .waiting, .asking: Palette.amber
        case .ready, .merged: Palette.green
        case .failed: Palette.red
        case .paused, .discarded: Palette.text3
        }
    }
}

private struct ReplyCard: View {
    let project: CompanionSnapshot.Project

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(project.lead)’s latest reply").font(.headline).foregroundStyle(Palette.text)
                Spacer()
                if project.working { ProgressView().controlSize(.small) }
            }
            Text((try? AttributedString(markdown: project.lastReply, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(project.lastReply))
                .font(.subheadline).foregroundStyle(Palette.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line))
        .padding(.top, 6)
    }
}

private struct NewJobSheet: View {
    let project: CompanionSnapshot.Project
    let start: (String, Int?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var brief = ""
    @State private var away = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What should the job do?", text: $brief, axis: .vertical).lineLimit(3...8)
                } footer: {
                    Text("It works on its own branch on the Mac, in \(project.name).")
                }
                Picker("Away", selection: $away) {
                    Text("Ask me each step").tag(0)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                }
            }
            .navigationTitle("New Job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        start(brief.trimmingCharacters(in: .whitespacesAndNewlines), away == 0 ? nil : away)
                        dismiss()
                    }
                    .disabled(brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

#if DEBUG
extension CompanionLibrary.Entry {
    static func debug(_ path: String) -> Self {
        let ext = (path as NSString).pathExtension.lowercased()
        let kind: CompanionPage.Kind = path.hasPrefix("dante:") || path.hasSuffix(".dante-diagram.json") ? .diagram
            : ext == "md" ? .markdown : ext == "pdf" ? .pdf : ["png", "jpg", "jpeg", "gif", "svg", "webp"].contains(ext) ? .image : .text
        return .init(path: path, title: (path as NSString).lastPathComponent, kind: kind)
    }
}
#endif
