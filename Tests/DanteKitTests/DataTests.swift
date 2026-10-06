import Foundation
import Testing
@testable import DanteKit

@Suite struct SQLScriptTests {
    @Test func splitsWithoutBreakingStringsCommentsOrDollarQuotes() {
        let script = """
        -- seed; not a split
        insert into notes(body) values ('a; b', 'it''s');
        /* block ; comment */ select 1;
        create function f() returns int as $$ begin return 1; end; $$ language plpgsql;
        select "semi;colon" from t
        """
        let parts = SQLScript.split(script)
        #expect(parts.count == 4)
        #expect(parts[0].hasSuffix("'it''s')"))
        #expect(parts[2].contains("return 1; end; $$"))
        #expect(parts[3] == #"select "semi;colon" from t"#)
        #expect(SQLScript.split("  ;; -- only a comment\n").isEmpty)
    }

    @Test func classifiesStatements() {
        #expect(SQLStatement("SELECT * FROM users").kind == .read)
        #expect(SQLStatement("with x as (select 1) select * from x").kind == .read)
        #expect(SQLStatement("with gone as (delete from t returning *) select * from gone").kind == .write)
        #expect(SQLStatement("insert into t values (1) returning id").returnsRows)
        #expect(!SQLStatement("insert into t values (1)").returnsRows)
        #expect(SQLStatement("explain select 1").kind == .read)
        #expect(SQLStatement("begin").kind == .control)
        #expect(SQLStatement("create table t (a int)").kind == .schema)
        #expect(SQLStatement("pragma table_info(t)").kind == .read)
        #expect(SQLStatement("pragma foreign_keys = on").kind == .control)
    }

    @Test func flagsDangerousStatements() {
        #expect(SQLStatement("DROP TABLE users").danger == "drops table")
        #expect(SQLStatement("delete from users").danger == "deletes every row")
        #expect(SQLStatement("delete from users where id = 1").danger == nil)
        #expect(SQLStatement("update users set admin = true").danger == "updates every row")
        #expect(SQLStatement("truncate orders").danger == "empties the table")
        // A WHERE inside a string doesn't count.
        #expect(SQLStatement("update t set note = 'where'").danger == "updates every row")
    }

    @Test func quotesNames() {
        #expect(SQLScript.quote("we\"ird", for: .postgres) == #""we""ird""#)
        #expect(SQLScript.quote("order", for: .mysql) == "`order`")
        #expect(SQLScript.literal("it's") == "'it''s'")
    }
}

@Suite struct TabularTextTests {
    @Test func readsCSVWithQuotesNewlinesAndNulls() {
        let rows = TabularText.csv("a,b,c\n1,␀,\"x,\"\"y\"\"\nz\"\n2,,\"␀\"\n", null: "␀")
        #expect(rows.count == 3)
        #expect(rows[1] == ["1", nil, "x,\"y\"\nz"])
        // An empty field is an empty string, and a quoted marker is text.
        #expect(rows[2] == ["2", "", "␀"])
    }

    @Test func readsMySQLBatchOutput() {
        let rows = TabularText.tsv("id\tnote\n1\tline\\nbreak\n2\tNULL")
        #expect(rows == [["id", "note"], ["1", "line\nbreak"], ["2", nil]])
    }

    @Test func splitsClientOutputIntoResults() {
        let statements = SQLScript.statements("begin; select 1 as x; update t set a = 1")
        let output = "BEGIN\n@@dante:0\nx\n1\n@@dante:1\nUPDATE 4\n@@dante:2\n"
        let run = DatabaseClient.parse(output, statements: statements, engine: .postgres)
        #expect(run.results.map(\.message) == ["BEGIN", nil, "UPDATE 4"])
        #expect(run.results[1].columns == ["x"])
        #expect(run.results[1].rows == [["1"]])

        let mysql = DatabaseClient.parse("rows_affected\n2\n@@dante\n@@dante:0\n", statements: SQLScript.statements("delete from t where a > 1"), engine: .mysql)
        #expect(mysql.results.first?.message == "2 rows affected")
    }
}

