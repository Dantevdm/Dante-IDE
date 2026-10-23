import Foundation
import Testing
@testable import DanteKit

struct ComposeProgressTests {
    static let output = """
    #0 building with "desktop-linux" instance using docker driver
    #1 [internal] load local bake definitions
    #1 DONE 0.0s
    #2 [api internal] load build definition from Dockerfile
    #2 DONE 0.0s
    #5 [api 2/5] WORKDIR /app
    #5 CACHED
    #6 [api 3/5] COPY package.json ./
    #6 CACHED
    #7 [api 4/5] RUN npm ci
    #7 sha256:4f4fb700ef54461cfa02571ae0db9a0dc1e0cdb5577484a6d75e68dc38e8acc1 32B / 32B 0.2s done
    #7 12.31 added 412 packages
    #7 DONE 14.2s
    #8 [api 5/5] RUN npm run build
    #8 ERROR: process "/bin/sh -c npm run build" did not complete successfully: exit code: 2
     Network shop_default  Creating
     Network shop_default  Created
     Container shop-db-1  Creating
     Container shop-db-1  Created
     Container shop-db-1  Starting
     Container shop-db-1  Started
     Container shop-db-1  Waiting
     Container shop-db-1  Healthy
     Container shop-worker-queue-1  Started
    """.components(separatedBy: "\n")

    @Test func eachServiceGetsOneLine() {
        let progress = ComposeProgress.parse(Self.output, known: ["api", "db", "worker-queue"])
        #expect(progress.services.map(\.name) == ["api", "db", "worker-queue"])
        #expect(progress.services[0].phase == .failed("Build failed"))
        #expect(progress.services[0].cached == 2)
        #expect(progress.services[0].ran == 1)
        #expect(progress.services[1].phase == .running("Healthy"))
        #expect(progress.services[2].phase.text == "Started")
        #expect(progress.errors == ["api: process \"/bin/sh -c npm run build\" did not complete successfully: exit code: 2"])
    }

    @Test func aRunningBuildSaysWhichStep() {
        let progress = ComposeProgress.parse(Array(Self.output.prefix(12)), known: ["api"])
        #expect(progress.services.first?.phase.text == "Building 4/5 · RUN npm ci")
        #expect(progress.services.first?.phase.isBusy == true)
    }

    @Test func containerNamesBecomeServices() {
        #expect(ComposeProgress.service(fromContainer: "shop-db-1", known: ["db"]) == "db")
        #expect(ComposeProgress.service(fromContainer: "shop_cache_2", known: ["cache"]) == "cache")
        #expect(ComposeProgress.service(fromContainer: "my-app-web-1", known: []) == "app-web")
        #expect(ComposeProgress.service(fromContainer: "postgres", known: ["db"]) == "postgres")
        #expect(ComposeProgress.parse(["dependency failed to start: container shop-db-1 is unhealthy"]).errors.count == 1)
    }
}

struct ServiceRecoveryTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func crashedAndLongUnhealthyServicesAreRestarted() {
        let states = [
            ContainerState(service: "api", state: "exited", status: "Exited (1) 1 minute ago"),
            ContainerState(service: "job", state: "exited", status: "Exited (0) 1 minute ago"),
            ContainerState(service: "db", state: "running", health: "unhealthy"),
            ContainerState(service: "cache", state: "running", health: "unhealthy"),
            ContainerState(service: "mail", state: "exited", status: "Exited (143) 3 minutes ago"),
            ContainerState(service: "web", state: "restarting"),
        ]
        let actions = ServiceRecovery.plan(states: states, services: ["api", "job", "db", "cache", "mail", "web"], attempts: [],
                                           unhealthySince: ["db": now.addingTimeInterval(-120), "cache": now.addingTimeInterval(-20)],
                                           stoppedByYou: [], now: now)
        #expect(actions == [.restart(service: "api", reason: "It crashed (exit 1)"), .restart(service: "db", reason: "Unhealthy for 2 minutes")])
    }

    @Test func itGivesUpOnceAndLeavesWhatYouStopped() {
        let states = [ContainerState(service: "api", state: "exited", status: "Exited (1) now"), ContainerState(service: "db", state: "dead")]
        let attempts = (1...3).map { ServiceRecovery.Attempt(service: "api", date: now.addingTimeInterval(Double(-$0 * 60))) }
        let actions = ServiceRecovery.plan(states: states, services: ["api", "db"], attempts: attempts, unhealthySince: [:], stoppedByYou: ["db"], now: now)
        #expect(actions == [.giveUp(service: "api", reason: "It crashed (exit 1), still after 3 restarts")])
        #expect(ServiceRecovery.plan(states: states, services: ["api", "db"], attempts: attempts, unhealthySince: [:], stoppedByYou: ["db"], gaveUp: ["api"], now: now).isEmpty)
        // An hour on, it's worth another try.
        #expect(ServiceRecovery.plan(states: states, services: ["api"], attempts: attempts, unhealthySince: [:], stoppedByYou: [], now: now.addingTimeInterval(3600)).count == 1)
    }

    @Test func aChangedComposeFileIsAppliedWhileServicesRun() {
        let running = [ContainerState(service: "api", state: "running")]
        #expect(ServiceRecovery.plan(states: running, services: ["api"], attempts: [], unhealthySince: [:], stoppedByYou: [], composeChanged: true, now: now)
                == [.apply(reason: "The compose file changed")])
        #expect(ServiceRecovery.plan(states: [], services: ["api"], attempts: [], unhealthySince: [:], stoppedByYou: [], composeChanged: true, now: now).isEmpty)
    }

    @Test func eachActionGetsTheRightComposeCommand() {
        let states = [
            ContainerState(service: "db", state: "running", health: "unhealthy"),
            ContainerState(service: "api", state: "exited", status: "Exited (1) 1 minute ago"),
            ContainerState(service: "web", state: "running"),
            ContainerState(service: "worker", state: "running"),
        ]
        #expect(ServiceRecovery.command(for: .restart(service: "db", reason: ""), states: states, stoppedByYou: []) == ["docker", "compose", "restart", "db"])
        #expect(ServiceRecovery.command(for: .restart(service: "api", reason: ""), states: states, stoppedByYou: []) == ["docker", "compose", "up", "-d", "api"])
        #expect(ServiceRecovery.command(for: .apply(reason: ""), states: states, stoppedByYou: ["worker"])
                == ["docker", "compose", "up", "-d", "--no-deps", "db", "web"])
        #expect(ServiceRecovery.command(for: .giveUp(service: "db", reason: ""), states: states, stoppedByYou: []) == nil)
    }

    @Test func multiStageBuildsShowTheirStep() {
        let progress = ComposeProgress.parse(["#12 [api builder 3/6] RUN npm ci", "#12 DONE 4.1s"], known: ["api"])
        #expect(progress.services.first?.phase == .building(step: "3/6", detail: "RUN npm ci"))
        #expect(progress.services.first?.ran == 1)
    }
}

