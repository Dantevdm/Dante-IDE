import DanteKit
import SwiftUI

/// Settings › Agents › Morning update: who it greets, whether it reads Outlook, the senders
/// whose mail always counts, and a button to hear it now.
struct BriefingSettingsSection: View {
    @Environment(\.theme) private var theme
    @Bindable private var preferences = Preferences.shared
    private var briefings = Briefings.shared
    @State private var shown: Briefing?

    var body: some View {
        SwiftUI.Section {
            TextField("Greet me as", text: $preferences.assistantName, prompt: Text("Your first name"))
                .help("Ask “give me my morning update” (or “what did I miss”) by voice, here or on the iPhone or iPad. It covers your open and recent projects since yesterday morning (Friday on a Monday): who changed what, tests, security, and pipelines.")
            Toggle("Include important mail from Outlook", isOn: $preferences.briefingReadsMail)
                .help("Reads the last day of Outlook’s inbox on this Mac through AppleScript; macOS asks once. Only each important message’s sender, subject and first sentence go into the update; nothing is sent anywhere else. Outlook must be open, and the new Outlook doesn’t answer scripts: use Legacy Outlook.")
            Toggle("Include today’s meetings from Outlook", isOn: $preferences.briefingReadsCalendar)
                .help("Reads today’s events from Outlook’s calendar on this Mac.")
            if preferences.briefingReadsMail {
                TextField("Always tell me about mail from", text: $preferences.briefingVIPs, prompt: Text("Names or addresses, comma-separated"))
                    .help("Mail from these people counts even when it looks routine.")
            }
            LabeledContent("Try it") {
                HStack {
                    if briefings.isGathering { ProgressView().controlSize(.small) }
                    Button("Show the Update") { Task { shown = await briefings.make(fresh: true) } }
                        .disabled(briefings.isGathering)
                }
            }
        } header: {
            Text("Morning update")
        }
        .sheet(item: $shown) { briefing in
            BriefingSheet(briefing: briefing) { shown = nil }
        }
    }
}

extension Briefing: Identifiable {
    public var id: Date { date }
}

/// The update as read: the greeting, then each section's summary and items.
struct BriefingSheet: View {
    @Environment(\.theme) private var theme
    let briefing: Briefing
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(briefing.greeting).font(.dante(size: 17, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(briefing.sections) { section in
                        if !section.summary.isEmpty || !section.items.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(section.kind.title, systemImage: section.kind.symbol)
                                    .font(.dante(size: 12, weight: .semibold)).foregroundStyle(color(section.status))
                                if !section.summary.isEmpty { Text(section.summary).font(.dante(size: 13)) }
                                if let problem = section.problem { Text(problem).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color) }
                                ForEach(section.items) { item in
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title).font(.dante(size: 12, weight: .medium))
                                        if let detail = item.detail, !detail.isEmpty {
                                            Text(detail).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(2)
                                        }
                                    }
                                    .padding(.leading, 10)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460, height: 520)
    }

    private func color(_ status: Briefing.Status) -> Color {
        switch status {
        case .bad: theme.red.color
        case .attention: theme.amber.color
        case .good: theme.green.color
        case .quiet: theme.text3.color
        }
    }
}
