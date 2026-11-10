import Foundation
import Testing
@testable import DanteKit

@Test func nightlyBackupsAreDueOnceANightAndKeepSeven() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    func at(_ day: Int, _ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))! }
    #expect(BackupSchedule.isDue(last: nil, now: at(10, 1), hour: 2, calendar: calendar))
    // Last night's (after 2 am yesterday) counts until 2 am today.
    #expect(!BackupSchedule.isDue(last: at(9, 3), now: at(10, 1), hour: 2, calendar: calendar))
    #expect(BackupSchedule.isDue(last: at(9, 3), now: at(10, 3), hour: 2, calendar: calendar))
    #expect(!BackupSchedule.isDue(last: at(10, 2), now: at(10, 23), hour: 2, calendar: calendar))

    let nightly = (1...9).map { "db-2026110\($0)-020000-nightly.dump" }
    let names = nightly + ["db-20261101-090000.dump", "db-20261101-090000-before-restore.dump"]
    let pruned = BackupSchedule.pruned(names, keep: 7)
    #expect(pruned == ["db-20261102-020000-nightly.dump", "db-20261101-020000-nightly.dump"])
    #expect(BackupSchedule.last(names) != nil)
    #expect(BackupSchedule.last(["db-20261101-090000.dump"]) == nil)
}

@Test func troubleIsNewOnlyOnce() {
    let calm = DeployWatch.State(app: "shop")
    let failed = DeployWatch.State(app: "shop", failedDeployment: "d2", unhealthy: ["api"], restarts: ["api": 2])
    #expect(DeployWatch.news(from: nil, to: failed).isEmpty)          // the first look sets the baseline
    #expect(DeployWatch.news(from: calm, to: failed) == ["The latest deployment of shop failed.", "api isn’t healthy."])
    #expect(DeployWatch.news(from: failed, to: failed).isEmpty)
    var restarting = failed
    restarting.restarts["api"] = 3
    #expect(DeployWatch.news(from: failed, to: restarting) == ["api restarted 3 times today."])
    #expect(restarting.trouble.count == 3)
    #expect(calm.trouble.isEmpty)
}

@Test func connectionPoolsAreFoundAndSizedToTheDatabase() {
    let files = [
        "api/internal/db/db.go": "pool, err := pgxpool.New(ctx, os.Getenv(\"DATABASE_URL\"))",
        "api/internal/db/db_test.go": "pgxpool.New(ctx, url)",
        "worker/db.ts": "import pg from 'pg'\nexport const pool = new pg.Pool({ connectionString, max: 20 })",
        "web/app.py": "engine = create_engine(url, pool_size=5)",
        "docs/notes.md": "pgxpool.New(",
    ]
    let pools = ConnectionPool.detect(files: Array(files.keys).sorted(), read: { files[$0] })
    #expect(pools.map(\.library).sorted() == ["SQLAlchemy", "node-postgres", "pgx"])
    #expect(pools.first { $0.library == "pgx" }?.maximum == nil)
    #expect(pools.first { $0.library == "node-postgres" }?.maximum == 20)
    #expect(pools.first { $0.library == "node-postgres" }?.line == 2)
    #expect(ConnectionPool.databaseLimit(clusterSize: nil) == 22)
    #expect(ConnectionPool.databaseLimit(clusterSize: "db-s-1vcpu-2gb") == 47)
    #expect(ConnectionPool.suggested(limit: 22, copies: 2) == 9)
    #expect(ConnectionPool.suggested(limit: 22, copies: 20) == 2)
}

@Test func poolAdviceWeighsCopiesAgainstTheDatabase() {
    guard case .success(let spec) = DOAppSpec.read("""
    name: shop
    services:
    - name: api
      instance_count: 3
    databases:
    - name: db
      engine: PG
    """) else { Issue.record("spec"); return }
    var inputs = DOAdvice.Inputs(file: spec)
    inputs.pools = [ConnectionPool(file: "api/db.go", line: 4, library: "pgx", maximum: nil, defaultMaximum: "4 per CPU"),
                    ConnectionPool(file: "worker/db.ts", line: 2, library: "node-postgres", maximum: 20, defaultMaximum: "10")]
    let advice = DOAdvice.analyse(inputs)
    let unset = advice.first { $0.id.hasPrefix("pool-unset") }
    #expect(unset?.fix.contains("pool_max_conns=6") == true)
    #expect(advice.contains { $0.id.hasPrefix("pool-too-big") && $0.place == "worker/db.ts:2" })
}

@Test func theCostGuardWarnsOnlyPastTheLimit() {
    #expect(CostGuard.warning(current: 12, new: 24, limit: 20) == nil)
    #expect(CostGuard.warning(current: 12, new: 50, limit: 20)?.contains("$38.00") == true)
    #expect(CostGuard.warning(current: 12, new: 50, limit: nil) == nil)
    #expect(CostGuard.warning(current: nil, new: 17, limit: 10) != nil)          // a new app costs all of it
    #expect(CostGuard.used(monthToDate: 30, budget: 60) == 0.5)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let mid = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 0))!
    #expect(abs(CostGuard.projected(monthToDate: 15, now: mid, calendar: calendar) - 30) < 0.01)
}

@Test func liveLoadTestsOnlyHitTheAppsOwnAddress() {
    let app = DOApp.parse(["id": "a", "live_url": "https://shop-x1.ondigitalocean.app",
                           "spec": ["name": "shop", "domains": [["domain": "shop.example.com"]]]])
    #expect(app.map { LiveLoadTest.isAppAddress("shop-x1.ondigitalocean.app", app: $0) } == true)
    #expect(app.map { LiveLoadTest.isAppAddress("SHOP.example.com", app: $0) } == true)
    #expect(app.map { LiveLoadTest.isAppAddress("other.ondigitalocean.app", app: $0) } == false)
    #expect(DOSignIn.scopes.contains("billing:read"))
}
