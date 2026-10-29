import AppKit
import AVFoundation
import DanteKit
import SwiftUI

/// Dante › Settings… (⌘,): a standard macOS Settings window. The panes that act on a project
/// (Tools, Project) use the one in the window used most recently.
struct SettingsWindow: View {
    @Environment(ThemeStore.self) private var themeStore
    private let active = ActiveProject.shared

    enum Pane: String {
        case appearance, editor, keyboard, languages, files, claude, tools, project
    }

    @AppStorage("settingsPane") private var pane: Pane = .appearance

    /// The most recent window's project, or any open one.
    private var session: Session? { active.session ?? Sessions.all.first { $0.workspace != nil } }

    var body: some View {
        let theme = themeStore.theme
        let session = session
        TabView(selection: $pane) {
            AppearancePane(themeStore: themeStore)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }.tag(Pane.appearance)
            EditorSettings(preferences: Preferences.shared)
                .tabItem { Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right") }.tag(Pane.editor)
            KeyboardPane()
                .tabItem { Label("Keyboard", systemImage: "keyboard") }.tag(Pane.keyboard)
            LanguagesPane()
                .tabItem { Label("Languages", systemImage: "curlybraces") }.tag(Pane.languages)
            FileSettings(preferences: Preferences.shared)
                .tabItem { Label("Files", systemImage: "doc") }.tag(Pane.files)
            ClaudePreferencesPane()
                .tabItem { Label("Agents", systemImage: "person.2") }.tag(Pane.claude)
            ToolsPane(session: session)
                .id(session.map(ObjectIdentifier.init))
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }.tag(Pane.tools)
            Group {
                if let session, let workspace = session.workspace {
                    ProjectPane(session: session, workspace: workspace)
                } else {
                    Form { Text("No project open").foregroundStyle(theme.text3.color) }
                }
            }
            .tabItem { Label("Project", systemImage: "folder.badge.gearshape") }.tag(Pane.project)
        }
        .formStyle(.grouped)
        .frame(width: 660, height: 580)
        .environment(\.theme, theme)
        .tint(theme.accent.color)
        .preferredColorScheme(theme.colorScheme)
    }
}

// MARK: Appearance

private struct AppearancePane: View {
    @Environment(\.theme) private var theme
    @Bindable var themeStore: ThemeStore

    /// A look's tile shows the half (light or night) that's in use.
    private func shownID(_ look: ThemeID) -> ThemeID {
        if isChosen(look) { return themeStore.id }
        guard themeStore.id.theme.isDark, let night = look.counterpart, night.theme.isDark else { return look }
        return night
    }

    private func isChosen(_ look: ThemeID) -> Bool { themeStore.id == look || themeStore.id == look.counterpart }

    var body: some View {
        Form {
            SwiftUI.Section("Look") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                    ForEach(ThemeID.looks, id: \.self) { look in
                        let shown = shownID(look)
                        let chosen = isChosen(look)
                        Button { themeStore.choose(shown) } label: {
                            VStack(spacing: 6) {
                                ThemePreview(theme: shown.theme)
                                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(chosen ? theme.accent.color : theme.line.color, lineWidth: chosen ? 2 : 1))
                                Text(look == .light ? "Classic" : look.displayName)
                                    .font(.dante(size: 12, weight: chosen ? .semibold : .regular)).foregroundStyle(theme.text.color)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(look.tagline)
                    }
                }
                .padding(.vertical, 6)
                if themeStore.id.counterpart != nil {
                    Picker("Light or night", selection: Binding(get: { themeStore.id.theme.isDark }, set: { night in
                        if night != themeStore.id.theme.isDark, let other = themeStore.id.counterpart { themeStore.choose(other) }
                    })) {
                        Text("Light").tag(false)
                        Text("Night").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .help("Each look comes light and at night. Vine, Tide, Dusk and Aurora move slowly behind the pages; Reduce Motion stills them.")
                }
            }
            SwiftUI.Section {
                LabeledContent("Editor font size") {
                    Stepper(value: $themeStore.editorFontSize, in: 9...28, step: 1) {
                        Text("\(Int(themeStore.editorFontSize)) pt").monospacedDigit()
                    }
                }
                Toggle("Geist and Geist Mono", isOn: Bindable(Preferences.shared).usesGeist)
                    .help("The design’s typeface, bundled with Dante. Off uses SF Pro and SF Mono.")
                Toggle("Dante’s orb in the menu bar", isOn: Bindable(Preferences.shared).showsPresence)
            }
        }
    }
}

