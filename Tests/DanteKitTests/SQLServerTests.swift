import Foundation
import Testing
@testable import DanteKit

struct SQLServerTests {
    @Test func scriptsGoInBatches() {
        let statements = SQLScript.statements("create view v as select 1 as a\nGO\nupdate t set a = 1 where a = 2; select * from t")
        #expect(statements.map(\.text) == ["create view v as select 1 as a", "update t set a = 1 where a = 2", "select * from t"])
        let script = SQLServer.script(statements)
        #expect(script.hasPrefix("SET NOCOUNT ON;\nGO\n"))
        #expect(script.contains("update t set a = 1 where a = 2\nSELECT @@ROWCOUNT AS rows_affected;\nGO\nPRINT '@@dante:1';"))
        // A GOTO label or a column named go isn't a batch separator.
        #expect(SQLScript.split("select go\nfrom t").count == 1)
        #expect(SQLScript.split("goto done").count == 1)
        #expect(SQLScript.quote("od]d", for: .sqlserver) == "[od]]d]")
        #expect(SQLStatement("exec sp_who").kind == .write)
    }

    @Test func readsItsOutput() {
        let s = SQLServer.separator
        let output = "id\(s)name    \(s)note\n--\(s)--------\(s)----\n 1\(s)Ana     \(s)NULL\n 2\(s)a, b    \(s)x\n@@dante:0\nrows_affected\n-------------\n            3\n@@dante:1\n@@dante:2\n"
        let statements = SQLScript.statements("select * from t; delete from t where id > 2; create table x (a int)")
        let run = DatabaseClient.parse(output, statements: statements, engine: .sqlserver)
        #expect(run.results.count == 3)
        #expect(run.results[0].columns == ["id", "name", "note"])
        #expect(run.results[0].rows == [["1", "Ana", nil], ["2", "a, b", "x"]])
        #expect(run.results[1].message == "3 rows affected")
        #expect(run.results[2].message == "Done")
        #expect(SQLServer.errors(in: "Msg 208, Level 16, State 1, Server x, Line 1\nInvalid object name 'nope'.\n") == "Invalid object name 'nope'.")
        #expect(SQLServer.errors(in: "Msg 5701, Level 0, State 2\nChanged database context.\n") == nil)
    }

    @Test func runsTheClientInItsContainer() {
        var connection = DatabaseConnection(name: "db", engine: .sqlserver, port: 1433, database: "Shop", user: "sa", service: "db")
        connection.composeFolder = "service/database"
        let command = DatabaseClient.command(for: SQLScript.statements("select 1"), on: connection, password: "pw",
                                             route: .compose(service: "db"), projectRoot: URL(filePath: "/home/me/shop"))
        #expect(command.arguments.prefix(7) == ["docker", "compose", "exec", "-T", "-e", "SQLCMDPASSWORD", "db"])
        #expect(command.arguments.contains("-d") && command.arguments.contains("Shop"))
        #expect(!command.arguments.contains("pw"))
        #expect(command.environment["SQLCMDPASSWORD"] == "pw")
        #expect(connection.composeDirectory(projectRoot: URL(filePath: "/home/me/shop")).path == "/home/me/shop/service/database")
        let local = DatabaseClient.command(for: [], on: connection, password: nil, route: .local("/opt/homebrew/bin/sqlcmd"), projectRoot: URL(filePath: "/"))
        #expect(local.arguments.prefix(3) == ["/opt/homebrew/bin/sqlcmd", "-S", "127.0.0.1,1433"])
    }

