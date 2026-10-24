import Foundation
import Testing
@testable import DanteKit

struct MailReplyTests {
    @Test func spokenRepliesAreRead() {
        #expect(MailReply.parse("Reply to Ana that Thursday works") == MailReply(who: "Ana", says: "Thursday works"))
        #expect(MailReply.parse("Hey Dante, reply to Sam Lee saying I'll be ten minutes late.") == MailReply(who: "Sam Lee", says: "I'll be ten minutes late."))
        #expect(MailReply.parse("could you answer Ana's email and say yes please") == MailReply(who: "Ana", says: "yes please"))
        #expect(MailReply.parse("write back to Lee with: sounds good") == MailReply(who: "Lee", says: "sounds good"))
        #expect(MailReply.parse("reply to the email from Ana that it's approved") == MailReply(who: "Ana", says: "it's approved"))
        #expect(MailReply.parse("reply to Ana") == nil)
        #expect(MailReply.parse("what should I reply to Ana that works") == nil)
        #expect(MailReply.parse("reply to the head of finance at the bank that yes") == nil)
    }

    @Test func theBodyIsASentence() {
        let reply = MailReply(who: "ana", says: "thursday works")
        #expect(reply.body(firstName: "Ana", signedBy: "Dan") == "Hi Ana,\n\nThursday works.\n\nDan")
        #expect(MailReply(who: "Sam", says: "Can we move it?").body(firstName: "Sam", signedBy: nil) == "Hi Sam,\n\nCan we move it?")
    }

    @Test func theNewestEmailFromThePersonIsPicked() {
        func at(_ hours: Double) -> Date { Date(timeIntervalSince1970: 1_792_000_000 + hours * 3600) }
        let mail = [
            MailMessage(id: "1", subject: "Plan", senderName: "Ana Sousa", senderAddress: "ana@example.com", received: at(1)),
            MailMessage(id: "2", subject: "Plan v2", senderName: "Ana Sousa", senderAddress: "ana@example.com", received: at(3)),
            MailMessage(id: "3", subject: "Your weekly digest", senderName: "Ana's Newsletter", senderAddress: "newsletter@ana.example", received: at(5)),
            MailMessage(id: "4", subject: "Lunch", senderName: "Banana Club", senderAddress: "club@example.com", received: at(6)),
            MailMessage(id: "5", subject: "Hi", senderName: "", senderAddress: "sam.lee@example.com", received: at(2)),
        ]
        #expect(MailReplies.pick("Ana", in: mail)?.id == "2")
        #expect(MailReplies.pick("ana sousa", in: mail)?.id == "2")
        #expect(MailReplies.pick("Sam Lee", in: mail)?.id == "5")
        #expect(MailReplies.pick("Sam", in: mail)?.id == "5")
        #expect(MailReplies.pick("Lee Park", in: mail) == nil)
        #expect(MailReplies.firstName(of: mail[4], said: "sam") == "Sam")
        #expect(MailReplies.firstName(of: mail[1], said: "ana") == "Ana")
    }

    @Test func voiceAndThePhoneBothHearIt() {
        let reply = MailReply(who: "Ana", says: "Thursday works")
        #expect(VoiceCommand.parse("Reply to Ana that Thursday works", projects: []) == .reply(reply))
        #expect(CompanionForeman.parse("reply to Ana that Thursday works", projects: []) == .reply(reply))
    }

    @Test func readingMailMustBeAllowed() async {
        let said = await MailReplies.draft(MailReply(who: "Ana", says: "yes"), readsMail: false, name: nil)
        #expect(said.contains("Settings › Agents › Morning update"))
    }
}