/// A tiny window in a theme's colours: title bar, sidebar, code lines and an accent button.
private struct ThemePreview: View {
    let theme: Theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(0..<3) { _ in Circle().fill(theme.line2.color).frame(width: 5, height: 5) }
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(height: 14)
            .background(theme.panel.color)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<4) { index in
                        RoundedRectangle(cornerRadius: 1.5).fill(index == 1 ? theme.accent.color : theme.text3.color.opacity(0.6)).frame(width: 18, height: 3)
                    }
                    Spacer()
                }
                .padding(6)
                .frame(width: 34)
                .background(theme.panel.color)
                VStack(alignment: .leading, spacing: 4) {
                    line(theme.syntax.keyword.color, 14, theme.syntax.function.color, 24)
                    line(theme.syntax.type.color, 20, theme.syntax.string.color, 30)
                    line(theme.syntax.comment.color, 40, nil, 0)
                    line(theme.syntax.keyword.color, 10, theme.syntax.number.color, 12)
                    Spacer()
                    HStack {
                        Spacer()
                        RoundedRectangle(cornerRadius: 3).fill(theme.accent.color).frame(width: 26, height: 9)
                    }
                }
                .padding(7)
                .background(theme.codeBackground.color)
            }
        }
        .padding(.leading, theme.id.scene == .none ? 0 : 10)
        .padding(.top, theme.id.scene == .none ? 0 : 10)
        .background(ThemeBackdrop(theme: theme, small: true))
        .frame(width: 150, height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func line(_ first: Color, _ a: CGFloat, _ second: Color?, _ b: CGFloat) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1.5).fill(first).frame(width: a, height: 3)
            if let second { RoundedRectangle(cornerRadius: 1.5).fill(second).frame(width: b, height: 3) }
        }
    }
}

// MARK: Claude

private struct ClaudePreferencesPane: View {
    @Environment(\.theme) private var theme
    @Bindable private var preferences = Preferences.shared

