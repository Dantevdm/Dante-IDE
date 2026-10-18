import Foundation
import Testing
@testable import DanteKit

@Suite struct SecurityToolsTests {
    @Test func readsSemgrep() {
        let json = #"{"results":[{"check_id":"javascript.express.security.audit.express-sql-injection","path":"./api/users.js","start":{"line":12},"extra":{"message":"Possible SQL injection","severity":"ERROR","lines":"db.query('x' + id)","metadata":{"cwe":["CWE-89: SQL Injection"],"impact":"HIGH"}}}],"errors":[]}"#
        let found = SecurityToolOutput.semgrep(json)
        #expect(found.count == 1)
        #expect(found[0].file == "api/users.js" && found[0].line == 12)
        #expect(found[0].severity == .high && found[0].reference == "CWE-89" && found[0].category == .code)
    }

    @Test func readsGitleaksRedacted() {
        let json = #"[{"RuleID":"slack-bot-token","Description":"Slack token","File":"config/app.yml","StartLine":3,"Match":"token: xoxb-REDACTED","Secret":"REDACTED"}]"#
        let found = SecurityToolOutput.gitleaks(json)
        #expect(found.first?.category == .secrets && found.first?.line == 3)
    }

    @Test func readsOSVScanner() {
        let json = #"{"results":[{"source":{"path":"/home/me/app/package-lock.json"},"packages":[{"package":{"name":"lodash","version":"4.17.15","ecosystem":"npm"},"vulnerabilities":[{"id":"GHSA-35jh-r3h4-6jhm","summary":"Command injection in lodash","affected":[{"package":{"name":"lodash"},"ranges":[{"events":[{"introduced":"0"},{"fixed":"4.17.21"}]}]}]}],"groups":[{"ids":["GHSA-35jh-r3h4-6jhm"],"max_severity":"7.2"}]}]}]}"#
        let found = SecurityToolOutput.osvScanner(json)
        #expect(found.first?.severity == .high)
        #expect(found.first?.fix == "Upgrade lodash to 4.17.21 or later.")
        #expect(found.first?.file == "package-lock.json")
    }

    @Test func readsGovulncheckOnlyWhenCalled() {
        let stream = """
        {"osv":{"id":"GO-2024-0001","summary":"Bad parsing in x/net"}}
        {"finding":{"osv":"GO-2024-0001","fixed_version":"v0.23.0","trace":[{"module":"golang.org/x/net","version":"v0.20.0","package":"golang.org/x/net/html","function":"Parse"},{"module":"example.com/app","package":"example.com/app/web","function":"Render","position":{"filename":"web/render.go","line":40}}]}}
        {"finding":{"osv":"GO-2024-0002","trace":[{"module":"golang.org/x/text","version":"v0.3.0"}]}}
        """
        let found = SecurityToolOutput.govulncheck(stream)
        #expect(found.map(\.reference) == ["GO-2024-0001"])
        #expect(found.first?.file == "web/render.go" && found.first?.line == 40)
        #expect(found.first?.fix == "Upgrade golang.org/x/net to v0.23.0 or later.")
    }

    @Test func readsNpmAudit() {
        let json = #"{"auditReportVersion":2,"vulnerabilities":{"minimist":{"name":"minimist","severity":"critical","via":[{"source":1,"title":"Prototype Pollution in minimist","url":"https://github.com/advisories/GHSA-xvch-5gv4-984h"}],"range":"<1.2.6","fixAvailable":true},"mkdirp":{"name":"mkdirp","severity":"critical","via":["minimist"],"range":"0.4.1 - 0.5.1","fixAvailable":true}}}"#
        let found = SecurityToolOutput.npmAudit(json)
        #expect(found.count == 1)
        #expect(found[0].severity == .critical && found[0].reference == "GHSA-xvch-5gv4-984h")
    }

    @Test func readsPipAudit() {
        let json = #"{"dependencies":[{"name":"flask","version":"0.5","vulns":[{"id":"PYSEC-2019-179","fix_versions":["1.0"],"description":"Flask before 1.0 allows a denial of service."}]},{"name":"requests","version":"2.32.0","vulns":[]}]}"#
        let found = SecurityToolOutput.pipAudit(json)
        #expect(found.count == 1 && found[0].fix == "Upgrade flask to 1.0 or later.")
    }

