import Foundation
import Testing
@testable import DanteKit

@Suite("Service opening")
struct ServiceOpeningTests {
    @Test func databasesOpenInDataAndWebInTheBrowser() {
        let db = ComposeFile.Service(name: "db", image: "postgres:17")
        #expect(ServiceOpening.target(service: db, ports: []) == .data)
        let app = ComposeFile.Service(name: "app", build: ".")
        #expect(ServiceOpening.target(service: app, ports: [":4317"]) == .browser(URL(string: "http://localhost:4317")!))
        #expect(ServiceOpening.target(service: app, ports: [":9229", ":3000"]) == .browser(URL(string: "http://localhost:3000")!))
        #expect(ServiceOpening.target(service: app, ports: []) == nil)
    }

    @Test func cachesAndQueuesDontOpenButTheirConsolesDo() {
        #expect(ServiceOpening.target(service: .init(name: "cache", image: "redis:7"), ports: [":6379"]) == nil)
        let rabbit = ComposeFile.Service(name: "queue", image: "rabbitmq:3-management")
        #expect(ServiceOpening.target(service: rabbit, ports: [":5672"]) == nil)
        #expect(ServiceOpening.target(service: rabbit, ports: [":5672", ":15672"]) == .browser(URL(string: "http://localhost:15672")!))
        #expect(ServiceOpening.target(service: .init(name: "mail", image: "axllent/mailpit"), ports: [":1025", ":8025"]) == .browser(URL(string: "http://localhost:8025")!))
    }
}
