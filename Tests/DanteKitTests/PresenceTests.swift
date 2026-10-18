import DanteKit
import Foundation
import Testing

@Suite struct PresenceTests {
    @Test func nothingOpenIsAsleep() {
        let presence = Presence.combine([])
        #expect(presence.mood == .asleep)
        #expect(presence.line == "No project open")
    }

    @Test func somethingWaitingWinsOverWork() {
        let presence = Presence.combine([
            PresenceSource(id: "a", project: "shop", claude: .working, running: "Run go test"),
            PresenceSource(id: "b", project: "Dante", claude: .working, waiting: 1, last: "Edit Map.swift"),
        ])
        #expect(presence.mood == .needsYou)
        #expect(presence.line == "Dante: Edit Map.swift")
    }

    @Test func countsWaitingAcrossProjects() {
        let presence = Presence.combine([
            PresenceSource(id: "a", project: "shop", claude: .working, waiting: 2),
            PresenceSource(id: "b", project: "Dante", claude: .working, waiting: 1),
        ])
        #expect(presence.line == "3 things waiting in shop and Dante")
    }

    @Test func aRunningToolIsActingOtherwiseThinking() {
        #expect(PresenceSource(id: "a", project: "p", claude: .working, running: "Read a.swift").mood == .acting)
        #expect(PresenceSource(id: "a", project: "p", claude: .working).mood == .thinking)
        let presence = Presence.combine([PresenceSource(id: "a", project: "shop", claude: .working, running: "Run make")])
        #expect(presence.line == "shop: Run make")
    }

    @Test func troubleBeatsRest() {
        let presence = Presence.combine([
            PresenceSource(id: "a", project: "shop", claude: .idle),
            PresenceSource(id: "b", project: "api", claude: .unavailable("Claude Code isn’t installed")),
        ])
        #expect(presence.mood == .trouble)
        #expect(presence.line == "api: Claude Code isn’t installed")
    }

    @Test func showsDoneForAMomentAfterATurn() {
        var tracker = PresenceTracker()
        let start = Date(timeIntervalSince1970: 0)
        let working = Presence.combine([PresenceSource(id: "a", project: "p", claude: .working)])
        let idle = Presence.combine([PresenceSource(id: "a", project: "p", claude: .idle)])
        #expect(tracker.mood(for: idle, at: start).mood == .idle)
        #expect(tracker.mood(for: working, at: start).mood == .thinking)
        let finished = tracker.mood(for: idle, at: start.addingTimeInterval(1))
        #expect(finished.mood == .done)
        #expect(finished.recheck == start.addingTimeInterval(1 + PresenceTracker.doneDuration))
        #expect(tracker.mood(for: idle, at: start.addingTimeInterval(2)).mood == .done)
        #expect(tracker.mood(for: idle, at: start.addingTimeInterval(5)).mood == .idle)
    }

    @Test func everyMoodHasFourColours() {
        for mood in PresenceMood.allCases {
            #expect(OrbStyle.of(mood).colors.count == 4)
        }
        #expect(OrbStyle.of(.acting).energy > OrbStyle.of(.idle).energy)
    }
}