    @Test func readsLockfiles() {
        let lock = #"{"lockfileVersion":3,"packages":{"":{"name":"app"},"node_modules/lodash":{"version":"4.17.21"},"node_modules/@scope/pkg":{"version":"1.0.0"},"node_modules/a/node_modules/b":{"version":"2.0.0"}}}"#
        #expect(Dependencies.parse(lock, file: "package-lock.json").map(\.name) == ["@scope/pkg", "b", "lodash"])
        let yarn = "# yarn lockfile v1\n\n\"@babel/core@^7.0.0\", \"@babel/core@^7.1.0\":\n  version \"7.24.0\"\n  resolved \"x\"\n\nlodash@^4.17.0:\n  version \"4.17.21\"\n"
        #expect(Dependencies.parse(yarn, file: "yarn.lock").map { "\($0.name)@\($0.version)" } == ["@babel/core@7.24.0", "lodash@4.17.21"])
        let pnpm = "lockfileVersion: '9.0'\n\npackages:\n\n  '@scope/pkg@1.0.0':\n    resolution: {integrity: x}\n\n  lodash@4.17.21(peer@1.0.0):\n    resolution: {}\n"
        #expect(Dependencies.parse(pnpm, file: "pnpm-lock.yaml").map { "\($0.name)@\($0.version)" } == ["@scope/pkg@1.0.0", "lodash@4.17.21"])
        let gomod = "module example.com/app\n\ngo 1.22\n\nrequire github.com/a/b v1.2.3\n\nrequire (\n\tgolang.org/x/net v0.20.0 // indirect\n\tgithub.com/c/d v0.1.0\n)\n"
        #expect(Dependencies.parse(gomod, file: "go.mod").map(\.version) == ["v1.2.3", "v0.20.0", "v0.1.0"])
        #expect(Dependencies.parse("flask==2.0.1\nrequests>=2\nuvicorn[standard]==0.30.0 ; python_version>'3.8'\n", file: "requirements.txt").map(\.name) == ["flask", "uvicorn"])
        let cargo = "[[package]]\nname = \"serde\"\nversion = \"1.0.200\"\n\n[[package]]\nname = \"tokio\"\nversion = \"1.37.0\"\n"
        #expect(Dependencies.parse(cargo, file: "Cargo.lock").map(\.ecosystem) == ["crates.io", "crates.io"])
        let gems = "GEM\n  remote: https://rubygems.org/\n  specs:\n    rack (2.2.8)\n    rails (7.1.3)\n      rack (>= 2.2.4)\n\nPLATFORMS\n  ruby\n"
        #expect(Dependencies.parse(gems, file: "Gemfile.lock").map { "\($0.name)@\($0.version)" } == ["rack@2.2.8", "rails@7.1.3"])
        let resolved = #"{"pins":[{"identity":"yams","location":"https://github.com/jpsim/Yams.git","state":{"version":"5.1.3"}}],"version":2}"#
        #expect(Dependencies.parse(resolved, file: "Package.resolved").first?.name == "https://github.com/jpsim/Yams")
    }

    @Test func buildsOSVQueries() throws {
        let body = OSV.batchBody([Dependency(ecosystem: "npm", name: "lodash", version: "4.17.15", file: "package-lock.json")])
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let query = try #require((object["queries"] as? [[String: Any]])?.first)
        #expect((query["package"] as? [String: String])?["ecosystem"] == "npm")
        #expect(query["version"] as? String == "4.17.15")
        let ids = OSV.batchIDs(Data(#"{"results":[{"vulns":[{"id":"GHSA-1"},{"id":"CVE-2"}]},{}]}"#.utf8))
        #expect(ids == [["GHSA-1", "CVE-2"], []])
        #expect(OSV.preferred(["CVE-2", "GHSA-1", "PYSEC-3"]) == ["GHSA-1", "PYSEC-3"])
    }

    @Test func splitsAJSONStream() {
        #expect(JSONStream.objects("{\"a\":\"}{\"}\n{\"b\":{\"c\":1}}").count == 2)
    }

    @Test func onlyOfflineToolsRunWithoutCheckingOnline() {
        let online = SecurityTool.all.filter(\.sendsDependencies).map(\.name)
        #expect(online == ["OSV-Scanner", "govulncheck", "npm audit", "pip-audit"])
    }
}
