import Foundation

/// The parts of a project that run on their own (a web frontend, an API, a worker), found
/// from the code: a package.json with a dev or start script, a Go main package, a Python web
/// app. Each says how it starts and whether the compose file already runs it, so the Env area
/// can offer to run it or add it to compose. Pure; `read` returns a file's text.
public struct RunnableApp: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case frontend, backend
    }

    /// The folder, relative to the project ("" is the root).
    public var folder: String
    public var name: String
    public var kind: Kind
    /// "Next.js", "Go", "FastAPI"…
    public var stack: String
    /// How to start it for development, from its folder.
    public var command: String
    public var hasDockerfile: Bool
    /// The compose service that already runs it.
    public var service: String?
    /// Which of several commands in one folder (a Go module's cmd/api and cmd/worker).
    public var entry: String?

    public var id: String { (folder.isEmpty ? "." : folder) + (entry.map { "#" + $0 } ?? "") }

    public init(folder: String, name: String, kind: Kind, stack: String, command: String, hasDockerfile: Bool = false, service: String? = nil) {
        self.folder = folder
        self.name = name
        self.kind = kind
        self.stack = stack
        self.command = command
        self.hasDockerfile = hasDockerfile
        self.service = service
    }

    /// `command`, run from the project root.
    public var commandFromRoot: String {
        folder.isEmpty ? command : "cd \(Shell.quote(folder)) && \(command)"
    }

    /// Frontends first, then backends, each by folder.
    public static func detect(files: [String], read: (String) -> String?, compose: ComposeFile? = nil) -> [RunnableApp] {
        let skipped = SystemMap.skippedFolders
        let visible = files.filter { file in
            !file.split(separator: "/").dropLast().contains { skipped.contains(String($0)) || $0.hasPrefix(".") }
        }
        var apps: [String: RunnableApp] = [:]
        var commands: [RunnableApp] = []
        for file in visible {
            let folder = (file as NSString).deletingLastPathComponent
            switch (file as NSString).lastPathComponent {
            case "package.json":
                if let text = read(file), let app = node(folder: folder, packageJSON: text, files: visible) { apps[folder] = app }
            case "go.mod":
                commands += go(module: folder, files: visible, read: read)
            case "manage.py":
                apps[folder] = RunnableApp(folder: folder, name: name(of: folder), kind: .backend, stack: "Django", command: "python manage.py runserver")
            case "pyproject.toml", "requirements.txt":
                if apps[folder] == nil, let text = read(file), let app = python(folder: folder, manifest: text, files: visible, read: read) { apps[folder] = app }
            case "pom.xml", "build.gradle", "build.gradle.kts":
                if apps[folder] == nil, let text = read(file), let app = jvm(folder: folder, build: text, maven: file.hasSuffix("pom.xml"), files: visible) { apps[folder] = app }
            case "Cargo.toml":
                if files.contains((folder.isEmpty ? "" : folder + "/") + "src/main.rs") {
                    apps[folder] = RunnableApp(folder: folder, name: name(of: folder), kind: .backend, stack: "Rust", command: "cargo run")
                }
            case let name where name.hasSuffix(".csproj"):
                if let text = read(file), text.contains("Microsoft.NET.Sdk.Web") {
                    apps[folder] = RunnableApp(folder: folder, name: (name as NSString).deletingPathExtension, kind: .backend, stack: ".NET", command: "dotnet watch run")
                }
            default:
                continue
            }
        }
        // A workspace root that only runs its packages (a monorepo) isn't an app of its own.
        if apps[""] != nil, apps.count > 1, let text = read("package.json"), runsWorkspaces(packageJSON: text) {
            apps[""] = nil
        }
        let dockerfiles = Set(visible.filter { ($0 as NSString).lastPathComponent.lowercased() == "dockerfile" }.map { ($0 as NSString).deletingLastPathComponent })
        for app in commands where apps[app.folder] == nil || app.entry != nil {
            if app.entry == nil { apps[app.folder] = app } else { apps[app.id] = app }
        }
        return apps.values.map { app in
            var app = app
            app.hasDockerfile = dockerfiles.contains(app.folder)
            app.service = compose.flatMap { service(for: app, in: $0) }
            return app
        }
        .sorted { ($0.kind == .frontend ? 0 : 1, $0.id) < ($1.kind == .frontend ? 0 : 1, $1.id) }
    }

    /// The compose service built from the app's folder, or named after it.
    static func service(for app: RunnableApp, in compose: ComposeFile) -> String? {
        func normalised(_ context: String) -> String {
            var path = context
            while path.hasPrefix("./") { path.removeFirst(2) }
            while path.hasSuffix("/") { path.removeLast() }
            return path == "." ? "" : path
        }
        let name = app.name.lowercased()
        if let named = compose.services.first(where: { $0.name.lowercased() == name && $0.image == nil }) { return named.name }
        // One of several commands only matches by name; a single app also by its build folder.
        guard app.entry == nil else { return nil }
        return compose.services.first { $0.build.map(normalised) == app.folder }?.name
    }

    static func name(of folder: String) -> String {
        folder.isEmpty ? "app" : (folder as NSString).lastPathComponent
    }

    // MARK: Node

    static let serverPackages: [(String, String)] = [("\"@nestjs/core\"", "NestJS"), ("\"fastify\"", "Fastify"), ("\"express\"", "Express"),
                                                     ("\"koa\"", "Koa"), ("\"hono\"", "Hono"), ("\"@hapi/hapi\"", "hapi")]

    static func node(folder: String, packageJSON text: String, files: [String]) -> RunnableApp? {
        guard let json = JSONValue(line: text.replacingOccurrences(of: "\n", with: " ")), let scripts = json["scripts"]?.object else { return nil }
        guard let script = ["dev", "start:dev", "start", "serve"].first(where: { scripts[$0]?.string?.isEmpty == false }) else { return nil }
        let prefix = folder.isEmpty ? "" : folder + "/"
        let manager = files.contains(prefix + "pnpm-lock.yaml") ? "pnpm" : files.contains(prefix + "yarn.lock") ? "yarn"
            : files.contains(prefix + "bun.lockb") || files.contains(prefix + "bun.lock") ? "bun" : "npm"
        let command = manager == "npm" ? (script == "start" ? "npm start" : "npm run \(script)") : "\(manager) \(script)"
        if let framework = SystemMap.framework(packageJSON: text), !["React Native", "Expo"].contains(framework) {
            return RunnableApp(folder: folder, name: name(of: folder), kind: .frontend, stack: framework, command: command)
        }
        let stack = serverPackages.first { text.contains($0.0) }?.1 ?? (text.contains("\"typescript\"") ? "TypeScript" : "Node")
        return RunnableApp(folder: folder, name: name(of: folder), kind: .backend, stack: stack, command: command)
    }

    /// A root package whose dev script only starts its workspaces (turbo, nx, lerna, pnpm -r).
    static func runsWorkspaces(packageJSON text: String) -> Bool {
        guard let scripts = JSONValue(line: text.replacingOccurrences(of: "\n", with: " "))?["scripts"]?.object,
              let script = ["dev", "start:dev", "start", "serve"].lazy.compactMap({ scripts[$0]?.string }).first else { return false }
        return ["turbo ", "nx ", "lerna ", "pnpm -r", "pnpm --recursive", "--workspaces", "--filter", "yarn workspaces"].contains { script.contains($0) }
    }

    // MARK: Go

    /// Each main package in a module: cmd/<name>/main.go, or main.go beside go.mod.
    static func go(module: String, files: [String], read: (String) -> String?) -> [RunnableApp] {
        let prefix = module.isEmpty ? "" : module + "/"
        var apps: [RunnableApp] = []
        for file in files where file.hasPrefix(prefix) && (file as NSString).lastPathComponent == "main.go" {
            let folder = (file as NSString).deletingLastPathComponent
            let relative = String(folder.dropFirst(prefix.count))
            // Only commands: the module root or cmd/<name>, not examples or tools deeper down.
            guard relative.isEmpty || relative.hasPrefix("cmd/") && relative.split(separator: "/").count == 2 else { continue }
            guard let text = read(file), text.contains("package main") else { continue }
            let target = relative.isEmpty ? "." : "./" + relative
            let name = relative.isEmpty ? name(of: module) : (relative as NSString).lastPathComponent
            apps.append(RunnableApp(folder: module, name: name, kind: .backend, stack: "Go", command: "go run \(target)"))
        }
        // Several commands in one module: each is its own app, told apart by name.
        if apps.count > 1 { apps = apps.map { var app = $0; app.entry = app.name; return app } }
        return apps
    }

    // MARK: JVM

    /// A Spring Boot, Quarkus or Micronaut service, run through the project's wrapper
    /// (mvnw, gradlew) when it has one, in its folder or a parent.
    static func jvm(folder: String, build text: String, maven: Bool, files: [String]) -> RunnableApp? {
        if maven, text.contains("<packaging>pom</packaging>") { return nil }
        let framework: String
        let goal: (maven: String, gradle: String)
        if text.contains("spring-boot") || text.contains("org.springframework.boot") {
            (framework, goal) = ("Spring Boot", ("spring-boot:run", "bootRun"))
        } else if text.contains("quarkus") {
            (framework, goal) = ("Quarkus", ("quarkus:dev", "quarkusDev"))
        } else if text.contains("micronaut") {
            (framework, goal) = ("Micronaut", ("mn:run", "run"))
        } else {
            return nil
        }
        let wrapper = maven ? "mvnw" : "gradlew"
        var tool = maven ? "mvn" : "gradle"
        var up = ""
        var parts = folder.split(separator: "/").map(String.init)
        while true {
            let here = parts.joined(separator: "/")
            if files.contains(here.isEmpty ? wrapper : here + "/" + wrapper) { tool = (up.isEmpty ? "./" : up) + wrapper; break }
            if parts.isEmpty { break }
            parts.removeLast()
            up += "../"
        }
        return RunnableApp(folder: folder, name: name(of: folder), kind: .backend, stack: framework,
                           command: "\(tool) \(maven ? goal.maven : goal.gradle)")
    }

    // MARK: Python

    static func python(folder: String, manifest: String, files: [String], read: (String) -> String?) -> RunnableApp? {
        let lower = manifest.lowercased()
        let prefix = folder.isEmpty ? "" : folder + "/"
        let sources = files.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".py") && $0.split(separator: "/").count - folder.split(separator: "/").count <= 3 }
        if lower.contains("fastapi") || lower.contains("starlette") {
            // The module that makes the app: `app = FastAPI(` in app/main.py → app.main:app.
            for file in sources.sorted(by: { $0.count < $1.count }) {
                guard let text = read(file), let range = text.range(of: #"(\w+)\s*=\s*FastAPI\("#, options: .regularExpression) else { continue }
                let variable = text[range].split(separator: "=").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "app"
                let module = String(file.dropFirst(prefix.count).dropLast(3)).replacingOccurrences(of: "/", with: ".")
                return RunnableApp(folder: folder, name: name(of: folder), kind: .backend, stack: "FastAPI", command: "uvicorn \(module):\(variable) --reload")
            }
            return RunnableApp(folder: folder, name: name(of: folder), kind: .backend, stack: "FastAPI", command: "uvicorn main:app --reload")
        }
        if lower.contains("flask") {
            return RunnableApp(folder: folder, name: name(of: folder), kind: .backend, stack: "Flask", command: "flask run --debug")
        }
        return nil
    }
}
