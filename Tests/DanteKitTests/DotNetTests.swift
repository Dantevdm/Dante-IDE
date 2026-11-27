import Foundation
import Testing
@testable import DanteKit

struct DotNetTests {
    @Test func readsAspNetRoutes() {
        let minimal = """
        var app = builder.Build();
        app.MapGet("/", () => "ok");
        var api = app.MapGroup("/api");
        var orders = api.MapGroup("orders");
        orders.MapGet("/{id}", (int id) => id);
        orders.MapPost("", (Order o) => o);
        // app.MapDelete("/old", …) is gone
        """
        let routes = SystemMap.serverRoutes(file: "src/Program.cs", text: minimal)
        #expect(routes.map { "\($0.method ?? "") \($0.path)" } == ["GET /", "GET /api/orders/{id}", "POST /api/orders"])
        #expect(routes[1].line == 5)

        let controller = """
        [ApiController]
        [Route("api/[controller]")]
        public class OrdersController : ControllerBase
        {
            [HttpGet]
            public IEnumerable<Order> List() => [];

            [HttpGet("{id}")]
            [ProducesResponseType(200)]
            public ActionResult<Order> Get(int id) => Ok();

            [HttpPost("[action]"), Authorize]
            public IActionResult Import(Order o) => Ok();

            [HttpDelete("/admin/purge")]
            public IActionResult Purge() => Ok();
        }
        """
        let actions = SystemMap.serverRoutes(file: "src/Controllers/OrdersController.cs", text: controller)
        #expect(actions.map { "\($0.method ?? "") \($0.path)" } == ["GET /api/Orders", "GET /api/Orders/{id}", "POST /api/Orders/Import", "DELETE /admin/purge"])
    }

    @Test func findsDeclarations() {
        let text = """
        namespace Shop.Data;

        public sealed record PendingEvent(long Id, string Name);

        public class OrderStore
        {
            public async Task<IReadOnlyList<Order>> ReadAsync(CancellationToken token)
            {
                return await Query();
            }
            private static int Count(int a) => a;
        }
        """
        let names = DeclarationScanner.symbols(in: text, language: .csharp, url: URL(filePath: "/x.cs")).map(\.name)
        #expect(names == ["PendingEvent", "OrderStore", "ReadAsync", "Count"])
    }

    @Test func graphsEveryProjectInTheRepo() throws {
        let files = [
            "v1/agent/go.mod", "v1/agent/main.go", "v1/agent/db/db.go",
            "v1/ui/go.mod", "v1/ui/main.go", "v1/ui/frontend/package.json", "v1/ui/frontend/src/App.tsx",
            "v2/Shop.sln", "v2/src/Shop.Api/Shop.Api.csproj", "v2/src/Shop.Api/Program.cs", "v2/src/Shop.Core/Shop.Core.csproj",
            "v2/src/Shop.Core/Orders.cs", "v2/tests/Shop.Tests/Shop.Tests.csproj", "v2/tests/Shop.Tests/OrderTests.cs",
            "v2/src/Shop.Api/bin/Debug/Shop.Api.csproj",
        ]
        let texts = [
            "v1/agent/go.mod": "module example.com/agent\n", "v1/ui/go.mod": "module example.com/ui\n",
            "v1/agent/main.go": "package main\nimport \"example.com/agent/db\"\n", "v1/agent/db/db.go": "package db\n",
            "v1/ui/main.go": "package main\n",
            "v2/src/Shop.Api/Shop.Api.csproj": #"<Project Sdk="Microsoft.NET.Sdk.Web"><ItemGroup><ProjectReference Include="..\Shop.Core\Shop.Core.csproj" /></ItemGroup></Project>"#,
            "v2/src/Shop.Core/Shop.Core.csproj": #"<Project Sdk="Microsoft.NET.Sdk"></Project>"#,
            "v2/tests/Shop.Tests/Shop.Tests.csproj": #"<Project Sdk="Microsoft.NET.Sdk"><PackageReference Include="Microsoft.NET.Test.Sdk" /><PackageReference Include="xunit" /></Project>"#,
        ]
        let graph = try #require(ArchitectureGraph.projects(files: files, read: { texts[$0] }))
        let names = graph.nodes.filter { $0.kind != .external }.map(\.name)
        #expect(names.contains("agent") && names.contains("db") && names.contains("ui"))
        #expect(names.contains("Shop.Api") && names.contains("Shop.Core") && names.contains("Shop.Tests"))
        #expect(graph.node("dotnet:v2/src/Shop.Api/Shop.Api.csproj")?.detail == "1 file · ASP.NET Core")
        #expect(graph.node("dotnet:v2/tests/Shop.Tests/Shop.Tests.csproj")?.kind == .test)
        #expect(graph.edges.contains(.init(from: "dotnet:v2/src/Shop.Api/Shop.Api.csproj", to: "dotnet:v2/src/Shop.Core/Shop.Core.csproj")))
        #expect(graph.edges.contains(.init(from: "example.com/agent", to: "example.com/agent/db")))
        // One Go module alone is still the Go graph.
        #expect(ArchitectureGraph.projects(files: ["go.mod", "main.go"], read: { $0 == "go.mod" ? "module m\n" : "package main\n" }) == nil)

        let layout = RepoLayout.detect(files: files)
        #expect(layout.projects.map(\.path) == ["v1/agent", "v1/ui", "v2"])
        #expect(layout.groups.map(\.name) == ["v1", "v2"])
        #expect(layout.groups[0].summary == "2 Go projects")
        #expect(layout.groups[1].summary == ".NET")
        #expect(layout.group(of: "v2/src/Shop.Core")?.name == "v2")
        #expect(RepoLayout.files(files, in: "v1").allSatisfy { $0.hasPrefix("v1/") })
        // One project, or projects that don't part ways, give no choice.
        #expect(!RepoLayout.detect(files: ["go.mod", "web/package.json"]).hasGroups)

        let map = SystemMap(parts: [.init(id: "code:a", name: "db", lane: .backend, kind: .package, detail: "1 file", path: "v1/agent/db")], links: [])
        #expect(map.labelled(by: layout).parts[0].detail == "v1 · 1 file")
    }