    var body: some View {
        Form {
            SwiftUI.Section {
                CodexRow()
            } header: {
                Text("Who leads")
                    .help("Claude (Claude Code, your Anthropic plan) or Codex (OpenAI, your ChatGPT plan) leads the conversation and the other reviews when asked.")
            }
            SwiftUI.Section("Claude") {
                Picker("Model", selection: $preferences.claudeModel) {
                    ForEach(Preferences.ClaudeModel.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .onChange(of: preferences.claudeModel) { Sessions.all.forEach { $0.applyClaudePreferences() } }
                Picker("Effort", selection: $preferences.claudeEffort) {
                    Text("Claude Code’s default").tag("")
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
                .help("How hard Claude thinks before answering. Low uses the least of your plan; the chat footer’s model menu changes it per message too.")
                .onChange(of: preferences.claudeEffort) { Sessions.all.forEach { $0.applyClaudePreferences() } }
                if SystemStatus.detect().claudePath == nil {
                    Label("Claude Code isn’t installed. Claude chat and coding features are unavailable.", systemImage: "exclamationmark.triangle.fill")
                        .font(.dante(size: 11.5)).foregroundStyle(theme.amber.color)
                }
            }
            SwiftUI.Section {
                Toggle("Ask clarifying questions before ambiguous work", isOn: $preferences.claudeAsksFirst)
                Toggle("Notify when the agent finishes or needs approval in the background", isOn: $preferences.notifiesOnClaude)
                    .onChange(of: preferences.notifiesOnClaude) { _, on in
                        if on { Task { if await !Session.requestNotificationPermission() { preferences.notifiesOnClaude = false } } }
                    }
                Toggle("Automatically manage task effort and local routing", isOn: $preferences.automaticTaskRouting)
                    .help("Uses low reasoning for routine tasks and normal reasoning for harder work. Self-contained prose can run locally. Turn off to use your selected effort for every task.")
                    .onChange(of: preferences.automaticTaskRouting) { Sessions.all.forEach { $0.applyClaudePreferences() } }
                Toggle("Give the agents a browser of their own to check the app", isOn: $preferences.agentsBrowse)
                    .help("The agent in charge and every job get a private browser inside Dante for trying the app as a user would: it visits only the app on this Mac (localhost, *.localhost, *.test) and test hosts listed under browser: hosts: in .dante/project.yaml, keeps no cookies or sign-ins, and never uses your browser. Screenshots are kept for a week in Application Support.")
                    .onChange(of: preferences.agentsBrowse) { Sessions.all.forEach { $0.applyClaudePreferences() } }
                Toggle("Let the agent in charge delegate small jobs to local models", isOn: $preferences.delegatesToLocalModels)
                    .help("The agent in charge gets a delegate tool backed by Ollama on this Mac, for summaries, triage, drafts and commit messages. It checks what comes back.")
                    .onChange(of: preferences.delegatesToLocalModels) { Sessions.all.forEach { $0.applyClaudePreferences() } }
            } header: {
                Text("Either agent")
            }
            TeamSettingsSection()
            VoicePreferencesSection()
            SwiftUI.Section {
                ForEach(CloudAgent.allCases) { agent in CloudAgentKeyRow(agent: agent) }
            } header: {
                Text("Cloud agents")
                    .help("The agent in charge can ask Grok for a second opinion and Jev for quick typed decisions, using your own keys. Keys stay in your Keychain; it asks before sending anything to them unless approvals are off.")
            }
            HandsSettingsSection()
            CompanionSettingsSection()
            BriefingSettingsSection()
        }
    }
}

/// The team Claude hands work to: each role on or off, and its model.
private struct TeamSettingsSection: View {
    @Bindable private var preferences = Preferences.shared

    var body: some View {
        SwiftUI.Section {
            ForEach(TeamRole.allCases) { role in
                Picker(selection: binding(role)) {
                    Text("Off").tag(Optional<TeamModel>.none)
                    ForEach(TeamModel.allCases) { Text($0.title).tag(Optional($0)) }
                } label: {
                    Label(role.title, systemImage: role.symbol)
                }
                .help(role.summary)
            }
            Toggle("Document decisions as we work", isOn: $preferences.documentsAsWeWork)
                .help("When a decision is made, the lead starts the Documenter beside the work to record it in docs/decisions/ and keep the project’s docs current.")
                .onChange(of: preferences.documentsAsWeWork) { Sessions.all.forEach { $0.applyClaudePreferences() } }
        } header: {
            Text("Team")
                .help("Claude hands self-contained work to these team members, each on its own model, and runs independent ones at the same time. Cheaper models for easier roles use less of your plan.")
        }
    }

    private func binding(_ role: TeamRole) -> Binding<TeamModel?> {
        Binding {
            preferences.teamRolesOff.contains(role) ? nil : preferences.teamModel(role)
        } set: { model in
            preferences.teamOff.removeAll { $0 == role.rawValue }
            if let model { preferences.teamModels[role.rawValue] = model.rawValue } else { preferences.teamOff.append(role.rawValue) }
            Sessions.all.forEach { $0.applyClaudePreferences() }
        }
    }
}

/// Talking to Claude: reading replies out, conversations, "Hey Dante" and the voice.
private struct VoicePreferencesSection: View {
    @Environment(\.theme) private var theme
    @Bindable private var preferences = Preferences.shared
    private let voice = VoiceController.shared
    private let voices = VoiceController.voices
    @State private var microphones = Microphones.all().filter { $0.transport != .virtual }
    private let naturalSetup = NaturalVoiceSetup.shared

    var body: some View {
        SwiftUI.Section {
            Toggle("Read replies aloud after you speak (\(VoiceController.keyLabel))", isOn: $preferences.speaksReplies)
            Toggle("Keep the conversation going", isOn: $preferences.keepsConversation)
                .help("After reading a reply, Dante listens for a follow-up without the key. Silence or “thanks” ends it.")
                .disabled(!preferences.speaksReplies)
            Toggle("Listen for “Hey Dante”", isOn: $preferences.listensForWakeWord)
                .help("While Dante is open, the microphone stays on and speech is recognised on this Mac only; nothing is sent anywhere until you say “Hey Dante”. macOS shows the microphone in use.")
                .onChange(of: preferences.listensForWakeWord) { VoiceController.shared.updateWakeListening() }
            if preferences.listensForWakeWord, let problem = voice.wakeProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.dante(size: 11.5))
                    .foregroundStyle(theme.amber.color)
            }
            Picker("Microphone", selection: $preferences.microphone) {
                Text("Automatic").tag("")
                ForEach(microphones) { microphone in
                    Text(microphone.transport == .bluetooth ? "\(microphone.name) (Bluetooth)" : microphone.name).tag(microphone.uid)
                }
            }
            .help("Automatic follows the input chosen in System Settings › Sound. While a Bluetooth headset’s microphone is open, macOS plays through it at call quality.")
            .onChange(of: preferences.microphone) { VoiceController.shared.microphoneChanged() }
            Toggle("Natural voice", isOn: $preferences.usesNaturalVoice)
                .help("Kokoro, a neural voice that runs on this Mac: it sounds far more like a person than the system voices, and nothing you hear is made anywhere else.")
                .onChange(of: preferences.usesNaturalVoice) { VoiceController.shared.naturalVoiceChanged() }
            if preferences.usesNaturalVoice, naturalSetup.installed {
                Picker("Voice", selection: $preferences.naturalVoice) {
                    ForEach(NaturalVoice.voices) { voice in
                        Text("\(voice.name) (\(voice.accent))").tag(voice.id)
                    }
                }
            } else {
                if preferences.usesNaturalVoice {
                    HStack {
                        Button(naturalSetup.isWorking ? "Setting Up…" : "Set Up Natural Voice") {
                            Task {
                                await naturalSetup.install()
                                VoiceController.shared.naturalVoiceChanged()
                            }
                        }
                        .disabled(naturalSetup.isWorking)
                        .help("Downloads Kokoro (about \(NaturalVoice.downloadSize)) into Application Support, with a Python environment of its own. Until then Dante speaks with the system voice below.")
                        switch naturalSetup.state {
                        case .working(let step):
                            ProgressView().controlSize(.small)
                            Text(step).foregroundStyle(theme.text3.color)
                        case .failed(let message):
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(theme.amber.color)
                        case .idle:
                            EmptyView()
                        }
                    }
                    .font(.dante(size: 11.5))
                }
                Picker(preferences.usesNaturalVoice ? "System voice" : "Voice", selection: $preferences.voiceIdentifier) {
                    Text("Best available").tag("")
                    ForEach(voices, id: \.identifier) { voice in
                        Text(Self.label(voice)).tag(voice.identifier)
                    }
                }
                .help("Premium and Enhanced voices sound far better. Download them in System Settings › Accessibility › Spoken Content › System Voice › Manage Voices.")
            }
            HStack {
                Slider(value: $preferences.speechRate, in: 0.4...0.62) {
                    Text("Speed")
                } minimumValueLabel: {
                    Image(systemName: "tortoise")
                } maximumValueLabel: {
                    Image(systemName: "hare")
                }
                Button("Preview") { VoiceController.shared.preview() }
            }
        } header: {
            Text("Voice")
        }
    }

    static func label(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality = switch voice.quality {
        case .premium: " · Premium"
        case .enhanced: " · Enhanced"
        default: ""
        }
        let region = Locale.current.localizedString(forRegionCode: String(voice.language.split(separator: "-").last ?? "")) ?? voice.language
        return "\(voice.name) (\(region))\(quality)"
    }
}

/// Codex: found on this Mac (often inside the ChatGPT app) and signed in with ChatGPT, so it
/// needs no key. Claude asks it read-only.
private struct CodexRow: View {
    @Environment(\.theme) private var theme
    @Bindable private var preferences = Preferences.shared
    @State private var signedIn: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Codex").font(.dante(size: 13, weight: .medium))
                    Text("OpenAI · Codes in charge, or reviews Claude’s work").font(.dante(size: 11)).foregroundStyle(theme.text3.color).lineLimit(1)
                }
                .fixedSize()
                Spacer(minLength: 12)
                if let path = Session.codexPath {
                    if signedIn == false {
                        Label("Not signed in", systemImage: "exclamationmark.triangle.fill")
                            .font(.dante(size: 11.5)).foregroundStyle(theme.amber.color)
                            .help("Run codex login in the terminal, or sign in from the ChatGPT app.")
                    }
                    Toggle("Let Claude ask Codex", isOn: $preferences.asksCodex)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .help("Claude gets an ask_codex tool. Codex runs read-only at \(path), on your ChatGPT plan, and asks before each use unless approvals are off.")
                        .onChange(of: preferences.asksCodex) { Sessions.all.forEach { $0.applyClaudePreferences() } }
                } else {
                    Text("Not installed").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                    Link("Get Codex", destination: URL(string: "https://developers.openai.com/codex/cli")!).font(.dante(size: 12))
                }
            }
            if Session.codexPath != nil {
                Picker("In charge", selection: $preferences.agentEngine) {
                    ForEach(AgentEngine.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Who leads new conversations; the other reviews when asked. Each window’s panel can switch too.")
                .onChange(of: preferences.agentEngine) { _, engine in
                    for session in Sessions.all {
                        guard let claude = session.claude, claude.state != .working, claude.remote == nil else { continue }
                        if engine == .claude { claude.keepClaude() }
                        claude.engine = engine
                        session.applyClaudePreferences()
                    }
                }
                Toggle("Switch to Codex when Claude’s limit is near", isOn: $preferences.switchesToCodexAtLimit)
                    .help("When Claude Code warns that your plan is at 90% or more, or stops at its limit, Codex takes over the conversation with a summary of it, and a request Claude couldn’t finish is sent again.")
                    .onChange(of: preferences.switchesToCodexAtLimit) { Sessions.all.forEach { $0.applyClaudePreferences() } }
            }
            if Session.codexPath != nil, preferences.asksCodex || preferences.agentEngine == .codex {
                TextField("Model", text: $preferences.codexModel, prompt: Text("Codex default"))
                    .onSubmit { Sessions.all.forEach { $0.applyClaudePreferences() } }
                    .help("Leave empty for Codex’s default. Dante ignores your Codex config.toml, since its model may not work with a ChatGPT sign-in.")
            }
        }
        .padding(.vertical, 2)
        .task {
            guard let path = Session.codexPath else { return }
            let status = await Shell.run([path, "login", "status"], in: FileManager.default.homeDirectoryForCurrentUser)
            signedIn = status.succeeded && (status.stdout + status.stderr).localizedCaseInsensitiveContains("logged in")
        }
    }
}

