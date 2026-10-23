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
}
