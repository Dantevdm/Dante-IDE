import DanteKit
import SwiftUI

/// Values the compose file needs that `.env` doesn't have (`ComposeVariables.missing`): a new
/// password for each secret, the example file's value, or a field to type one. Adding writes
/// them to `.env`, keeps it out of git, and carries on with a start that waited.
struct MissingValuesCard: View {
    @Environment(\.theme) private var theme
    let missing: [ComposeVariables.Missing]
    /// A start is waiting on these.
    let held: Bool
    let gitIgnored: Bool
    let add: ([String: String]) -> Void
    let cancel: () -> Void
    @State private var typed: [String: String] = [:]

    private var blocking: Bool { missing.contains(where: \.blocks) }
    private var waitingOnTyping: Bool {
        missing.contains { $0.fill == .ask && $0.blocks && (typed[$0.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "key.horizontal.fill").foregroundStyle(blocking ? theme.amber.color : theme.accent.color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.dante(size: 13.5, weight: .semibold)).foregroundStyle(theme.text.color)
                    Text(detail).font(.dante(size: 12)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(missing) { item in
                    HStack(spacing: 10) {
                        Text(item.name).font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text.color)
                            .frame(minWidth: 180, alignment: .leading)
                        switch item.fill {
                        case .generated:
                            Label("a new random password", systemImage: "wand.and.stars").font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                        case .example(let value):
                            TextField(value, text: binding(item.name)).textFieldStyle(.roundedBorder).font(.dante(size: 12, design: .monospaced))
                                .frame(maxWidth: 280)
                                .help("From the example env file; change it if this Mac needs something else.")
                        case .ask:
                            TextField(item.blocks ? "needed" : "optional", text: binding(item.name)).textFieldStyle(.roundedBorder)
                                .font(.dante(size: 12, design: .monospaced)).frame(maxWidth: 280)
                        }
                        if !item.blocks {
                            Text("would start blank").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            HStack(spacing: 8) {
                Button(held ? "Add to .env and Start" : "Add to .env") { add(typed) }
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .disabled(waitingOnTyping)
                if held {
                    Button("Cancel") { cancel() }.buttonStyle(DanteButtonStyle())
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill((blocking ? theme.amber : theme.accent).color.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder((blocking ? theme.amber : theme.accent).color.opacity(0.35)))
    }

    private var title: String {
        let names = missing.count == 1 ? missing[0].name : "\(missing.count) values"
        if held { return "\(names) needed before the services can start" }
        return blocking ? "Compose can’t start without \(names)" : "\(names) would start blank"
    }

    private var detail: String {
        var parts = ["Dante writes them to .env, which docker compose reads"]
        if !gitIgnored { parts.append("and adds .env to .gitignore so they stay on this Mac") }
        var text = parts.joined(separator: " ") + "."
        if missing.contains(where: { $0.fill == .generated }) {
            text += " A database that already has data keeps the password it was created with."
        }
        return text
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { typed[name] ?? "" }, set: { typed[name] = $0 })
    }
}
