import Foundation
import Testing
@testable import DanteKit

private func spec(_ yaml: String) -> DOAppSpec {
    guard case .success(let spec) = DOAppSpec.read(yaml) else { fatalError("unreadable spec") }
    return spec
}

@Test func theDatabaseIsReachedThroughTheComponentBoundToIt() {
    let live = spec("""
    name: shop
    services:
    - name: site
      http_port: 80
    - name: api
      http_port: 8080
      envs:
      - key: PGHOST
        value: ${db.HOSTNAME}
      - key: PGUSER
        value: ${db.USERNAME}
      - key: POSTGRES_PASSWORD
        value: ${db.PASSWORD}
      - key: PGDATABASE
        value: ${db.DATABASE}
      - key: PGPORT
        value: ${db.PORT}
      - key: OTHER
        value: ${cache.HOSTNAME}
    databases:
    - name: db
      engine: PG
    """)
    let plan = DODatabaseAccess.plan(spec: live, database: "db")
    #expect(plan?.component == "api")
    #expect(plan?.reads["POSTGRES_PASSWORD"] == "PASSWORD")
    #expect(plan?.reads["OTHER"] == nil)
    // Only a password isn't enough to connect.
    #expect(DODatabaseAccess.plan(spec: spec("""
    name: shop
    services:
    - name: api
      envs:
      - key: POSTGRES_PASSWORD
        value: ${db.PASSWORD}
    """), database: "db") == nil)

    let script = DODatabaseAccess.script(for: plan!)
    #expect(!script.contains("_DANTE_"))    // the shell's echo can't look like the answer
    #expect(script.contains(#"printf '%s=%s\n' PGHOST "$PGHOST""#))
    let output = "\u{1B}[?2004h$ stty -echo; printf …\r\n\r\n_DANTE_B_\r\nPGHOST=db-host.example\r\nPGUSER=shop\r\nPOSTGRES_PASSWORD=a=b\r\nPGDATABASE=shop\r\nPGPORT=25060\r\n_DANTE_E_\r\n"
    let values = DODatabaseAccess.values(in: output)
    #expect(values?["POSTGRES_PASSWORD"] == "a=b")
    let connection = DODatabaseAccess.connection(values!, plan: plan!)
    #expect(connection == PGConnection(host: "db-host.example", port: 25060, user: "shop", password: "a=b", database: "shop"))
    #expect(!connection!.description.contains("a=b"))
    #expect(!connection!.arguments.joined().contains("a=b"))
    #expect(connection!.environment["PGPASSWORD"] == "a=b")
}

@Test func aDatabaseURLIsEnough() {
    let live = spec("""
    name: shop
    workers:
    - name: jobs
      envs:
      - key: DATABASE_URL
        value: ${db.DATABASE_URL}
    """)
    let plan = DODatabaseAccess.plan(spec: live, database: "db")!
    let url = "postgresql://shop:p%40ss@db-host.example:25060/shop?sslmode=require"
    let connection = DODatabaseAccess.connection(["DATABASE_URL": url], plan: plan)
    #expect(connection?.password == "p@ss")
    #expect(connection?.database == "shop")
    #expect(connection?.port == 25060)
}

@Test func backupsAreNamedByDateAndRestoreSafely() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9, minute: 5, second: 7))!
    let name = PGTools.backupName(database: "shop-db", date: date, note: "before-restore")
    #expect(name == "shop-db-20261110-090507-before-restore.dump")
    #expect(PGTools.date(ofBackup: name) == date)
    #expect(!PGTools.backupFolder(app: "shop").path.contains(".dante"))
    let connection = PGConnection(host: "h", port: 5432, user: "u", password: "secret", database: "d")
    let restore = PGTools.restoreArguments(connection, from: URL(filePath: "/tmp/x.dump"))
    #expect(restore.contains("--single-transaction") && restore.contains("--clean") && restore.last == "/tmp/x.dump")
    #expect(!(restore + PGTools.dumpArguments(connection, to: URL(filePath: "/tmp/y.dump")) + PGTools.freshArguments(connection)).joined().contains("secret"))
    // A fresh start keeps the schema and its grants.
    #expect(!PGTools.freshSQL.contains("DROP SCHEMA") && !PGTools.freshSQL.contains("DROP OWNED"))
    #expect(PGTools.explain("pg_dump: error: aborting because of server version mismatch").contains("older than the database"))
}

@Test func managedSizesArePricedAndRestoresNamed() {
    #expect(DODatabaseSizes.monthly("db-s-2vcpu-4gb", nodes: 2) == 120)
    #expect(DODatabaseSizes.monthly("db-unknown") == nil)
    #expect(DODatabaseSizes.title("db-s-1vcpu-1gb") == "1 vCPU · 1 GB")
    let backup = DODatabaseBackup(createdAt: "2026-11-09T03:15:00Z", sizeGigabytes: 0.2)
    #expect(backup.date != nil)
    let name = DODatabaseSizes.restoredName(String(repeating: "a", count: 60), backup: backup.date!)
    #expect(name.count == 63)
    #expect(DOSignIn.scopes.contains("database:update"))
}

@Test func aCloudConnectionKeepsWhereItLives() throws {
    var connection = DatabaseConnection(name: "db on DigitalOcean", engine: .postgres, host: "db-host.example", port: 25060, database: "shop", user: "shop")
    connection.cloud = .init(provider: "DigitalOcean", app: "shop", appID: "a1", kind: "dev database", region: "fra")
    #expect(connection.readOnly)
    let back = try JSONDecoder().decode(DatabaseConnection.self, from: JSONEncoder().encode(connection))
    #expect(back.cloud == connection.cloud)
    #expect(back.cloud?.label { $0 == "fra" ? "Frankfurt" : $0 } == "DigitalOcean · shop’s dev database · Frankfurt")
    // Connections saved before there was a cloud field still read.
    let old = #"{"id":"x","name":"n","engine":"postgres","host":"h","port":5432,"database":"d","user":"u","readOnly":true,"origin":"saved"}"#
    #expect(try JSONDecoder().decode(DatabaseConnection.self, from: Data(old.utf8)).cloud == nil)
}