struct CrashReportTests {
    @Test func nodeCrashNamesTheMissingModule() {
        let logs = """
        api-1  | > api@1.0.0 start
        api-1  | > node server.js
        api-1  | node:internal/modules/cjs/loader:1228
        api-1  | Error: Cannot find module 'express'
        api-1  |     at Module._resolveFilename (node:internal/modules/cjs/loader:1225:15)
        api-1  |     at Module._load (node:internal/modules/cjs/loader:1051:27)
        api-1  | > api@1.0.0 start
        api-1  | > node server.js
        api-1  | Error: Cannot find module 'express'
        api-1  |     at Module._resolveFilename (node:internal/modules/cjs/loader:1225:15)
        api-1  | Node.js v22.9.0
        """
        let report = CrashReport.read(service: "api", reason: "It crashed (exit 1)", logs: logs)
        #expect(report.headline == "Error: Cannot find module 'express'")
        #expect(report.excerpt.last == "Node.js v22.9.0")
        #expect(report.excerpt.filter { $0.contains("Cannot find module") }.count <= 2)
        #expect(report.brief.contains("It crashed (exit 1). The logs say: Error: Cannot find module 'express'"))
        #expect(report.brief.contains("```\n") && report.brief.contains("don't restart"))
    }

    @Test func pythonCrashNamesTheErrorAfterItsTraceback() {
        let logs = """
        worker-1  | INFO: starting worker
        worker-1  | Traceback (most recent call last):
        worker-1  |   File "/app/worker.py", line 12, in <module>
        worker-1  |     main()
        worker-1  |   File "/app/worker.py", line 8, in main
        worker-1  |     url = os.environ["QUEUE_URL"]
        worker-1  | KeyError: 'QUEUE_URL'
        """
        let report = CrashReport.read(service: "worker", reason: "It crashed (exit 1)", logs: logs)
        #expect(report.headline == "KeyError: 'QUEUE_URL'")
        #expect(report.excerpt.first == "INFO: starting worker")
    }

    @Test func goPanicAndQuietLogs() {
        let logs = "api-1  | listening on :8080\napi-1  | panic: assignment to entry in nil map\napi-1  | \napi-1  | goroutine 1 [running]:\napi-1  | main.main()\napi-1  | \t/app/main.go:14 +0x2c"
        #expect(CrashReport.read(service: "api", reason: "It died", logs: logs).headline == "panic: assignment to entry in nil map")
        let quiet = CrashReport.read(service: "db", reason: "Unhealthy for 3 minutes", logs: "db-1  | ready\ndb-1  | still ready")
        #expect(quiet.headline == nil && quiet.summary == nil && quiet.excerpt == ["ready", "still ready"])
    }
}

extension CrashReportTests {
    @Test func aCrashLoopKeepsOnlyTheLastCrash() {
        let crash = "w-1  | INFO: starting\nw-1  | Traceback (most recent call last):\nw-1  |   File \"/app/w.py\", line 8, in main\nw-1  | KeyError: 'Q'\n"
        let report = CrashReport.read(service: "w", reason: "It crashed (exit 1)", logs: crash + crash + crash)
        #expect(report.excerpt == ["INFO: starting", "Traceback (most recent call last):", "  File \"/app/w.py\", line 8, in main", "KeyError: 'Q'"])
    }
}
