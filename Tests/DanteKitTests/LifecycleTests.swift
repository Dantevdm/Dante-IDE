import DanteKit
import Foundation
import Testing

struct LifecycleTests {
    @Test func readsCurrentPhase() {
        let yaml = """
        name: ledger-api
        lifecycle:
          template: service@1
          current: build   # where we are
        phases:
          build:
            current: not-this-one
        """
        let lifecycle = Lifecycle.parse(projectYAML: yaml)
        #expect(lifecycle.hasSpec)
        #expect(lifecycle.phases == Lifecycle.defaultPhases)
        #expect(lifecycle.currentIndex == 3)
    }

    @Test func readsCustomPhases() {
        let yaml = """
        lifecycle:
          phases: [define, design, build, validate, change, operate]
          current: "validate"
        """
        let lifecycle = Lifecycle.parse(projectYAML: yaml)
        #expect(lifecycle.phases == ["Define", "Design", "Build", "Validate", "Change", "Operate"])
        #expect(lifecycle.currentIndex == 3)
    }

    @Test func unknownPhaseHasNoCurrent() {
        let lifecycle = Lifecycle.parse(projectYAML: "lifecycle:\n  current: shipping\n")
        #expect(lifecycle.hasSpec)
        #expect(lifecycle.currentIndex == nil)
    }

    @Test func missingSpec() throws {
        let folder = try TemporaryFolder()
        let lifecycle = Lifecycle.load(projectRoot: folder.url)
        #expect(!lifecycle.hasSpec)
        #expect(lifecycle.currentIndex == nil)
    }

    @Test func loadsFromDanteFolder() throws {
        let folder = try TemporaryFolder()
        try folder.write(".dante/project.yaml", "lifecycle:\n  current: test\n")
        #expect(Lifecycle.load(projectRoot: folder.url).currentIndex == 4)
    }
}

struct LifecycleTemplateTests {
    @Test func templateSuppliesThePhases() {
        let lifecycle = Lifecycle.parse(projectYAML: "lifecycle:\n  template: infra@1\n  current: validate\n")
        #expect(lifecycle.phases == LifecycleTemplate.infra.phaseNames)
        #expect(lifecycle.currentIndex == 3)
        #expect(lifecycle.phaseDocTemplate("Validate").contains("- [ ] Change set or plan reviewed"))
    }

    @Test func explicitPhasesWinOverTheTemplate() {
        let lifecycle = Lifecycle.parse(projectYAML: "lifecycle:\n  template: apple@1\n  phases: [Build, Ship]\n")
        #expect(lifecycle.phases == ["Build", "Ship"])
        #expect(lifecycle.template?.id == "apple")
    }

    @Test func unknownTemplateFallsBackToDefaults() {
        #expect(Lifecycle.parse(projectYAML: "lifecycle:\n  template: nope@2\n").phases == Lifecycle.defaultPhases)
        #expect(LifecycleTemplate.named("APP@1")?.id == "app")
    }

    @Test func suggestions() {
        #expect(LifecycleTemplate.suggest(for: ["main.tf", "variables.tf", "README.md"]).id == "infra")
        #expect(LifecycleTemplate.suggest(for: ["App.xcodeproj/project.pbxproj", "App/ContentView.swift"]).id == "apple")
        #expect(LifecycleTemplate.suggest(for: ["notebooks/explore.ipynb", "load.py"]).id == "data")
        #expect(LifecycleTemplate.suggest(for: ["package.json", "src/index.ts", "src/app.ts"]).id == "app")
        #expect(LifecycleTemplate.suggest(for: []).id == "app")
        let cfn = LifecycleTemplate.suggest(for: ["template.yaml", "src/handler.py"]) { _ in "AWSTemplateFormatVersion: '2010-09-09'" }
        #expect(cfn.id == "infra")
    }

    @Test func projectYAMLRoundTrips() {
        let yaml = LifecycleTemplate.data.projectYAML(name: "Sales: daily", summary: "Loads \"orders\".", current: "Build")
        let lifecycle = Lifecycle.parse(projectYAML: yaml)
        #expect(lifecycle.template?.id == "data")
        #expect(lifecycle.phases[lifecycle.currentIndex ?? 0] == "Build")
        #expect(yaml.contains(#"name: "Sales: daily""#))
    }
}

@MainActor
struct WorkspaceSetUpTests {
    @Test func setUpWritesTheSpecAndKeepsExistingFiles() throws {
        let folder = try TemporaryFolder()
        try folder.write("README.md", "# Billing\n\n![badge](x.svg)\n\nCharges customers **monthly**, see [docs](docs/).\nSecond line.\n\nMore.\n")
        try folder.write(".dante/phases/build.md", "# Build\n\nMine.\n")
        let workspace = Workspace(url: folder.url)
        try workspace.setUp(with: .apple, current: "Beta")
        #expect(workspace.lifecycle.template?.id == "apple")
        #expect(workspace.lifecycle.phases[workspace.lifecycle.currentIndex ?? 0] == "Beta")
        let project = try String(contentsOf: folder.url.appending(path: ".dante/project.yaml"), encoding: .utf8)
        #expect(project.contains("Charges customers monthly, see docs. Second line."))
        #expect(try String(contentsOf: folder.url.appending(path: ".dante/phases/build.md"), encoding: .utf8) == "# Build\n\nMine.\n")
        #expect(FileManager.default.fileExists(atPath: folder.url.appending(path: ".dante/phases/beta.md").path))
        #expect(try String(contentsOf: folder.url.appending(path: ".dante/tasks.yaml"), encoding: .utf8).contains("prefix: "))
    }

    @Test func taskPrefixes() {
        #expect(Workspace.taskPrefix(for: "Dante IDE") == "DI")
        #expect(Workspace.taskPrefix(for: "billing") == "BIL")
        #expect(Workspace.taskPrefix(for: "my-web-app-v2") == "MWA")
    }
}