/// A cloud agent's key: pasted once, kept in the Keychain, shown masked, checked on request.
private struct CloudAgentKeyRow: View {
    @Environment(\.theme) private var theme
    @Bindable private var preferences = Preferences.shared
    let agent: CloudAgent
    @State private var entered = ""
    @State private var saved: String?
    @State private var status: (text: String, ok: Bool)?
    @State private var checking = false
    @State private var models: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.title).font(.dante(size: 13, weight: .medium))
                    Text("\(agent.company) · \(agent.role)").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                        .lineLimit(1)
                }
                .fixedSize()
                if let saved {
                    Text(saved).font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text2.color)
                    Spacer()
                    Button(checking ? "Checking…" : "Check") { Task { await check() } }
                        .disabled(checking)
                        .help(agent == .jev ? "Asks Jev one tiny question (a fraction of a cent)." : "Lists the models your key can use.")
                    Button("Remove") { store(nil) }
                } else {
                    Spacer(minLength: 12)
                    SecureField("\(agent.title) API key", text: $entered, prompt: Text(agent.keyHint))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .onSubmit { store(entered) }
                    Button("Save") { store(entered) }
                        .disabled(entered.trimmingCharacters(in: .whitespaces).isEmpty)
                    Link("Get a key", destination: agent.keysPage).font(.dante(size: 12))
                }
            }
            if let status {
                Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.dante(size: 11.5))
                    .foregroundStyle(status.ok ? theme.green.color : theme.amber.color)
                    .lineLimit(2)
            }
            if agent == .grok, saved != nil {
                Picker("Model", selection: $preferences.grokModel) {
                    Text("Best available").tag("")
                    ForEach(models.contains(preferences.grokModel) || preferences.grokModel.isEmpty ? models : [preferences.grokModel] + models, id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .onChange(of: preferences.grokModel) { Sessions.all.forEach { $0.applyClaudePreferences() } }
                .help("Check lists the models your key can use.")
            }
        }
        .padding(.vertical, 2)
        .onAppear { saved = AgentKeys.key(for: agent).map(AgentKeys.masked) }
    }

    private func store(_ key: String?) {
        let ok = AgentKeys.set(key, for: agent)
        entered = ""
        saved = AgentKeys.key(for: agent).map(AgentKeys.masked)
        status = ok ? nil : ("Couldn’t save to the Keychain.", false)
        if key == nil { models = [] }
        Sessions.all.forEach { $0.applyClaudePreferences() }
    }

    private func check() async {
        guard let key = AgentKeys.key(for: agent) else { return }
        checking = true
        defer { checking = false }
        do {
            switch agent {
            case .grok:
                models = try await Grok(key: key).models()
                status = models.isEmpty ? ("The key works but has no chat models.", false) : ("Works: \(models.count) model\(models.count == 1 ? "" : "s").", true)
            case .jev:
                let decision = try await Jev(key: key).check()
                let credit = decision.creditsRemainingUSD.map { String(format: " $%.2f credit left.", $0) } ?? ""
                status = ("Works: \(decision.model).\(credit)", true)
            }
        } catch {
            status = (error.localizedDescription, false)
        }
    }
}

