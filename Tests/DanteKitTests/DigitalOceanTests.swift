import Foundation
import Testing
@testable import DanteKit

struct DigitalOceanTests {
    // MARK: Sources

    @Test func sourceFromRemotes() {
        #expect(DOSource.from(remote: "git@github.com:acme/shop.git") == .github(repo: "acme/shop"))
        #expect(DOSource.from(remote: "https://github.com/acme/shop") == .github(repo: "acme/shop"))
        #expect(DOSource.from(remote: "https://sam@bitbucket.org/acme/shop.git") == .bitbucket(repo: "acme/shop"))
        #expect(DOSource.from(remote: "ssh://git@gitlab.com/acme/group/shop.git") == .gitlab(repo: "acme/group/shop"))
        #expect(DOSource.from(remote: "https://git.example.test/acme/shop.git") == .builtHere)
        #expect(DOSource.from(remote: "https://git.example.test/acme/shop.git", isPublic: true) == .publicGit(url: "https://git.example.test/acme/shop.git"))
        #expect(DOSource.from(remote: nil) == .builtHere)
        #expect(DOSource.from(remote: "") == .builtHere)
    }

    // MARK: Planning

    static func reader(_ files: [String: String]) -> (String) -> String? { { files[$0] } }

    @Test func dockerfileBuiltHere() {
        let files = [
            "api/Dockerfile": "FROM golang:1.23 AS build\nRUN go build\nFROM alpine:3.20\nEXPOSE 9000/tcp\nCMD [\"/app\"]",
            "api/main.go": "package main\nfunc main() { http.HandleFunc(\"/healthz\", ok) }",
            "api/go.mod": "module shop",
            "api/.env.example": "DATABASE_URL=postgres://localhost/shop\nSTRIPE_SECRET_KEY=\nGREETING=hello\n",
        ]
        let compose = ComposeFile(url: URL(fileURLWithPath: "/home/me/shop/compose.yaml"), services: [.init(name: "db", image: "postgres:16-alpine")])
        let plan = DOPlan.make(projectName: "Acme Shop", files: Array(files.keys), read: Self.reader(files), compose: compose, source: .builtHere, branch: "main")
        #expect(plan.spec.name == "acme-shop")
        #expect(plan.spec.region == "fra")
        let api = plan.spec.services?.first
        #expect(api?.name == "api")
        #expect(api?.httpPort == 9000)
        #expect(api?.image?.registryType == "DOCR")
        #expect(api?.image?.repository == "acme-shop")
        #expect(api?.image?.tag == "api-latest")
        #expect(api?.dockerfilePath == nil)
        #expect(api?.sourceDir == nil)
        #expect(api?.healthCheck?.httpPath == "/healthz")
        #expect(plan.builds == [DOImageBuild(component: "api", context: "api", dockerfilePath: "api/Dockerfile")])
        #expect(plan.spec.databases == [.init(name: "db", engine: "PG", production: false)])
        let envs = api?.envs ?? []
        #expect(envs.first == .init(key: "DATABASE_URL", value: "${db.DATABASE_URL}", scope: "RUN_TIME"))
        #expect(envs.contains(.init(key: "STRIPE_SECRET_KEY", scope: "RUN_TIME", type: "SECRET")))
        #expect(envs.contains(.init(key: "GREETING", value: "hello", scope: "RUN_AND_BUILD_TIME")))
        #expect(plan.spec.alerts?.map(\.rule) == ["DEPLOYMENT_FAILED", "DOMAIN_FAILED"])
    }

    @Test func gitHostUsesBuildpacksAndStaticSites() {
        let files = [
            "web/package.json": #"{"name":"web","scripts":{"dev":"vite","build":"vite build"},"dependencies":{"react":"18","vite":"5"}}"#,
            "server/package.json": #"{"name":"server","scripts":{"start":"node index.js"},"dependencies":{"express":"4"}}"#,
            "server/index.js": "app.get('/health', ok)",
        ]
        let plan = DOPlan.make(projectName: "shop", files: Array(files.keys), read: Self.reader(files), source: .github(repo: "acme/shop"), branch: "main")
        let site = plan.spec.staticSites?.first
        #expect(site?.name == "web")
        #expect(site?.github == .init(repo: "acme/shop", branch: "main", deployOnPush: true))
        #expect(site?.sourceDir == "web")
        #expect(site?.buildCommand == "npm run build")
        #expect(site?.outputDir == "dist")
        let server = plan.spec.services?.first
        #expect(server?.name == "server")
        #expect(server?.httpPort == 3000)
        #expect(server?.healthCheck?.httpPath == "/health")
        #expect(plan.builds.isEmpty)
        #expect(plan.gaps.isEmpty)
    }

