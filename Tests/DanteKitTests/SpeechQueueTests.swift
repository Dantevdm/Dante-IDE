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

    @Test func longBacklogPlaysInBoundedChunksWithoutLosingWords() throws {
        var queue = SpeechQueue()
        let sentences = (0..<24).map { "Sentence \($0) explains a different part of the system." }
        for sentence in sentences { queue.add(sentence) }
        var chunks: [String] = []
        while let chunk = queue.next(outstanding: 1) { chunks.append(chunk) }
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= SpeechQueue.chunkLimit })
        #expect(chunks.joined(separator: " ") == sentences.joined(separator: " "))
        #expect(queue.isEmpty)
    }

    @Test func longSentenceSplitsAtWordsAndLookaheadIsBounded() {
        var queue = SpeechQueue()
        let sentence = Array(repeating: "a longer explanation", count: 35).joined(separator: " ") + "."
        queue.add(sentence)
        #expect(queue.next(outstanding: 3, capacity: 3) == nil)
        var chunks: [String] = []
        while let chunk = queue.next(outstanding: 2, capacity: 3) { chunks.append(chunk) }
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= SpeechQueue.chunkLimit })
        #expect(chunks.joined(separator: " ") == sentence)
        queue.add(sentence)
        queue.reset()
        #expect(queue.next(outstanding: 0, capacity: 3) == nil)
    }
}