// MARK: Tools

private struct ToolsPane: View {
    @Environment(\.theme) private var theme
    let session: Session?
    @State private var statuses: [String: ToolStatus] = [:]
    @State private var showsAll = false
    @State private var command: CommandLineTool.State?
    private let bundledCommand = CommandLineTool.bundled()

    private var languages: [String] {
        let names: [String: String] = ["go": "Go", "js": "JavaScript", "mjs": "JavaScript", "jsx": "JavaScript", "ts": "TypeScript", "tsx": "TypeScript",
                                       "py": "Python", "rs": "Rust", "swift": "Swift"]
        return Array(Set((session?.workspace?.files ?? []).compactMap { names[($0 as NSString).pathExtension.lowercased()] }))
    }

    private var tools: [Tool] { showsAll || session?.workspace == nil ? Tool.all : Tool.relevant(stack: languages) }

    var body: some View {
        Form {
            SwiftUI.Section("Dante") { commandRow }
            ForEach(Tool.Group.allCases, id: \.self) { group in
                let inGroup = tools.filter { $0.group == group }
                if !inGroup.isEmpty {
                    SwiftUI.Section {
                        ForEach(inGroup) { tool in row(tool) }
                    } header: {
                        Text(group.rawValue)
                    }
                }
            }
            if session?.workspace != nil {
                SwiftUI.Section {
                    Toggle("Show tools for languages this project doesn’t use", isOn: $showsAll)
                }
            }
        }
        .task(id: showsAll) { await check() }
    }

