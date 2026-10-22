import DanteKit
import Testing

struct PushToTalkTests {
    @Test func holdingWaitsForReleaseAndSubmitsOnlyOnce() throws {
        var key = PushToTalk()
        let ticket = try #require({ key.press() }())
        #expect(key.phase == .starting)
        #expect({ key.started(ticket) }())
        #expect(key.phase == .listening)
        #expect({ key.press() }() == nil) // key repeat doesn't restart the microphone
        #expect({ key.release() }())
        #expect(key.phase == .finishing)
        #expect(!{ key.release() }()) // duplicate key-up can't send twice
        key.cancel() // recognition finished
        #expect(key.phase == .idle)
        #expect({ key.press() }() != nil)
    }

    @Test func quickTapCannotOpenTheMicrophoneAfterPermissionsReturn() throws {
        var key = PushToTalk()
        let old = try #require({ key.press() }())
        #expect(!{ key.release() }())
        #expect(!{ key.started(old) }())
        let current = try #require({ key.press() }())
        #expect(!{ key.started(old) }()) // an older permission callback arrives during a new hold
        #expect(key.canStart(current))
        #expect({ key.started(current) }())
        #expect({ key.release() }())
    }

    @Test func cancellationInvalidatesStartupAndDoesNotSubmit() throws {
        var key = PushToTalk()
        let ticket = try #require({ key.press() }())
        key.cancel()
        #expect(!{ key.started(ticket) }())
        #expect(!{ key.release() }())
        let next = try #require({ key.press() }())
        #expect({ key.started(next) }())
        key.cancel()
        #expect(!{ key.release() }())
    }
}
