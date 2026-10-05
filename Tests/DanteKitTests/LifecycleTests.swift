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
