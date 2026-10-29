import Testing
@testable import DanteKit

struct WaitingReplyTests {
    @Test func yesApprovesTheWaitingStep() {
        #expect(WaitingReply.read("Yes go ahead please") == .approve)
        #expect(WaitingReply.read("ok, do it!") == .approve)
        #expect(WaitingReply.read("Allow") == .approve)
    }

    @Test func noDeclinesIt() {
        #expect(WaitingReply.read("No.") == .decline)
        #expect(WaitingReply.read("don’t") == .decline)
    }

    @Test func anythingElseIsSaidInstead() {
        #expect(WaitingReply.read(" Use Safari instead ") == .instead("Use Safari instead"))
        #expect(WaitingReply.read("yes but only the first file") == .instead("yes but only the first file"))
    }
}
