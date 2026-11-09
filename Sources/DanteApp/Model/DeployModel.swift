import AppKit
import DanteKit
import Foundation
import Observation
import UserNotifications

/// Ship › Deploy's state for one window: the DigitalOcean sign-in, the app this project
/// deploys to (linked per project on this Mac), its deployments, health and logs, a deploy in
/// progress, and the security and recommendations found. Kept here so a deploy carries on and
/// is watched while you look at other pages.
@MainActor @Observable
final class DeployModel {
    // Sign-in
    var person: DOSignIn.Person? = DOAccount.person
    var signedIn = DOAccount.isSignedIn
    var signingIn = false
    var signInProblem: String?

    // The project
    private(set) var root: URL?
    var specText: String?
    var spec: DOAppSpec?
    var specProblem: String?
    var plan: DOPlan?
    var source: DOSource = .builtHere
    var branch = "main"
    var commit: String?
    var dirty = false
    /// Commits on this branch the remote doesn't have yet (a git source deploys what's pushed).
    var unpushed = 0
    var region = DOPlan.defaultRegion

    // The app
    var apps: [DOApp] = []
    var app: DOApp?
    var deployments: [DODeployment] = []
    var health: [DOComponentHealth] = []
    var alerts: [DOAlert] = []
    var sizes: [DOInstanceSize] = []
    var cpu: [String: DOSeries] = [:]
    var memory: [String: DOSeries] = [:]
    var restarts: [String: Double] = [:]
    var headers: [String: String]?
    var loading = false
    var problem: String?

    // Logs
    var logKind: DOClient.LogKind = .run
    var logComponent: String?
    var logText = ""
    /// Which logs the last load was for, so an empty answer reads as "none yet" rather than "press Load".
    var logsLoadedFor: String?
    var loadingLogs = false

    // Advice
    var advice: [DOAdvice] = []

    // A deploy
    enum Stage: Equatable {
        case checking, needsSecrets, confirming, registry, building(String), sending, watching
    }
    var stage: Stage?
    var needed: [DOSpecSend.Needed] = []
    var typedSecrets: [String: String] = [:]
    /// Secrets the spec's database answers itself (`${db.PASSWORD}`), shown rather than asked for.
    var databaseBindings: [(needed: DOSpecSend.Needed, binding: String)] = []
    /// Values for the needed secrets in the project's env files and mise, by `Needed.id`; used
    /// only when the person presses Fill, and never shown.
    var envMatches: [String: String] = [:]
    var filledFromEnv: Set<String> = []
    var proposal: DOProposal?
    var estimate: Double?
    var registryToMake: String?
    /// The team's registry the images go to, when it already has one.
    var registryInUse: String?
    /// Why the push wouldn't fit the registry's plan, said before anything is built.
    var registryFull: String?
    var buildLines: [String] = []
    var deployProblem: String?
    private var preparedSpec: [String: Any]?
    private(set) var builds: [(build: DOImageBuild, repository: String)] = []
    private var deployTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?

    let client = DOClient()

    var isDeploying: Bool { stage != nil && stage != .confirming && stage != .needsSecrets }
    var current: DODeployment? { app?.current }

    // MARK: Loading

    private static func appKey(_ root: URL) -> String { "deploy.app." + root.path }
    private static func regionKey(_ root: URL) -> String { "deploy.region." + root.path }

    var linkedAppID: String? {
        guard let root else { return nil }
        return UserDefaults.standard.string(forKey: Self.appKey(root))
    }

    func load(workspace: Workspace) async {
        let root = workspace.url
        if self.root != root {
            self.root = root
            app = nil
            deployments = []
            health = []
            logText = ""
            logsLoadedFor = nil
            region = UserDefaults.standard.string(forKey: Self.regionKey(root)) ?? DOPlan.defaultRegion
        }
        signedIn = DOAccount.isSignedIn
        person = DOAccount.person
        await readProject(workspace: workspace)
        if signedIn { await refresh() }
        analyse(workspace: workspace)
    }