@Suite struct DatabaseConnectionTests {
    @Test func parsesDatabaseURLs() throws {
        let pg = try #require(DatabaseConnection.parse(url: "postgresql://app:s%40cret@localhost:5433/shop?sslmode=disable"))
        #expect(pg.engine == .postgres)
        #expect(pg.port == 5433)
        #expect(pg.user == "app")
        #expect(pg.devPassword == "s@cret")
        #expect(pg.database == "shop")
        #expect(!pg.readOnly)
        #expect(pg.displayURL == "postgres://app@localhost:5433/shop")

        let remote = try #require(DatabaseConnection.parse(url: "mysql://ro@db.example.com/orders"))
        #expect(remote.readOnly)
        #expect(remote.port == 3306)

        let file = try #require(DatabaseConnection.parse(url: "file:./prisma/dev.db"))
        #expect(file.engine == .sqlite)
        #expect(file.file == "prisma/dev.db")

        #expect(DatabaseConnection.parse(url: "postgres://${DB_HOST}/x") == nil)
        #expect(DatabaseConnection.parse(url: "redis://localhost:6379") == nil)
    }

    @Test func passwordsAreNeverEncoded() throws {
        var connection = DatabaseConnection(name: "db", engine: .postgres, database: "app", user: "app")
        connection.devPassword = "hunter2"
        let json = String(decoding: try JSONEncoder().encode(connection), as: UTF8.self)
        #expect(!json.contains("hunter2"))
    }
}

@Suite struct DataDetectorTests {
    @Test func findsComposeDatabasesAndEnvURLs() throws {
        let compose = try ComposeFile.parse("""
        services:
          db:
            image: postgres:16
            environment:
              POSTGRES_USER: shop
              POSTGRES_PASSWORD: ${DB_PASSWORD:-devpass}
              POSTGRES_DB: shop_dev
            ports: ["5544:5432"]
          cache:
            image: redis:7
        """)
        let files: [String: String] = [
            "package.json": #"{"dependencies": {"pg": "^8", "drizzle-orm": "1", "ioredis": "5"}}"#,
            ".env.example": "DATABASE_URL=postgres://shop:devpass@localhost:5544/shop_dev\n",
        ]
        let profile = DataDetector.detect(
            paths: ["package.json", ".env.example", "drizzle/0001_init.sql", "drizzle/0002_users.sql", "node_modules/x/test.db"],
            compose: ComposeFile(url: URL(filePath: "/p/compose.yaml"), services: compose),
            read: { files[$0] }
        )
        #expect(profile.suggestedEngine == .postgres)
        #expect(profile.connections.count == 1)
        let db = try #require(profile.connections.first)
        #expect(db.port == 5544)
        #expect(db.user == "shop")
        #expect(db.database == "shop_dev")
        #expect(db.service == "db")
        #expect(db.devPassword == "devpass")
        #expect(profile.otherStores == ["Redis"])
        #expect(profile.orms == ["Drizzle"])
        #expect(profile.migrations.first?.path == "drizzle")
        #expect(profile.migrations.first?.count == 2)
        #expect(profile.headline?.hasPrefix("Uses PostgreSQL") == true)
    }

    @Test func findsPrismaSQLiteAndPythonDrivers() {
        let files: [String: String] = [
            "prisma/schema.prisma": "datasource db {\n  provider = \"sqlite\"\n  url = \"file:./dev.db\"\n}",
            "requirements.txt": "psycopg[binary]==3.2\nSQLAlchemy==2.0",
        ]
        let profile = DataDetector.detect(paths: ["prisma/schema.prisma", "requirements.txt"], read: { files[$0] })
        #expect(profile.connections.map(\.file) == ["prisma/dev.db"])
        #expect(profile.signals.contains { $0.label == "Prisma (sqlite)" })
        #expect(profile.signals.contains { $0.engine == .postgres && $0.label == "psycopg in requirements.txt" })
        #expect(profile.orms.contains("SQLAlchemy"))
    }

    @Test func emptyProjectsHaveNothing() {
        #expect(DataDetector.detect(paths: ["README.md", "main.go"]).isEmpty)
    }

    @Test func hostPorts() {
        #expect(DataDetector.hostPort(["127.0.0.1:6000:5432"], container: 5432) == 6000)
        #expect(DataDetector.hostPort(["5432"], container: 5432) == nil)
        #expect(DataDetector.hostPort(["8080:80"], container: 5432) == nil)
    }
}

@Suite struct EnvFileTests {
    @Test func readsAndInterpolates() {
        let values = EnvFile.values("# c\nexport A=1\nB=\"two words\"\nC=x # note\n")
        #expect(values == ["A": "1", "B": "two words", "C": "x"])
        #expect(EnvFile.interpolate("${A}-${MISSING:-def}-$A-${NOPE}", env: ["A": "1"]) == "1-def-1-${NOPE}")
    }