    @Test func builtHereWithoutDockerfileIsAGap() {
        let files = ["server/package.json": #"{"scripts":{"start":"node index.js"},"dependencies":{"express":"4"}}"#]
        let plan = DOPlan.make(projectName: "shop", files: Array(files.keys), read: Self.reader(files), source: .builtHere, branch: "main")
        #expect(plan.spec.services == nil)
        #expect(plan.gaps.count == 1)
    }

    @Test func plainHTMLBuiltHereIsServedByNginx() {
        let files = ["site/index.html": "<h1>Hi</h1>"]
        let plan = DOPlan.make(projectName: "Studio", files: Array(files.keys), read: Self.reader(files), source: .builtHere, branch: "main")
        #expect(plan.spec.services?.first?.name == "site")
        #expect(plan.spec.services?.first?.httpPort == 80)
        #expect(plan.builds.first?.dockerfile?.contains("-name '.*'") == true)
        let fromGit = DOPlan.make(projectName: "Studio", files: Array(files.keys), read: Self.reader(files), source: .gitlab(repo: "acme/studio"), branch: "main")
        #expect(fromGit.spec.staticSites?.first?.sourceDir == "site")
        #expect(fromGit.spec.services == nil)
    }

    @Test func aSiteFolderBesideAService() {
        let files = ["api/Dockerfile": "FROM alpine:3.20\nEXPOSE 8080", "api/www/index.html": "<p>", "site/index.html": "<p>"]
        let plan = DOPlan.make(projectName: "shop", files: Array(files.keys), read: Self.reader(files), source: .github(repo: "acme/shop"), branch: "main")
        #expect(plan.spec.services?.map(\.name) == ["api"])
        #expect(plan.spec.staticSites?.map(\.name) == ["site"])
        #expect(plan.spec.ingress?.rules == [.init(prefix: "/", component: "site"), .init(prefix: "/api", component: "api")])
        #expect(plan.spec.yaml().contains("prefix: /api"))
    }

    @Test func namesFollowAppPlatformRules() {
        #expect(DOPlan.appName("My Shop!") == "my-shop")
        #expect(DOPlan.appName("9lives") == "app-9lives")
        #expect(DOPlan.appName("x") == "app-x")
        #expect(DOPlan.appName(String(repeating: "a", count: 50)).count == 32)
    }

    // MARK: The spec file

    @Test func specRoundTripsThroughYAML() throws {
        var spec = DOAppSpec(name: "shop", region: "ams")
        var api = DOAppSpec.Component(name: "api")
        api.httpPort = 8080
        api.envs = [.init(key: "TOKEN", scope: "RUN_TIME", type: "SECRET")]
        spec.services = [api]
        let text = spec.yaml(header: ["Written by Dante"])
        #expect(text.hasPrefix("# Written by Dante\nname: shop\nregion: ams\nservices:"))
        #expect(text.contains("http_port: 8080"))
        #expect(!text.contains("static_sites"))
        #expect(try DOAppSpec.read(text).get() == spec)
    }

    @Test func specProblemsSayWhere() {
        guard case .failure(let problem) = DOAppSpec.read("region: ams\n") else { Issue.record("read a spec without a name"); return }
        #expect(problem.message == "name is missing.")
        guard case .failure(let typed) = DOAppSpec.read("name: x\nservices:\n  - name: api\n    http_port: lots\n") else { Issue.record("read a bad port"); return }
        #expect(typed.message.hasPrefix("services[0].http_port"))
    }

    // MARK: Sending

    @Test func yamlBecomesJSONKeepingTextAndUnknownKeys() throws {
        let yaml = """
        name: shop
        features: [buildpack-stack=ubuntu-22]
        services:
          - name: api
            http_port: 8080
            image: {registry_type: DOCR, repository: shop, tag: 1.0}
            maintenance: {enabled: false}
        databases:
          - name: db
            version: 16
        """
        let object = try DOSpecSend.object(yaml: yaml).get()
        let api = (object["services"] as? [[String: Any]])?.first
        #expect(api?["http_port"] as? Int == 8080)
        #expect((api?["image"] as? [String: Any])?["tag"] as? String == "1.0")
        #expect((api?["maintenance"] as? [String: Any])?["enabled"] as? Bool == false)
        #expect((object["databases"] as? [[String: Any]])?.first?["version"] as? String == "16")
        #expect(object["features"] as? [String] == ["buildpack-stack=ubuntu-22"])
    }

    @Test func secretsComeFromTypedThenLiveAndTagsAreFilled() throws {
        var spec = try DOSpecSend.object(yaml: """
        name: shop
        envs:
          - {key: SHARED_TOKEN, type: SECRET}
        services:
          - name: api
            image: {registry_type: DOCR, repository: shop, tag: api-latest, digest: sha256:abc}
            envs:
              - {key: STRIPE_KEY, type: SECRET, scope: RUN_TIME}
              - {key: SESSION_SECRET, type: SECRET}
              - {key: MODE, value: live}
        """).get()
        #expect(DOSpecSend.secrets(in: spec).map(\.id) == ["SHARED_TOKEN", "api/STRIPE_KEY", "api/SESSION_SECRET"])
        let live: [String: Any] = ["services": [["name": "api", "envs": [["key": "SESSION_SECRET", "type": "SECRET", "value": "EV[1:kept]"]]]]]
        let missing = DOSpecSend.prepare(&spec, tags: ["api": "api-1a2b3c4"], secrets: ["api/STRIPE_KEY": "typed"], live: live)
        #expect(missing == [.init(component: nil, key: "SHARED_TOKEN")])
        let api = (spec["services"] as? [[String: Any]])?.first
        let envs = api?["envs"] as? [[String: Any]] ?? []
        #expect(envs.first { $0["key"] as? String == "STRIPE_KEY" }?["value"] as? String == "typed")
        #expect(envs.first { $0["key"] as? String == "SESSION_SECRET" }?["value"] as? String == "EV[1:kept]")
        let image = api?["image"] as? [String: Any]
        #expect(image?["tag"] as? String == "api-1a2b3c4")
        #expect(image?["digest"] == nil)
    }

    @Test func wrapsTheSpecForTheAPI() throws {
        let body = DOClient.wrap(Data(#"{"name":"shop"}"#.utf8), appID: "abc")
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((object["spec"] as? [String: Any])?["name"] as? String == "shop")
        #expect(object["app_id"] as? String == "abc")
    }

    // MARK: Images

    @Test func tagsNameTheCommit() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(DODocker.tag(component: "api", commit: "1a2b3c4d5e6f", dirty: false, now: now) == "api-1a2b3c4")
        #expect(DODocker.tag(component: "api", commit: "1a2b3c4d5e6f", dirty: true, now: now) == "api-1a2b3c4-20270115-080000")
        #expect(DODocker.tag(component: "api", commit: nil, dirty: false, now: now) == "api-build-20270115-080000")
        #expect(DODocker.reference(registry: "acme", repository: "shop", tag: "api-1") == "registry.digitalocean.com/acme/shop:api-1")
    }

    @Test func buildsAreTheDOCRComponentsDanteKnows() throws {
        let spec = try DOSpecSend.object(yaml: """
        name: shop
        services:
          - {name: api, image: {registry_type: DOCR, repository: shop, tag: api-latest}}
          - {name: worker, image: {registry_type: DOCR, repository: shop, tag: worker-v1}}
          - {name: proxy, image: {registry_type: DOCKER_HUB, registry: library, repository: nginx, tag: "1.27"}}
        """).get()
        let planned = [DOImageBuild(component: "api", context: "api", dockerfilePath: "api/Dockerfile"), DOImageBuild(component: "proxy", context: "", dockerfilePath: "Dockerfile")]
        let builds = DODocker.builds(for: spec, planned: planned)
        #expect(builds.map(\.build.component) == ["api"])
        #expect(builds.first?.repository == "shop")
        let arguments = DODocker.buildArguments(reference: "r", context: URL(fileURLWithPath: "/home/me/shop/api"), dockerfile: URL(fileURLWithPath: "/home/me/shop/api/Dockerfile"))
        #expect(arguments.prefix(4) == ["docker", "build", "--platform", "linux/amd64"])
    }

    // MARK: Signing in

    @Test func signInPieces() throws {
        let registration = try #require(try JSONSerialization.jsonObject(with: DOSignIn.registration(redirect: DOSignIn.redirect(port: 51234))) as? [String: Any])
        #expect(registration["token_endpoint_auth_method"] as? String == "none")
        // DigitalOcean sends the browser to the registered address exactly, so the port is in it.
        #expect(registration["redirect_uris"] as? [String] == ["http://127.0.0.1:51234/callback"])
        #expect(registration["client_id"] == nil)
        let update = try #require(try JSONSerialization.jsonObject(with: DOSignIn.registration(redirect: "http://127.0.0.1:2/callback", clientID: "abc")) as? [String: Any])
        #expect(update["client_id"] as? String == "abc")
        let client = DOSignIn.client(Data(#"{"client_id":"abc","registration_access_token":"reg","redirect_uris":["http://127.0.0.1:51234/callback"]}"#.utf8))
        #expect(client == .init(id: "abc", registrationToken: "reg", redirect: "http://127.0.0.1:51234/callback"))
        #expect(client?.port == 51234)
        #expect(DOSignIn.Client(id: "abc", redirect: "http://127.0.0.1/callback").port == nil)
        #expect(DOSignIn.client(Data("{}".utf8)) == nil)

        let pkce = MicrosoftSignIn.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = DOSignIn.authorize(clientID: "abc", redirect: URL(string: "http://127.0.0.1:5555/callback")!, pkce: pkce, state: "s")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.host == "cloud.digitalocean.com")
        #expect(items["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["redirect_uri"] == "http://127.0.0.1:5555/callback")
        #expect(items["scope"]?.contains("app:create") == true)
        #expect(items["scope"]?.contains("droplet") == false)

        let answer = #"{"access_token":"doo_v1_a","refresh_token":"dor_v1_b","expires_in":3600,"scope":"app:read","info":{"name":"Sam","email":"sam@example.test","team_name":"Acme"}}"#
        let tokens = try DOSignIn.tokens(Data(answer.utf8), now: Date(timeIntervalSince1970: 0)).get()
        #expect(tokens.refresh == "dor_v1_b")
        #expect(tokens.expires == Date(timeIntervalSince1970: 3600))
        #expect(tokens.person?.label == "Sam · Acme")
        guard case .failure(.refused(let text)) = DOSignIn.tokens(Data(#"{"error":"invalid_grant","error_description":"Refresh token used"}"#.utf8)) else {
            Issue.record("accepted an error"); return
        }
        #expect(text == "Refresh token used")
        #expect(MicrosoftSignIn.code(fromRequest: "GET /callback?code=xyz&state=s HTTP/1.1\r\n", state: "s") == .success("xyz"))
    }

    // MARK: The API's answers

    @Test func readsAnAppAndItsDeployment() throws {
        let json = """
        {"id":"app-1","live_url":"https://shop-abc.ondigitalocean.app","region":{"slug":"ams"},"tier_slug":"basic",
         "spec":{"name":"shop","services":[{"name":"api","envs":[{"key":"TOKEN","type":"SECRET","value":"EV[1:x]"}]}]},
         "in_progress_deployment":{"id":"d2","phase":"BUILDING","cause":"manual","created_at":"2026-11-09T10:00:00Z",
           "progress":{"steps":[{"name":"build","status":"ERROR","steps":[{"name":"build","component_name":"api","status":"ERROR","reason":{"code":"BuildJobExitNonZero","message":"exit code 1"}}]},{"name":"deploy","status":"PENDING"}]},
           "services":[{"name":"api","source_commit_hash":"abcdef1234"}]},
         "active_deployment":{"id":"d1","phase":"ACTIVE"}}
        """
        let app = try #require(DOApp.parse(try JSONSerialization.jsonObject(with: Data(json.utf8))))
        #expect(app.name == "shop")
        #expect(app.liveURL?.host == "shop-abc.ondigitalocean.app")
        #expect(app.region == "ams")
        #expect(app.current?.id == "d2")
        #expect(app.current?.phase == .building)
        #expect(app.current?.phase.isRunning == true)
        #expect(app.current?.commit == "abcdef1234")
        #expect(app.current?.failure?.place == "Build › api")
        #expect(app.current?.failure?.message == "exit code 1")
        #expect(app.current?.created == Date(timeIntervalSince1970: 1_794_218_400))
        #expect(app.spec?.services?.first?.envs?.first?.isEncrypted == true)
        #expect(app.active?.phase == .active)
        #expect(DODeployment.Phase.superseded.isRunning == false)
    }

    @Test func seriesSumReplicas() {
        let json = #"{"status":"success","data":{"resultType":"matrix","result":[{"metric":{},"values":[[100,"10"],[160,"20"]]},{"metric":{},"values":[[100,"5"],[160,"7.5"]]}]}}"#
        let series = DOSeries.parse(Data(json.utf8))
        #expect(series.points.map(\.1) == [15, 27.5])
        #expect(series.last == 27.5)
        #expect(DOSeries.parse(Data("{}".utf8)).points.isEmpty)
    }

    @Test func failuresReadDigitalOceansMessage() {
        let failure = DOClient.Failure.parse(status: 422, data: Data(#"{"id":"unprocessable_entity","message":"GitHub user not authenticated"}"#.utf8))
        #expect(failure.message == "GitHub user not authenticated")
        #expect(DOClient.Failure.parse(status: 401, data: Data()).isSignedOut)
        #expect(DOClient.Failure.parse(status: 404, data: Data()).isMissing)
    }

    // MARK: Advice

    @Test func adviceOnAFreshSpec() throws {
        let text = """
        name: shop
        services:
          - name: api
            image: {registry_type: DOCR, repository: shop, tag: latest}
            envs:
              - {key: API_TOKEN, value: \("ghp_" + "abcdefghijklmnopqrstuvwxyz0123456789")}
              - {key: SESSION_SECRET, type: SECRET, value: \("hunter" + "2hunter2")}
              - {key: PAYMENT_KEY, type: SECRET}
        databases:
          - {name: db, engine: PG, production: false}
        """
        let spec = try DOAppSpec.read(text).get()
        let dockerfile = "FROM node\nWORKDIR /app\nCOPY . .\nCMD [\"node\", \"index.js\"]"
        let advice = DOAdvice.analyse(.init(file: spec, fileText: text, dockerfiles: ["Dockerfile": dockerfile], ignoresEnv: ["": false], envFiles: [""]))
        let ids = advice.map { String($0.id.split(separator: "|")[0]) }
        #expect(ids.contains("plain-secret"))
        #expect(ids.contains("secret-in-file"))
        #expect(ids.contains("secret-at-build"))    // PAYMENT_KEY without a scope reaches the build
        #expect(ids.contains("root-user"))
        #expect(ids.contains("unpinned-base"))
        #expect(ids.contains("env-in-image"))
        #expect(ids.contains("latest-tag"))
        #expect(ids.contains("dev-db"))
        #expect(ids.contains("no-health"))
        #expect(ids.contains("alert-deploy"))
        #expect(advice.first?.severity == .critical)
        #expect(advice.filter(\.isSecurity).count >= 5)
    }

    @Test func adviceIsQuietForAGoodSetUp() throws {
        let spec = try DOAppSpec.read("""
        name: shop
        alerts: [{rule: DEPLOYMENT_FAILED}]
        services:
          - name: api
            github: {repo: acme/shop, branch: release, deploy_on_push: true}
            instance_count: 2
            health_check: {http_path: /healthz}
            alerts: [{rule: MEM_UTILIZATION, operator: GREATER_THAN, value: 80, window: FIVE_MINUTES}]
            log_destinations: [{name: papertrail}]
            envs: [{key: TOKEN, type: SECRET, scope: RUN_TIME}]
        """).get()
        let dockerfile = "FROM node:22-alpine AS build\nCOPY . .\nFROM build AS final\nUSER node\nCMD [\"node\"]"
        let headers = ["strict-transport-security": "max-age=63072000", "x-content-type-options": "nosniff", "content-security-policy": "default-src 'self'"]
        let advice = DOAdvice.analyse(.init(file: spec, dockerfiles: ["Dockerfile": dockerfile], ignoresEnv: ["": true], envFiles: [""], headers: headers,
                                            health: [.init(name: "api", cpuUsagePercent: 20, memoryUsagePercent: 40, replicasDesired: 2, replicasReady: 2, state: "HEALTHY")]))
        #expect(advice.isEmpty, "\(advice.map(\.title))")
    }

    @Test func adviceFromTheLiveSite() {
        let advice = DOAdvice.analyse(.init(headers: ["x-powered-by": "Express", "server": "nginx/1.25.3"],
                                            health: [.init(name: "api", replicasDesired: 2, replicasReady: 1, state: "UNHEALTHY")],
                                            alerts: [.init(id: "a", spec: .init(rule: "DEPLOYMENT_FAILED"), emails: [])], restarts: ["api": 4]))
        let ids = Set(advice.map { String($0.id.split(separator: "|")[0]) })
        #expect(ids.isSuperset(of: ["header-strict-transport-security", "header-frames", "banner-x-powered-by", "banner-server", "unhealthy", "restarts", "alert-nobody"]))
        #expect(advice.first { $0.id.hasPrefix("restarts") }?.severity == .high)
    }

    @Test func dockerfileInstructionsJoinContinuations() {
        let lines = DOAdvice.instructions("# base\nFROM node:22 \\\n  AS build\nRUN npm ci && \\\n    npm run build\nUSER node")
        #expect(lines.map(\.0) == ["FROM", "RUN", "USER"])
        #expect(lines[0].1 == "node:22  AS build")
        #expect(DOAdvice.looksLikeCredential("postgres://app:pw@db:5432/app"))
        #expect(!DOAdvice.looksLikeCredential("production"))
    }

    @Test func registryRoomCountsOnlyNewRepositories() {
        // Starter holds one repository: a team's registry with another project's is full.
        #expect(DORegistryRoom.overflow(limit: 1, existing: ["order-service"], pushing: ["shop"]) == ["shop"])
        #expect(DORegistryRoom.overflow(limit: 1, existing: ["shop"], pushing: ["shop", "shop"]).isEmpty)
        #expect(DORegistryRoom.overflow(limit: 1, existing: [], pushing: ["shop"]).isEmpty)
        #expect(DORegistryRoom.overflow(limit: 5, existing: ["a", "b"], pushing: ["shop"]).isEmpty)
        // No limit known (or 0): never blocks.
        #expect(DORegistryRoom.overflow(limit: nil, existing: ["a"], pushing: ["shop"]).isEmpty)
        #expect(DORegistryRoom.overflow(limit: 0, existing: ["a"], pushing: ["shop"]).isEmpty)
    }

    @Test func runtimeLogsComeFromTheStream() {
        #expect(DOClient.socketURL("https://logs.example.com/live?token=t")?.absoluteString == "wss://logs.example.com/live?token=t")
        #expect(DOClient.socketURL("http://logs.example.com/live") == nil)
        #expect(DOClient.streamText(#"{"data":"api 12:00 GET / 200"}"#) == "api 12:00 GET / 200\n")
        #expect(DOClient.streamText("plain line\n") == "plain line\n")
    }

    @Test func databaseVariablesComeFromTheDatabase() {
        #expect(DOSpecSend.databaseField("POSTGRES_PASSWORD") == "PASSWORD")
        #expect(DOSpecSend.databaseField("DB_HOST") == "HOSTNAME")
        #expect(DOSpecSend.databaseField("PGUSER") == "USERNAME")
        #expect(DOSpecSend.databaseField("POSTGRES_DB") == "DATABASE")
        #expect(DOSpecSend.databaseField("ORDERS_DATABASE_URL") == "DATABASE_URL")
        #expect(DOSpecSend.databaseField("SHOP_PII_ENC_KEY") == nil)
        #expect(DOSpecSend.databaseField("REDIS_PASSWORD") == nil)
        #expect(DOSpecSend.databaseField("DB") == nil)

        var spec: [String: Any] = [
            "name": "shop",
            "databases": [["name": "db", "engine": "PG", "production": false]],
            "services": [["name": "api", "envs": [
                ["key": "POSTGRES_PASSWORD", "type": "SECRET", "scope": "RUN_TIME"],
                ["key": "SHOP_ADMIN_KEY", "type": "SECRET", "scope": "RUN_TIME"],
            ]]],
        ]
        #expect(DOSpecSend.databaseBindings(in: spec).map(\.binding) == ["${db.PASSWORD}"])
        let missing = DOSpecSend.prepare(&spec)
        #expect(missing.map(\.key) == ["SHOP_ADMIN_KEY"])
        let envs = ((spec["services"] as? [[String: Any]])?.first?["envs"] as? [[String: Any]]) ?? []
        #expect(envs.first?["value"] as? String == "${db.PASSWORD}")
        #expect(envs.first?["type"] as? String == "GENERAL")

        // Without a database in the spec, it's asked for like any other secret.
        var plain: [String: Any] = ["name": "shop", "envs": [["key": "POSTGRES_PASSWORD", "type": "SECRET"]]]
        #expect(DOSpecSend.prepare(&plain).map(\.key) == ["POSTGRES_PASSWORD"])
    }
}

@Test func aMissingScopeAsksToSignInAgain() {
    let message = "missing database create permission: rpc error: code = PermissionDenied desc = forbidden"
    #expect(DOSignIn.missingScope(in: message) == "database:create")
    #expect(DOSignIn.scopes.contains("database:create"))
    #expect(DOSignIn.explain(message).contains("Sign out and sign in again"))
    #expect(DOSignIn.explain("missing droplet delete permission: forbidden").contains("doesn’t ask for that"))
    #expect(DOSignIn.explain("Some other failure.") == "Some other failure.")
}