    private func row(_ tool: Tool) -> some View {
        let status = statuses[tool.id]
        return HStack(spacing: 10) {
            Text(tool.name).font(.dante(size: 13, weight: .medium))
                .help(tool.purpose)
            Spacer()
            if let status {
                if status.installed {
                    Label(status.version ?? "Installed", systemImage: "checkmark.circle.fill")
                        .font(.dante(size: 12))
                        .foregroundStyle(theme.green.color)
                        .help(status.path ?? "")
                } else {
                    Text("Not installed").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                    Button("Install…") { install(tool.install) }
                        .disabled(session == nil)
                        .help("Types \(tool.install) into the project’s terminal")
                }
            } else {
                ProgressView().controlSize(.mini)
            }
        }
    }

    /// The `dante` command: open folders and files from any terminal.
    private var commandRow: some View {
        HStack(spacing: 10) {
            Text("dante command").font(.dante(size: 13, weight: .medium))
                .help("Open folders and files from the terminal: dante . or dante src/main.go:42")
            Spacer()
            if let bundledCommand {
                let install = CommandLineTool.installCommand(
                    source: bundledCommand.path,
                    path: Shell.environment()["PATH"] ?? "",
                    home: NSHomeDirectory(),
                    isWritable: { FileManager.default.isWritableFile(atPath: $0) }
                )
                switch command {
                case .installed(let path):
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.dante(size: 12))
                        .foregroundStyle(theme.green.color)
                        .help(path)
                case .elsewhere(let path):
                    Text("Points to another copy").font(.dante(size: 12)).foregroundStyle(theme.amber.color).help(path)
                    Button("Link This Copy…") { self.install(install) }.disabled(session == nil).help(install)
                case .notInstalled:
                    Text("Not installed").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                    Button("Install…") { self.install(install) }.disabled(session == nil).help(install)
                case nil:
                    ProgressView().controlSize(.mini)
                }
            } else {
                Text("Comes with the app bundle").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
            }
        }
    }

    /// Types the command into the project's terminal and brings its window forward; it runs
    /// only when the user presses Return there.
    private func install(_ command: String) {
        guard let session else { return }
        session.typeInTerminal(command)
        session.window?.makeKeyAndOrderFront(nil)
    }

    private func check() async {
        if let bundledCommand {
            let found = Shell.which(CommandLineTool.name)
            let resolved = found.map { URL(filePath: $0).resolvingSymlinksInPath().path }
            command = CommandLineTool.state(found: found, resolved: resolved, bundled: bundledCommand.resolvingSymlinksInPath().path)
        }
        await withTaskGroup(of: (String, ToolStatus).self) { group in
            for tool in tools where statuses[tool.id] == nil {
                group.addTask { (tool.id, await ToolStatus.check(tool)) }
            }
            for await (id, status) in group { statuses[id] = status }
        }
    }
}