    @Test func connectionStrings() throws {
        let ado = try #require(SQLServer.connection(adoNet: "Server=localhost,1433;Database=Shop;User Id=sa;Password=p" + "w1;TrustServerCertificate=True;"))
        #expect(ado.engine == .sqlserver && ado.port == 1433 && ado.database == "Shop" && ado.user == "sa" && ado.devPassword == "pw1")
        #expect(SQLServer.connection(adoNet: "Data Source=tcp:db.example.com;Initial Catalog=Orders")?.host == "db.example.com")
        #expect(SQLServer.connection(adoNet: "Server=.\\SQLEXPRESS;Database=Shop") == nil)
        let npgsql = try #require(SQLServer.connection(adoNet: "Host=localhost;Port=5433;Database=shop;Username=app"))
        #expect(npgsql.engine == .postgres && npgsql.port == 5433)
        let jdbc = try #require(SQLServer.connection(jdbc: "jdbc:sqlserver://db:1433;databaseName=Shop;encrypt=true"))
        #expect(jdbc.database == "Shop" && jdbc.host == "db")
        let settings = "\u{FEFF}{\n  // local\n  \"ConnectionStrings\": { \"Default\": \"Server=localhost,1433;Database=Shop;User Id=sa;\" }\n}"
        #expect(SQLServer.connections(appSettings: settings, path: "src/appsettings.json").map(\.database) == ["Shop"])
    }

    @Test func findsItInAProjectWithSeveralParts() throws {
        let files = ["v2/api/src/appsettings.json", "v2/api/src/Api.csproj", "v2/api/database/compose.yml", "v2/api/database/shop.bak", "v1/tool/go.mod"]
        let compose = ComposeFile(url: URL(filePath: "/home/me/shop/v2/api/database/compose.yml"), services: [
            .init(name: "db", image: "mcr.microsoft.com/mssql/server:2022-latest", ports: ["1433:1433"], environment: ["MSSQL_SA_PASSWORD": "pw2"]),
            .init(name: "flyway", image: "flyway/flyway", environment: ["FLYWAY_URL": "jdbc:sqlserver://db:1433;databaseName=Shop;encrypt=true"]),
        ])
        #expect(ComposeFile.nested(in: files + ["node_modules/x/compose.yml"]) == ["v2/api/database/compose.yml"])
        let texts = [
            "v2/api/src/appsettings.json": #"{"ConnectionStrings": {"Default": "Server=localhost,1433;Database=Shop;User Id=sa;TrustServerCertificate=True"}}"#,
            "v2/api/src/Api.csproj": #"<PackageReference Include="Microsoft.Data.SqlClient" Version="6.0.0" />"#,
        ]
        let profile = DataDetector.detect(paths: files, nested: [("v2/api/database", compose)], read: { texts[$0] })
        let db = try #require(profile.connections.first)
        #expect(profile.connections.count == 1)
        #expect(db.engine == .sqlserver && db.database == "Shop" && db.service == "db" && db.composeFolder == "v2/api/database")
        #expect(db.devPassword == "pw2")
        #expect(profile.suggestedEngine == .sqlserver)
        #expect(profile.signals.contains { $0.label == "Microsoft.Data.SqlClient in Api.csproj" })
        #expect(SQLServerBackups.inProject(files) == ["v2/api/database/shop.bak"])
    }

    @Test func restoresABackup() {
        let header = QueryResult(columns: ["BackupName", "DatabaseName", "ServerName", "BackupFinishDate", "SoftwareVersionMajor"],
                                 rows: [[nil, "Shop", "prod-1", "2026-11-20 10:00:00", "16"]])
        #expect(SQLServerBackups.header(from: header) == BackupHeader(database: "Shop", server: "prod-1", finished: "2026-11-20 10:00:00", version: "SQL Server 2022"))
        let list = QueryResult(columns: ["LogicalName", "PhysicalName", "Type"],
                               rows: [["Shop", "D:\\data\\Shop.mdf", "D"], ["Shop_log", "D:\\data\\Shop_log.ldf", "L"]])
        let files = SQLServerBackups.files(from: list)
        let sql = SQLServerBackups.restoreSQL(path: "/var/opt/mssql/backup/shop.bak", database: "Shop Copy", files: files, makeSaOwner: true)
        #expect(sql.contains("MOVE N'Shop' TO N'/var/opt/mssql/data/Shop_Copy.mdf', MOVE N'Shop_log' TO N'/var/opt/mssql/data/Shop_Copy_log.ldf', REPLACE, RECOVERY"))
        #expect(sql.contains("ALTER AUTHORIZATION ON DATABASE::[Shop Copy] TO sa;"))
        #expect(sql.hasPrefix("IF DB_ID(N'Shop Copy') IS NOT NULL ALTER DATABASE [Shop Copy] SET SINGLE_USER"))
        #expect(SQLServerBackups.parseList("18291200\t1764248460.5\t/var/opt/mssql/backup/shop.bak\n").first?.name == "shop.bak")
        #expect(DatabaseBackup(place: .project("db/Shop-2026-11-20.bak")).suggestedDatabase == "Shop")
        #expect(SQLServerBackups.backupName(database: "Shop", date: Date(timeIntervalSince1970: 0)).hasPrefix("Shop-19"))
    }

