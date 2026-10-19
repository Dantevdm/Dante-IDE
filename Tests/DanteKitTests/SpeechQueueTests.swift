import DanteKit
import Testing

struct SpeechQueueTests {
    @Test func firstSentenceGoesStraightAway() {
        var queue = SpeechQueue()
        queue.add("Hello.")
        #expect(queue.next(outstanding: 0) == "Hello.")
        #expect(queue.next(outstanding: 1) == nil)
    }

    @Test func sentencesGatherWhileOneIsPlayingAndOneWaits() {
        var queue = SpeechQueue()
        queue.add("Two.")
        #expect(queue.next(outstanding: 1) == "Two.")
        queue.add("Three.")
        queue.add("Four.")
        #expect(queue.next(outstanding: 2) == nil)
        #expect(queue.next(outstanding: 1) == "Three. Four.")
        #expect(queue.isEmpty)
    }

    @Test func blankSentencesAreSkippedAndResetClears() {
        var queue = SpeechQueue()
        queue.add("  ")
        #expect(queue.isEmpty)
        queue.add("A.")
        queue.reset()
        #expect(queue.next(outstanding: 0) == nil)
    }
}
