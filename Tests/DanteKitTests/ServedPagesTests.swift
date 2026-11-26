import Foundation
import Testing
@testable import DanteKit

struct ServedPagesTests {
    @Test func placesUnderABackendsResources() {
        #expect(ServedPages.place(of: "resources/static/console")?.module == "")
        #expect(ServedPages.place(of: "resources/static/console")?.urlPath == "/console")
        #expect(ServedPages.place(of: "services/api/src/main/resources/static")?.module == "services/api")
        #expect(ServedPages.place(of: "services/api/src/main/resources/static")?.urlPath == "/")
        #expect(ServedPages.place(of: "src/main/resources/META-INF/resources/admin")?.urlPath == "/admin")
        #expect(ServedPages.place(of: "src/main/webapp")?.module == "")
        // Build output and a front-end's own public folder aren't served pages.
        #expect(ServedPages.place(of: "web/public") == nil)
        #expect(ServedPages.place(of: "build/resources/static") == nil)
        #expect(ServedPages.place(of: "static") == nil)
    }

    @Test func pageNamesAndAddresses() {
        #expect(ServedPages.screenName(of: "resources/static/console/index.html") == "console")
        #expect(ServedPages.screenName(of: "resources/static/console/report.html") == "console/report")
        #expect(ServedPages.screenName(of: "src/main/resources/static/index.html") == "home")
        #expect(ServedPages.urlPath(of: "resources/static/console/index.html", text: #"<script src="/console/app.js"></script>"#) == "/console")
        #expect(ServedPages.urlPath(of: "resources/static/console/index.html", text: #"<script src="app.js"></script>"#) == "/console/")
        #expect(ServedPages.urlPath(of: "resources/static/console/report.html", text: nil) == "/console/report.html")
        #expect(ServedPages.isScript("resources/static/console/app.js"))
        #expect(!ServedPages.isScript("resources/static/console/chart.min.js"))
    }

    @Test func theBackendsPortAndCommand() {
        let files = ["module.yaml", "kotlin", "mise.toml", "resources/application.yaml", "src/Application.kt"]
        let texts = [
            "mise.toml": "[tools]\njava = \"21\"\n\n[tasks.dev]\nrun = \"./kotlin run\"\n",
            "resources/application.yaml": "ktor:\n  deployment:\n    # the API\n    port: 8090\n",
        ]
        let port = ServedPages.port(module: "", files: files, read: { texts[$0] })
        #expect(port.port == 8090)
        #expect(port.source == "application.yaml")
        #expect(ServedPages.command(module: "", files: files, read: { texts[$0] }).command == "mise run dev")
        #expect(ServedPages.command(module: "", files: ["module.yaml", "kotlin"], read: { _ in nil }).command == "./kotlin run")
        let spring = ServedPages.command(module: "api", files: ["api/build.gradle.kts", "api/gradlew"],
                                         read: { $0 == "api/build.gradle.kts" ? "plugins { id(\"org.springframework.boot\") }" : nil })
        #expect(spring.command == "cd api && ./gradlew bootRun")
        #expect(ServedPages.configuredPort("server.port=9000") == 9000)
        #expect(ServedPages.configuredPort("ktor {\n  deployment {\n    port = 8081\n  }\n}") == 8081)
    }

    @Test func theMapListsThemAsAClient() throws {
        let files = ["module.yaml", "kotlin", "src/Routing.kt", "resources/static/console/index.html", "resources/static/console/api.js",
                     "resources/static/console/chart.min.js", "resources/static/error.html"]
        let texts = [
            "src/Routing.kt": "fun Application.routes() { routing { get(\"/orders\") { call.respond(\"ok\") } } }",
            "resources/static/console/index.html": #"<html><script src="/console/api.js"></script><button>Load orders</button></html>"#,
            "resources/static/console/api.js": "fetch('/orders').then(r => r.json())",
            "resources/static/error.html": "<html><p>Something went wrong</p></html>",
        ]
        let clients = SystemMap.frontends(files: files, read: { texts[$0] })
        let console = try #require(clients.first)
        #expect(clients.count == 1)
        #expect(console.id == "client:resources/static/console")
        #expect(console.name == "console")
        #expect(console.items.map(\.text) == ["console"])

        let target = WebPreview.target(folder: "resources/static/console", name: "console", files: files, read: { texts[$0] })
        #expect(target.served)
        #expect(target.folder == "")
        #expect(target.port == 8080)
        #expect(target.path == "/console")
        #expect(target.command == "./kotlin run")
        #expect(StoryKit.folder(frontend: target.folder) == "stories")
    }

    @Test func storiesGetTheirOwnPackage() {
        let names = StoryKit.files(existing: { _ in nil }, ownPackage: true).map(\.name)
        #expect(names.contains("package.json"))
        #expect(!StoryKit.files(existing: { _ in nil }).map(\.name).contains("package.json"))
        #expect(StoryKit.installCommand(storiesFolder: "stories") == "cd stories && npm install -D @playwright/test && ./node_modules/.bin/playwright install chromium")
    }
}
