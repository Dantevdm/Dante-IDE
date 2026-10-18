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

@Suite struct VitalityTests {
    @Test func fatigueStartsPastOnsetAndPeaksAtTheBusiestWindow() {
        #expect(Vitality.fatigue(current: 100, busiest: nil) == 0)
        #expect(Vitality.fatigue(current: 50, busiest: 100) == 0)
        #expect(Vitality.fatigue(current: 100, busiest: 100) == 1)
        #expect(Vitality.fatigue(current: 300, busiest: 100) == 1)
        let middle = Vitality.fatigue(current: 775, busiest: 1000)
        #expect(abs(middle - 0.5) < 0.001)
    }

    @Test func recognisesLimitMessages() {
        #expect(Vitality.isLimitMessage("Claude AI usage limit reached|1760000000"))
        #expect(Vitality.isLimitMessage("You've hit your limit · resets 3pm"))
        #expect(!Vitality.isLimitMessage("Not logged in · Please run /login"))
    }

    @Test func workRateCountsNewToolCallsInTheLastMinute() {
        var rate = WorkRate()
        let start = Date(timeIntervalSince1970: 0)
        rate.record(total: 10, at: start)
        #expect(rate.perMinute(at: start) == 0)
        rate.record(total: 22, at: start.addingTimeInterval(10))
        #expect(rate.perMinute(at: start.addingTimeInterval(10)) == 12)
        #expect(rate.intensity(at: start.addingTimeInterval(10), running: 1) == 0.7)
        rate.record(total: 22, at: start.addingTimeInterval(80))
        #expect(rate.perMinute(at: start.addingTimeInterval(80)) == 0)
    }

    @Test func workBlazesAndFatigueWearsDown() {
        let acting = OrbStyle.of(.acting)
        let flatOut = acting.adjusted(for: Vitality(intensity: 1))
        let tired = acting.adjusted(for: Vitality(intensity: 1, fatigue: 1))
        #expect(flatOut.energy > acting.adjusted(for: Vitality(intensity: 0)).energy)
        #expect(tired.energy < flatOut.energy && tired.lightning < flatOut.lightning)
        #expect(tired.lids == 0.5)
        #expect(OrbStyle.of(.asleep).lids == 1)
    }
}

@Suite struct VoiceTests {
    @Test func parsesCommandsAndQuestions() {
        let projects = ["Dante IDE", "shop"]
        #expect(VoiceCommand.parse("Stop.", projects: projects) == .stop)
        #expect(VoiceCommand.parse("never mind", projects: projects) == .cancel)
        #expect(VoiceCommand.parse("Yes, do it", projects: projects) == .approve)
        #expect(VoiceCommand.parse("go ahead", projects: projects) == .approve)
        #expect(VoiceCommand.parse("Switch to dante", projects: projects) == .show(project: "Dante IDE"))
        #expect(VoiceCommand.parse("open the shop project", projects: projects) == .show(project: "shop"))
        #expect(VoiceCommand.parse("Open a pull request for this", projects: projects) == .ask("Open a pull request for this"))
        #expect(VoiceCommand.parse("  ", projects: projects) == .cancel)
    }

    @Test func spokenRepliesDropCodeAndMarkdown() {
        let reply = """
        ## Done

        I fixed the **parser** in `Sources/DanteKit/Docs/MarkdownDocument.swift`.

        ```swift
        let x = 1
        ```

        - Tests pass
        """
        #expect(SpokenReply.text(from: reply) == "Done I fixed the parser in MarkdownDocument.swift. Tests pass")
        let long = String(repeating: "This is a sentence that goes on. ", count: 30)
        #expect(SpokenReply.text(from: long).count <= SpokenReply.length)
    }
}
