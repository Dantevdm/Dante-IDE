import Foundation
import Testing
@testable import DanteKit

/// Rows as the new Outlook labels them in its message list (made-up people and mail).
struct OutlookWindowTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Africa/Johannesburg")!
        return calendar
    }()
    // Thursday 29 October 2026, 15:00.
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 15))! }

    @Test func readsAMessageFromToday() throws {
        let row = "     Sender: Ana Smith, Subject: Thursday's release | step 2 - out of hours, done,      14:05,        Message preview: Hi Sam, all good "
        let message = try #require(OutlookWindow.message(from: row, now: now, calendar: calendar))
        #expect(message.senderName == "Ana Smith")
        #expect(message.subject == "Thursday's release | step 2 - out of hours, done")
        #expect(calendar.component(.hour, from: message.received) == 14)
        #expect(calendar.component(.day, from: message.received) == 29)
        #expect(message.preview == "Hi Sam, all good")
        #expect(message.isRead)
    }

    @Test func readsConversationsFlagsAndOlderDates() throws {
        let conversation = "Unread, Flagged,   Conversation, 3 messages, Sender: Sam Jones, Ana Smith, Subject: Card retries,    Latest message:  Yesterday,        Message preview: Can we"
        let message = try #require(OutlookWindow.message(from: conversation, now: now, calendar: calendar))
        #expect(message.senderName == "Sam Jones")
        #expect(!message.isRead)
        #expect(message.isFlagged)
        #expect(calendar.component(.day, from: message.received) == 28)

        let older = "     Sender: billing@acme-shop.example, Subject: Your invoice,      2026/10/23,    Has attachments,    Message preview: "
        let invoice = try #require(OutlookWindow.message(from: older, now: now, calendar: calendar))
        #expect(invoice.senderAddress == "billing@acme-shop.example")
        #expect(invoice.sender == "billing")
        #expect(calendar.component(.day, from: invoice.received) == 23)
        #expect(invoice.preview.isEmpty)
    }

    @Test func skipsHeadingsAndFindsTheList() {
        #expect(OutlookWindow.message(from: "Today", now: now, calendar: calendar) == nil)
        #expect(OutlookWindow.message(from: "Last week", now: now, calendar: calendar) == nil)
        typealias Node = WindowReader.Node
        let table = Node(role: "AXTable", help: "Message List", children: [
            Node(role: "AXRow", children: [Node(role: "AXCell", help: "Today")]),
            Node(role: "AXRow", children: [Node(role: "AXCell", help: "Sender: Ana, Subject: Hi, 09:00, Message preview: x")]),
            Node(role: "AXRow"),
        ])
        let window = Node(role: "AXWindow", children: [Node(role: "AXScrollArea", children: [table])])
        #expect(OutlookWindow.messageRows(window) == ["Today", "Sender: Ana, Subject: Hi, 09:00, Message preview: x"])
    }

    @Test func aTimeLaterThanNowWasYesterday() throws {
        let row = "Sender: Ana, Subject: Late one, 22:30, Message preview: "
        let message = try #require(OutlookWindow.message(from: row, now: now, calendar: calendar))
        #expect(calendar.component(.day, from: message.received) == 28)
        let pm = try #require(OutlookWindow.message(from: "Sender: Ana, Subject: Lunch, 1:15 PM, Message preview: ", now: now, calendar: calendar))
        #expect(calendar.component(.hour, from: pm.received) == 13)
    }
}