    @Test func setsKeysInPlace() {
        let text = "# app\nDATABASE_URL=old\nOTHER=1\n"
        let out = EnvFile.setting([("DATABASE_URL", "new"), ("POSTGRES_PASSWORD", "pw")], in: text, comment: "Added by Dante")
        #expect(out == "# app\nDATABASE_URL=new\nOTHER=1\n\n# Added by Dante\nPOSTGRES_PASSWORD=pw\n")
    }
}

@Suite struct NewDatabaseTests {
    @Test func plansAPostgresService() {
        let plan = NewDatabasePlan(engine: .postgres, project: "My Shop-API", port: 5433, password: "pw")
        #expect(plan.name == "my_shop_api")
        #expect(plan.composeService.contains("    - \"5433:5432\""))
        #expect(plan.composeService.contains("    POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}"))
        #expect(plan.envValues.last?.value == "postgres://my_shop_api:pw@localhost:5433/my_shop_api")
        #expect(plan.exampleValues.map(\.value) == ["change-me", "postgres://my_shop_api:${POSTGRES_PASSWORD}@localhost:5433/my_shop_api"])
        #expect(plan.connection.service == "db")
        #expect(!plan.connection.readOnly)
    }

    @Test func addsToAnExistingComposeFileKeepingIt() throws {
        let existing = """
        # dev stack
        services:
            web:
                build: .
                ports: ["3000:3000"]

        volumes: {}
        """
        let out = ComposeEditing.adding(service: ["db:", "  image: postgres:17-alpine", "  ports:", "    - \"5433:5432\""], volume: "db-data", to: existing)
        #expect(out == """
        # dev stack
        services:
            web:
                build: .
                ports: ["3000:3000"]

            db:
                image: postgres:17-alpine
                ports:
                    - "5433:5432"

        volumes:
            db-data:

        """)
        #expect(try ComposeFile.parse(out).map(\.name) == ["db", "web"])
    }

    @Test func writesANewComposeFile() throws {
        let out = ComposeEditing.adding(service: NewDatabasePlan(engine: .mysql, project: "x", password: "pw").composeService, volume: "db-data", to: nil)
        let services = try ComposeFile.parse(out)
        #expect(services.first?.image == "mysql:8.4")
        #expect(services.first?.environment["MYSQL_DATABASE"] == "x")
        #expect(ComposeEditing.freeServiceName("db", taken: ["db", "db2"]) == "db3")
    }

    @Test func gitIgnoreGetsWhatsMissing() {
        #expect(GitIgnore.ensuring([".env"], in: "node_modules\n.env\n") == nil)
        #expect(GitIgnore.ensuring([".env"], in: "node_modules") == "node_modules\n.env\n")
    }
}

@Suite struct SchemaTests {
    @Test func buildsASchemaFromIntrospectionRows() {
        let results = [
            QueryResult(columns: ["version"], rows: [["PostgreSQL 17.2 on aarch64-apple-darwin"]]),
            QueryResult(columns: Array(repeating: "c", count: 7), rows: [
                ["public", "users", "id", "integer", "NO", "nextval('users_id_seq')", "BASE TABLE"],
                ["public", "users", "email", "character varying(255)", "NO", nil, "BASE TABLE"],
                ["public", "orders", "id", "integer", "NO", nil, "BASE TABLE"],
                ["public", "orders", "user_id", "integer", "YES", nil, "BASE TABLE"],
                ["billing", "invoices", "id", "bigint", "NO", nil, "BASE TABLE"],
                ["public", "active_users", "id", "integer", "YES", nil, "VIEW"],
            ]),
            QueryResult(columns: Array(repeating: "c", count: 7), rows: [
                ["public", "users", "id", "PRIMARY KEY", nil, nil, nil],
                ["public", "orders", "id", "PRIMARY KEY", nil, nil, nil],
                ["public", "orders", "user_id", "FOREIGN KEY", "public", "users", "id"],
            ]),
            QueryResult(columns: ["n", "t", "r", "b"], rows: [["public", "users", "1200", "65536"]]),
            QueryResult(columns: ["size"], rows: [["9000000"]]),
        ]
        let schema = SchemaQueries.schema(from: results, engine: .postgres)
        #expect(schema.version == "PostgreSQL 17.2")
        #expect(schema.tables.map(\.qualifiedName) == ["users", "orders", "billing.invoices", "active_users"])
        #expect(schema.schemas == ["public", "billing"])
        let users = schema.table("users")!
        #expect(users.primaryKey == ["id"])
        #expect(users.rows == 1200)
        #expect(schema.table("orders")!.foreignKeys.first?.references?.table == "users")
        #expect(schema.referencing(users).map(\.table.name) == ["orders"])
        #expect(schema.table("active_users")!.isView)
        #expect(schema.bytes == 9_000_000)

        let diagram = schema.erDiagram()
        #expect(diagram.entities.count == 3)
        #expect(diagram.relationships.first?.from == "users")
        #expect(diagram.entities.first?.attributes.map(\.type) == ["int", "varchar(255)"])
        #expect(schema.summary.contains("orders(id int pk, user_id int → users.id)"))
        #expect(schema.table("billing.invoices")!.sqlName(for: .postgres) == #""billing"."invoices""#)
    }

    @Test func browseQueries() {
        let table = DatabaseSchema.Table(name: "users", columns: [.init(name: "id", type: "int", isPrimaryKey: true)])
        #expect(SchemaQueries.browse(table, engine: .postgres, limit: 100, offset: 200) == #"select * from "users" order by "id" limit 100 offset 200"#)
        #expect(SchemaQueries.browse(table, engine: .mysql, limit: 50, offset: 0, orderBy: "email", descending: true, filter: "id > 3")
            == "select * from `users` where id > 3 order by `email` desc limit 50 offset 0")
    }
}

/// Real runs against sqlite3, which every Mac has.
@Suite struct SQLiteClientTests {
    @Test func runsScriptsAndReadsTheSchema() async throws {
        let folder = try TemporaryFolder()
        let connection = DatabaseConnection(name: "test", engine: .sqlite, database: "test.sqlite", file: "test.sqlite")
        let setup = await DatabaseClient.run("""
            create table users (id integer primary key, email text not null);
            create table orders (id integer primary key, user_id integer references users(id), note text);
            insert into users (email) values ('a@example.com'), ('b@example.com');
            insert into orders (user_id, note) values (1, 'first, "quoted"'), (1, null);
            select id, note from orders order by id;
            select * from users where 0
            """, on: connection, password: nil, projectRoot: folder.url, hasCompose: false)
        #expect(setup.error == nil)
        #expect(setup.results.count == 6)
        #expect(setup.results[2].message == "2 rows affected")
        #expect(setup.results[4].rows == [["1", "first, \"quoted\""], ["2", nil]])
        #expect(setup.results[5].message == "No rows")

        let introspection = await DatabaseClient.run(SchemaQueries.script(for: .sqlite), on: connection, password: nil, projectRoot: folder.url, hasCompose: false)
        #expect(introspection.error == nil)
        let schema = SchemaQueries.schema(from: introspection.results, engine: .sqlite)
        #expect(schema.version?.hasPrefix("SQLite 3") == true)
        #expect(schema.tables.map(\.name) == ["orders", "users"])
        #expect(schema.table("orders")?.foreignKeys.first?.references?.table == "users")
        #expect(schema.table("users")?.primaryKey == ["id"])
        #expect((schema.bytes ?? 0) > 0)

        let failed = await DatabaseClient.run("select 1; selec 2", on: connection, password: nil, projectRoot: folder.url, hasCompose: false)
        #expect(failed.results.count == 1)
        #expect(failed.error?.contains("syntax error") == true)
    }

    @Test func readOnlyConnectionsRefuseWrites() async throws {
        let folder = try TemporaryFolder()
        var connection = DatabaseConnection(name: "ro", engine: .sqlite, database: "ro.sqlite", file: "ro.sqlite")
        connection.readOnly = true
        let run = await DatabaseClient.run("delete from users", on: connection, password: nil, projectRoot: folder.url, hasCompose: false)
        #expect(run.error?.contains("read-only") == true)
        #expect(run.results.isEmpty)
    }
}

@Suite struct NewDatabaseKeyTests {
    @Test func aSecondDatabaseGetsItsOwnVariable() {
        var plan = NewDatabasePlan(engine: .sqlite, project: "x")
        plan.avoidTakenKeys(["DATABASE_URL"])
        #expect(plan.envKey == "SQLITE_DATABASE_URL")
        var docker = NewDatabasePlan(engine: .postgres, project: "x", password: "pw")
        docker.service = "db2"
        docker.avoidTakenKeys(["DATABASE_URL", "DB2_DATABASE_URL"])
        #expect(docker.envKey == "DB22_DATABASE_URL")
        #expect(docker.replacedKeys(in: "POSTGRES_PASSWORD=old\nOTHER=1") == ["POSTGRES_PASSWORD"])
    }
}
