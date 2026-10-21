import DanteKit
import Testing

struct RunnableAppsTests {
    let files: [String: String] = [
        "web/package.json": #"{"name":"web","scripts":{"dev":"vite","build":"vite build"},"dependencies":{"react":"18.3.1"}}"#,
        "web/pnpm-lock.yaml": "",
        "web/src/main.tsx": "",
        "server/go.mod": "module example.com/server",
        "server/cmd/api/main.go": "package main\nfunc main() {}",
        "server/cmd/worker/main.go": "package main\nfunc main() {}",
        "server/internal/tools/main.go": "package main",
        "server/Dockerfile": "FROM golang",
        "ml/requirements.txt": "fastapi==0.115\nuvicorn",
        "ml/app/main.py": "from fastapi import FastAPI\napi = FastAPI()\n",
        "scripts/package.json": #"{"name":"scripts","scripts":{"lint":"eslint ."}}"#,
        "web/node_modules/thing/package.json": #"{"scripts":{"start":"node x"}}"#,
    ]

    func detect(_ compose: ComposeFile? = nil) -> [RunnableApp] {
        RunnableApp.detect(files: Array(files.keys), read: { files[$0] }, compose: compose)
    }

    @Test func findsEachAppAndHowItStarts() {
        let apps = detect()
        #expect(apps.map(\.id) == ["web", "ml", "server#api", "server#worker"])
        let web = apps[0]
        #expect(web.kind == .frontend && web.stack == "React" && web.command == "pnpm dev" && web.commandFromRoot == "cd web && pnpm dev")
        #expect(apps[1].stack == "FastAPI" && apps[1].command == "uvicorn app.main:api --reload")
        #expect(apps[2].name == "api" && apps[2].command == "go run ./cmd/api" && apps[2].folder == "server" && apps[2].hasDockerfile)
    }

    @Test func knowsWhatComposeAlreadyRuns() {
        let compose = ComposeFile(services: [
            .init(name: "db", image: "postgres:17"),
            .init(name: "frontend", build: "./web"),
            .init(name: "worker", build: "./server"),
        ])
        let apps = detect(compose)
        #expect(apps.first { $0.id == "web" }?.service == "frontend")
        #expect(apps.first { $0.id == "server#worker" }?.service == "worker")
        // Built from the same module, but named for the other command: not the API.
        #expect(apps.first { $0.id == "server#api" }?.service == nil)
        #expect(apps.first { $0.id == "ml" }?.service == nil)
    }

    @Test func jvmDotnetAndRustServices() {
        let files = [
            "services/java/orders/mvnw": "",
            "services/java/orders/pom.xml": "<project><parent><artifactId>spring-boot-starter-parent</artifactId></parent></project>",
            "gradlew": "",
            "billing/build.gradle.kts": #"plugins { id("org.springframework.boot") version "3.3.0" }"#,
            "lib/pom.xml": "<project><packaging>pom</packaging><dependency>spring-boot</dependency></project>",
            "plain/pom.xml": "<project><artifactId>utils</artifactId></project>",
            "Api/Api.csproj": #"<Project Sdk="Microsoft.NET.Sdk.Web"></Project>"#,
            "Tools/Tools.csproj": #"<Project Sdk="Microsoft.NET.Sdk"></Project>"#,
            "relay/Cargo.toml": "[package]\nname = \"relay\"",
            "relay/src/main.rs": "fn main() {}",
        ]
        let apps = RunnableApp.detect(files: Array(files.keys), read: { files[$0] })
        #expect(apps.map(\.id) == ["Api", "billing", "relay", "services/java/orders"])
        #expect(apps[0].name == "Api" && apps[0].command == "dotnet watch run")
        #expect(apps[1].stack == "Spring Boot" && apps[1].command == "../gradlew bootRun")
        #expect(apps[2].command == "cargo run")
        #expect(apps[3].command == "./mvnw spring-boot:run" && apps[3].name == "orders")
    }

    @Test func aSingleNodeServerAndAMonorepoRoot() {
        let files = [
            "package.json": #"{"scripts":{"dev":"turbo run dev"}}"#,
            "api/package.json": #"{"scripts":{"start":"node index.js"},"dependencies":{"express":"4"}}"#,
            "api/yarn.lock": "",
        ]
        let apps = RunnableApp.detect(files: Array(files.keys), read: { files[$0] })
        #expect(apps.map(\.id) == ["api"])
        #expect(apps[0].kind == .backend && apps[0].stack == "Express" && apps[0].command == "yarn start")
    }

    @Test func aNodeAppWithoutNodeModulesInstallsFirst() {
        let web = RunnableApp(folder: "web", name: "web", kind: .frontend, stack: "Vite", command: "pnpm dev")
        #expect(web.needsInstall(exists: ["web/package.json"].contains))
        #expect(!web.needsInstall(exists: ["web/package.json", "web/node_modules"].contains))
        #expect(web.installingCommandFromRoot == "cd web && pnpm install && pnpm dev")
        let api = RunnableApp(folder: "api", name: "api", kind: .backend, stack: "Go", command: "go run ./cmd/api")
        #expect(!api.needsInstall(exists: { _ in false }) && api.installingCommandFromRoot == api.commandFromRoot)
    }
}