// MARK: This project

private struct ProjectPane: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    @State private var confirmsRemoval = false
    @State private var confirmsForget = false
    @State private var message: String?

    private var danteFiles: [String] { workspace.files.filter { $0.hasPrefix(".dante/") } }
    private var hasDante: Bool { FileManager.default.fileExists(atPath: workspace.danteFolder.path) }
    private var savedConnections: Int { ConnectionStore().connections(for: workspace.url).count }

    var body: some View {
        Form {
            SwiftUI.Section {
                LabeledContent("Folder") {
                    Text(workspace.url.path(percentEncoded: false).replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.dante(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Dante setup") {
                    Text(hasDante ? "\(danteFiles.count) files in .dante/" : "None")
                        .foregroundStyle(theme.text2.color)
                }
            }
            SwiftUI.Section {
                if hasDante {
                    LabeledContent("The .dante folder") {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([workspace.danteFolder]) }
                    }
                    LabeledContent("Remove Dante from this project") {
                        Button("Remove…", role: .destructive) { confirmsRemoval = true }
                            .help("Moves .dante/ to the Trash. The code isn’t touched.")
                    }
                }
            } header: {
                Text("Dante setup")
            }
            SwiftUI.Section {
                LabeledContent("Saved database connections") {
                    HStack {
                        Text(savedConnections == 0 ? "None" : "\(savedConnections)").foregroundStyle(theme.text2.color)
                        Button("Forget…") { confirmsForget = true }
                            .disabled(savedConnections == 0)
                    }
                }
            } header: {
                Text("Kept on this Mac")
            }
            if let message {
                Text(message).font(.dante(size: 12)).foregroundStyle(theme.text2.color)
            }
        }
        .confirmationDialog("Move .dante to the Trash?", isPresented: $confirmsRemoval) {
            Button("Move to Trash", role: .destructive) { removeDante() }
        } message: {
            Text("Claude’s rules for this project go with it. You can restore the folder from the Trash.")
        }
        .confirmationDialog("Forget the saved connections?", isPresented: $confirmsForget) {
            Button("Forget", role: .destructive) {
                try? ConnectionStore().removeAll(for: workspace.url)
                message = "Saved connections forgotten."
            }
        }
    }

    private func removeDante() {
        do {
            try FileManager.default.trashItem(at: workspace.danteFolder, resultingItemURL: nil)
            workspace.reloadSpec()
            message = "Moved .dante to the Trash."
        } catch {
            message = "Couldn’t move .dante to the Trash: \(error.localizedDescription)"
        }
    }
}

// MARK: Keyboard

private struct KeyboardPane: View {
    @Environment(\.theme) private var theme
    private let shortcuts = Shortcuts.shared
    @State private var recording: String?

    private var menus: [String] {
        var seen: [String] = []
        for command in Shortcuts.commands where !seen.contains(command.menu) { seen.append(command.menu) }
        return seen
    }

