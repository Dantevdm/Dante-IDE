import AppKit
import ApplicationServices
import Foundation

/// The new Outlook answers no scripts, so its inbox is read from its window instead, through
/// Accessibility (as VoiceOver reads it). Each message in the list is one row whose label
/// reads like `Unread, Sender: Ana Smith, Subject: Thursday's release, 14:05, Message preview: …`;
/// rows such as `Today` head each group. Only what the list shows is there: the folder and tab
/// in view (Focused or Other), the messages scrolled into view, and a line of each one's text.
/// Outlook may be in the background or minimised.
public enum OutlookWindow {
    static let bundleID = "com.microsoft.Outlook"

    /// The messages in Outlook's message list received within `hours`, newest first.
    public static func mail(hours: Int, limit: Int, now: Date = .now) throws(Outlook.Failure) -> [MailMessage] {
        guard AXIsProcessTrusted() else { throw .noAccessibility }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { throw .notRunning }
        // Outlook answers Accessibility slowly while it's busy (a script asking it for the
        // calendar, say), so a read that comes back empty is tried again.
        var rows: [String] = []
        for attempt in 0..<4 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 1.5) }
            rows = WindowReader.windows(of: bundleID).flatMap(messageRows)
            if rows.contains(where: { $0.contains("Subject:") }) { break }
        }
        guard !rows.isEmpty else { throw .noMessageList }
        let cutOff = now.addingTimeInterval(-Double(hours) * 3_600)
        return rows.compactMap { message(from: $0, now: now) }
            .filter { $0.received >= cutOff }
            .sorted { $0.received > $1.received }
            .prefix(limit)
            .map { $0 }
    }

    /// The labels of the message list's rows (headings included), in order.
    static func messageRows(_ node: WindowReader.Node) -> [String] {
        if node.role == "AXTable", node.help.localizedCaseInsensitiveContains("message list") {
            return node.children.compactMap { row in
                let label = row.children.first { !$0.help.isEmpty }?.help ?? row.help
                return label.isEmpty ? nil : label
            }
        }
        return node.children.flatMap(messageRows)
    }

    /// One row's label as a message; nil for a group heading or a row it can't read.
    public static func message(from label: String, now: Date, calendar: Calendar = .current) -> MailMessage? {
        let text = label.trimmingCharacters(in: .whitespaces)
        guard let senderRange = text.range(of: #"(?:Sender|From):\s*"#, options: .regularExpression),
              let subjectRange = text.range(of: ", Subject:", range: senderRange.upperBound..<text.endIndex) else { return nil }
        let flags = text[..<senderRange.lowerBound].lowercased()
        let sender = text[senderRange.upperBound..<subjectRange.lowerBound].trimmingCharacters(in: .whitespaces)
        // Several people in a conversation: the first named is the latest.
        let name = sender.components(separatedBy: ", ").first ?? sender
        let rest = String(text[subjectRange.upperBound...])
        guard let when = whenPattern.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
              let whenText = Range(when.range(at: 1), in: rest).map({ String(rest[$0]) }),
              let subjectEnd = Range(when.range, in: rest)?.lowerBound,
              let received = date(whenText, now: now, calendar: calendar) else { return nil }
        let subject = rest[..<subjectEnd].trimmingCharacters(in: .whitespaces)
        let tail = rest[subjectEnd...]
        var preview = ""
        if let start = tail.range(of: "Message preview:") {
            preview = tail[start.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        let isAddress = name.contains("@")
        return MailMessage(id: "outlook-window:" + String(label.hashValue, radix: 36), subject: subject,
                           senderName: isAddress ? "" : name, senderAddress: isAddress ? name : "", received: received,
                           isRead: !flags.contains("unread"),
                           priority: tail.localizedCaseInsensitiveContains("high importance") || flags.contains("important") ? .high : .normal,
                           isFlagged: flags.contains("flagged"), preview: preview)
    }

    /// `, 14:05,` or `, Latest message:  Yesterday,` after the subject.
    nonisolated(unsafe) static let whenPattern = try! NSRegularExpression(
        pattern: #",\s+(?:\w+ message:\s+)?(\d{1,2}:\d{2}(?:\s?[AaPp][Mm])?|Today|Yesterday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\w* \d{1,2}:\d{2}(?:\s?[AaPp][Mm])?|\d{4}/\d{1,2}/\d{1,2}|\d{1,2}/\d{1,2}/\d{2,4}|\d{4}-\d{2}-\d{2})\s*(?:,|$)"#)

    /// The list shows a time for today, a weekday or Yesterday for the past week and a date
    /// before that. Without a time a message counts as received at noon.
    static func date(_ text: String, now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        func at(_ day: Date, _ time: String?) -> Date? {
            guard let time else { return calendar.date(byAdding: .hour, value: 12, to: day) }
            let parts = time.lowercased().replacingOccurrences(of: " ", with: "")
            let pm = parts.hasSuffix("pm"), am = parts.hasSuffix("am")
            let numbers = parts.trimmingCharacters(in: CharacterSet.letters).split(separator: ":").compactMap { Int($0) }
            guard numbers.count == 2 else { return nil }
            var hour = numbers[0]
            if pm, hour < 12 { hour += 12 }
            if am, hour == 12 { hour = 0 }
            return calendar.date(bySettingHour: hour, minute: numbers[1], second: 0, of: day)
        }
        if text.first?.isNumber == true, text.contains(":") {
            // A time today; one later than now was yesterday's.
            guard let time = at(today, text) else { return nil }
            return time > now.addingTimeInterval(300) ? calendar.date(byAdding: .day, value: -1, to: time) : time
        }
        if text == "Today" { return at(today, nil) }
        if text == "Yesterday" { return calendar.date(byAdding: .day, value: -1, to: today).flatMap { at($0, nil) } }
        let words = text.split(separator: " ")
        if let first = words.first, let weekday = weekdays.firstIndex(where: { first.lowercased().hasPrefix($0) }) {
            // The latest such weekday before today.
            let todayWeekday = calendar.component(.weekday, from: today) - 1
            var back = (todayWeekday - weekday + 7) % 7
            if back == 0 { back = 7 }
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            return at(day, words.count > 1 ? words[1...].joined(separator: " ") : nil)
        }
        for format in ["yyyy/M/d", "yyyy-MM-dd", "d/M/yyyy", "d/M/yy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = format
            if let day = formatter.date(from: text) { return at(calendar.startOfDay(for: day), nil) }
        }
        return nil
    }

    /// For checking the reader against a real Outlook without reading any mail: counts, how
    /// recent the newest is, and the rows that didn't read with every word masked.
    public static func check(now: Date = .now) async -> String {
        let script: String
        do { script = "script: \(try Outlook.parseMail(try await Outlook.run(Outlook.mailScript(hours: 24, limit: 5))).count) messages" } catch { script = "script: \(error)" }
        let full: String
        do { full = "Outlook.mail: \(try await Outlook.mail(hours: 24, limit: 200).count) messages" } catch { full = "Outlook.mail: \(error)" }
        return [script, full, windowCheck(now: now)].joined(separator: "\n")
    }

    static func windowCheck(now: Date) -> String {
        guard AXIsProcessTrusted() else { return "not trusted" }
        let rows = WindowReader.windows(of: bundleID).flatMap(messageRows)
        var lines = ["\(rows.count) rows"]
        var read = 0, newest: Date?
        for row in rows {
            if let message = message(from: row, now: now) {
                read += 1
                newest = max(newest ?? message.received, message.received)
                if message.subject.isEmpty || message.sender.isEmpty { lines.append("empty field: " + WindowReader.masked(.init(role: "row", help: row))) }
            } else if row.contains("Subject:") {
                lines.append("unread row: " + WindowReader.masked(.init(role: "row", help: row)))
            }
        }
        lines.insert("\(read) messages read; newest \(newest.map { Int(now.timeIntervalSince($0) / 60) }.map { "\($0) minutes ago" } ?? "none")", at: 1)
        lines.append("last 24 hours: \((try? mail(hours: 24, limit: 200, now: now).count) ?? -1)")
        return lines.joined(separator: "\n")
    }

    static let weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
}
