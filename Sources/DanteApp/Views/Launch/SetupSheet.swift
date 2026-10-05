import DanteKit
import SwiftUI

/// Offered when a project without `.dante/project.yaml` opens: what Dante worked out from
/// the files and history, the lifecycle and phase to start at, and what Claude should fill
/// in. Dante writes the skeleton straight away; Claude's edits come through for review.
struct SetupSheet: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let profile: ProjectProfile

    @State private var templateID: String
    @State private var phase: String
    @State private var parts: Set<ProjectSetupRequest.Part>

    init(session: Session, workspace: Workspace, profile: ProjectProfile) {
        self.session = session
        self.workspace = workspace
        self.profile = profile
        _templateID = State(initialValue: profile.template.id)
        _phase = State(initialValue: profile.phase)
        _parts = State(initialValue: ProjectSetupRequest.defaultParts(for: profile))
    }

    private var template: LifecycleTemplate { LifecycleTemplate.named(templateID) ?? profile.template }
    private var request: ProjectSetupRequest { ProjectSetupRequest(template: template, phase: phase, parts: parts) }
    private var claudeReady: Bool { session.claude != nil && !isUnavailable }
    private var isUnavailable: Bool {
        if case .unavailable = session.claude?.state { true } else { false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 18)).foregroundStyle(theme.accent.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up \(workspace.name) for Dante").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text.color)
                    Text("This project has no .dante folder yet. Here’s what Dante found; Claude can fill in the rest.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.text2.color)
                }
            }

            found

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Lifecycle").font(.system(size: 12)).foregroundStyle(theme.text2.color)
                    Picker("Lifecycle", selection: $templateID) {
                        ForEach(LifecycleTemplate.all) { option in
                            Text(option.id == profile.template.id ? "\(option.name) (suggested)" : option.name).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text(template.phaseNames.joined(separator: " → "))
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.text3.color)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Current phase").font(.system(size: 12)).foregroundStyle(theme.text2.color)
                    Picker("Current phase", selection: $phase) {
                        ForEach(template.phaseNames, id: \.self) { name in Text(name).tag(name) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text(profile.stageReason)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.text3.color)
                }
                .frame(width: 210, alignment: .leading)
            }
            .onChange(of: templateID) {
                phase = template.phase(phase)?.name ?? ProjectProfile.phase(for: profile.stage, in: template)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Have Claude fill in").font(.system(size: 12)).foregroundStyle(theme.text2.color)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(ProjectSetupRequest.Part.allCases) { part in
                        Toggle(isOn: Binding(
                            get: { parts.contains(part) },
                            set: { on in if on { parts.insert(part) } else { parts.remove(part) } }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(part.title).font(.system(size: 12.5)).foregroundStyle(theme.text.color)
                                Text(detail(for: part)).font(.system(size: 11.5)).foregroundStyle(theme.text3.color)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) {
                            if part != ProjectSetupRequest.Part.allCases.first { Rectangle().fill(theme.line.color).frame(height: 1) }
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.panel.color))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.line.color))
                .disabled(!claudeReady)
                if !claudeReady {
                    Text("Claude Code isn’t available, so Dante can only create the files from the template.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.amber.color)
                }
            }

            HStack {
                Button("Not now") { session.declineSetup() }
                    .buttonStyle(DanteButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .help("Dante won’t ask again for this project. Set it up later from File or Plan.")
                Spacer()
                Button("Just create the files") {
                    session.setUpProject(ProjectSetupRequest(template: template, phase: phase, parts: []))
                }
                .buttonStyle(DanteButtonStyle())
                .help("project.yaml, a checklist per phase and an empty task list, from the template")
                Button(parts.isEmpty || !claudeReady ? "Create files" : "Set up with Claude") {
                    session.setUpProject(claudeReady ? request : ProjectSetupRequest(template: template, phase: phase, parts: []))
                }
                .buttonStyle(DanteButtonStyle(primary: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600)
        .background(theme.card.color)
    }

    private var found: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 5) {
                ForEach(profile.stack, id: \.self) { item in chip(item, symbol: "shippingbox") }
                chip("\(profile.sourceFiles) source files", symbol: "doc.text")
                chip(profile.testFiles == 0 ? "no tests found" : "\(profile.testFiles) test files", symbol: "checkmark.diamond")
                if profile.commits > 0 { chip("\(profile.commits) commits", symbol: "clock.arrow.circlepath") }
                if profile.tags > 0 { chip("\(profile.tags) tags", symbol: "tag") }
                if let test = profile.testCommand { chip(test, symbol: "play") }
                if !profile.sensitivePaths.isEmpty { chip("secrets: \(profile.sensitivePaths.joined(separator: ", "))", symbol: "lock", warning: true) }
            }
            if let summary = profile.summary {
                Text("“\(summary)”")
                    .font(.system(size: 12))
                    .italic()
                    .foregroundStyle(theme.text2.color)
                    .lineLimit(3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.panel.color))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.line.color))
    }

    private func chip(_ text: String, symbol: String, warning: Bool = false) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11.5))
            .foregroundStyle(warning ? theme.amber.color : theme.text2.color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.raised.color))
            .overlay(Capsule().strokeBorder(theme.line.color))
    }

    private func detail(for part: ProjectSetupRequest.Part) -> String {
        switch part {
        case .tests where profile.testCommand != nil: "Dante found \(profile.testCommand!); Claude can pin it or pick a better one"
        case .rules where !profile.sensitivePaths.isEmpty: "never rules for \(profile.sensitivePaths.joined(separator: ", ")), so Claude can’t read or edit them"
        default: part.detail
        }
    }
}
