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
        let files = workspace.files, read = Self.reader(root)
        pools = await Task.detached { ConnectionPool.detect(files: files, read: read) }.value
        analyse(workspace: workspace)
    }

    /// Database connection pools in the code, for the advice.
    var pools: [ConnectionPool]?

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
        defer { loading = false; lastRefreshed = .now }
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
        var inputs = DOAdvice.Inputs(file: spec, fileText: specText, live: app, dockerfiles: dockerfiles, ignoresEnv: ignores, envFiles: envFiles,
                                     headers: headers, health: health, alerts: alerts, restarts: restarts, sizes: sizes)
        inputs.pools = pools ?? []
        inputs.clusterSizes = Dictionary(clusters.compactMap { cluster in cluster.size.map { (cluster.name, $0) } }, uniquingKeysWith: { first, _ in first })
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
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try plan.spec.yaml(header: Self.specHeader).write(to: url, atomically: true, encoding: .utf8)
            specText = try String(contentsOf: url, encoding: .utf8)
            spec = plan.spec
            session.open(file: url)
        } catch {
            problem = "Couldn’t write \(DOAppSpec.path): \(error.localizedDescription)"
        }
    }

    static let specHeader = [
        "App Platform spec for DigitalOcean, written by Dante from the project. Edit it freely:",
        "Dante deploys what's here. Secrets are type: SECRET without a value; Dante asks for them",
        "when you deploy and DigitalOcean keeps them encrypted.",
        "Reference: https://docs.digitalocean.com/products/app-platform/reference/app-spec/",
    ]

    // MARK: The wizard

    /// The deploy wizard's steps. The first six edit the spec; leaving them saves it and prices it.
    enum WizardStep: Int, CaseIterable, Comparable {
        case source, region, parts, variables, data, reach, secrets, review

        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .source: "Source"
            case .region: "Region"
            case .parts: "Components"
            case .variables: "Variables"
            case .data: "Database"
            case .reach: "Domains & alerts"
            case .secrets: "Secrets"
            case .review: "Review"
            }
        }

        var symbol: String {
            switch self {
            case .source: "arrow.triangle.branch"
            case .region: "globe.europe.africa"
            case .parts: "square.stack.3d.up"
            case .variables: "list.bullet.rectangle"
            case .data: "cylinder.split.1x2"
            case .reach: "bell.badge"
            case .secrets: "key"
            case .review: "checkmark.seal"
            }
        }
    }

    var wizardStep: WizardStep?
    /// The choices being made, with an estimate kept in step.
    var setup: DOSetup? { didSet { if setup != oldValue { setupEstimate = setupPrice() } } }
    private(set) var setupStart: DOSetup?
    private(set) var setupEstimate: Double?
    var clusters: [DODatabaseCluster] = []
    var setupProblem: String?
    private var isDemo = false
    var isDemoMode: Bool { isDemo }

    var setupChanged: Bool { setup != setupStart || specText == nil }

    /// Opens the wizard on the spec (or, before there is one, on the plan Dante would write).
    func openWizard() {
        guard !isDeploying, let spec = spec ?? plan?.spec, !spec.components.isEmpty else { return }
        deployProblem = nil
        setupProblem = nil
        var choices = DOSetup(spec: spec, region: region)
        if let specText { choices.readTargets(from: specText) }
        setupStart = choices
        setup = choices
        wizardStep = .source
        guard signedIn, !isDemo else { return }
        Task {
            if sizes.isEmpty { sizes = (try? await client.instanceSizes()) ?? [] }
            clusters = (try? await client.databaseClusters()) ?? []
        }
    }

    func closeWizard() {
        cancelDeploy()
        wizardStep = nil
        resizing = nil
        editingVariables = false
        rotating = []
        costAcknowledged = false
        setup = nil
        setupStart = nil
        setupProblem = nil
    }

    /// Back to the choices from pricing: whatever was priced no longer counts.
    func goBack(to step: WizardStep) {
        if step < .secrets, stage == .checking || stage == .needsSecrets || stage == .confirming {
            deployTask?.cancel()
            stage = nil
            proposal = nil
            needed = []
        }
        wizardStep = step
    }

    /// Writes the choices into `.do/app.yaml` (only when they changed) and prices the deploy.
    func saveSetup(workspace: Workspace) {
        guard let setup else { return }
        setupProblem = setup.problems.first
        guard setupProblem == nil else { return }
        if setupChanged {
            let url = workspace.url.appending(path: DOAppSpec.path)
            do {
                let base = specText ?? plan?.spec.yaml(header: Self.specHeader) ?? ""
                let text = try setup.written(into: base)
                guard case .success(let read) = DOAppSpec.read(text) else {
                    setupProblem = "The choices didn’t make a spec App Platform can read."
                    return
                }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
                specText = text
                spec = read
                specProblem = nil
                setupStart = setup
            } catch {
                setupProblem = "Couldn’t write \(DOAppSpec.path): \(error.localizedDescription)"
                return
            }
        }
        wizardStep = .secrets
        #if DEBUG
        if isDemo { showDemo(workspace: workspace); return }
        #endif
        prepare(workspace: workspace)
    }

    private func setupPrice() -> Double? {
        guard let setup, let base = specText ?? plan?.spec.yaml(),
              let text = try? setup.written(into: base), case .success(let read) = DOAppSpec.read(text) else { return nil }
        // Autoscaling bills at least the smallest count.
        var spec = read
        for (index, part) in setup.parts.enumerated() where part.autoscale != nil {
            for list in [\DOAppSpec.services, \DOAppSpec.workers] {
                if let at = spec[keyPath: list]?.firstIndex(where: { $0.name == part.name }) {
                    spec[keyPath: list]?[at].instanceCount = setup.parts[index].autoscale?.minimum
                }
            }
        }
        return Self.estimate(spec, sizes: sizes)
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
        costAcknowledged = false
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
            addRotating()
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
                    deployProblem = DOClient.explain(error.message)
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
            if wizardStep == nil || wizardStep! < .secrets || needed.isEmpty { wizardStep = needed.isEmpty ? .review : .secrets }
        }
    }

    /// Secrets being changed are asked for too; the typed value wins over the kept one.
    private func addRotating() {
        for id in rotating.sorted() where !needed.contains(where: { $0.id == id }) && (typedSecrets[id] ?? "").isEmpty {
            let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
            needed.append(parts.count == 2 ? .init(component: parts[0], key: parts[1]) : .init(component: nil, key: id))
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
            if !isDemo { proposal = try? await client.propose(DOSpecSend.json(probe), appID: app?.id) }
            stage = .confirming
            wizardStep = .review
        }
    }

    #if DEBUG
    /// `DANTE_DEPLOY_DEMO=1`: opens the deploy sheet on the project's own spec with a made-up
    /// team and registry and no DigitalOcean calls, to look at the sheet without spending anything.
    func showDemo(workspace: Workspace) {
        guard stage == nil, let specText, case .success(var object) = DOSpecSend.object(yaml: specText) else { return }
        if !isDemo {
            // First call: made-up sizes and a cluster, then the wizard from its first step.
            isDemo = true
            person = DOSignIn.Person(name: "Sam", email: nil, team: "Acme")
            sizes = Self.demoSizes
            clusters = [DODatabaseCluster(id: "1", name: "acme-db", engine: "pg", version: "16", region: "fra1", size: "db-s-1vcpu-1gb", status: "online", numNodes: 1)]
            openWizard()
            return
        }
        stage = .checking
        databaseBindings = DOSpecSend.databaseBindings(in: object)
        needed = DOSpecSend.prepare(&object)
        addRotating()
        envMatches = Self.envValues(for: needed, spec: object, root: workspace.url)
        let planned = DOPlan.make(projectName: workspace.url.lastPathComponent, files: workspace.files, read: Self.reader(workspace.url),
                                  compose: ComposeFile.load(projectRoot: workspace.url), source: .builtHere, branch: branch, region: region).builds
        builds = DODocker.builds(for: object, planned: planned)
        registryInUse = "acme"
        preparedSpec = object
        estimate = setupEstimate ?? 12
        stage = needed.isEmpty ? .confirming : .needsSecrets
        wizardStep = needed.isEmpty ? .review : .secrets
    }

    /// `DANTE_DEPLOY_DEMO=live`: the page as for a running app (made up, no network), for
    /// checking the Components, Database and Getting in cards.
    func showLiveDemo() {
        guard let specText, case .success(var object) = DOSpecSend.object(yaml: specText) else { return }
        isDemo = true
        person = DOSignIn.Person(name: "Sam", email: nil, team: "Acme")
        sizes = Self.demoSizes
        object["databases"] = [["name": "db", "engine": "PG", "version": "16"], ["name": "orders", "engine": "PG", "cluster_name": "acme-db"]]
        var services = object["services"] as? [[String: Any]] ?? []
        if !services.isEmpty {
            var envs = services[0]["envs"] as? [[String: Any]] ?? []
            envs.append(["key": "DATABASE_URL", "value": "${db.DATABASE_URL}", "scope": "RUN_TIME"])
            services[0]["envs"] = envs
            object["services"] = services
        }
        let wire: [String: Any] = ["id": "demo", "live_url": "https://shop-demo.ondigitalocean.app", "region": ["slug": "fra"],
                                   "active_deployment": ["id": "d1", "phase": "ACTIVE"], "spec": object]
        app = DOApp.parse(wire)
        clusters = [DODatabaseCluster(id: "1", name: "acme-db", engine: "pg", version: "16", region: "fra1", size: "db-s-1vcpu-2gb", status: "online", numNodes: 1)]
        clusterBackups["1"] = [DODatabaseBackup(createdAt: "2026-11-10T03:12:00Z", sizeGigabytes: 0.42), DODatabaseBackup(createdAt: "2026-11-09T03:11:00Z", sizeGigabytes: 0.41)]
        monthToDate = 23.41
        trouble = ["api restarted 4 times today."]
    }

    static let demoSizes: [DOInstanceSize] = [
        ("apps-s-1vcpu-0.5gb", "1", 0.5, 5), ("apps-s-1vcpu-1gb", "1", 1, 12), ("apps-s-1vcpu-2gb", "1", 2, 25), ("apps-s-2vcpu-4gb", "2", 4, 50),
        ("apps-d-1vcpu-0.5gb", "1", 0.5, 29), ("apps-d-1vcpu-1gb", "1", 1, 34), ("apps-d-2vcpu-4gb", "2", 4, 78), ("apps-d-4vcpu-8gb", "4", 8, 156),
    ].map { DOInstanceSize(name: nil, slug: $0.0, cpus: $0.1, memoryBytes: String(Int($0.2 * 1_073_741_824)), usdPerMonth: String($0.3), tierSlug: nil) }
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
        #if DEBUG
        // The demo stops short of anything real.
        if isDemo { closeWizard(); return }
        #endif
        wizardStep = nil
        setup = nil
        setupStart = nil
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
                deployProblem = DOClient.explain(error.message)
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

    // MARK: Console

    /// The component whose console is being opened, for the button's spinner.
    var openingConsole: String?

    /// Opens a shell in a running component in a terminal tab of its own, through the bundled
    /// `dante do-console` (DigitalOcean's console WebSocket; the address goes over in a one-use
    /// file, never on the command line).
    func openConsole(_ component: String, run command: String? = nil, session: Session) {
        guard let id = app?.id, openingConsole == nil else { return }
        guard let dante = Session.danteCommand else {
            problem = "The console needs Dante's bundled command, which only the app has."
            return
        }
        openingConsole = component
        Task {
            defer { openingConsole = nil }
            do throws(DOClient.Failure) {
                let url = try await client.consoleURL(id, component: component)
                guard let file = try? DOConsole.handOver(url, run: command) else { problem = "Couldn’t hand the console over to the terminal."; return }
                session.runInNewTerminal("\(Shell.quote(dante)) do-console \(Shell.quote(file.path))", title: "\(component) on DigitalOcean")
            } catch {
                if error.status == 403 {
                    problem = "This DigitalOcean sign-in isn’t allowed to open a console (app:access_console): it was granted before Dante asked for that. Sign out and sign in again to allow it."
                } else {
                    report(error)
                }
            }
        }
    }

    // MARK: Database (DeployModel+Database.swift)

    /// Backups Dante made on this Mac, by database, newest first.
    var localBackups: [String: [URL]] = [:]
    /// Bumped when the nightly setting changes, so views redraw.
    var nightlyChanged = 0
    var nightlyProblem: String?
    /// What's wrong with the live app now, in short lines (`DeployWatch`), for the companion.
    var trouble: [String] = []
    var watched: DeployWatch.State?
    var lastRefreshed: Date?
    /// The team's bill this month so far, and when it was read.
    var monthToDate: Double?
    var spendingLoaded: Date?
    var spendingProblem: String?
    var spendingChanged = 0
    /// The person read the cost warning on the review step and still wants to deploy.
    var costAcknowledged = false
    /// A managed cluster's daily backups, by cluster id.
    var clusterBackups: [String: [DODatabaseBackup]] = [:]
    /// What's being done to a database ("Backing up db…"), one thing at a time.
    var databaseWork: String?
    var databaseNotice: String?
    var databaseProblem: String?
    /// The component whose size the wizard opened on (Resize…), showing only that one.
    var resizing: String?
    /// The wizard opened on the variables alone (Edit variables…).
    var editingVariables = false
    /// Secrets the person wants to give a new value (`Needed.id`), asked for like missing ones.
    var rotating: Set<String> = []

    // MARK: Getting in

    /// How someone gets into the app: `.dante/access.yaml`, or Dante's guess from the code.
    var access: AccessGuide?
    private var accessRevision: Int?

    /// Reads the file, or drafts a guide off the main thread (it reads the code that checks
    /// requests, scripts and the README).
    func loadAccess(workspace: Workspace) async {
        guard accessRevision != workspace.revision else { return }
        accessRevision = workspace.revision
        let root = workspace.url
        if let text = try? String(contentsOf: root.appending(path: AccessGuide.path), encoding: .utf8), let guide = AccessGuide.read(yaml: text) {
            access = guide
            return
        }
        let files = workspace.files
        let spec = spec ?? plan?.spec
        let variables = (spec?.envs ?? []).map(\.key) + (spec?.components ?? []).flatMap { ($0.component.envs ?? []).map(\.key) }
        let component = consoleComponent
        access = await Task.detached(priority: .utility) {
            AccessGuide.detect(files: files, read: Self.reader(root), variables: variables, component: component)
        }.value
    }

    /// The service a console step opens in when the guide doesn't name one.
    var consoleComponent: String? {
        let components = (app?.spec ?? spec ?? plan?.spec)?.components ?? []
        return (components.first { $0.kind == .service } ?? components.first { $0.kind == .worker })?.component.name
    }

    /// Saves the draft as `.dante/access.yaml`, so it can be corrected and travels with the repo.
    func saveAccess(workspace: Workspace) {
        guard let access, !access.isWritten else { return }
        let file = workspace.url.appending(path: AccessGuide.path)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try access.yaml.write(to: file, atomically: true, encoding: .utf8)
            self.access?.isWritten = true
        } catch {
            problem = "Couldn’t write \(AccessGuide.path): \(error.localizedDescription)"
        }
    }

    /// Runs a step where it belongs: in the running component's console, or here in a terminal tab.
    func run(_ step: AccessGuide.Step, session: Session) {
        guard let command = step.command(url: app?.liveURL) else { return }
        switch step.place {
        case .console:
            if let component = step.component ?? consoleComponent { openConsole(component, run: command, session: session) }
        case .local:
            let line = step.folder.map { "cd \(Shell.quote($0)) && \(command)" } ?? command
            session.runInNewTerminal(line, title: step.title)
        case .note:
            break
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
        for (kind, component) in spec.components where kind != .staticSite && !(kind == .job && component.kind?.uppercased().hasSuffix("_DEPLOY") == true) {
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
