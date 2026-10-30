import DanteKit
import SwiftUI

/// The footer's model chip ("Opus 5.5  Medium") and the panel it opens: the main models with
/// a tick and 1–4 keys, Effort and More models as flyouts (to the left, since the panel sits on the right), and Claude's fast mode. Works for
/// whichever agent leads; Codex's models come from its app-server's `model/list`.
struct ModelPicker: View {
    @Environment(\.theme) private var theme
    let session: Session
    let claude: ClaudeSession
    @State private var showing = false
    @State private var hovering = false
    @State private var codexModels: [CodexModel] = ModelPicker.codexCache

    @MainActor private static var codexCache: [CodexModel] = []

    var body: some View {
        let menu = self.menu
        Button { showing.toggle() } label: {
            HStack(spacing: 5) {
                Text(menu.model).foregroundStyle(hovering || showing ? theme.text.color : theme.text2.color)
                if let effort = menu.effortLabel { Text(effort).foregroundStyle(theme.text3.color) }
                if menu.fast { Image(systemName: "bolt.fill").font(.dante(size: 8.5)).foregroundStyle(theme.amber.color) }
                Image(systemName: "chevron.up.chevron.down").font(.dante(size: 7.5, weight: .semibold)).foregroundStyle(theme.text3.color)
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering || showing ? theme.raised.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .fixedSize()
        .help("\(claude.engine.title)’s model and how hard it thinks, from the next message")
        .popover(isPresented: $showing, arrowEdge: .top) {
            ModelPickerPanel(menu: menu, close: { showing = false })
        }
        .task(id: claude.engine) {
            guard claude.engine == .codex, codexModels.isEmpty, let path = Session.codexPath else { return }
            let found = await Codex(executable: path).models()
            Self.codexCache = found
            codexModels = found
        }
    }

    private var menu: PickerMenu {
        claude.engine == .codex ? codexMenu : claudeMenu
    }

    // MARK: Claude

    /// Claude Code's `--effort` levels: id, title, note and help. Extra is `xhigh`.
    static let claudeEfforts: [(String, String, String?, String)] = [
        ("", "Default", nil, "Claude Code’s own choice"),
        ("low", "Low", nil, "Quick answers and small edits; uses the least"),
        ("medium", "Medium", "Recommended", "Most work"),
        ("high", "High", nil, "Hard problems; more thorough, slower"),
        ("xhigh", "Extra", nil, "Harder problems still; uses your limits faster"),
        ("max", "Max", "3.5× or more usage", "The most thorough; uses your limits much faster"),
    ]

    static func effortTitle(_ id: String) -> String {
        claudeEfforts.first { $0.0 == id }?.1 ?? id.capitalized
    }

    private var claudeMenu: PickerMenu {
        let chosen = Preferences.shared.claudeModel
        let effort = Preferences.shared.claudeEffort
        let fastAllowed = chosen.hasFastMode
        return PickerMenu(
            model: claudeModelName,
            effortLabel: effort.isEmpty ? nil : Self.effortTitle(effort),
            fast: Preferences.shared.claudeFastMode && fastAllowed,
            heading: "Claude",
            options: Preferences.ClaudeModel.picked.map { model in
                PickerOption(id: model.rawValue, title: model.title, note: model.note, checked: model == chosen || (chosen == .default && model == runningFamily),
                             help: claudeHelp(model)) { chooseClaude(model) }
            },
            more: [PickerOption(id: "default", title: "Claude Code’s default", checked: chosen == .default,
                                help: "Whatever Claude Code picks for your plan") { chooseClaude(.default) }],
            effortTitle: effort.isEmpty ? "Default" : Self.effortTitle(effort),
            efforts: Self.claudeEfforts.map { id, title, note, help in
                PickerOption(id: id, title: title, note: note, checked: effort == id, help: help) {
                    Preferences.shared.claudeEffort = id
                    applyAll()
                }
            },
            fastMode: FastModeOption(
                isOn: Preferences.shared.claudeFastMode && fastAllowed,
                available: fastAllowed,
                help: fastAllowed ? "Faster replies from Opus, billed as extra usage beyond your plan." : "Fast mode runs on Opus only.",
                set: { on in
                    Preferences.shared.claudeFastMode = on
                    applyAll()
                })
        )
    }

    /// The family Claude Code says it's running, for the tick while the choice is its default.
    private var runningFamily: Preferences.ClaudeModel? {
        guard let id = claude.model?.lowercased() else { return nil }
        return Preferences.ClaudeModel.picked.first { id.contains($0.rawValue) }
    }

    /// The running model's name when Claude Code has said it, else the chosen one's.
    private var claudeModelName: String {
        let chosen = Preferences.shared.claudeModel
        if let id = claude.model, let name = Preferences.ClaudeModel.displayName(id: id),
           chosen == .default || name.lowercased().hasPrefix(chosen.rawValue) {
            return name
        }
        return chosen == .default ? "Default model" : chosen.title
    }

    private func claudeHelp(_ model: Preferences.ClaudeModel) -> String {
        switch model {
        case .opus: "The most capable; uses your plan fastest"
        case .sonnet: "Strong and quicker; goes further on your plan"
        case .fable: "Billed from usage credits rather than your plan"
        case .haiku: "Fast and light, for renames and explanations"
        case .default: ""
        }
    }

    private func chooseClaude(_ model: Preferences.ClaudeModel) {
        Preferences.shared.claudeModel = model
        applyAll()
    }

    // MARK: Codex

    private var codexMenu: PickerMenu {
        let chosenID = Preferences.shared.codexModel
        let current = codexModels.first { $0.id == (chosenID.isEmpty ? (claude.model ?? "") : chosenID) }
            ?? (chosenID.isEmpty ? codexModels.first(where: \.isDefault) : nil)
        let auto = Preferences.shared.automaticTaskRouting
        let effort = Preferences.shared.codexEffort
        let efforts = current?.efforts ?? codexModels.first(where: \.isDefault)?.efforts ?? []
        let options = codexModels.map { model in
            PickerOption(id: model.id, title: model.name, checked: model.id == current?.id,
                         help: model.summary) { chooseCodex(model: model.id) }
        }
        var effortRows = [
            PickerOption(id: "auto", title: "Automatic by task", checked: auto, help: "Dante picks low or medium per message, from what it asks") {
                Preferences.shared.automaticTaskRouting = true
                applyAll()
            },
            PickerOption(id: "", title: "Default", checked: !auto && effort.isEmpty, help: "The model’s own default") { chooseCodex(effort: "") },
        ]
        effortRows += efforts.map { level in
            PickerOption(id: level, title: level.capitalized, checked: !auto && effort == level, help: "") { chooseCodex(effort: level) }
        }
        let routed = claude.routingDecision?.effort
        let effortTitle = auto ? (routed.map { "Auto (\($0))" } ?? "Auto") : (effort.isEmpty ? "Default" : effort.capitalized)
        return PickerMenu(
            model: current?.name ?? (chosenID.isEmpty ? "Default model" : chosenID),
            effortLabel: auto ? effortTitle : (effort.isEmpty ? nil : effort.capitalized),
            fast: false,
            heading: "Codex",
            options: Array(options.prefix(4)),
            more: Array(options.dropFirst(4)) + [
                PickerOption(id: "default", title: "Codex’s default", checked: chosenID.isEmpty, help: "The model Codex marks as its default") {
                    chooseCodex(model: "")
                },
            ],
            effortTitle: effortTitle,
            efforts: efforts.isEmpty ? [] : effortRows,
            fastMode: nil,
            loading: codexModels.isEmpty && Session.codexPath != nil
        )
    }

    private func chooseCodex(model: String? = nil, effort: String? = nil) {
        if let model { Preferences.shared.codexModel = model }
        if let effort {
            Preferences.shared.codexEffort = effort
            Preferences.shared.automaticTaskRouting = false
        }
        applyAll()
    }

    private func applyAll() {
        Sessions.all.forEach { $0.applyClaudePreferences() }
    }
}

/// What the panel lists, already worked out for one engine.
struct PickerMenu {
    var model: String
    /// Shown after the model in the chip; nil when it's the default.
    var effortLabel: String?
    var fast: Bool
    var heading: String
    var options: [PickerOption]
    var more: [PickerOption]
    var effortTitle: String
    var efforts: [PickerOption]
    var fastMode: FastModeOption?
    var loading = false
}

struct PickerOption: Identifiable {
    var id: String
    var title: String
    var note: String? = nil
    var checked: Bool
    var help: String
    var action: () -> Void
}

struct FastModeOption {
    var isOn: Bool
    var available: Bool
    var help: String
    var set: (Bool) -> Void
}

/// The popover itself, laid out like Claude Code's own model picker.
private struct ModelPickerPanel: View {
    @Environment(\.theme) private var theme
    let menu: PickerMenu
    let close: () -> Void
    @State private var flyout: Flyout?

    enum Flyout { case effort, more }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            caption("Model · from the next message")
            if menu.loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Asking \(menu.heading) for its models…").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            ForEach(Array(menu.options.enumerated()), id: \.element.id) { index, option in
                PickerRow(option: option, shortcut: index < 9 ? index + 1 : nil) {
                    option.action()
                    close()
                }
            }
            divider
            if !menu.efforts.isEmpty {
                FlyoutRow(title: "Effort", value: menu.effortTitle, open: flyout == .effort) { flyout = flyout == .effort ? nil : .effort }
                    .popover(isPresented: binding(.effort), arrowEdge: .leading) {
                        FlyoutList(options: menu.efforts) { flyout = nil }
                    }
            }
            if !menu.more.isEmpty {
                FlyoutRow(title: "More models", value: nil, open: flyout == .more) { flyout = flyout == .more ? nil : .more }
                    .popover(isPresented: binding(.more), arrowEdge: .leading) {
                        FlyoutList(options: menu.more) {
                            flyout = nil
                            close()
                        }
                    }
            }
            if let fast = menu.fastMode {
                divider
                caption("Fast mode")
                Toggle(isOn: Binding(get: { fast.isOn }, set: { fast.set($0) })) {
                    Text("Enable fast mode").font(.dante(size: 13)).foregroundStyle(fast.available ? theme.text.color : theme.text3.color)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("Enable fast mode")
                .tint(theme.accent.color)
                .disabled(!fast.available)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .help(fast.help)
            }
        }
        .padding(6)
        .frame(width: 264)
    }

