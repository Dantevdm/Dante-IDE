import Foundation
import Testing
@testable import DanteKit

struct ComposeDiagnosisTests {
    let services = [
        ComposeFile.Service(name: "app", build: ".", ports: ["3000:3000"], dependsOn: ["llm"]),
        ComposeFile.Service(name: "llm", image: "ollama/ollama", ports: ["127.0.0.1:11434:11434/tcp"]),
    ]

    @Test func readsPublishedPorts() {
        #expect(services[0].publishedPorts == [3000])
        #expect(services[1].publishedPorts == [11434])
        #expect(ComposeFile.Service(name: "x", ports: ["8080", "9000-9002:9000-9002"]).publishedPorts == [9000])
    }

    @Test func parsesListeningPorts() {
        let output = "p700\ncControlCenter\nf9\nn*:7000\nf10\nn*:7000\np812\ncnotifications\nf4\nn*:3000\np900\nccom.docker.backend\nf5\nn[::1]:5432\n"
        let ports = ListeningPort.parse(output)
        #expect(ports == [
            ListeningPort(port: 7000, pid: 700, command: "ControlCenter"),
            ListeningPort(port: 3000, pid: 812, command: "notifications"),
            ListeningPort(port: 5432, pid: 900, command: "com.docker.backend"),
        ])
        #expect(ports[2].isDocker && !ports[1].isDocker)
    }

    @Test func explainsAServiceWaitingOnAnUnhealthyOne() {
        let containers = [
            ContainerState(service: "app", state: "created", status: "Created"),
            ContainerState(service: "llm", state: "running", health: "unhealthy"),
        ]
        let notes = ComposeDiagnosis.notes(services: services, containers: containers, holders: [],
                                           healthOutput: ["llm": "\"curl\": executable file not found in $PATH"])
        #expect(notes["app"] == "Hasn’t started: it waits for llm, which is unhealthy.")
        #expect(notes["llm"] == "Its health check fails: \"curl\": executable file not found in $PATH")
    }

    @Test func aTakenPortComesFirst() {
        let containers = [ContainerState(service: "app", state: "created"), ContainerState(service: "llm", state: "running", health: "healthy")]
        let holders = [PortHolder(listening: ListeningPort(port: 3000, pid: 812, command: "notifications"), elapsed: "01:16:22"),
                       PortHolder(listening: ListeningPort(port: 11434, pid: 900, command: "com.docker.backend"))]
        let notes = ComposeDiagnosis.notes(services: services, containers: containers, holders: holders)
        #expect(notes["app"]?.hasPrefix("Port 3000 is already in use by notifications (pid 812, up 01:16:22).") == true)
        #expect(notes["llm"] == nil)
    }

    @Test func runningServicesNeedNoNote() {
        let containers = [ContainerState(service: "app", state: "running"), ContainerState(service: "llm", state: "running", health: "healthy")]
        // The app's own published port is held by Docker; a running service isn't checked anyway.
        let notes = ComposeDiagnosis.notes(services: services, containers: containers, holders: [PortHolder(listening: ListeningPort(port: 3000, pid: 1, command: "x"))])
        #expect(notes.isEmpty)
    }

    @Test func readsTheLastFailingHealthCheck() {
        let json = #"{"Status":"unhealthy","FailingStreak":3,"Log":[{"ExitCode":0,"Output":"ok"},{"ExitCode":-1,"Output":"OCI runtime exec failed: exec failed: unable to start container process: exec: \"curl\": executable file not found in $PATH: unknown"}]}"#
        #expect(ComposeDiagnosis.lastHealthFailure(json) == "\"curl\": executable file not found in $PATH")
        #expect(ComposeDiagnosis.lastHealthFailure(#"{"Log":[{"ExitCode":1,"Output":"connection refused\n"}]}"#) == "connection refused")
        #expect(ComposeDiagnosis.lastHealthFailure("null") == nil)
    }
}
