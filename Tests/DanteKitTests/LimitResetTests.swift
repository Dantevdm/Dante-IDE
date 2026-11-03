import Foundation
import Testing
@testable import DanteKit

struct LimitResetTests {
    let zone = TimeZone(identifier: "Africa/Johannesburg")!

    func at(_ text: String, _ zone: TimeZone) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        return formatter.date(from: text)!
    }

    @Test func clockTimeInTheNamedZone() {
        let now = at("2026-11-03T10:05:00+02:00", zone)
        let reset = LimitReset.date(in: "You've hit your session limit · resets 2:20pm (Africa/Johannesburg)", now: now)
        #expect(reset == at("2026-11-03T14:20:00+02:00", zone))
    }

    @Test func aTimeAlreadyPastIsTomorrows() {
        let now = at("2026-11-03T22:00:00+02:00", zone)
        #expect(LimitReset.date(in: "resets 3am", now: now, timeZone: zone) == at("2026-11-04T03:00:00+02:00", zone))
    }

    @Test func dateAndTime() {
        let now = at("2026-11-03T10:00:00+02:00", zone)
        #expect(LimitReset.date(in: "You've hit your weekly limit · resets Nov 6, 9am", now: now, timeZone: zone) == at("2026-11-06T09:00:00+02:00", zone))
    }

    @Test func relativeWait() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(LimitReset.date(in: "Rate limited. Try again in 45 minutes.", now: now) == now.addingTimeInterval(45 * 60))
        #expect(LimitReset.date(in: "usage limit, resets in 2 hours", now: now) == now.addingTimeInterval(7200))
    }

    @Test func nothingToRead() {
        #expect(LimitReset.date(in: "Not logged in · Please run /login") == nil)
    }
}
