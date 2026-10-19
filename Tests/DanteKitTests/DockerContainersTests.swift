import DanteKit
import Testing

struct DockerContainersTests {
    let output = """
    {"Names":"shop-db-1","Image":"postgres:17-alpine","State":"running","Status":"Up 5 hours (healthy)","Ports":"0.0.0.0:5434->5432/tcp","Labels":"com.docker.compose.project=shop,com.docker.compose.service=db"}
    {"Names":"sp-pg","Image":"postgres:16.4","State":"exited","Status":"Exited (0) 29 hours ago","Ports":"","Labels":""}
    {"Names":"sp-api","Image":"shop-portal:local","State":"exited","Status":"Exited (143) 2 days ago","Ports":"0.0.0.0:8088->8080/tcp, [::]:8088->8080/tcp","Labels":""}
    {"Names":"other-pg","Image":"mysql:8","State":"running","Status":"Up 1 hour","Ports":"127.0.0.1:3307->3306/tcp","Labels":""}
    {"Names":"mail-1","Image":"axllent/mailpit","State":"exited","Status":"Exited (0) 7 days ago","Ports":"","Labels":"com.docker.compose.project=notifications"}
    """

    @Test func readsDockerPs() {
        let containers = DockerContainer.parse(output)
        #expect(containers.map(\.name) == ["shop-db-1", "sp-pg", "sp-api", "other-pg", "mail-1"])
        #expect(containers[0].composeProject == "shop" && containers[0].isRunning && containers[0].hostPort(for: 5432) == 5434)
        #expect(containers[2].ports == [.init(host: 8088, container: 8080)])
        #expect(containers[1].engine == .postgres && containers[3].engine == .mysql && containers[2].engine == nil)
    }

    @Test func findsTheProjectsContainersOutsideCompose() {
        let related = DockerContainer.related(DockerContainer.parse(output), project: "shop-portal")
        // By initials (sp-) and by image name; compose's own and unrelated ones are left out.
        #expect(related.map(\.name) == ["sp-pg", "sp-api"])
        #expect(DockerContainer.related(DockerContainer.parse(output), project: "billing").isEmpty)
        let containers = DockerContainer.parse(output)
        #expect(containers[1].belonging(to: "shop-portal") == "named sp-")
        #expect(containers[2].belonging(to: "shop-portal") == "built as shop-portal:local")
        // Compose's own containers show with their services instead.
        #expect(containers[0].belonging(to: "shop") == nil)
    }

    @Test func readsPortBindingsOfAStoppedContainer() {
        let json = #"{"5432/tcp":[{"HostIp":"","HostPort":"55432"},{"HostIp":"::","HostPort":"55432"}],"9187/tcp":null,"80/tcp":[{"HostIp":"","HostPort":""}]}"#
        #expect(DockerContainer.bindings(json) == [.init(host: 55432, container: 5432)])
        #expect(DockerContainer.bindings("null").isEmpty)
    }

    @Test func aDatabaseContainerBecomesAConnection() throws {
        let container = DockerContainer(name: "sp-pg", image: "postgres:16.4", state: "running", ports: [.init(host: 55432, container: 5432)])
        let connection = try #require(container.connection(environment: ["POSTGRES_USER=portal", "POSTGRES_DB=portal", "POSTGRES_" + "PASSWORD=dev", "PATH=/usr/bin"]))
        #expect(connection.port == 55432 && connection.user == "portal" && connection.database == "portal" && connection.devPassword == "dev")
        #expect(connection.container == "sp-pg" && connection.service == nil && connection.origin == DatabaseConnection.Origin.detected)
        // Defaults when the image's variables aren't set.
        let bare = container.connection(environment: [])
        #expect(bare?.user == "postgres" && bare?.database == "postgres")
        // Not published to the Mac: nothing to connect to.
        #expect(DockerContainer(name: "x", image: "postgres", state: "exited").connection(environment: []) == nil)
    }
}
