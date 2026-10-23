import Foundation
import Testing
@testable import DanteKit

@Suite struct TestCommandTests {
    @Test func narrowsEachRunnerToChosenTests() {
        let swift = TestCommand(label: "swift test", arguments: ["swift", "test"], readsXUnit: true)
        let narrowed = swift.only([TestResult(suite: "MathTests", name: "adds()", status: .failed),
                                   TestResult(suite: "", name: "loose()", status: .failed)])
        #expect(narrowed?.arguments == ["swift", "test", "--filter", #"MathTests/adds\(\)|loose\(\)"#])
        #expect(narrowed?.label == "swift test · 2 tests" && narrowed?.readsXUnit == true)

        let go = TestCommand(label: "go test -v ./...", arguments: ["go", "test", "-v", "./..."], readsXUnit: false)
        #expect(go.only([TestResult(suite: "shop", name: "TestLimit/zero", status: .failed)])?.arguments
                == ["go", "test", "-v", "-run", "^(TestLimit)$", "./..."])

        let cargo = TestCommand(label: "cargo test", arguments: ["cargo", "test"], readsXUnit: false)
        #expect(cargo.only([TestResult(suite: "parser::tests", name: "splits", status: .failed)])?.arguments
                == ["cargo", "test", "--", "parser::tests::splits"])

        let pytest = TestCommand(label: "pytest -v", arguments: ["python3", "-m", "pytest", "-v"], readsXUnit: false)
        #expect(pytest.only([TestResult(suite: "tests/test_a.py", name: "test_b", status: .failed)])?.arguments.last == "tests/test_a.py::test_b")
        #expect(pytest.only([TestResult(suite: "tests/test_a.py", name: "test_b", status: .failed)])?.label == "pytest -v · test_b")

        let npm = TestCommand(label: "npm test", arguments: ["npm", "test"], readsXUnit: false)
        #expect(npm.only([TestResult(suite: "src/a.test.ts", name: "adds (1+1)", status: .failed)])?.arguments
                == ["npm", "test", "--", "src/a.test.ts", "-t", #"adds \(1\+1\)"#])

        let custom = TestCommand(label: "make test", arguments: ["sh", "-c", "make test"], readsXUnit: false)
        #expect(custom.only([TestResult(suite: "", name: "x", status: .failed)]) == nil)
        #expect(swift.only([]) == nil)
    }

    @Test func findsRunnersInAppFolders() throws {
        let folder = try TemporaryFolder()
        _ = try folder.write("api/pom.xml", "<project/>")
        _ = try folder.write("web/package.json", #"{"scripts": {"test": "vitest"}}"#)
        _ = try folder.write("docs/package.json", #"{"scripts": {"test": "jest"}}"#)
        let both = TestCommand.detect(projectRoot: folder.url)
        #expect(both?.label == "mvn test in api · npm test in web")
        #expect(both?.arguments == ["sh", "-c", "status=0; (cd api && mvn -B test) || status=1; (cd web && npm test) || status=1; exit $status"])

        let gradle = try TemporaryFolder()
        _ = try gradle.write("service/build.gradle.kts", "")
        _ = try gradle.write("service/gradlew", "")
        #expect(TestCommand.detect(projectRoot: gradle.url)?.arguments == ["sh", "-c", "cd service && ./gradlew test"])
        #expect(TestCommand.detect(projectRoot: gradle.url)?.label == "./gradlew test in service")

        _ = try gradle.write("go.mod", "module x")
        #expect(TestCommand.detect(projectRoot: gradle.url)?.label == "go test -v ./...")
    }
}