    @Test func readsTheSchema() {
        let results = [
            QueryResult(columns: ["v"], rows: [["Microsoft SQL Server 2022 (RTM-CU16) - 16.0.4165.4 (X64)"]]),
            QueryResult(columns: Array(repeating: "c", count: 7), rows: [
                ["dbo", "orders", "id", "bigint", "NO", nil, "BASE TABLE"],
                ["dbo", "orders", "note", "nvarchar(max)", "YES", nil, "BASE TABLE"],
                ["sales", "lines", "order_id", "bigint", "NO", nil, "BASE TABLE"],
            ]),
            QueryResult(columns: Array(repeating: "c", count: 7), rows: [
                ["dbo", "orders", "id", "PRIMARY KEY", nil, nil, nil],
                ["sales", "lines", "order_id", "FOREIGN KEY", "dbo", "orders", "id"],
            ]),
            QueryResult(columns: Array(repeating: "c", count: 4), rows: [["dbo", "orders", "12", "16384"]]),
            QueryResult(columns: ["b"], rows: [["8388608"]]),
        ]
        let schema = SchemaQueries.schema(from: results, engine: .sqlserver)
        #expect(schema.version == "SQL Server 2022 (RTM-CU16)")
        #expect(schema.tables.map(\.qualifiedName) == ["orders", "sales.lines"])
        #expect(schema.tables[1].columns[0].references?.table == "orders")
        #expect(schema.tables[0].rows == 12)
        let browse = SchemaQueries.browse(schema.tables[0], engine: .sqlserver, limit: 100, offset: 200)
        #expect(browse == "select * from [dbo].[orders] order by [id] offset 200 rows fetch next 100 rows only")
    }

    @Test func readsTableScansFromAPlan() {
        let plan = "  |--Table Scan(OBJECT:([shop].[dbo].[orders]), WHERE:([shop].[dbo].[orders].[status]=N'paid'))"
        let scans = QueryPlan.scans(in: plan, engine: .sqlserver)
        #expect(scans.first?.name == "orders")
        #expect(scans.first?.filter?.contains("status") == true)
    }

