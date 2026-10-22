@testable import DanteKit
import Foundation
import Testing

@Suite struct VoiceConversationTests {
    @Test func speaksSentencesAsTheReplyStreams() {
        var stream = SpokenStream()
        #expect(stream.feed("I'll look at the par", final: false).isEmpty)
        #expect(stream.feed("I'll look at the parser first. Then the", final: false) == ["I'll look at the parser first."])
        // Code isn't read out, and nothing is said twice.
        let reply = "I'll look at the parser first. Then the tests.\n\n```swift\nlet x = 1\n```\n\nAll green."
        #expect(stream.feed(reply, final: false) == ["Then the tests."])
        #expect(stream.feed(reply, final: true) == ["All green."])
        #expect(stream.feed(reply, final: true).isEmpty)
    }

    @Test func longRepliesPointToTheScreen() {
        var stream = SpokenStream(limit: 40)
        let reply = "The build is fixed now. The parser had an off by one. I also tidied three other files while I was there."
        #expect(stream.feed(reply, final: true) == ["The build is fixed now.", SpokenStream.more])
        #expect(stream.isCut)
        #expect(stream.feed(reply + " More.", final: true).isEmpty)
    }

    @Test func completedSentenceDoesNotWaitForTheNextOne() {
        var stream = SpokenStream()
        let first = "The dashboard requires a login."
        #expect(stream.feed(first, final: false).isEmpty)
        #expect(stream.feed(first, final: false, settled: true) == [first])
        #expect(stream.feed(first, final: false, settled: true).isEmpty)
        #expect(stream.feed(first + " The ping endpoint is public.", final: true) == ["The ping endpoint is public."])
    }

    @Test func stabilityCheckKeepsIncompleteWordsAndAbbreviations() {
        for partial in ["I will check the", "Ask Dr.", "Version 3.", "For e.g.", "A.", "Working..."] {
            var stream = SpokenStream()
            #expect(stream.feed(partial, final: false, settled: true).isEmpty)
            #expect(stream.feed(partial, final: true) == [partial])
        }
        for text in ["Ready?", "Done!", "He said “done.”"] {
            var stream = SpokenStream()
            #expect(stream.feed(text, final: false, settled: true) == [text])
        }
    }

    @Test func settledTailStillSkipsCodeAndHonoursTheSpokenLimit() {
        var stream = SpokenStream(limit: 25)
        #expect(stream.feed("Ready.\n```swift\nlet x = 1\n```", final: false, settled: true) == ["Ready."])
        #expect(stream.feed("Ready.\n```swift\nlet x = 1\n```\nThis explanation belongs on the screen.", final: false, settled: true) == [SpokenStream.more])
    }

    @Test func hearsTheWakeWord() {
        #expect(WakeWord.command(in: "Hey Dante, run the tests") == "run the tests")
        #expect(WakeWord.command(in: "so I said okay dante") == "")
        #expect(WakeWord.command(in: "hey dante what's up hey Dante stop") == "stop")
        #expect(WakeWord.command(in: "Hey Jarvis full screen") == "full screen")
        #expect(WakeWord.command(in: "the dante project is nice") == nil)
        #expect(WakeWord.command(in: "they dante") == nil)
    }

    @Test func answersStatusAndUsageItself() {
        #expect(VoiceCommand.parse("Hey Claude, what are you doing?", projects: []) == .status)
        #expect(VoiceCommand.parse("How much usage do I have left?", projects: []) == .usage)
        #expect(VoiceCommand.parse("Thanks, Claude.", projects: []) == .goodbye)
        #expect(VoiceCommand.parse("Next slide, please.", projects: []) == .slide(true))
        #expect(VoiceCommand.parse("Go back a slide", projects: []) == .slide(false))
        #expect(VoiceCommand.parse("Back", projects: [], presenting: true) == .slide(false))
        #expect(VoiceCommand.parse("Back", projects: []) == .stage(false))
        #expect(VoiceCommand.parse("Next", projects: [], presenting: true) == .slide(true))
        #expect(VoiceCommand.parse("What are you doing with the parser", projects: []) == .ask("What are you doing with the parser"))

        #expect(VoiceStatus.summary([]) == "No projects are open.")
        let sources = [
            PresenceSource(id: "a", project: "shop", claude: .working, running: "Edit Cart.swift"),
            PresenceSource(id: "b", project: "Dante IDE", claude: .idle, waiting: 2),
            PresenceSource(id: "c", project: "notes", claude: .idle),
        ]
        #expect(VoiceStatus.summary(sources) == "Dante IDE needs you: 2 things are waiting. In shop, Claude is editing Cart.swift.")
        #expect(VoiceStatus.summary([sources[2], PresenceSource(id: "d", project: "api", claude: .idle)]) == "All quiet. Claude is free in notes and api.")

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let utc = TimeZone(identifier: "UTC")!, gb = Locale(identifier: "en_GB")
        #expect(VoiceStatus.usage(share: 0.42, resets: now.addingTimeInterval(3600), limitReached: false, now: now, locale: gb, timeZone: utc)
            == "This five-hour window is at about 42% of your busiest one: plenty left. It resets at 23:13.")
        #expect(VoiceStatus.usage(share: nil, resets: nil, limitReached: true, now: now) == "You’ve hit the limit.")
        #expect(VoiceStatus.usage(share: nil, resets: nil, limitReached: false, now: now) == "There’s no usage on record yet.")
    }
}
