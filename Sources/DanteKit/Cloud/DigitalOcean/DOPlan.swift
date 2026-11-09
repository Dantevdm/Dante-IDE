import Foundation

/// Where the code comes from: a git host App Platform is connected to (it builds and deploys
/// on every push), a public git URL it can clone, or an image Dante builds here and pushes to
/// the account's container registry.
public enum DOSource: Equatable, Sendable {
    case github(repo: String), gitlab(repo: String), bitbucket(repo: String)
    case publicGit(url: String)
    case builtHere

    /// The source for a git remote. `isPublic` is whether the remote answered without a
    /// sign-in, which only matters for hosts App Platform has no connector for.
    public static func from(remote: String?, isPublic: Bool = false) -> DOSource {
        guard let remote = remote?.trimmingCharacters(in: .whitespacesAndNewlines), !remote.isEmpty,
              let (host, path) = hostAndPath(remote) else { return .builtHere }
        var repo = path
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        guard repo.split(separator: "/").count >= 2 else { return .builtHere }
        switch host {
        case "github.com": return .github(repo: repo)
        case "gitlab.com": return .gitlab(repo: repo)
        case "bitbucket.org": return .bitbucket(repo: repo)
        default:
            return isPublic && remote.hasPrefix("https://") ? .publicGit(url: remote) : .builtHere
        }
    }