    /// Against a real server in Docker, from a compose file in a subfolder, when
    /// DANTE_MSSQL=1 (it needs the SQL Server image and takes a minute).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DANTE_MSSQL"] == "1"))
    func backsUpAndRestoresForReal() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "dante-mssql-\(UUID().uuidString.prefix(8))")
        let folder = root.appending(path: "service/database")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let password = "Test-" + "only-Pa55"
        try """
        services:
          db:
            image: mcr.microsoft.com/mssql/server:2025-latest
            environment:
              ACCEPT_EULA: "Y"
              MSSQL_SA_PASSWORD: "\(password)"
            ports:
              - "14331:1433"
        """.write(to: folder.appending(path: "compose.yml"), atomically: true, encoding: .utf8)
        defer {
            let down = Process()
            down.executableURL = URL(filePath: "/usr/bin/env")
            down.arguments = ["docker", "compose", "down", "-v"]
            down.currentDirectoryURL = folder
            try? down.run()
            down.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        #expect(await Shell.run(["docker", "compose", "up", "-d"], in: folder).succeeded)
        var master = DatabaseConnection(name: "db", engine: .sqlserver, port: 14331, database: "master", user: "sa", service: "db", readOnly: false)
        master.composeFolder = "service/database"
        master.insideDocker = true
        var ready = false
        for _ in 0..<60 where !ready {
            ready = await DatabaseClient.run("select 1", on: master, password: password, projectRoot: root, hasCompose: false).error == nil
            if !ready { try await Task.sleep(for: .seconds(2)) }
        }
        #expect(ready)
        let setup = await DatabaseClient.run("""
            create database Shop
            GO
            use Shop; create table dbo.orders (id int primary key, note nvarchar(max)); insert into dbo.orders values (1, N'first, with a comma'), (2, null)
            """, on: master, password: password, projectRoot: root, hasCompose: false)
        #expect(setup.error == nil)
        var shop = master
        shop.database = "Shop"
        let schemaRun = await DatabaseClient.run(SchemaQueries.script(for: .sqlserver), on: shop, password: password, projectRoot: root, hasCompose: false)
        #expect(schemaRun.error == nil)
        let schema = SchemaQueries.schema(from: schemaRun.results, engine: .sqlserver)
        #expect(schema.tables.map(\.qualifiedName) == ["orders"])
        #expect(schema.tables.first?.primaryKey == ["id"])
        let rows = await DatabaseClient.run(SchemaQueries.browse(schema.tables[0], engine: .sqlserver, limit: 10, offset: 0), on: shop, password: password, projectRoot: root, hasCompose: false)
        #expect(rows.results.first?.rows == [["1", "first, with a comma"], ["2", nil]])

        let path = SQLServerBackups.containerFolder + "/" + SQLServerBackups.backupName(database: "Shop")
        _ = await Shell.run(["docker", "compose", "exec", "-T", "db", "mkdir", "-p", SQLServerBackups.containerFolder], in: folder)
        let backup = await DatabaseClient.run(SQLServerBackups.backupSQL(database: "Shop", path: path), on: master, password: password, projectRoot: root, hasCompose: false)
        #expect(backup.error == nil)
        let listed = await Shell.run(["docker", "compose", "exec", "-T", "db"] + SQLServerBackups.listCommand, in: folder)
        #expect(SQLServerBackups.parseList(listed.stdout).map(\.name) == [(path as NSString).lastPathComponent])

        let header = await DatabaseClient.run(SQLServerBackups.headerSQL(path: path), on: master, password: password, projectRoot: root, hasCompose: false)
        #expect(SQLServerBackups.header(from: header.results.first).database == "Shop")
        let list = await DatabaseClient.run(SQLServerBackups.fileListSQL(path: path), on: master, password: password, projectRoot: root, hasCompose: false)
        let files = SQLServerBackups.files(from: list.results.first)
        #expect(files.map(\.type) == ["D", "L"])
        let restore = await DatabaseClient.run(SQLServerBackups.restoreSQL(path: path, database: "ShopCopy", files: files, makeSaOwner: true),
                                               on: master, password: password, projectRoot: root, hasCompose: false)
        #expect(restore.error == nil)
        var copy = master
        copy.database = "ShopCopy"
        let copied = await DatabaseClient.run("select count(*) as n from dbo.orders", on: copy, password: password, projectRoot: root, hasCompose: false)
        #expect(copied.results.first?.rows == [["2"]])
        // Restoring over the original, which is in use, works too.
        let over = await DatabaseClient.run(SQLServerBackups.restoreSQL(path: path, database: "Shop", files: files, makeSaOwner: false),
                                            on: master, password: password, projectRoot: root, hasCompose: false)
        #expect(over.error == nil)
        let failed = await DatabaseClient.run("select * from nope", on: shop, password: password, projectRoot: root, hasCompose: false)
        #expect(failed.error == "Invalid object name 'nope'.")
    }
}