    private var divider: some View {
        Rectangle().fill(theme.line.color).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 4)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
    }

    private func binding(_ which: Flyout) -> Binding<Bool> {
        Binding(get: { flyout == which }, set: { if !$0, flyout == which { flyout = nil } })
    }
}

/// One choice: a tick when it's chosen, a note pill, and its number key.
private struct PickerRow: View {
    @Environment(\.theme) private var theme
    let option: PickerOption
    let shortcut: Int?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(option.title).font(.dante(size: 13)).foregroundStyle(theme.text.color).lineLimit(1)
                if let note = option.note {
                    Label(note, systemImage: "info.circle")
                        .font(.dante(size: 10.5)).foregroundStyle(theme.text2.color)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.raised.color))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.line.color))
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 6)
                if option.checked {
                    Image(systemName: "checkmark").font(.dante(size: 11, weight: .semibold)).foregroundStyle(theme.text.color)
                } else if let shortcut {
                    Text("\(shortcut)").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).monospacedDigit()
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme.raised.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(option.help)
        .modifier(NumberKey(number: shortcut))
        .accessibilityAddTraits(option.checked ? .isSelected : [])
    }
}

private struct NumberKey: ViewModifier {
    let number: Int?

    func body(content: Content) -> some View {
        if let number, let key = "\(number)".first {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: [])
        } else {
            content
        }
    }
}

/// "Effort … Medium ›": opens its list beside the panel.
private struct FlyoutRow: View {
    @Environment(\.theme) private var theme
    let title: String
    let value: String?
    let open: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.dante(size: 13)).foregroundStyle(theme.text.color)
                Spacer(minLength: 6)
                if let value { Text(value).font(.dante(size: 12.5)).foregroundStyle(theme.text3.color).lineLimit(1) }
                Image(systemName: "chevron.right").font(.dante(size: 10, weight: .semibold)).foregroundStyle(theme.text3.color)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering || open ? theme.raised.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct FlyoutList: View {
    let options: [PickerOption]
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(options) { option in
                PickerRow(option: option, shortcut: nil) {
                    option.action()
                    done()
                }
            }
        }
        .padding(6)
        .frame(width: 230)
    }
}
