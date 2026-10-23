import Foundation
import Testing
@testable import DanteKit

struct AssistantTests {
    static let fs = "\u{1F}"
    static let rs = "\u{1E}"
    static let zone = TimeZone(identifier: "Africa/Johannesburg")!

    @Test func outlookMailIsReadNewestFirst() throws {
        let output = [
            ["101", "Lunch on Friday?", "Pat Rivers", "pat@example.com", "2026-10-23T07:10:00", "false", "priority normal", "0", "Are you free?"],
            ["102", "Release sign-off", "", "lee@example.com", "2026-10-23T08:45:00", "true", "priority high", "1", "Line one\(Self.fs)still the body"],
        ].map { $0.joined(separator: Self.fs) }.joined(separator: Self.rs) + Self.rs
        let mail = try Outlook.parseMail(output, timeZone: Self.zone)
        #expect(mail.map(\.id) == ["102", "101"])
        #expect(mail[0].sender == "lee")
        #expect(mail[0].priority == .high)
        #expect(mail[0].isFlagged && mail[0].isRead)
        #expect(mail[0].preview == "Line one\(Self.fs)still the body")
        #expect(mail[1].sender == "Pat Rivers")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.zone
        #expect(calendar.component(.hour, from: mail[1].received) == 7)
    }

    @Test func outlookCalendarIsReadInOrder() throws {
        let output = [
            ["e2", "Planning", "2026-10-23T14:00:00", "2026-10-23T15:00:00", "Room 4", "false", "Sam"],
            ["e1", "Stand-up", "2026-10-23T09:00:00", "2026-10-23T09:15:00", "", "false", ""],
            ["broken", "No dates", "soon", "later", "", "false", ""],
        ].map { $0.joined(separator: Self.fs) }.joined(separator: Self.rs)
        let entries = try Outlook.parseCalendar(output, timeZone: Self.zone)
        #expect(entries.map(\.title) == ["Stand-up", "Planning"])
        #expect(entries[1].location == "Room 4" && entries[1].organizer == "Sam")
    }

    @Test func outlookSaysWhyItCouldNotRead() throws {
        #expect(throws: Outlook.Failure.notRunning) { try Outlook.parseMail("NOT_RUNNING") }
        #expect(throws: Outlook.Failure.newOutlook) { try Outlook.parseMail("EMPTY_INBOX") }
        #expect(Outlook.failure("execution error: Not authorized to send Apple events to Microsoft Outlook. (-1743)") == .notAllowed)
        #expect(Outlook.failure("Microsoft Outlook got an error: Application isn’t running. (-600)") == .notRunning)
        #expect(Outlook.failure("line one\nsomething odd") == .failed("something odd"))
        #expect(try Outlook.parseMail("").isEmpty)
    }

    @Test func outlookScriptsNeverStartOutlook() {
        let mail = Outlook.mailScript(hours: 24, limit: 60)
        #expect(mail.hasPrefix("if application \"Microsoft Outlook\" is not running then return \"NOT_RUNNING\""))
        #expect(mail.contains("24 * hours") && mail.contains("n > 60"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.zone
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23))!
        let script = Outlook.calendarScript(from: start, to: start.addingTimeInterval(86_400), calendar: calendar)
        #expect(script.hasPrefix("if application \"Microsoft Outlook\" is not running"))
        #expect(script.contains("set day of d to 23") && script.contains("set day of d to 24"))
    }
}
