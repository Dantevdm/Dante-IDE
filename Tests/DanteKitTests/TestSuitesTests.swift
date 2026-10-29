import Foundation
import Testing
@testable import DanteKit

struct TestSuitesTests {
    /// A repo of apps two folders down, as in a services/ monorepo.
    private let files = [
        "README.md",
        "services/api/pom.xml", "services/api/mvnw",
        "services/api/core/pom.xml",
        "services/api/src/main/java/shop/OrderService.java",
        "services/api/src/test/java/shop/OrderServiceTest.java",
        "services/web/package.json", "services/web/package-lock.json",
        "services/web/src/Cart.test.tsx",
        "services/web/node_modules/left-pad/package.json",
    ]
    private let packages = [
        "services/web/package.json": #"{"scripts": {"test": "react-scripts test"}, "dependencies": {"react": "18.3.1"}}"#,
        "services/web/node_modules/left-pad/package.json": #"{"scripts": {"test": "jest"}}"#,
    ]

    private var suites: [TestSuite] { TestSuites.find(files: files) { packages[$0] } }

    @Test func findsAppsBelowTheTopFolder() {
        #expect(suites.map(\.folder) == ["services/api", "services/web"])
        #expect(suites[0].tool == .maven && suites[0].runner == "./mvnw" && suites[0].side == .backEnd)
        #expect(suites[1].tool == .node && suites[1].runner == "npm" && suites[1].side == .frontEnd && suites[1].framework == "react-scripts")
    }

    @Test func runsEachAppInItsFolder() throws {
        let command = try #require(TestSuites.command(suites))
        let script = command.arguments[2]
        #expect(script.contains("(cd services/api && ./mvnw -B test) || status=1"))
        #expect(script.contains("(cd services/web && CI=true npm test -- --verbose --watchAll=false) || status=1"))
        #expect(command.reportFolders.contains("services/api/target/surefire-reports"))
    }

    @Test func narrowsToTheTestsOfOneKind() throws {
        let java = WrittenTest(name: "placesAnOrder", file: "services/api/src/test/java/shop/OrderServiceTest.java", line: 9, category: "Back-end", area: "")
        let web = WrittenTest(name: "adds to cart", file: "services/web/src/Cart.test.tsx", line: 3, category: "Front-end", area: "")
        let backEnd = try #require(TestSuites.command(suites, only: [java]))
        #expect(backEnd.arguments[2] == "cd services/api && ./mvnw -B test -Dtest=OrderServiceTest -Dsurefire.failIfNoSpecifiedTests=false -DfailIfNoTests=false")
        let frontEnd = try #require(TestSuites.command(suites, only: [web]))
        #expect(frontEnd.arguments[2] == "cd services/web && CI=true npm test -- --verbose --watchAll=false src/Cart.test.tsx")
    }

    @Test func swiftAtTheRootRunsDirectly() throws {
        let suites = TestSuites.find(files: ["Package.swift", "Tests/AppTests/AppTests.swift"]) { _ in nil }
        let command = try #require(TestSuites.command(suites))
        #expect(command.arguments == ["swift", "test"])
        #expect(command.readsXUnit)
    }

    @Test func sortsTestsByKind() {
        #expect(TestInventory.category(path: "services/api/src/test/java/shop/OrderServiceTest.java", text: "", side: .backEnd) == "Back-end")
        #expect(TestInventory.category(path: "services/web/src/Cart.test.tsx", text: "", side: .frontEnd) == "Front-end")
        #expect(TestInventory.category(path: "web/src/Cart.test.tsx", text: "") == "Front-end", "a tsx test is front-end without a suite")
        #expect(TestInventory.category(path: "api/src/test/java/shop/security/LoginTest.java", text: "") == "Security")
        #expect(TestInventory.category(path: "api/src/test/java/shop/OrderRepositoryTest.java", text: "@Testcontainers class X { testcontainers }") == "Integration")
        #expect(TestInventory.nameCategory("rejectsAnExpiredToken") == "Security")
        #expect(TestInventory.category(path: "Tests/AppTests/AppTests.swift", text: "", side: .app) == "Unit")
    }

    @Test func groupsTheMapByKind() {
        let inventory = TestInventory(tests: [
            WrittenTest(name: "a", file: "web/src/A.test.tsx", line: 1, category: "Front-end", area: "web/src"),
            WrittenTest(name: "b", file: "api/BTest.java", line: 1, category: "Back-end", area: "api"),
            WrittenTest(name: "c", file: "api/CTest.java", line: 1, category: "Back-end", area: "api"),
        ])
        let kinds = TestMap.build(inventory: inventory, runs: []).kinds(order: inventory.categories)
        #expect(kinds.map(\.name) == ["Front-end", "Back-end"])
        #expect(kinds[1].tiles.count == 2)
    }
}