    var body: some View {
        Form {
            ForEach(menus, id: \.self) { menu in
                SwiftUI.Section(menu) {
                    ForEach(Shortcuts.commands.filter { $0.menu == menu }) { command in
                        row(command)
                    }
                }
            }
            SwiftUI.Section {
                HStack {
                    Spacer()
                    Button("Restore All Defaults") { shortcuts.reset() }
                        .disabled(shortcuts.overrides.isEmpty)
                }
            }
        }
        .background(KeyRecorder(isActive: recording != nil) { event in
            guard let id = recording else { return }
            if event.keyCode == 53 { recording = nil; return }
            if event.keyCode == 51, event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function).isEmpty {
                shortcuts.set(nil, for: id)
                recording = nil
                return
            }
            if let binding = KeyBinding(event: event) {
                shortcuts.set(binding, for: id)
                recording = nil
            }
        })
    }

    private func row(_ command: ShortcutCommand) -> some View {
        let binding = shortcuts.binding(command.id)
        let conflicts = binding.map { shortcuts.conflicts($0, except: command.id) } ?? []
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(command.title)
                Spacer()
                if shortcuts.isChanged(command.id) {
                    Button { shortcuts.reset(command.id) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.text3.color)
                        .help("Back to \(command.defaultBinding?.display ?? "no shortcut")")
                }
                Button { recording = recording == command.id ? nil : command.id } label: {
                    Text(recording == command.id ? "Type a shortcut…" : binding?.display ?? "None")
                        .font(.dante(size: 12, design: .monospaced))
                        .foregroundStyle(recording == command.id ? theme.accent.color : binding == nil ? theme.text3.color : theme.text.color)
                        .frame(minWidth: 110)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(recording == command.id ? theme.accentTint.color : theme.raised.color))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(recording == command.id ? theme.accentLine.color : theme.line2.color))
                }
                .buttonStyle(.plain)
            }
            if !conflicts.isEmpty {
                Text("Also on \(conflicts.map(\.title).joined(separator: ", ")); whichever is available at the time runs.")
                    .font(.dante(size: 11)).foregroundStyle(theme.amber.color)
            }
            if MenuShortcuts.shared.needsRestart.contains(command.id) {
                Text("The menu shows this after Dante restarts.")
                    .font(.dante(size: 11)).foregroundStyle(theme.text3.color)
            }
        }
    }
}

/// Hands key presses to `record` while a shortcut is being recorded, and swallows them.
private struct KeyRecorder: NSViewRepresentable {
    let isActive: Bool
    let record: @MainActor (NSEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard coordinator.isActive else { return event }
            MainActor.assumeIsolated { coordinator.record?(event) }
            return nil
        }
        return NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.record = record
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    @MainActor
    final class Coordinator {
        var isActive = false
        var record: (@MainActor (NSEvent) -> Void)?
        var monitor: Any?
    }
}

// MARK: Languages

private struct LanguagesPane: View {
    @Environment(\.theme) private var theme
    @State private var options: [String: LanguageServerOptions] = LanguageServerOptions.load()
    @State private var saved: [String: LanguageServerOptions] = LanguageServerOptions.load()

    var body: some View {
        Form {
            ForEach(LanguageServer.all, id: \.name) { server in
                SwiftUI.Section {
                    Toggle("Run \(server.name)", isOn: binding(server.name, \.enabled))
                    TextField("Command", text: binding(server.name, \.command),
                              prompt: Text(server.commands.map { $0.joined(separator: " ") }.joined(separator: "  or  ")))
                        .font(.dante(size: 12, design: .monospaced))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Settings (JSON)").font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                        TextEditor(text: binding(server.name, \.settings))
                            .font(.dante(size: 12, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(5)
                            .frame(height: 70)
                            .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line.color))
                        if let error = options[server.name]?.settingsError {
                            Text(error).font(.dante(size: 11)).foregroundStyle(theme.red.color)
                        }
                    }
                    if (options[server.name] ?? LanguageServerOptions()) != (saved[server.name] ?? LanguageServerOptions()) {
                        HStack {
                            Spacer()
                            Button("Revert") { options[server.name] = saved[server.name] }
                            Button("Apply and Restart") { apply(server.name) }
                                .buttonStyle(.borderedProminent)
                                .disabled(options[server.name]?.settingsError != nil)
                        }
                    }
                } header: {
                    Text("\(server.name) · \(server.languageIDs.keys.map(\.displayName).sorted().joined(separator: ", "))")
                }
            }
        }
    }

    private func binding<Value>(_ name: String, _ path: WritableKeyPath<LanguageServerOptions, Value>) -> Binding<Value> {
        Binding(get: { (options[name] ?? LanguageServerOptions())[keyPath: path] },
                set: { value in var current = options[name] ?? LanguageServerOptions(); current[keyPath: path] = value; options[name] = current })
    }

    private func apply(_ name: String) {
        LanguageServerOptions.save(options)
        saved = options
        // Every window restarts it; files already open in that language get it back right away.
        for session in Sessions.all {
            session.languages?.restart(name)
            guard let workspace = session.workspace else { continue }
            for document in workspace.documents where LanguageServer.for(document.language)?.name == name {
                session.languages?.opened(document)
            }
        }
    }
}
