import Foundation
import Testing
@testable import DanteKit

@Suite struct QueryPlanTests {
    let schema = DatabaseSchema(tables: [
        DatabaseSchema.Table(schema: "public", name: "orders", columns: [
            DatabaseSchema.Column(name: "id", type: "integer", nullable: false, isPrimaryKey: true),
            DatabaseSchema.Column(name: "customer_id", type: "integer"),
            DatabaseSchema.Column(name: "status", type: "text"),
            DatabaseSchema.Column(name: "created_at", type: "timestamp"),
        ], rows: 250_000),
        DatabaseSchema.Table(schema: "public", name: "customers", columns: [
            DatabaseSchema.Column(name: "id", type: "integer", nullable: false, isPrimaryKey: true),
            DatabaseSchema.Column(name: "email", type: "text"),
        ], rows: 40),
    ])

    @Test func findsPostgresSeqScansWithFilters() {
        let plan = """
        Hash Join  (cost=1.90..5000.00 rows=10 width=40)
          Hash Cond: (o.customer_id = c.id)
          ->  Seq Scan on orders o  (cost=0.00..4800.00 rows=12 width=36)
                Filter: ((created_at > '2026-01-01'::date) AND (status = 'open'::text))
          ->  Hash  (cost=1.40..1.40 rows=40 width=4)
                ->  Seq Scan on customers c  (cost=0.00..1.40 rows=40 width=4)
        """
        let query = "select * from orders o join customers c on o.customer_id = c.id where o.status = 'open' and o.created_at > '2026-01-01'"
        let findings = QueryPlan.findings(plan: plan, query: query, engine: .postgres, schema: schema)
        #expect(findings.count == 1)
        #expect(findings[0].table == "orders" && findings[0].columns == ["status", "created_at"])
        #expect(findings[0].suggestion == #"create index orders_status_created_at_idx on "orders" (status, created_at)"#)
        #expect(!findings[0].isSmall)
    }

    @Test func readsMySQLAndSQLitePlans() {
        let mysql = """
        -> Filter: (o.customer_id = 7)  (cost=10.25 rows=10)
            -> Table scan on o  (cost=10.25 rows=100)
        """
        let found = QueryPlan.findings(plan: mysql, query: "select * from orders as o where o.customer_id = 7", engine: .mysql, schema: schema)
        #expect(found.map(\.columns) == [["customer_id"]])

        let sqlite = "SCAN orders\nSEARCH customers USING INTEGER PRIMARY KEY (rowid=?)"
        let sqliteFound = QueryPlan.findings(plan: sqlite, query: "select * from orders where customer_id = ? and status like 'o%'", engine: .sqlite, schema: schema)
        #expect(sqliteFound.first?.columns == ["customer_id", "status"])
        // Filtering on the primary key alone isn't worth an index.
        #expect(QueryPlan.findings(plan: "SCAN orders", query: "select * from orders where id > 5", engine: .sqlite, schema: schema).isEmpty)
    }

    @Test func picksColumnsOutOfConditions() {
        let columns = QueryPlan.filteredColumns(in: "((customer_id)::text = '4'::text) AND (lower(email) = 'x') AND o.total >= 10 AND deleted_at IS NULL")
        #expect(columns.map(\.name) == ["customer_id", "total", "deleted_at"])
        #expect(columns[1].qualifier == "o" && !columns[1].equality && columns[2].equality)
        #expect(QueryPlan.tableAliases(in: "select * from public.orders as o left join customers c on true")["o"] == "orders")
        #expect(QueryPlan.tableAliases(in: "select * from orders where x = 1")["where"] == nil)
    }

    @Test func readsPlanText() {
        let sqlite = QueryResult(id: 0, statement: "", columns: ["id", "parent", "notused", "detail"], rows: [["2", "0", "0", "SCAN orders"]])
        #expect(QueryPlan.text(from: [sqlite]) == "SCAN orders")
        let postgres = QueryResult(id: 0, statement: "", columns: ["QUERY PLAN"], rows: [["Seq Scan on t"], ["  Filter: (a = 1)"]])
        #expect(QueryPlan.text(from: [postgres]) == "Seq Scan on t\n  Filter: (a = 1)")
    }
}

