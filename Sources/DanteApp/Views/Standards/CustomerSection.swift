import AppKit
import DanteKit
import SwiftUI

/// Docs › Standards › Customer: the customers in the company library and which of them, and
/// which of their parts, apply to this project. What applies goes to the agents (their brief,
/// the customer tools, their MCP servers, notes on edits) and is checked against the code.
struct CustomerSection: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    @State private var findings: [CustomerFinding]?
    @State private var naming = false
    @State private var newName = ""
    @State private var error: String?
    @State private var remotes: [String] = []

    private var library: [CustomerProfile] { workspace.customerLibrary }
    private var choice: CustomerChoice { workspace.customerChoice }
    private var applied: [CustomerProfile] { library.filter { choice.customers.contains($0.id) } }
    private var others: [CustomerProfile] { library.filter { !choice.customers.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.square.filled.and.at.rectangle").font(.dante(size: 11, weight: .medium)).foregroundStyle(theme.text3.color)
                Eyebrow("Customer")
                Spacer()
                if let folder = customersFolder, FileManager.default.fileExists(atPath: folder.path) {
                    IconButton(symbol: "folder", label: "Show the customers folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                }
                Button { naming = true } label: { Label("New customer", systemImage: "plus") }
                    .buttonStyle(DanteButtonStyle())
                    .help("Starts customers/<name>/customer.yaml in the company library: their rules, naming, processes, infrastructure, theme, skills and MCP servers, to fill in")
            }
            if let error { Text(error).font(.dante(size: 12)).foregroundStyle(theme.red.color) }
            ForEach(applied) { profile in AppliedCustomerCard(session: session, workspace: workspace, profile: profile, findings: findings?.filter { $0.customer == profile.name }) }
            if library.isEmpty {
                Card {
                    Text("A customer is how you always work for them: rules the code keeps, naming standards, processes like an RFC before an infrastructure change, the infrastructure tool they always use, their theme, the skills that know their world and MCP servers of their own. Each lives in the company library, outside every repo; you choose per project which apply, and the agents follow them.")
                        .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                    Button("New customer…") { naming = true }.buttonStyle(DanteButtonStyle(primary: true))
                }
            } else if !others.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(others.enumerated()), id: \.element.id) { index, profile in
                        if index > 0 { Rectangle().fill(theme.line.color).frame(height: 1) }
                        otherRow(profile)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line.color))
            }
        }
        .padding(.bottom, 6)
        .task(id: "\(workspace.revision)#\(choice.customers.joined())#\(choice.off.joined())#\(library.count)") { await check() }
        .task(id: workspace.git.root) { remotes = Self.remotes(in: workspace.git.root) }
        .sheet(isPresented: $naming) { newCustomerSheet }
    }

    private var customersFolder: URL? { Preferences.shared.standardsLibraryURL?.appending(path: "customers", directoryHint: .isDirectory) }

    private func otherRow(_ profile: CustomerProfile) -> some View {
        let reason = CustomerDetect.reason(profile, remotes: remotes, projectPath: workspace.url.path, files: workspace.files)
        return HStack(spacing: 10) {
            Image(systemName: reason == nil ? "person.crop.square" : "sparkle.magnifyingglass").font(.dante(size: 13)).foregroundStyle(theme.accent.color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.dante(size: 13, weight: .medium)).foregroundStyle(theme.text.color)
                Text(reason.map { "Looks like theirs: \($0)" } ?? (profile.summary.isEmpty ? Self.counts(profile) : profile.summary))
                    .font(.dante(size: 11.5)).foregroundStyle(reason == nil ? theme.text3.color : theme.accent.color).lineLimit(1)
            }
            Spacer()
            Button { openFile(profile) } label: { Text("Edit") }.buttonStyle(DanteButtonStyle())
            Button { setApplied(profile, true) } label: { Text("Apply to this project") }
                .buttonStyle(DanteButtonStyle(primary: reason != nil))
                .help("Their rules, naming, processes and the rest apply to this project on this Mac: the agents follow them and Dante checks the code. Nothing is written into the repo.")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var newCustomerSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New customer").font(.dante(size: 15, weight: .semibold)).foregroundStyle(theme.text.color)
            Text("Starts a customer.yaml in the company library with every section to fill in, and opens it.")
                .font(.dante(size: 12)).foregroundStyle(theme.text2.color)
            TextField("Their name", text: $newName).textFieldStyle(.roundedBorder).onSubmit(create)
            HStack {
                Spacer()
                Button("Cancel") { naming = false }.buttonStyle(DanteButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Create") { create() }.buttonStyle(DanteButtonStyle(primary: true)).disabled(ThemeMaker.slug(newName).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(theme.panel.color)
    }

    private func create() {
        guard let library = Preferences.shared.standardsLibraryURL, !ThemeMaker.slug(newName).isEmpty else { return }
        do {
            let file = try CustomerLibrary.create(name: newName, in: library)
            naming = false
            newName = ""
            error = nil
            session.open(file: file)
            Task { await workspace.reloadStandards(library: library) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func openFile(_ profile: CustomerProfile) {
        if let file = profile.file { session.open(file: file) }
    }

    private func setApplied(_ profile: CustomerProfile, _ on: Bool) {
        var next = choice
        next.apply(profile.id, on)
        workspace.setCustomerChoice(next)
        session.applyClaudePreferences()
    }

    private func check() async {
        let customers = workspace.customers
        guard !customers.isEmpty else { findings = nil; return }
        let root = workspace.url, files = workspace.files
        let found = await Task.detached(priority: .utility) {
            CustomerCheck.run(customers, files: files, read: { CustomerCheck.readText(root.appending(path: $0)) })
        }.value
        if !Task.isCancelled { findings = found }
    }

    static func counts(_ profile: CustomerProfile) -> String {
        var parts: [String] = []
        if let infrastructure = profile.infrastructure { parts.append(infrastructure.toolName) }
        if !profile.rules.isEmpty { parts.append("\(profile.rules.count) rule\(profile.rules.count == 1 ? "" : "s")") }
        if !profile.naming.isEmpty { parts.append("\(profile.naming.count) naming") }
        if !profile.process.isEmpty { parts.append("\(profile.process.count) process\(profile.process.count == 1 ? "" : "es")") }
        return parts.isEmpty ? "Nothing filled in yet" : parts.joined(separator: " · ")
    }

    /// The repository's remote URLs, from .git/config.
    static func remotes(in root: URL) -> [String] {
        guard let config = try? String(contentsOf: root.appending(path: ".git/config"), encoding: .utf8) else { return [] }
        return config.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("url") , let equals = trimmed.firstIndex(of: "=") else { return nil }
            return trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "/")
        }
    }
}

/// One applied customer: every part with a switch, and what the check found.
private struct AppliedCustomerCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let profile: CustomerProfile
    let findings: [CustomerFinding]?

    private var choice: CustomerChoice { workspace.customerChoice }

    var body: some View {
        Card(profile.name, accent: true) {
            HStack(spacing: 8) {
                if let findings {
                    Chip(text: findings.isEmpty ? "Keeps every checked rule" : "\(findings.count) to look at",
                         symbol: findings.isEmpty ? "checkmark.circle" : "exclamationmark.triangle",
                         color: findings.isEmpty ? theme.green.color : findings.contains { $0.severity == .blocker } ? theme.red.color : theme.amber.color)
                }
                Button("Edit") { if let file = profile.file { session.open(file: file) } }.buttonStyle(DanteButtonStyle())
                    .help("Opens customer.yaml from the company library")
                Button("Stop applying") {
                    var next = choice
                    next.apply(profile.id, false)
                    workspace.setCustomerChoice(next)
                    session.applyClaudePreferences()
                }
                .buttonStyle(DanteButtonStyle())
            }
        } content: {
            if !profile.summary.isEmpty {
                Text(profile.summary).font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
            }
            ForEach(profile.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle").font(.dante(size: 12)).foregroundStyle(theme.amber.color)
            }
            if let infrastructure = profile.infrastructure {
                part("Infrastructure", key: "infrastructure") {
                    Text(infrastructure.sentence + infrastructure.notes.map { " " + $0 }.joined()).font(.dante(size: 12.5)).foregroundStyle(theme.text.color)
                }
            }
            if let name = profile.theme {
                part("Theme", key: "theme") {
                    HStack(spacing: 8) {
                        Chip(text: name, symbol: "swatchpalette", mono: true)
                        if !(workspace.standards?.themeSets.contains { $0.themes.contains { $0.name == name } } ?? false) {
                            Text("Not in the library’s themes yet").font(.dante(size: 11.5)).foregroundStyle(theme.amber.color)
                        }
                    }
                }
            }
            if !profile.rules.isEmpty {
                group("Rules") {
                    ForEach(profile.rules) { rule in
                        row(key: CustomerProfile.key("rule", rule.id)) {
                            HStack(spacing: 6) {
                                severity(rule.severity)
                                Text(rule.title).font(.dante(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color)
                                Text(rule.isCheckable ? "Checked" : "Told to the agents").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                            }
                            if !rule.detail.isEmpty { Text(rule.detail).font(.dante(size: 12)).foregroundStyle(theme.text2.color) }
                        }
                    }
                }
            }
            if !profile.naming.isEmpty {
                group("Naming") {
                    ForEach(profile.naming) { naming in
                        row(key: CustomerProfile.key("naming", naming.id)) {
                            Text(naming.what).font(.dante(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color)
                            Text(naming.shape ?? naming.pattern ?? "").font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text2.color).textSelection(.enabled)
                        }
                    }
                }
            }
            if !profile.process.isEmpty {
                group("Process") {
                    ForEach(profile.process) { process in
                        row(key: CustomerProfile.key("process", process.id)) {
                            Text(process.title).font(.dante(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color)
                            if !process.when.isEmpty { Text(process.when).font(.dante(size: 12)).foregroundStyle(theme.text2.color) }
                            ForEach(Array(process.steps.enumerated()), id: \.offset) { index, step in
                                Text("\(index + 1). \(step)").font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                            }
                        }
                    }
                }
            }
            if !profile.skills.isEmpty || !profile.servers.isEmpty {
                group("Skills and MCP servers") {
                    ForEach(profile.skills) { skill in
                        row(key: CustomerProfile.key("skill", skill.name)) {
                            HStack(spacing: 6) {
                                Image(systemName: "graduationcap").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                                Text(skill.name).font(.dante(size: 12.5, weight: .medium, design: .monospaced)).foregroundStyle(theme.text.color)
                                if let when = skill.when { Text(when).font(.dante(size: 12)).foregroundStyle(theme.text2.color) }
                            }
                        }
                    }
                    ForEach(profile.servers) { server in
                        row(key: CustomerProfile.key("mcp", server.name)) {
                            HStack(spacing: 6) {
                                Image(systemName: "server.rack").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                                Text(server.name).font(.dante(size: 12.5, weight: .medium, design: .monospaced)).foregroundStyle(theme.text.color)
                                Text(server.summary).font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color).lineLimit(1)
                            }
                        }
                    }
                }
            }
            if let findings, !findings.isEmpty {
                group("What the check found") {
                    ForEach(findings.prefix(40)) { finding in
                        Button { open(finding) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                severity(finding.severity)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(finding.title).font(.dante(size: 12, weight: .medium)).foregroundStyle(theme.text.color)
                                    Text(finding.detail).font(.dante(size: 11.5)).foregroundStyle(theme.text2.color).lineLimit(2)
                                }
                                Spacer()
                                if let file = finding.file {
                                    Text(file + (finding.line.map { ":\($0)" } ?? "")).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color).lineLimit(1)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(finding.file == nil)
                    }
                    if findings.count > 40 {
                        Text("…and \(findings.count - 40) more").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                    }
                }
            }
            if profile.isEmpty, profile.problems.isEmpty {
                Text("Nothing filled in yet: Edit opens customer.yaml.").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
            }
        }
    }

    private func open(_ finding: CustomerFinding) {
        guard let file = finding.file else { return }
        let url = workspace.url.appending(path: file)
        if let line = finding.line { session.open(file: url, line: line) } else { session.open(file: url) }
    }

    private func severity(_ severity: CustomerProfile.Severity) -> some View {
        let color: Color = switch severity {
        case .blocker: theme.red.color
        case .issue: theme.amber.color
        case .note: theme.text3.color
        }
        return Text(severity.rawValue.uppercased())
            .font(.dante(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.dante(size: 10, weight: .semibold)).foregroundStyle(theme.text3.color)
            content()
        }
        .padding(.top, 4)
    }

    private func part<Content: View>(_ title: String, key: String, @ViewBuilder content: () -> Content) -> some View {
        group(title) { row(key: key, content: content) }
    }

    /// A part with its switch: on applies it to this project.
    private func row<Content: View>(key: String, @ViewBuilder content: () -> Content) -> some View {
        let on = choice.isOn(profile.id, key)
        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { on }, set: { value in
                var next = choice
                next.set(profile.id, key, on: value)
                workspace.setCustomerChoice(next)
                session.applyClaudePreferences()
            }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(on ? "Applies to this project. Switch off to leave it out here." : "Left out of this project")
            VStack(alignment: .leading, spacing: 3) { content() }
                .opacity(on ? 1 : 0.45)
            Spacer(minLength: 0)
        }
    }
}