    /// The file, git's view of the branch, and the plan Dante would write.
    func readProject(workspace: Workspace) async {
        let git = workspace.git.root
        async let remote = Shell.run(["git", "remote", "get-url", "origin"], in: git)
        async let head = Shell.run(["git", "rev-parse", "--abbrev-ref", "HEAD"], in: git)
        async let sha = Shell.run(["git", "rev-parse", "HEAD"], in: git)
        async let status = Shell.run(["git", "status", "--porcelain"], in: git)
        async let ahead = Shell.run(["git", "rev-list", "--count", "@{u}..HEAD"], in: git)
        let (remoteOut, headOut, shaOut, statusOut, aheadOut) = await (remote, head, sha, status, ahead)
        source = DOSource.from(remote: remoteOut.succeeded ? remoteOut.stdout : nil)
        branch = headOut.succeeded && headOut.stdout != "HEAD" ? headOut.stdout : "main"
        commit = shaOut.succeeded ? shaOut.stdout : nil
        dirty = statusOut.succeeded && !statusOut.stdout.isEmpty
        unpushed = aheadOut.succeeded ? Int(aheadOut.stdout) ?? 0 : 0

        let fileURL = workspace.url.appending(path: DOAppSpec.path)
        specText = try? String(contentsOf: fileURL, encoding: .utf8)
        if let specText {
            switch DOAppSpec.read(specText) {
            case .success(let read):
                spec = read
                specProblem = nil
            case .failure(let failure):
                spec = nil
                specProblem = failure.message
            }
        } else {
            spec = nil
            specProblem = nil
        }
        plan = makePlan(workspace: workspace, source: source)
    }

    private func makePlan(workspace: Workspace, source: DOSource) -> DOPlan {
        let root = workspace.url
        return DOPlan.make(projectName: root.lastPathComponent, files: workspace.files, read: Self.reader(root), compose: ComposeFile.load(projectRoot: root),
                           source: source, branch: branch, region: region)
    }