@Suite struct MigrationPreviewTests {
    let schema = DatabaseSchema(tables: [
        DatabaseSchema.Table(name: "users", columns: [
            DatabaseSchema.Column(name: "id", type: "integer", isPrimaryKey: true),
            DatabaseSchema.Column(name: "email", type: "text"),
        ], rows: 500_000),
        DatabaseSchema.Table(name: "posts", columns: [
            DatabaseSchema.Column(name: "id", type: "integer", isPrimaryKey: true),
            DatabaseSchema.Column(name: "author_id", type: "integer", references: (table: "users", column: "id")),
        ], rows: 0),
    ])

    @Test func describesWhatAMigrationChanges() {
        let script = """
        create table if not exists comments (
          id serial primary key,
          post_id integer not null references posts(id),
          body text,
          constraint body_present check (body <> '')
        );
        alter table users add column name varchar(80) not null, add column bio text;
        alter table posts add column title text not null;
        create index users_email_idx on users (email);
        alter table users rename column email to email_address;
        alter table users alter column email_address type varchar(320);
        drop table users;
        """
        let changes = MigrationPreview.changes(script, schema: schema, engine: .postgres)
        #expect(changes.map(\.kind) == [.createTable, .addColumn, .addColumn, .addColumn, .createIndex, .renameColumn, .alterColumn, .dropTable])
        #expect(changes[0].summary == "create table comments (3 columns)" && changes[0].warning == nil)
        #expect(changes[1].summary == "users: add column name varchar(80)")
        #expect(changes[1].warning?.contains("NOT NULL with no default") == true)
        #expect(changes[2].warning == nil)
        // posts is empty, so NOT NULL is fine.
        #expect(changes[3].warning == nil)
        #expect(changes[4].warning?.contains("CONCURRENTLY") == true)
        #expect(changes[6].summary == "users: change email_address to varchar(320)" && changes[6].warning?.contains("rewrite") == true)
        #expect(changes[7].warning?.contains("500000 rows") == true && changes[7].warning?.contains("posts.author_id") == true)
        #expect(changes[7].isDestructive)
    }

    @Test func catchesMistakesAgainstTheSchema() {
        let changes = MigrationPreview.changes("""
            create table users (id int);
            alter table people add column x int;
            alter table users drop column nickname;
            drop table if exists ghosts;
            create table a (b_id int references b(id));
            """, schema: schema, engine: .sqlite)
        #expect(changes[0].warning?.contains("already exists") == true)
        #expect(changes[1].warning == "There’s no table people.")
        #expect(changes[2].warning?.contains("no column nickname") == true)
        #expect(changes[3].warning == "Deletes the table and its rows.")
        #expect(changes[4].warning?.contains("References b") == true)
        // Reads aren't changes.
        #expect(MigrationPreview.changes("select 1; insert into users values (1)", schema: schema, engine: .sqlite).isEmpty)
    }

    @Test func listsMigrationFilesInOrder() throws {
        let folder = try TemporaryFolder()
        try folder.write("migrations/002_b.sql", "")
        try folder.write("migrations/001_a.sql", "")
        try folder.write("migrations/20260101_init/migration.sql", "")
        try folder.write("migrations/notes.md", "")
        let files = MigrationPreview.files(in: folder.url.appending(path: "migrations"))
        #expect(files.map(\.lastPathComponent) == ["001_a.sql", "002_b.sql", "migration.sql"])
        #expect(MigrationPreview.isDownMigration(URL(filePath: "/m/1_init.down.sql")))
    }
}

@Suite struct DatabaseVersionTests {
    @Test func shortensServerVersions() {
        #expect(SchemaQueries.shortVersion("PostgreSQL 17.2 on aarch64-apple-darwin, compiled by clang") == "PostgreSQL 17.2")
        #expect(SchemaQueries.shortVersion("8.4.3-0ubuntu0.24.04.1") == "MySQL 8.4.3")
        #expect(SchemaQueries.shortVersion("SQLite 3.46.1") == "SQLite 3.46.1")
    }
}
