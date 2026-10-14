@testable import DanteKit
import Foundation
import Testing

struct TranscriptScanTests {
    // As Claude Code writes them: an assistant line's own type comes after its message.
    static let transcript = """
        {"parentUuid":null,"type":"user","message":{"role":"user","content":"Fix the {braces} \\"here\\""},"uuid":"u1","timestamp":"2026-05-01T10:00:00.000Z"}
        {"parentUuid":"u1","message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"Done \\"type\\":\\"user\\""}],"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":100}},"requestId":"req_1","type":"assistant","uuid":"a1","timestamp":"2026-05-01T10:00:05.000Z"}
        {"type":"progress","data":{"type":"assistant"},"timestamp":"2026-05-01T10:00:06.000Z"}

        """

    @Test func findsEachLinesOwnType() {
        var types: [String?] = []
        TranscriptScan.lines(Self.transcript) { types.append(TranscriptScan.topLevelType($0)) }
        #expect(types == ["user", "assistant", "progress"])
    }

    @Test func readsUsageAndItemsWithTheMessageFirst() {
        let entries = ClaudeUsage.entries(fromTranscript: Self.transcript)
        #expect(entries.count == 1 && entries.first?.usage.cacheRead == 100 && entries.first?.model == "claude-opus-5-5")
        let items = ClaudeHistory.items(fromTranscript: Self.transcript)
        #expect(items.count == 2)
        let session = ClaudeTranscripts.session(id: "s", transcript: Self.transcript)
        #expect(session?.title == #"Fix the {braces} "here""# && session?.detail?.hasPrefix("1 prompt") == true)
    }

    @Test func readsTimestampsWithoutAFormatter() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for stamp in ["2026-05-01T10:00:05.123Z", "2024-02-29T23:59:59.999Z", "1999-12-31T00:00:00.000Z", "2026-01-01T00:00:00.5Z"] {
            #expect(TranscriptScan.date(stamp) == formatter.date(from: stamp), "\(stamp)")
        }
        #expect(TranscriptScan.date("2026-05-01T10:00:05Z") == ISO8601DateFormatter().date(from: "2026-05-01T10:00:05Z"))
        #expect(TranscriptScan.date("2026-05-01T12:00:05+02:00") == ISO8601DateFormatter().date(from: "2026-05-01T12:00:05+02:00"))
        #expect(TranscriptScan.date("soon") == nil)
    }
}
