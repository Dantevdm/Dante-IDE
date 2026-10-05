import Foundation
import Testing
@testable import DanteKit

@Suite struct ProjectSetupTests {
    @Test func emptyRepoIsStarting() {
        let profile = ProjectProfile.detect(paths: ["README.md"])
        #expect(profile.stage == .starting)
        #expect(profile.phase == "Discover")
        #expect(profile.stack.isEmpty)
    }

    @Test func nodeAppWithoutReleasesIsBuilding() {
        let paths = ["package.json", "Dockerfile", ".github/workflows/ci.yml"]
            + (1...12).map { "src/module\($0).ts" } + ["src/__tests__/module1.test.ts"]
        let profile = ProjectProfile.detect(paths: paths, commits: 40)
        #expect(profile.stack == ["TypeScript", "Docker", "GitHub Actions"])
        #expect(profile.template.id == "app")
        #expect(profile.stage == .building)
        #expect(profile.phase == "Build")
        #expect(profile.testFiles == 1)
        #expect(profile.hasCI)
    }

    @Test func taggedDeployedServiceIsOperating() {
        let paths = ["go.mod", "fly.toml"] + (1...8).map { "cmd/app/f\($0).go" }
        let profile = ProjectProfile.detect(paths: paths, commits: 300, tags: 4)
        #expect(profile.stage == .operating)
        #expect(profile.phase == "Operate")
        #expect(profile.stageReason == "4 tagged releases and deploy config")
    }

    @Test func stagesMapOntoEachTemplatesPhases() {
        #expect(ProjectProfile.phase(for: .verifying, in: .infra) == "Validate")
        #expect(ProjectProfile.phase(for: .releasing, in: .data) == "Schedule")
        #expect(ProjectProfile.phase(for: .operating, in: .data) == "Monitor")
        #expect(ProjectProfile.phase(for: .starting, in: .data) == "Explore")
    }

    @Test func findsSecretsButNotExamples() {
        let profile = ProjectProfile.detect(paths: [".env", ".env.local", ".env.example", "certs/server.pem", "secrets/db.txt", "config/credentials.json"])
        #expect(profile.sensitivePaths == [".env*", "*.pem", "secrets/", "config/credentials.json"])
    }

    @Test func defaultPartsFollowWhatWasFound() {
        let small = ProjectProfile.detect(paths: ["main.py"])
        #expect(ProjectSetupRequest.defaultParts(for: small) == [.summary, .phases, .tasks])
        let withSecrets = ProjectProfile.detect(paths: [".env", "app.py", "tests/test_app.py"])
        #expect(ProjectSetupRequest.defaultParts(for: withSecrets) == [.summary, .phases, .tasks, .tests, .rules])
    }

    @Test func promptListsOnlyThePickedParts() {
        let profile = ProjectProfile.detect(paths: [".env", "Package.swift", "Sources/A/a.swift"], commits: 3, testCommand: "swift test")
        let request = ProjectSetupRequest(template: .apple, phase: "Build", parts: [.rules, .summary])
        let prompt = request.prompt(profile: profile)
        #expect(prompt.contains("swift and apple platforms lifecycle"))
        #expect(prompt.contains("currently at Build"))
        #expect(prompt.contains("never: rules for .env*"))
        #expect(prompt.contains("tests run with `swift test`"))
        #expect(!prompt.contains("tasks.yaml"))
        #expect(request.summary == "Set this project up for Dante (swift and apple platforms, at Build): project summary and goals and keep Claude away from secrets.")
        // Summary comes before rules, whatever order they were picked in.
        #expect(prompt.range(of: "project.yaml, set name")!.lowerBound < prompt.range(of: "never: rules")!.lowerBound)
    }
}