    nonisolated static func reader(_ root: URL) -> (String) -> String? {
        { path in
            let url = root.appending(path: path)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 512_000 else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    /// The app, its deployments, health, alerts and metrics.
    func refresh() async {
        guard signedIn else { return }
        loading = true
        defer { loading = false }
        do throws(DOClient.Failure) {
            if sizes.isEmpty { sizes = (try? await client.instanceSizes()) ?? [] }
            if let id = linkedAppID {
                let fetched = try await client.app(id)
                app = fetched
                async let deploymentList = client.deployments(id)
                async let healthList = client.health(id)
                async let alertList = client.alerts(id)
                deployments = (try? await deploymentList) ?? deployments
                health = (try? await healthList) ?? []
                alerts = (try? await alertList) ?? []
                problem = nil
                await loadMetrics(appID: id)
                await loadHeaders()
                if fetched.current?.phase.isRunning == true { watch() }
            } else {
                apps = try await client.apps()
                problem = nil
            }
        } catch {
            if error.isSignedOut {
                signedIn = false
                person = nil
            } else if error.isMissing, let root {
                // Deleted elsewhere: forget the link.
                UserDefaults.standard.removeObject(forKey: Self.appKey(root))
                app = nil
                apps = (try? await client.apps()) ?? []
                problem = "The app this project deployed to is gone from DigitalOcean."
            } else {
                report(error)
            }
        }
    }

    private func loadMetrics(appID: String) async {
        let names = (app?.spec?.services ?? []).map(\.name) + (app?.spec?.workers ?? []).map(\.name)
        let hour = Date.now.addingTimeInterval(-3600), day = Date.now.addingTimeInterval(-86_400)
        for name in names {
            cpu[name] = try? await client.metric(.cpu, appID: appID, component: name, since: hour)
            memory[name] = try? await client.metric(.memory, appID: appID, component: name, since: hour)
            if let series = try? await client.metric(.restarts, appID: appID, component: name, since: day), let first = series.points.first?.1, let last = series.last {
                restarts[name] = max(0, last - first)
            }
        }
    }

    /// The live site's headers, for the HTTPS checks. Only the app's own address is asked.
    private func loadHeaders() async {
        guard let url = app?.liveURL, url.scheme == "https" else { headers = nil; return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { headers = nil; return }
        var found: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String { found[key.lowercased()] = "\(value)" }
        }
        headers = found
    }

    func analyse(workspace: Workspace) {
        let root = workspace.url
        var dockerfiles: [String: String] = [:]
        var ignores: [String: Bool] = [:]
        var envFiles = Set<String>()
        let read = Self.reader(root)
        for file in workspace.files where (file as NSString).lastPathComponent == "Dockerfile" && file.split(separator: "/").count <= 3 {
            guard let text = read(file) else { continue }
            dockerfiles[file] = text
            let folder = (file as NSString).deletingLastPathComponent
            let base = folder.isEmpty ? root : root.appending(path: folder)
            if FileManager.default.fileExists(atPath: base.appending(path: ".env").path) { envFiles.insert(folder) }
            let ignore = (try? String(contentsOf: base.appending(path: ".dockerignore"), encoding: .utf8)) ?? ""
            ignores[folder] = ignore.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .contains { [".env", ".env*", "**/.env", "*.env", "**/.env*", "*"].contains($0) }
        }
        let inputs = DOAdvice.Inputs(file: spec, fileText: specText, live: app, dockerfiles: dockerfiles, ignoresEnv: ignores, envFiles: envFiles,
                                     headers: headers, health: health, alerts: alerts, restarts: restarts, sizes: sizes)
        advice = DOAdvice.analyse(inputs)
    }

    // MARK: Signing in

    func signIn() {
        guard !signingIn else { return }
        signingIn = true
        signInProblem = nil
        Task {
            let result = await DOSignIn.signIn { url in
                Task { @MainActor in NSWorkspace.shared.open(url) }
            }
            signingIn = false
            switch result {
            case .success:
                signedIn = true
                person = DOAccount.person
                await refresh()
            case .failure(let failure):
                signInProblem = failure.message(from: "DigitalOcean")
            }
        }
    }

    /// Signs out and straight back in, for a sign-in granted before Dante asked for a scope it
    /// now needs. The linked app stays linked.
    func signInAgain() {
        deployProblem = nil
        Task {
            await DOAccount.signOut()
            signedIn = false
            person = nil
            signIn()
        }
    }

    func signOut() {
        Task {
            await DOAccount.signOut()
            signedIn = false
            person = nil
            apps = []
            forgetApp()
        }
    }

    // MARK: The spec

    /// Writes the plan to `.do/app.yaml` (only when there's no file) and opens it.
    func writeSpec(session: Session, workspace: Workspace) {
        guard let plan, specText == nil else { return }
        let url = workspace.url.appending(path: DOAppSpec.path)
        let header = [
            "App Platform spec for DigitalOcean, written by Dante from the project. Edit it freely:",
            "Dante deploys what's here. Secrets are type: SECRET without a value; Dante asks for them",
            "when you deploy and DigitalOcean keeps them encrypted.",
            "Reference: https://docs.digitalocean.com/products/app-platform/reference/app-spec/",
        ]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try plan.spec.yaml(header: header).write(to: url, atomically: true, encoding: .utf8)
            specText = try String(contentsOf: url, encoding: .utf8)
            spec = plan.spec
            session.open(file: url)
        } catch {
            problem = "Couldn’t write \(DOAppSpec.path): \(error.localizedDescription)"
        }
    }

    func setRegion(_ region: String, workspace: Workspace) {
        self.region = region
        if let root { UserDefaults.standard.set(region, forKey: Self.regionKey(root)) }
        plan = makePlan(workspace: workspace, source: source)
    }

    func link(_ app: DOApp) {
        guard let root else { return }
        UserDefaults.standard.set(app.id, forKey: Self.appKey(root))
        self.app = app
        Task { await refresh() }
    }

    func unlink() {
        guard let root else { return }
        UserDefaults.standard.removeObject(forKey: Self.appKey(root))
        forgetApp()
        Task { await refresh() }
    }

    /// Everything read from the linked app, so nothing about it (its live site's headers
    /// included) lingers once it's unlinked or deleted.
    private func forgetApp() {
        app = nil
        deployments = []
        health = []
        alerts = []
        cpu = [:]
        memory = [:]
        restarts = [:]
        headers = nil
        logText = ""
        logsLoadedFor = nil
    }

    // MARK: Deploying

    /// Step one: read the file, see what has to be built and which secrets are missing, and
    /// price it. Nothing is made until `confirm`.
    func prepare(workspace: Workspace) {
        guard stage == nil || stage == .needsSecrets || deployProblem != nil else { return }
        deployProblem = nil
        guard let specText else {
            deployProblem = "Write \(DOAppSpec.path) first."
            return
        }
        stage = .checking
        Task {
            guard case .success(var object) = DOSpecSend.object(yaml: specText) else {
                deployProblem = specProblem ?? "\(DOAppSpec.path) isn’t valid YAML."
                stage = nil
                return
            }
            if object["region"] == nil { object["region"] = region }
            let live = app?.specJSON.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            var probe = object
            databaseBindings = DOSpecSend.databaseBindings(in: object)
            needed = DOSpecSend.prepare(&probe, secrets: typedSecrets, live: live)
            envMatches = Self.envValues(for: needed, spec: object, root: workspace.url)
            filledFromEnv = []
            let planned = DOPlan.make(projectName: workspace.url.lastPathComponent, files: workspace.files, read: Self.reader(workspace.url),
                                      compose: ComposeFile.load(projectRoot: workspace.url), source: .builtHere, branch: branch, region: region).builds
            builds = DODocker.builds(for: object, planned: planned)
            registryToMake = nil
            registryInUse = nil
            registryFull = nil
            if !builds.isEmpty {
                do throws(DOClient.Failure) {
                    if let registry = try await client.registry() {
                        registryInUse = registry.name
                        let limit = try await client.registryRepositoryLimit()
                        let existing = try await client.repositories(registry: registry.name)
                        let overflow = DORegistryRoom.overflow(limit: limit, existing: existing, pushing: builds.map(\.repository))
                        if !overflow.isEmpty, let limit {
                            registryFull = "The team’s registry, \(registry.name), already holds \(existing.count) of the \(limit) repositor\(limit == 1 ? "y" : "ies") its plan allows, so pushing \(overflow.joined(separator: ", ")) would fail. Upgrade the registry’s plan on DigitalOcean, or point the spec’s image at an existing repository."
                        }
                    } else {
                        registryToMake = Self.registryName(person: person, app: object["name"] as? String)
                    }
                } catch {
                    deployProblem = DOSignIn.explain(error.message)
                    stage = nil
                    return
                }
            }
            // From here on the spec is what App Platform sees: folders inside the repository.
            let prefix = workspace.git.prefix
            object = DOSpecSend.inRepository(object, prefix: prefix)
            probe = DOSpecSend.inRepository(probe, prefix: prefix)
            preparedSpec = object
            estimate = Self.estimate(DOAppSpec.fromJSON((try? JSONSerialization.data(withJSONObject: object)) ?? Data()), sizes: sizes)
            proposal = nil
            if needed.isEmpty {
                var priced = probe
                if !builds.isEmpty { priced = Self.withoutBuiltImages(priced, builds: builds) }
                proposal = try? await client.propose(DOSpecSend.json(priced), appID: app?.id)
            }
            stage = needed.isEmpty ? .confirming : .needsSecrets
        }
    }

    /// Typed secrets are in; price it and ask.
    func secretsEntered() {
        needed = needed.filter { (typedSecrets[$0.id] ?? "").isEmpty }
        guard needed.isEmpty, var probe = preparedSpec else { return }
        let live = app?.specJSON.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        DOSpecSend.prepare(&probe, secrets: typedSecrets, live: live)
        stage = .checking
        Task {
            if !builds.isEmpty { probe = Self.withoutBuiltImages(probe, builds: builds) }
            proposal = try? await client.propose(DOSpecSend.json(probe), appID: app?.id)
            stage = .confirming
        }
    }

    #if DEBUG
    /// `DANTE_DEPLOY_DEMO=1`: opens the deploy sheet on the project's own spec with a made-up
    /// team and registry and no DigitalOcean calls, to look at the sheet without spending anything.
    func showDemo(workspace: Workspace) {
        guard stage == nil, let specText, case .success(var object) = DOSpecSend.object(yaml: specText) else { return }
        person = DOSignIn.Person(name: "Sam", email: nil, team: "Acme")
        databaseBindings = DOSpecSend.databaseBindings(in: object)
        needed = DOSpecSend.prepare(&object)
        envMatches = Self.envValues(for: needed, spec: object, root: workspace.url)
        let planned = DOPlan.make(projectName: workspace.url.lastPathComponent, files: workspace.files, read: Self.reader(workspace.url),
                                  compose: ComposeFile.load(projectRoot: workspace.url), source: .builtHere, branch: branch, region: region).builds
        builds = DODocker.builds(for: object, planned: planned)
        registryInUse = "acme"
        estimate = 12
        stage = needed.isEmpty ? .confirming : .needsSecrets
    }
    #endif

    /// Puts the values found in the project's env files into the secret fields, for the
    /// person to look over before Continue.
    func fillFromEnv() {
        for (id, value) in envMatches {
            typedSecrets[id] = value
            filledFromEnv.insert(id)
        }
    }

    /// The needed secrets' values in `.env` and `.env.local` at the project root and in each
    /// component's folder (the component's own win), over what mise sets there. Placeholders
    /// and values that still name other variables are left out.
    static func envValues(for needed: [DOSpecSend.Needed], spec: [String: Any], root: URL) -> [String: String] {
        var folders: [String: String] = [:]
        for list in ["services", "static_sites", "workers", "jobs"] {
            for component in spec[list] as? [[String: Any]] ?? [] {
                guard let name = component["name"] as? String else { continue }
                let dir = ((component["source_dir"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !dir.isEmpty, !dir.contains("..") { folders[name] = dir }
            }
        }
        func values(in folder: URL) -> [String: String] {
            var found = Mise.overlay(for: folder)
            for name in [".env", ".env.local"] {
                guard let text = try? String(contentsOf: folder.appending(path: name), encoding: .utf8) else { continue }
                found.merge(EnvFile.values(text)) { _, file in file }
            }
            return found
        }
        let atRoot = values(in: root)
        var result: [String: String] = [:]
        for item in needed {
            var env = atRoot
            if let dir = item.component.flatMap({ folders[$0] }) { env.merge(values(in: root.appending(path: dir))) { _, own in own } }
            guard var value = env[item.key] else { continue }
            value = EnvFile.interpolate(value, env: env)
            let lower = value.lowercased()
            let placeholder = value.isEmpty || value.contains("$") || value.hasPrefix("<") || ["changeme", "change-me", "change_me", "xxx", "todo", "secret", "password"].contains(lower) || lower.hasPrefix("your")
            if !placeholder { result[item.id] = value }
        }
        return result
    }

    func cancelDeploy() {
        deployTask?.cancel()
        if stage == .confirming || stage == .needsSecrets || stage == .checking {
            stage = nil
            typedSecrets = [:]
            filledFromEnv = []
        }
    }

    /// After the person confirmed: make the registry, build and push, then create or update
    /// the app and watch the deployment.
    func confirm(workspace: Workspace) {
        guard stage == .confirming, let prepared = preparedSpec else { return }
        let root = workspace.url
        let secrets = typedSecrets
        typedSecrets = [:]
        buildLines = []
        deployTask = Task {
            var spec = prepared
            var tags: [String: String] = [:]
            do throws(DOClient.Failure) {
                if !builds.isEmpty {
                    var registry = try await client.registry()
                    if registry == nil, let name = registryToMake {
                        stage = .registry
                        registry = try await client.createRegistry(name: name, region: Self.registryRegion(region))
                    }
                    guard let registry else { throw DOClient.Failure(status: 0, message: "There's no container registry to push to.") }
                    stage = .building("Signing in to the registry")
                    let credentials = try await client.dockerConfig()
                    let result = await DODocker.buildAndPush(builds, registry: registry.name, commit: commit, dirty: dirty, projectRoot: root, credentials: credentials) { event in
                        Task { @MainActor in self.receive(event) }
                    }
                    switch result {
                    case .success(let pushed): tags = pushed
                    case .failure(let failure): throw DOClient.Failure(status: 0, message: failure.message)
                    }
                }
                if Task.isCancelled { stage = nil; return }
                let live = app?.specJSON.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                let missing = DOSpecSend.prepare(&spec, tags: tags, secrets: secrets, live: live)
                guard missing.isEmpty else { throw DOClient.Failure(status: 0, message: "Still missing: \(missing.map(\.key).joined(separator: ", ")).") }
                stage = .sending
                let sent: DOApp
                if let existing = app {
                    let before = existing.current?.id
                    sent = try await client.update(existing.id, spec: DOSpecSend.json(spec))
                    // An unchanged spec doesn't start a deployment by itself; deploy what's pushed.
                    if sent.inProgress == nil, sent.pending == nil, sent.current?.id == before {
                        _ = try await client.deploy(existing.id, forceBuild: true)
                    }
                } else {
                    do throws(DOClient.Failure) {
                        sent = try await client.create(DOSpecSend.json(spec))
                    } catch let error where error.isTimedOut {
                        // A slow answer may still have made the app; trying again would make a second.
                        stage = .sending
                        guard let name = spec["name"] as? String, let made = await Self.findApp(named: name, client: client) else {
                            throw DOClient.Failure(status: 0, message: "DigitalOcean took too long to answer, and no app named \(spec["name"] as? String ?? "after the spec") has appeared. Try again in a minute.")
                        }
                        sent = made
                    }
                    UserDefaults.standard.set(sent.id, forKey: Self.appKey(root))
                }
                app = sent
                stage = .watching
                await refresh()
                watch()
            } catch {
                deployProblem = DOSignIn.explain(error.message)
                stage = nil
            }
        }
    }

    /// Looks for an app a timed-out create may have made, for up to a minute.
    private static func findApp(named name: String, client: DOClient) async -> DOApp? {
        for attempt in 0..<6 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(10)) }
            if Task.isCancelled { return nil }
            if let apps = try? await client.apps(), let app = apps.first(where: { $0.name == name }) { return app }
        }
        return nil
    }

    private func receive(_ event: DODocker.Event) {
        switch event {
        case .step(let text): stage = .building(text)
        case .line(let line):
            buildLines.append(line)
            if buildLines.count > 400 { buildLines.removeFirst(buildLines.count - 400) }
        }
    }

    /// Re-reads the app every five seconds while a deployment runs, then once more, and says
    /// how it ended.
    func watch() {
        guard watchTask == nil, let id = app?.id else { return }
        watchTask = Task {
            defer { watchTask = nil }
            var last = app?.current
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let fresh = try? await client.app(id) else { continue }
                app = fresh
                if let running = fresh.current, running.phase.isRunning {
                    last = running
                    if let list = try? await client.deployments(id) { deployments = list }
                    continue
                }
                if stage == .watching { stage = nil }
                await refresh()
                if let last, let ended = deployments.first(where: { $0.id == last.id }) { notify(ended) }
                return
            }
        }
    }