    @Test func runsAndReadsDotnetTest() throws {
        let files = ["v2/Shop.sln", "v2/src/Shop.Api/Shop.Api.csproj", "v2/tests/Shop.Tests/Shop.Tests.csproj", "tool/Tool.csproj"]
        let texts = ["v2/tests/Shop.Tests/Shop.Tests.csproj": "<PackageReference Include=\"Microsoft.NET.Test.Sdk\" />", "tool/Tool.csproj": "<Project />"]
        let suites = TestSuites.find(files: files, read: { texts[$0] })
        #expect(suites.map(\.folder) == ["v2"])
        let suite = try #require(suites.first)
        #expect(suite.script() == "dotnet test --logger 'console;verbosity=normal'")
        let test = WrittenTest(name: "AddsUp", file: "v2/tests/Shop.Tests/OrderTests.cs", line: 3, category: "Unit", area: "")
        #expect(suite.script(only: [test]).contains("--filter 'FullyQualifiedName~OrderTests|FullyQualifiedName~AddsUp'"))

        var parser = TestOutputParser()
        for line in """
          Passed Shop.Tests.OrderTests.AddsUp [3 ms]
          Failed Shop.Tests.OrderTests.Breaks(count: 2) [12 ms]
          Error Message:
           Assert.Equal() Failure: Values differ
           Expected: 2
          Stack Trace:
             at Shop.Tests.OrderTests.Breaks(Int32 count) in /home/me/shop/v2/tests/Shop.Tests/OrderTests.cs:line 14
          Skipped Shop.Tests.OrderTests.Later [1 ms]
        Failed!  - Failed:     1, Passed:     1, Skipped:     1, Total:     3
        """.components(separatedBy: "\n") { parser.consume(line) }
        #expect(parser.results.map(\.status) == [.passed, .failed, .skipped])
        #expect(parser.results[0].suite == "Shop.Tests.OrderTests" && parser.results[0].name == "AddsUp")
        #expect(parser.results[1].name == "Breaks(count: 2)")
        #expect(parser.results[1].issues.first?.message == "Assert.Equal() Failure: Values differ\nExpected: 2")
        #expect(parser.results[1].issues.first?.line == 14)
        #expect(parser.results[1].issues.first?.file?.hasSuffix("OrderTests.cs") == true)
    }

    @Test func findsWrittenTests() {
        let text = """
        public class OrderTests
        {
            [Fact]
            public void AddsUp() { }

            [Theory]
            [InlineData(2)]
            public async Task Breaks(int count) { }

            [Test, Category("slow")]
            public void Later() { }
        }
        """
        #expect(TestInventory.isTestFile("tests/Shop.Tests/OrderTests.cs"))
        #expect(!TestInventory.isTestFile("src/Shop.Api/Program.cs"))
        #expect(TestInventory.tests(in: text, path: "tests/Shop.Tests/OrderTests.cs").map(\.name) == ["AddsUp", "Breaks", "Later"])
    }

    @Test func followsUsingLinesInsideAProject() {
        let found = ArchitectureGraph.imports(of: "src/Api/Endpoints/Orders.cs", text: "using System.Text;\nusing Api.Data;\nglobal using Api.Data.Models;\n",
                                              javaRoot: nil, base: "src/Api", goModule: nil)
        #expect(found == ["src/Api/Data", "src/Api/Data/Models"])
    }

    @Test func aSQLServerContainerIsItsStore() {
        let files = ["api/Api.csproj", "api/Program.cs"]
        let texts = ["api/Api.csproj": #"<Project Sdk="Microsoft.NET.Sdk.Web"><PackageReference Include="Microsoft.Data.SqlClient" /></Project>"#,
                     "api/Program.cs": "var app = WebApplication.Create();\napp.MapGet(\"/orders\", () => new SqlConnection(cs));\n"]
        let compose = ComposeFile(services: [.init(name: "db", image: "mcr.microsoft.com/mssql/server:2022-latest")])
        let map = SystemMap.build(files: files, read: { texts[$0] }, compose: compose)
        #expect(map.parts.first { $0.id == "db:sqlserver" }?.container == "db")
        #expect(!map.parts.contains { $0.id == "svc:db" })
    }
}
