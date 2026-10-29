import SwiftUI

/// On the iPad, a step waiting for you or a question pops up over whatever is open, the Wall
/// included. A Hands step (keyboard, mouse, screen) and Hands at work show the Mac's screen,
/// refreshed every second, with a Stop button that is Hands' kill switch on the Mac.
struct WaitingPrompt: ViewModifier {
    let connection: CompanionConnection
    var active = true
    /// Put away with Later: not shown again until something new waits.
    @State private var putAway: Set<String> = []

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { active ? shown : nil }, set: { if $0 == nil, let shown { putAway.insert(shown.id) } })) { prompt in
            WaitingSheet(connection: connection, prompt: prompt) { putAway.insert(prompt.id) }
                .presentationDetents(prompt.showsScreen ? [.large] : [.medium, .large])
        }
        // Hands put away comes back the next time they start.
        .onChange(of: connection.snapshot?.hands == nil) { _, idle in if idle { putAway.remove("hands") } }
    }

    private var shown: Prompt? {
        guard let snapshot = connection.snapshot else { return nil }
        let waiting = snapshot.projects.flatMap { project in project.approvals.map { (project, $0) } }
        if let (project, approval) = waiting.first(where: { !putAway.contains($0.1.id) }) {
            return Prompt(project: project, approval: approval, hands: snapshot.hands, count: waiting.count)
        }
        if let hands = snapshot.hands, !putAway.contains("hands") {
            return Prompt(project: nil, approval: nil, hands: hands, count: 0)
        }
        return nil
    }

    struct Prompt: Identifiable, Equatable {
        var project: CompanionSnapshot.Project?
        var approval: CompanionSnapshot.Approval?
        var hands: CompanionSnapshot.HandsAtWork?
        var count: Int
        /// The sheet stays up across snapshots of the same step; Hands at work is one prompt.
        var id: String { approval?.id ?? "hands" }
        var showsScreen: Bool { approval?.isHands == true || approval == nil && hands != nil }
    }
}

extension View {
    func waitingPrompt(_ connection: CompanionConnection, active: Bool = true) -> some View {
        modifier(WaitingPrompt(connection: connection, active: active))
    }
}

private struct WaitingSheet: View {
    let connection: CompanionConnection
    let prompt: WaitingPrompt.Prompt
    let later: () -> Void
    @State private var picks: [String: String] = [:]
    @State private var stopped = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if prompt.showsScreen { screen }
                    if let approval = prompt.approval {
                        if let note = approval.note {
                            Label(note, systemImage: "exclamationmark.shield.fill").font(.callout).foregroundStyle(Palette.amber)
                        }
                        if !approval.detail.isEmpty, approval.questions.isEmpty {
                            Text(approval.detail).font(.system(.callout, design: .monospaced)).foregroundStyle(Palette.text2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(RoundedRectangle(cornerRadius: Palette.controlRadius).fill(Palette.background))
                        }
                        if approval.questions.isEmpty { decision(approval) } else { questions(approval) }
                    }
                }
                .padding(24)
            }
            .background(Palette.card.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Later", action: later) }
                if prompt.count > 1 {
                    ToolbarItem(placement: .principal) { Text("1 of \(prompt.count) waiting").font(.subheadline).foregroundStyle(Palette.text3) }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption).font(.subheadline.weight(.medium)).foregroundStyle(Palette.text3)
            Text(prompt.approval?.title ?? prompt.hands?.step ?? "")
                .font(.title.weight(.semibold)).foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var caption: String {
        let lead = prompt.project?.lead ?? prompt.hands?.agent ?? "The agent"
        guard let approval = prompt.approval else { return "\(lead) is using Hands on your Mac" }
        let asks = approval.questions.isEmpty ? (approval.isHands ? "\(lead) wants to use Hands" : "\(lead) is waiting for you") : "\(lead) has a question"
        return [prompt.project?.name, asks].compactMap { $0 }.joined(separator: " · ")
    }

    /// The Mac's screen and Hands' kill switch.
    private var screen: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacScreen(connection: connection)
            Button(role: .destructive) {
                connection.stopHands()
                stopped = true
            } label: {
                Label(stopped ? "Hands stopped" : "Stop Hands", systemImage: "stop.circle.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent).tint(Palette.red)
            .disabled(stopped)
            Text("Stops every step at once and turns Hands off on the Mac, like ⌃⌥⌘. there.")
                .font(.footnote).foregroundStyle(Palette.text3)
        }
    }

    private func decision(_ approval: CompanionSnapshot.Approval) -> some View {
        HStack(spacing: 14) {
            Button { answer(approval, allow: false) } label: {
                Text("Decline").font(.title3.weight(.medium)).frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.bordered).tint(Palette.red)
            Button { answer(approval, allow: true) } label: {
                Text(approval.isHands ? "Allow this step" : "Approve").font(.title3.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// Every question with its options; one question sends on the first tap.
    private func questions(_ approval: CompanionSnapshot.Approval) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(approval.questions, id: \.question) { question in
                VStack(alignment: .leading, spacing: 10) {
                    Text(question.question).font(.title3.weight(.medium)).foregroundStyle(Palette.text)
                    ForEach(question.options, id: \.self) { option in
                        let picked = picks[question.question] == option
                        Button {
                            picks[question.question] = option
                            if approval.questions.count == 1 { answer(approval, allow: true, answers: picks) }
                        } label: {
                            HStack {
                                Text(option).font(.body.weight(.medium)).multilineTextAlignment(.leading)
                                Spacer()
                                if picked { Image(systemName: "checkmark.circle.fill") }
                            }
                            .foregroundStyle(picked ? Palette.onAccent : Palette.text)
                            .padding(.horizontal, 16).frame(minHeight: 50)
                            .background(RoundedRectangle(cornerRadius: Palette.controlRadius).fill(picked ? Palette.accent : Palette.background))
                            .overlay(RoundedRectangle(cornerRadius: Palette.controlRadius).strokeBorder(Palette.line))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 14) {
                Button { answer(approval, allow: false) } label: {
                    Text("Skip").frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.bordered)
                if approval.questions.count > 1 {
                    Button { answer(approval, allow: true, answers: picks) } label: {
                        Text("Send answers").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(picks.count < approval.questions.count)
                }
            }
        }
    }

    private func answer(_ approval: CompanionSnapshot.Approval, allow: Bool, answers: [String: String]? = nil) {
        guard let project = prompt.project else { return }
        connection.answer(approval, project: project.id, allow: allow, answers: answers)
    }
}

/// The Mac's main screen, asked for once a second while shown.
private struct MacScreen: View {
    let connection: CompanionConnection
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Palette.controlRadius).fill(Palette.background)
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Palette.controlRadius))
            } else {
                VStack(spacing: 8) {
                    if failed {
                        Image(systemName: "display.trianglebadge.exclamationmark").font(.largeTitle)
                        Text("Can’t see the Mac’s screen. Hands may be off there.").font(.callout)
                    } else {
                        ProgressView()
                        Text("Looking at your Mac…").font(.callout)
                    }
                }
                .foregroundStyle(Palette.text3)
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .overlay(RoundedRectangle(cornerRadius: Palette.controlRadius).strokeBorder(Palette.line))
        .task {
            while !Task.isCancelled {
                if let data = await connection.screen(), let picture = UIImage(data: data) {
                    image = picture
                    failed = false
                } else if image == nil {
                    failed = true
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
