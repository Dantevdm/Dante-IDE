import AppKit
import DanteKit
import SwiftUI

/// The new-database wizard: pick an engine (Dante suggests the one the code uses), set
/// it up, see exactly which files change, then create it and start it.
struct NewDatabaseSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let session: Session
    let workspace: Workspace

    @State private var step = 0
    @State private var plan: NewDatabasePlan
    @State private var showsPassword = false
    @State private var startNow = true
    @State private var askClaude = true
    @State private var creating = false
    @State private var error: String?
    private let compose: ComposeFile?
    private let hasDocker = Shell.which("docker") != nil

    init(session: Session, workspace: Workspace) {
        self.session = session
        self.workspace = workspace
        let compose = ComposeFile.load(projectRoot: workspace.url)
        self.compose = compose
        let engine = session.data.profile.suggestedEngine ?? .postgres
        _plan = State(initialValue: Self.plan(for: engine, workspace: workspace, compose: compose))
    }

    static func plan(for engine: DatabaseEngine, workspace: Workspace, compose: ComposeFile?) -> NewDatabasePlan {
        let taken = Set((compose?.services ?? []).flatMap(\.ports).compactMap { port in
            port.split(separator: ":").dropLast().last.flatMap { Int($0) }
        })
        let port = engine.defaultPort.map { PortProbe.firstFree(from: $0, skipping: taken) }
        var plan = NewDatabasePlan(engine: engine, project: workspace.name, port: port)
        plan.service = ComposeEditing.freeServiceName("db", taken: compose?.services.map(\.name) ?? [])
        let keys = [".env", ".env.example"].flatMap { name in
            EnvFile.parse((try? String(contentsOf: workspace.url.appending(path: name), encoding: .utf8)) ?? "").map(\.key)
        }
        plan.avoidTakenKeys(Set(keys))
        return plan
    }

    private let steps = ["Engine", "Settings", "Review"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(theme.line.color).frame(height: 1)
            ScrollView {
                Group {
                    switch step {
                    case 0: engineStep
                    case 1: settingsStep
                    default: reviewStep
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 430)
            Rectangle().fill(theme.line.color).frame(height: 1)
            footer
        }
        .frame(width: 640)
        .background(theme.card.color)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "cylinder.split.1x2.fill").font(.dante(size: 18)).foregroundStyle(theme.accent.color)
            VStack(alignment: .leading, spacing: 2) {
                Text("New database").font(.dante(size: 16, weight: .semibold)).foregroundStyle(theme.text.color)
                Text("For \(workspace.name), on this Mac").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { index in
                    HStack(spacing: 5) {
                        Text("\(index + 1)")
                            .font(.dante(size: 10, weight: .bold))
                            .foregroundStyle(index <= step ? theme.onAccent.color : theme.text3.color)
                            .frame(width: 17, height: 17)
                            .background(Circle().fill(index <= step ? theme.accent.color : theme.raised.color))
                        Text(steps[index]).font(.dante(size: 11.5, weight: index == step ? .semibold : .regular))
                            .foregroundStyle(index == step ? theme.text.color : theme.text3.color)
                    }
                    if index < steps.count - 1 { Rectangle().fill(theme.line2.color).frame(width: 14, height: 1) }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    // MARK: Steps

    private var engineStep: some View {
        let profile = session.data.profile
        return VStack(alignment: .leading, spacing: 12) {
            Text("Which database?").font(.dante(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
            ForEach(DatabaseEngine.allCases) { engine in
                let reasons = profile.signals.filter { $0.engine == engine }.map(\.label)
                let selected = plan.engine == engine
                Button {
                    plan = Self.plan(for: engine, workspace: workspace, compose: compose)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        EngineBadge(engine: engine, size: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(engine.name).font(.dante(size: 13.5, weight: .semibold)).foregroundStyle(theme.text.color)
                                if engine == profile.suggestedEngine { Chip(text: "The code uses this", color: theme.accent.color) }
                            }
                            Text(description(engine)).font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                                .fixedSize(horizontal: false, vertical: true)
                            if !reasons.isEmpty {
                                Text("Found: " + reasons.prefix(3).joined(separator: ", "))
                                    .font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                            }
                        }
                        Spacer()
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.dante(size: 16))
                            .foregroundStyle(selected ? theme.accent.color : theme.line2.color)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? theme.accentTint.color : theme.panel.color))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? theme.accentLine.color : theme.line.color))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func description(_ engine: DatabaseEngine) -> String {
        switch engine {
        case .postgres: "Runs in Docker (\(engine.image!)) with a named volume, so data survives restarts. The usual choice for web apps."
        case .mysql: "Runs in Docker (\(engine.image!)) with a named volume. Pick it if production runs MySQL or MariaDB."
        case .sqlite: "A single file in the repo. No server, nothing to start; good for tools, prototypes and local-first apps."
        }
    }

    @ViewBuilder
    private var settingsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if plan.engine == .sqlite {
                dataField("File", detail: "Relative to the project. Commit it with seed data, or add it to .gitignore.") {
                    TextField("data/app.sqlite", text: $plan.file).textFieldStyle(.roundedBorder).font(.dante(size: 12.5, design: .monospaced))
                }
                dataField("Env variable", detail: "Where the app reads the location from.") {
                    TextField("DATABASE_URL", text: $plan.envKey).textFieldStyle(.roundedBorder).font(.dante(size: 12.5, design: .monospaced))
                }
            } else {
                if !hasDocker {
                    DataNote(symbol: "exclamationmark.triangle.fill", color: theme.amber.color,
                             text: "Docker isn’t installed, so Dante can write the compose service but not start it. Install Docker Desktop or OrbStack first.")
                }
                HStack(spacing: 14) {
                    dataField("Database") { TextField("app", text: $plan.name).textFieldStyle(.roundedBorder).font(.dante(size: 12.5, design: .monospaced)) }
                    dataField("User") { TextField("app", text: $plan.user).textFieldStyle(.roundedBorder).font(.dante(size: 12.5, design: .monospaced)) }
                }
                HStack(alignment: .top, spacing: 14) {
                    dataField("Port on this Mac", detail: PortProbe.isFree(plan.port) ? "Free" : "In use: the service won’t start on it") {
                        TextField("5432", value: $plan.port, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).font(.dante(size: 12.5, design: .monospaced))
                    }
                    dataField("Compose service") { TextField("db", text: $plan.service).textFieldStyle(.roundedBorder).font(.dante(size: 12.5, design: .monospaced)) }
                }
                dataField("Image") {
                    Picker("", selection: $plan.image) {
                        ForEach(images, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                dataField("Password", detail: "Generated. It goes in .env (git-ignored) and the Keychain, never in compose.yaml.") {
                    HStack(spacing: 6) {
                        Group {
                            if showsPassword {
                                TextField("", text: $plan.password)
                            } else {
                                SecureField("", text: $plan.password)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.dante(size: 12.5, design: .monospaced))
                        IconButton(symbol: showsPassword ? "eye.slash" : "eye", label: showsPassword ? "Hide" : "Show") { showsPassword.toggle() }
                        IconButton(symbol: "arrow.triangle.2.circlepath", label: "Generate another") { plan.password = NewDatabasePlan.makePassword() }
                    }
                }
                dataField("Env variable") {
                    TextField("DATABASE_URL", text: $plan.envKey).textFieldStyle(.roundedBorder).font(.dante(size: 12.5, design: .monospaced))
                }
            }
        }
    }

    private var images: [String] {
        switch plan.engine {
        case .postgres: ["postgres:17-alpine", "postgres:16-alpine", "postgres:15-alpine", "pgvector/pgvector:pg17", "postgis/postgis:17-3.5-alpine"]
        case .mysql: ["mysql:8.4", "mysql:9", "mariadb:11"]
        case .sqlite: []
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dante will change these files").font(.dante(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
            if plan.engine != .sqlite {
                FileChange(path: compose?.url.lastPathComponent ?? "compose.yaml", action: compose == nil ? "new file" : "adds the \(plan.service) service and its volume",
                           lines: plan.composeService)
            } else {
                FileChange(path: plan.file, action: "new, empty database", lines: [])
            }
            FileChange(path: ".env", action: FileManager.default.fileExists(atPath: workspace.url.appending(path: ".env").path) ? "sets \(plan.envValues.map(\.key).joined(separator: ", "))" : "new file, git-ignored",
                       lines: plan.envValues.map { "\($0.key)=\($0.value.replacingOccurrences(of: plan.password, with: "••••••••"))" },
                       replaces: plan.replacedKeys(in: try? String(contentsOf: workspace.url.appending(path: ".env"), encoding: .utf8)))
            FileChange(path: ".env.example", action: "so others know what to set", lines: plan.exampleValues.map { "\($0.key)=\($0.value)" },
                       replaces: plan.replacedKeys(in: try? String(contentsOf: workspace.url.appending(path: ".env.example"), encoding: .utf8)))
            if GitIgnore.ensuring([".env"], in: try? String(contentsOf: workspace.url.appending(path: ".gitignore"), encoding: .utf8)) != nil {
                FileChange(path: ".gitignore", action: plan.engine == .sqlite ? "adds .env, so local settings aren’t committed" : "adds .env, so the password isn’t committed", lines: [".env"])
            }
            VStack(alignment: .leading, spacing: 6) {
                if plan.engine != .sqlite {
                    Toggle("Start it now (docker compose up -d \(plan.service))", isOn: $startNow).disabled(!hasDocker)
                }
                Toggle("Ask Claude to connect the app: client library, migrations and a first schema", isOn: $askClaude)
            }
            .toggleStyle(.checkbox)
            .font(.dante(size: 12.5))
            .foregroundStyle(theme.text.color)
            if let error {
                DataNote(symbol: "xmark.octagon.fill", color: theme.red.color, text: error)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }.buttonStyle(DanteButtonStyle()).keyboardShortcut(.cancelAction)
            Spacer()
            if step > 0 {
                Button("Back") { step -= 1 }.buttonStyle(DanteButtonStyle())
            }
            if step < steps.count - 1 {
                Button("Continue") { step += 1 }
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == 1 && !settingsValid)
            } else {
                Button(creating ? "Creating…" : "Create \(plan.engine.name)") { Task { await create() } }
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var settingsValid: Bool {
        if plan.engine == .sqlite { return !plan.file.trimmingCharacters(in: .whitespaces).isEmpty }
        return !plan.name.isEmpty && !plan.user.isEmpty && !plan.password.isEmpty && !plan.service.isEmpty && (1...65535).contains(plan.port)
    }

    // MARK: Creating

    private func create() async {
        creating = true
        defer { creating = false }
        let root = workspace.url
        do {
            if plan.engine == .sqlite {
                let url = root.appending(path: plan.file)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    // An empty file is an empty SQLite database.
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
            } else {
                let composeURL = compose?.url ?? root.appending(path: "compose.yaml")
                let existing = try? String(contentsOf: composeURL, encoding: .utf8)
                try ComposeEditing.adding(service: plan.composeService, volume: plan.volume, to: existing).write(to: composeURL, atomically: true, encoding: .utf8)
            }
            let envURL = root.appending(path: ".env")
            try EnvFile.setting(plan.envValues, in: try? String(contentsOf: envURL, encoding: .utf8), comment: "\(plan.engine.name) for local development, added by Dante")
                .write(to: envURL, atomically: true, encoding: .utf8)
            let exampleURL = root.appending(path: ".env.example")
            try EnvFile.setting(plan.exampleValues, in: try? String(contentsOf: exampleURL, encoding: .utf8), comment: "\(plan.engine.name) for local development")
                .write(to: exampleURL, atomically: true, encoding: .utf8)
            let ignoreURL = root.appending(path: ".gitignore")
            if let ignore = GitIgnore.ensuring([".env"], in: try? String(contentsOf: ignoreURL, encoding: .utf8)) {
                try ignore.write(to: ignoreURL, atomically: true, encoding: .utf8)
            }
        } catch {
            self.error = "Couldn’t write the files: \(error.localizedDescription)"
            return
        }
        let connection = plan.connection
        let model = session.data
        model.save(connection, password: plan.engine == .sqlite ? nil : plan.password)
        if askClaude {
            session.askClaude(
                "I just created a \(plan.engine.name) database for this project with Dante (\(connection.displayURL)\(plan.engine == .sqlite ? "" : ", Docker Compose service \"\(plan.service)\"")); the app should read it from \(plan.envKey) in .env. Connect the app to it: add the client library or ORM that fits this stack (or use the one already here), set up migrations, and ask me what the app needs to store before you design the first schema.",
                instructions: DataContext.describe(connection, schema: nil)
            )
        }
        dismiss()
        if plan.engine != .sqlite, startNow, hasDocker {
            await model.start(connection)
        }
    }
}

private struct FileChange: View {
    @Environment(\.theme) private var theme
    let path: String
    let action: String
    let lines: [String]
    var replaces: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                Text(path).font(.dante(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(theme.text.color)
                Text(action).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                Spacer()
                if !replaces.isEmpty {
                    Label("replaces \(replaces.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                        .font(.dante(size: 11))
                        .foregroundStyle(theme.amber.color)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if !lines.isEmpty {
                Rectangle().fill(theme.line.color).frame(height: 1)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 8) {
                            Text("+").foregroundStyle(theme.green.color)
                            Text(line).foregroundStyle(theme.text.color)
                        }
                        .font(.dante(size: 11.5, design: .monospaced))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.green.color.opacity(0.05))
            }
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.panel.color))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.line.color))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct DataNote: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.dante(size: 12)).foregroundStyle(theme.text.color).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.3)))
    }
}

/// A labelled form field for the data sheets.
@MainActor func dataField(_ label: String, detail: String? = nil, @ViewBuilder content: () -> some View) -> some View {
    DataField(label: label, detail: detail, content: content())
}

private struct DataField<Content: View>: View {
    @Environment(\.theme) private var theme
    let label: String
    let detail: String?
    let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.dante(size: 12)).foregroundStyle(theme.text2.color)
            content
            if let detail {
                Text(detail).font(.dante(size: 11)).foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