    /// (host, "owner/name") from https, ssh and scp-like remotes.
    static func hostAndPath(_ remote: String) -> (String, String)? {
        if let url = URL(string: remote), let scheme = url.scheme, ["https", "http", "ssh"].contains(scheme), let host = url.host {
            return (host.lowercased(), url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
        if let at = remote.firstIndex(of: "@"), let colon = remote.firstIndex(of: ":"), at < colon {
            return (remote[remote.index(after: at)..<colon].lowercased(), String(remote[remote.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
        return nil
    }

    public var label: String {
        switch self {
        case .github(let repo): "GitHub (\(repo))"
        case .gitlab(let repo): "GitLab (\(repo))"
        case .bitbucket(let repo): "Bitbucket (\(repo))"
        case .publicGit: "the public git repository"
        case .builtHere: "images built on this Mac"
        }
    }

    /// Whether a failure says App Platform can't read the repository (so the page offers
    /// `connectURL`), rather than anything else that merely mentions git or DigitalOcean.
    public static func needsRepositoryAccess(_ problem: String) -> Bool {
        let text = problem.lowercased()
        guard ["repo", "github", "gitlab", "bitbucket"].contains(where: { text.contains($0) }) else { return false }
        return ["access", "permission", "authori", "install", "connect", "not found", "unable to", "could not", "couldn't"].contains { text.contains($0) }
    }

    /// The page where the person lets App Platform read their repositories.
    public var connectURL: URL? {
        switch self {
        case .github: URL(string: "https://cloud.digitalocean.com/apps/github/install")
        case .gitlab: URL(string: "https://cloud.digitalocean.com/apps/gitlab/install")
        case .bitbucket: URL(string: "https://cloud.digitalocean.com/apps/bitbucket/install")
        default: nil
        }
    }

    public var isGitHost: Bool {
        switch self {
        case .github, .gitlab, .bitbucket: true
        default: false
        }
    }
}

/// An image Dante builds on this Mac for one component and pushes to the registry.
public struct DOImageBuild: Equatable, Sendable {
    /// The component it's for, which is also the registry repository.
    public var component: String
    /// The build context, relative to the project ("" is the root).
    public var context: String
    /// The Dockerfile, relative to the project; nil when `dockerfile` is passed on stdin.
    public var dockerfilePath: String?
    /// A Dockerfile Dante writes for the build only (a static site served by nginx), never
    /// into the project.
    public var dockerfile: String?
}

/// A first app spec for a project, from what Dante can see: Dockerfiles, the apps in the code
/// (`RunnableApp.detect`), plain static folders, compose's database and the env examples.
public struct DOPlan: Equatable, Sendable {
    public var spec: DOAppSpec
    public var source: DOSource
    public var builds: [DOImageBuild]
    /// One sentence per decision, for the page.
    public var notes: [String]
    /// What it couldn't place (an app needing a Dockerfile to be built here, a database
    /// engine App Platform has no dev database for).
    public var gaps: [String]

    public static let defaultRegion = "fra"

    public static func make(projectName: String, files: [String], read: (String) -> String?, compose: ComposeFile? = nil,
                            source: DOSource, branch: String, region: String = defaultRegion, registry: String? = nil) -> DOPlan {
        let visible = files.filter { file in
            !file.split(separator: "/").dropLast().contains { SystemMap.skippedFolders.contains(String($0)) && $0 != "public" || $0.hasPrefix(".") }
        }
        var spec = DOAppSpec(name: appName(projectName), region: region)
        var builds: [DOImageBuild] = []
        var notes: [String] = []
        var gaps: [String] = []
        var used = Set<String>()

        func unique(_ base: String) -> String {
            var name = componentName(base), n = 2
            while used.contains(name) { name = componentName(base) + "-\(n)"; n += 1 }
            used.insert(name)
            return name
        }

        func attachSource(_ component: inout DOAppSpec.Component, folder: String) {
            switch source {
            case .github(let repo): component.github = .init(repo: repo, branch: branch, deployOnPush: true)
            case .gitlab(let repo): component.gitlab = .init(repo: repo, branch: branch, deployOnPush: true)
            case .bitbucket(let repo): component.bitbucket = .init(repo: repo, branch: branch, deployOnPush: true)
            case .publicGit(let url): component.git = .init(repoCloneURL: url, branch: branch)
            case .builtHere:
                // One repository for the app, a tag per component: the free registry plan holds one.
                component.image = .init(registryType: "DOCR", registry: registry, repository: appName(projectName), tag: component.name + "-latest")
            }
            if source != .builtHere, !folder.isEmpty { component.sourceDir = folder }
        }

        // Folders with a Dockerfile run as services built from it.
        let dockerfiles = visible.filter { ($0 as NSString).lastPathComponent == "Dockerfile" && $0.split(separator: "/").count <= 3 }
        var covered = Set<String>()
        for file in dockerfiles.sorted(by: { $0.count < $1.count }) {
            let folder = (file as NSString).deletingLastPathComponent
            let text = read(file) ?? ""
            let context = buildContext(dockerfile: file, text: text, compose: compose)
            var component = DOAppSpec.Component(name: unique(folder.isEmpty ? projectName : (folder as NSString).lastPathComponent))
            component.httpPort = exposedPort(text) ?? 8080
            attachSource(&component, folder: context)
            // Folders the image copies in from a wider context are built inside it (an admin
            // site the API embeds), so they aren't components of their own.
            for copied in copiedFolders(text) where context != folder {
                covered.insert(context.isEmpty ? copied : context + "/" + copied)
            }
            if source == .builtHere {
                builds.append(DOImageBuild(component: component.name, context: context, dockerfilePath: file))
            } else {
                component.dockerfilePath = file
            }
            component.instanceCount = 1
            component.instanceSizeSlug = smallestService
            component.healthCheck = .init(httpPath: healthPath(in: visible, folder: folder, read: read) ?? "/")
            spec.services = (spec.services ?? []) + [component]
            covered.insert(folder)
            notes.append("\(component.name) runs from \(file), on port \(component.httpPort ?? 8080).")
        }

        // Apps without a Dockerfile: buildpacks from git, or a gap when built here.
        for app in RunnableApp.detect(files: files, read: read, compose: compose) where !covered.contains(app.folder) {
            covered.insert(app.folder)
            let prefix = app.folder.isEmpty ? "" : app.folder + "/"
            if app.kind == .frontend, let output = staticOutput(stack: app.stack, packageJSON: read(prefix + "package.json") ?? "") {
                var component = DOAppSpec.Component(name: unique(app.folder.isEmpty ? projectName : app.name))
                let build = buildCommand(app)
                if source == .builtHere {
                    component.httpPort = 80
                    component.instanceCount = 1
                    component.instanceSizeSlug = smallestService
                    attachSource(&component, folder: app.folder)
                    builds.append(DOImageBuild(component: component.name, context: app.folder, dockerfilePath: nil,
                                               dockerfile: nodeStaticDockerfile(manager: app.nodeTool ?? "npm", build: build, output: output)))
                    spec.services = (spec.services ?? []) + [component]
                    notes.append("\(component.name) is a \(app.stack) site: built here and served by nginx, since App Platform only builds static sites from git.")
                } else {
                    attachSource(&component, folder: app.folder)
                    component.buildCommand = build
                    component.outputDir = output
                    spec.staticSites = (spec.staticSites ?? []) + [component]
                    notes.append("\(component.name) is a \(app.stack) site: built with \(build) and served from \(output) (static sites are free).")
                }
                continue
            }
            guard source != .builtHere else {
                gaps.append("\(app.name) (\(app.stack)) has no Dockerfile, so it can't be built here. Ask the agent to write one, or push the code to GitHub, GitLab or Bitbucket.")
                continue
            }
            var component = DOAppSpec.Component(name: unique(app.folder.isEmpty ? projectName : app.name))
            attachSource(&component, folder: app.folder)
            component.httpPort = defaultPorts[app.stack] ?? 8080
            if app.nodeTool != nil {
                if let pkg = read(prefix + "package.json"), pkg.contains("\"build\"") { component.buildCommand = buildCommand(app) }
                component.runCommand = app.stack == "Next.js" ? "\(app.nodeTool ?? "npm") start" : nil
            }
            component.instanceCount = 1
            component.instanceSizeSlug = smallestService
            component.healthCheck = .init(httpPath: healthPath(in: visible, folder: app.folder, read: read) ?? "/")
            spec.services = (spec.services ?? []) + [component]
            notes.append("\(component.name) (\(app.stack)) is built by App Platform's buildpacks and listens on port \(component.httpPort ?? 8080).")
        }

        // Plain folders of HTML that no app above serves: the project itself when nothing
        // else was found, else a top-level site/, www/, web/ or public/.
        let inside = { (folder: String) in covered.contains { $0.isEmpty || folder == $0 || folder.hasPrefix($0 + "/") } }
        let folders = spec.components.isEmpty ? ["", "public", "site", "www", "web", "docs"] : ["site", "www", "web", "public"]
        for folder in folders where visible.contains((folder.isEmpty ? "" : folder + "/") + "index.html") && !inside(folder) {
            covered.insert(folder)
            var component = DOAppSpec.Component(name: unique(folder.isEmpty ? projectName : folder))
            attachSource(&component, folder: folder)
            if source == .builtHere {
                component.httpPort = 80
                component.instanceCount = 1
                component.instanceSizeSlug = smallestService
                builds.append(DOImageBuild(component: component.name, context: folder, dockerfilePath: nil, dockerfile: plainStaticDockerfile))
                spec.services = (spec.services ?? []) + [component]
                notes.append("\(component.name) serves the HTML in \(folder.isEmpty ? "the project" : folder + "/") with nginx, built here (App Platform only builds static sites from git).")
            } else {
                spec.staticSites = (spec.staticSites ?? []) + [component]
                notes.append("\(component.name) serves the HTML in \(folder.isEmpty ? "the project" : folder + "/") as a static site (free).")
            }
            if folder.isEmpty { break }
        }

        // Compose's Postgres becomes a dev database; others are noted.
        let databases = (compose?.services ?? []).compactMap { service -> (String, String)? in
            guard let image = service.image?.lowercased() else { return nil }
            if image.hasPrefix("postgres") || image.contains("/postgres") || image.hasPrefix("pgvector") { return (service.name, "PG") }
            if image.hasPrefix("mysql") || image.hasPrefix("mariadb") { return (service.name, "MYSQL") }
            if image.hasPrefix("redis") || image.hasPrefix("valkey") { return (service.name, "VALKEY") }
            if image.hasPrefix("mongo") { return (service.name, "MONGODB") }
            return nil
        }
        if let pg = databases.first(where: { $0.1 == "PG" }), !(spec.services ?? []).isEmpty {
            spec.databases = [.init(name: "db", engine: "PG", production: false)]
            notes.append("\(pg.0) in compose becomes a dev Postgres database (about $7 a month, no backups); its address reaches the services as DATABASE_URL.")
        }
        for (name, engine) in databases where engine != "PG" {
            gaps.append("\(name) (\(engineName(engine))) needs a managed database cluster, which Dante doesn't create. Make one in DigitalOcean and add it under databases: with cluster_name.")
        }

        // Variables from the env examples: secrets are asked for at deploy, never written here.
        for index in (spec.services ?? []).indices {
            let service = spec.services![index], build = builds.first { $0.component == service.name }
            // The app's own folder, even when its image builds from a wider context.
            let folder = (service.dockerfilePath ?? build?.dockerfilePath).map { ($0 as NSString).deletingLastPathComponent }
                ?? service.sourceDir ?? build?.context ?? ""
            var envs = variables(folder: folder, files: visible, read: read)
            if spec.databases != nil {
                envs.removeAll { $0.key == "DATABASE_URL" }
                // The database's own password, host and so on, rather than this Mac's.
                envs = envs.map { env in
                    guard let field = DOSpecSend.databaseField(env.key) else { return env }
                    return .init(key: env.key, value: "${db.\(field)}", scope: env.scope ?? "RUN_TIME")
                }
                envs.insert(.init(key: "DATABASE_URL", value: "${db.DATABASE_URL}", scope: "RUN_TIME"), at: 0)
            }
            if !envs.isEmpty { spec.services![index].envs = envs }
        }
        if spec.components.contains(where: { $0.component.envs?.contains { $0.isSecretType } == true }) {
            notes.append("Secrets are marked SECRET without a value: Dante asks for them when you deploy and sends them encrypted, never into this file.")
        }

        // Several components on the web: the front end at /, the others at /<name>.
        let public_ = (spec.staticSites ?? []).map(\.name) + (spec.services ?? []).filter { $0.httpPort != nil }.map(\.name)
        if public_.count > 1 {
            let frontWords = ["web", "site", "www", "frontend", "front", "ui", "client", "app"]
            let front = spec.staticSites?.first?.name ?? public_.first { name in frontWords.contains { name.contains($0) } } ?? public_[0]
            spec.ingress = .init(rules: public_.map { .init(prefix: $0 == front ? "/" : "/" + $0, component: $0) })
            notes.append("\(front) answers at /, " + public_.filter { $0 != front }.map { "\($0) at /\($0)" }.joined(separator: ", ") + " (the prefix is taken off before the request reaches it).")
        }

        spec.alerts = [.init(rule: "DEPLOYMENT_FAILED"), .init(rule: "DOMAIN_FAILED")]
        return DOPlan(spec: spec, source: source, builds: builds, notes: notes, gaps: gaps)
    }

    // MARK: Pieces

    /// The cheapest instance that runs a service (about $5 a month).
    public static let smallestService = "apps-s-1vcpu-0.5gb"

    /// Where a single-page app's build puts its files; nil for frameworks that run a server
    /// (Next.js, Nuxt, SvelteKit).
    static func staticOutput(stack: String, packageJSON: String) -> String? {
        guard ["React", "Vue", "Svelte", "Angular", "Preact", "Solid", "Lit"].contains(stack) else { return nil }
        if stack == "Angular" {
            let name = JSONValue(line: packageJSON.replacingOccurrences(of: "\n", with: " "))?["name"]?.string ?? ""
            return name.isEmpty ? "dist" : "dist/\(name)/browser"
        }
        if packageJSON.contains("\"react-scripts\"") { return "build" }
        return "dist"
    }

    static let defaultPorts: [String: Int] = [
        "Next.js": 3000, "Nuxt": 3000, "Express": 3000, "Fastify": 3000, "NestJS": 3000, "Node": 3000, "TypeScript": 3000,
        "FastAPI": 8000, "Django": 8000, "Flask": 5000, "Go": 8080, "Spring Boot": 8080, "Rust": 8080, ".NET": 8080,
    ]

    static func buildCommand(_ app: RunnableApp) -> String {
        let tool = app.nodeTool ?? "npm"
        return tool == "npm" ? "npm run build" : "\(tool) build"
    }

    /// App names: lowercase letters, digits and dashes, 2 to 32 long, starting with a letter.
    public static func appName(_ text: String) -> String {
        var name = componentName(text)
        if name.count < 2 { name = "app-" + name }
        return String(name.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func componentName(_ text: String) -> String {
        let lowered = text.lowercased().map { $0.isLetter && $0.isASCII || $0.isNumber ? $0 : "-" }
        var name = String(lowered).split(separator: "-").joined(separator: "-")
        if let first = name.first, !first.isLetter { name = "app-" + name }
        return name.isEmpty ? "app" : String(name.prefix(32))
    }

    /// The folder a Dockerfile builds from: what compose's `build:` gives for it, else the
    /// folder above when its copies name the Dockerfile's own folder (`COPY api/go.mod .` in
    /// `api/Dockerfile` means the context is the parent), else its own folder.
    static func buildContext(dockerfile file: String, text: String, compose: ComposeFile?) -> String {
        for service in compose?.services ?? [] {
            guard let build = service.build else { continue }
            let context = tidy(build)
            if tidy((context.isEmpty ? "" : context + "/") + (service.dockerfile ?? "Dockerfile")) == file { return context }
        }
        let folder = (file as NSString).deletingLastPathComponent
        if !folder.isEmpty, copiedFolders(text).contains((folder as NSString).lastPathComponent) {
            return (folder as NSString).deletingLastPathComponent
        }
        return folder
    }

    /// The sources of a Dockerfile's COPY and ADD lines, leaving out copies from other stages.
    static func copySources(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).flatMap { raw -> [String] in
            let words = raw.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
            guard let verb = words.first?.uppercased(), verb == "COPY" || verb == "ADD" else { return [] }
            let rest = words.dropFirst()
            guard !rest.contains(where: { $0.hasPrefix("--from") }) else { return [] }
            let paths = rest.filter { !$0.hasPrefix("--") }
            return paths.dropLast().map { tidy($0) }
        }
    }

    /// The top folders a Dockerfile's copies name (`admin/package.json` → `admin`).
    static func copiedFolders(_ text: String) -> [String] {
        var seen: [String] = []
        for source in copySources(text) {
            guard let first = source.split(separator: "/").first.map(String.init), source.contains("/"), first != "." else { continue }
            if !seen.contains(first) { seen.append(first) }
        }
        return seen
    }

    /// A path written in compose or a Dockerfile as Dante's project paths write it.
    static func tidy(_ path: String) -> String {
        var path = path
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasSuffix("/") { path.removeLast() }
        return path == "." ? "" : path
    }

    static func exposedPort(_ dockerfile: String) -> Int? {
        for line in dockerfile.split(whereSeparator: \.isNewline) {
            let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            if words.first?.uppercased() == "EXPOSE", words.count > 1, let port = Int(words[1].split(separator: "/")[0]) { return port }
        }
        return nil
    }

    /// A health route the code serves, so App Platform checks the app rather than the port.
    static func healthPath(in files: [String], folder: String, read: (String) -> String?) -> String? {
        let prefix = folder.isEmpty ? "" : folder + "/"
        let candidates = ["/healthz", "/health", "/api/health", "/actuator/health", "/livez", "/ping"]
        for file in files where file.hasPrefix(prefix) && SystemMap.isCode(file) {
            guard let text = read(file) else { continue }
            if let path = candidates.first(where: { text.contains("\"\($0)\"") || text.contains("'\($0)'") || text.contains("`\($0)`") }) { return path }
            if text.contains("spring-boot-starter-actuator") { return "/actuator/health" }
        }
        return nil
    }

    /// Variables from `.env.example` and friends in the folder, else the project root.
    static func variables(folder: String, files: [String], read: (String) -> String?) -> [DOAppSpec.Env] {
        let names = [".env.example", ".env.sample", ".env.template", "env.example"]
        let prefixes = folder.isEmpty ? [""] : [folder + "/", ""]
        guard let file = prefixes.lazy.flatMap({ prefix in names.map { prefix + $0 } }).first(where: { files.contains($0) }),
              let text = read(file) else { return [] }
        return EnvFile.parse(text).compactMap { key, value in
            if SystemMap.isSecret(key) { return .init(key: key, scope: "RUN_TIME", type: "SECRET") }
            let local = ["localhost", "127.0.0.1", "0.0.0.0", "host.docker.internal"].contains { value.contains($0) }
            guard !value.isEmpty, !local, key != "PORT" else { return nil }
            return .init(key: key, value: value, scope: "RUN_AND_BUILD_TIME")
        }
    }

    static func engineName(_ engine: String) -> String {
        ["PG": "Postgres", "MYSQL": "MySQL", "VALKEY": "Redis", "MONGODB": "MongoDB"][engine] ?? engine
    }

    static func nodeStaticDockerfile(manager: String, build: String, output: String) -> String {
        let install = ["pnpm": "corepack enable && pnpm install --frozen-lockfile", "yarn": "corepack enable && yarn install --frozen-lockfile",
                       "bun": "npm install -g bun && bun install"][manager] ?? "npm ci"
        return """
        FROM node:22-alpine AS build
        WORKDIR /app
        COPY . .
        RUN \(install) && \(build)
        FROM nginx:1.27-alpine
        COPY --from=build /app/\(output) /usr/share/nginx/html
        EXPOSE 80
        """
    }

    /// Dot files (.env, .git) are dropped in a stage of their own, so they're in no layer of
    /// the image that's pushed.
    static let plainStaticDockerfile = """
    FROM alpine:3.20 AS files
    COPY . /site
    RUN find /site -mindepth 1 -name '.*' -prune -exec rm -rf {} + && rm -f /site/Dockerfile
    FROM nginx:1.27-alpine
    COPY --from=files /site /usr/share/nginx/html
    EXPOSE 80
    """
}