    private func notify(_ deployment: DODeployment) {
        guard NSApp.isActive == false else { return }
        let content = UNMutableNotificationContent()
        content.title = deployment.phase == .active ? "\(app?.name ?? "App") is live" : "\(app?.name ?? "App") didn’t deploy"
        content.body = deployment.failure.map { "\($0.place): \($0.message)" } ?? app?.liveURL?.absoluteString ?? ""
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "deploy-\(deployment.id)", content: content, trigger: nil))
    }

    func cancelRunning() {
        guard let id = app?.id, let deployment = current, deployment.phase.isRunning else { return }
        Task {
            do throws(DOClient.Failure) { try await client.cancel(id, deployment: deployment.id) } catch { report(error) }
            await refresh()
        }
    }

    func rollback(to deployment: DODeployment) {
        guard let id = app?.id else { return }
        Task {
            do throws(DOClient.Failure) {
                try await client.rollback(id, to: deployment.id)
                stage = .watching
                await refresh()
                watch()
            } catch {
                report(error)
            }
        }
    }

    func delete() {
        guard let app, let root else { return }
        Task {
            do throws(DOClient.Failure) {
                try await client.delete(app.id)
                UserDefaults.standard.removeObject(forKey: Self.appKey(root))
                forgetApp()
                await refresh()
            } catch {
                report(error)
            }
        }
    }

    // MARK: Logs

    /// Shows a failure, except a request dropped because the page that asked went away.
    private func report(_ error: DOClient.Failure) {
        if !error.isCancelled { problem = error.message }
    }

    func loadLogs() {
        guard let id = app?.id, let deployment = (logKind == .run ? app?.active : nil) ?? deployments.first else { return }
        loadingLogs = true
        let kind = logKind, component = logComponent
        Task {
            defer { loadingLogs = false }
            do throws(DOClient.Failure) {
                let text = try await client.logs(id, deployment: deployment.id, component: component, kind: kind)
                logText = text.isEmpty ? "" : String(text.suffix(200_000))
                logsLoadedFor = "\(kind.rawValue) \(component ?? "") \(deployment.id)"
            } catch {
                logText = ""
                logsLoadedFor = nil
                report(error)
            }
        }
    }

    // MARK: Pieces

    /// A registry name: globally unique, so the team's name plus a few random letters.
    static func registryName(person: DOSignIn.Person?, app: String?) -> String {
        let base = DOPlan.appName(person?.team ?? app ?? "dante")
        let letters = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String(base.prefix(24)) + "-" + String((0..<5).map { _ in letters.randomElement()! })
    }

    /// The registry's region nearest the app's.
    static func registryRegion(_ app: String) -> String {
        ["nyc": "nyc3", "tor": "nyc3", "atl": "nyc3", "sfo": "sfo3", "ams": "ams3", "lon": "ams3", "fra": "fra1", "sgp": "sgp1",
         "blr": "blr1", "syd": "syd1"][app] ?? "fra1"
    }

    /// What it costs a month from the sizes list, when the API's own price isn't known.
    static func estimate(_ spec: DOAppSpec?, sizes: [DOInstanceSize]) -> Double? {
        guard let spec, !sizes.isEmpty else { return nil }
        var total = 0.0
        for (kind, component) in spec.components where kind != .staticSite {
            let size = sizes.first { $0.slug == (component.instanceSizeSlug ?? DOPlan.smallestService) }
            total += (size?.monthly ?? 5) * Double(component.instanceCount ?? 1)
        }
        total += Double((spec.databases ?? []).filter { $0.production != true }.count) * 7
        return total
    }

    /// The spec with images still to be built swapped out, so pricing doesn't fail on a tag
    /// that isn't pushed yet: the size is what's priced.
    static func withoutBuiltImages(_ spec: [String: Any], builds: [(build: DOImageBuild, repository: String)]) -> [String: Any] {
        var spec = spec
        let names = Set(builds.map(\.build.component))
        for list in ["services", "workers", "jobs"] {
            guard var components = spec[list] as? [[String: Any]] else { continue }
            for index in components.indices where names.contains(components[index]["name"] as? String ?? "") {
                components[index]["image"] = ["registry_type": "DOCKER_HUB", "registry": "library", "repository": "nginx", "tag": "1.27-alpine"]
            }
            spec[list] = components
        }
        return spec
    }
}
