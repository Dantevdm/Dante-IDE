import Foundation

/// When a usage limit lifts, read from the agent's own words ("resets 2:20pm
/// (Africa/Johannesburg)", "resets Nov 6, 9am", "try again in 3 hours") (pure, tested), so a
/// conversation stopped at its limit can carry on by itself then.
public enum LimitReset {
    public static func date(in text: String, now: Date = Date(), timeZone fallback: TimeZone = .current) -> Date? {
        let lower = text.lowercased()
        if let relative = relativeDate(lower, now: now) { return relative }
        guard let match = lower.firstMatch(of: pattern) else { return nil }
        let zone = match.output.zone.flatMap { TimeZone(identifier: String($0).trimmingCharacters(in: .whitespaces)) } ?? fallback
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard var hour = Int(match.output.hour) else { return nil }
        let minute = match.output.minute.flatMap { Int($0) } ?? 0
        let meridiem = match.output.meridiem.map(String.init)
        if meridiem == "pm", hour < 12 { hour += 12 }
        if meridiem == "am", hour == 12 { hour = 0 }
        guard hour < 24, minute < 60 else { return nil }
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = hour
        parts.minute = minute
        if let month = match.output.month, let day = match.output.day.flatMap({ Int($0) }),
           let number = months.firstIndex(of: String(month.prefix(3))) {
            parts.month = number + 1
            parts.day = day
            guard var date = calendar.date(from: parts) else { return nil }
            // "Jan 2" seen in December is next year's.
            if date < now.addingTimeInterval(-86400) { parts.year = (parts.year ?? 0) + 1; date = calendar.date(from: parts) ?? date }
            return date
        }
        guard let today = calendar.date(from: parts) else { return nil }
        // A time already past today means tomorrow's.
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    nonisolated(unsafe) private static let pattern = /resets?\s+(?:at\s+)?(?:(?<month>jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(?<day>\d{1,2}),?\s+(?:at\s+)?)?(?<hour>\d{1,2})(?::(?<minute>\d{2}))?\s*(?<meridiem>am|pm)?(?:\s*\((?<zone>[^)]+)\))?/

    nonisolated(unsafe) private static let relative = /(?:try again|resets?)\s+in\s+(?<count>\d+)\s*(?<unit>minute|min|hour|hr|h|m)/

    private static func relativeDate(_ text: String, now: Date) -> Date? {
        guard let match = text.firstMatch(of: relative), let count = Double(match.output.count) else { return nil }
        let minutes = match.output.unit.hasPrefix("h") ? count * 60 : count
        return now.addingTimeInterval(minutes * 60)
    }
}
