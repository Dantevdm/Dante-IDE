import Foundation

/// A message in the inbox, as much as the morning update needs: who, what, when and the
/// start of the text for a one-line gist. Bodies stay on the Mac.
public struct MailMessage: Equatable, Sendable, Identifiable {
    public enum Priority: String, Sendable { case low, normal, high }

    public var id: String
    public var subject: String
    public var senderName: String
    public var senderAddress: String
    public var received: Date
    public var isRead: Bool
    public var priority: Priority
    public var isFlagged: Bool
    /// The first few hundred characters of the plain text.
    public var preview: String

    public init(id: String, subject: String, senderName: String, senderAddress: String, received: Date, isRead: Bool = false,
                priority: Priority = .normal, isFlagged: Bool = false, preview: String = "") {
        self.id = id
        self.subject = subject
        self.senderName = senderName
        self.senderAddress = senderAddress
        self.received = received
        self.isRead = isRead
        self.priority = priority
        self.isFlagged = isFlagged
        self.preview = preview
    }

    /// The sender as a person would say it: the name, else the address before the @.
    public var sender: String {
        let name = senderName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, !name.contains("@") { return name }
        return String(senderAddress.split(separator: "@").first ?? Substring(senderAddress))
    }
}

/// A meeting or appointment today.
public struct CalendarEntry: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var location: String
    public var isAllDay: Bool
    public var organizer: String

    public init(id: String, title: String, start: Date, end: Date, location: String = "", isAllDay: Bool = false, organizer: String = "") {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.isAllDay = isAllDay
        self.organizer = organizer
    }
}

/// Microsoft Outlook on this Mac, through AppleScript. macOS asks once whether Dante may
/// control Outlook. The "new Outlook" barely answers scripts, so an empty inbox comes back
/// with a note saying to switch to Legacy Outlook. It never starts Outlook.
public enum Outlook {
    public enum Failure: Error, Equatable, LocalizedError {
        case notRunning
        case notAllowed
        case newOutlook
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notRunning: "Outlook isn’t open on the Mac."
            case .notAllowed: "Dante isn’t allowed to read Outlook. Allow it in System Settings › Privacy & Security › Automation."
            case .newOutlook: "The new Outlook doesn’t answer Dante. Switch to Legacy Outlook in Outlook’s Help menu, or turn off New Outlook."
            case .failed(let message): "Outlook didn’t answer: \(message)"
            }
        }
    }

    static let field = "\u{1F}"
    static let record = "\u{1E}"

    /// AppleScript that prints the inbox's messages received since `hours` ago, newest first.
    public static func mailScript(hours: Int, limit: Int) -> String {
        """
        if application "Microsoft Outlook" is not running then return "NOT_RUNNING"
        set fs to (ASCII character 31)
        set rs to (ASCII character 30)
        set cutOffDate to (current date) - (\(hours) * hours)
        set mailOut to ""
        tell application "Microsoft Outlook"
            if (count of messages of inbox) is 0 then return "EMPTY_INBOX"
            set recentMail to (messages of inbox whose time received > cutOffDate)
            set n to 0
            repeat with m in recentMail
                set n to n + 1
                if n > \(limit) then exit repeat
                set mSender to sender of m
                set whoName to ""
                set whoAddress to ""
                try
                    set whoName to name of mSender
                end try
                try
                    set whoAddress to address of mSender
                end try
                set mBody to ""
                try
                    set mBody to plain text content of m
                    if (length of mBody) > 500 then set mBody to text 1 thru 500 of mBody
                end try
                set mFlag to "0"
                try
                    if todo flag of m is not not flagged then set mFlag to "1"
                end try
                set mailOut to mailOut & (id of m as text) & fs & (subject of m) & fs & whoName & fs & whoAddress & fs & ((time received of m) as «class isot» as string) & fs & (is read of m as text) & fs & (priority of m as text) & fs & mFlag & fs & mBody & rs
            end repeat
        end tell
        return mailOut
        """
    }

    /// AppleScript that prints the calendar's events starting between two dates.
    public static func calendarScript(from: Date, to: Date, calendar: Calendar = .current) -> String {
        func when(_ date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            return "set d to current date\nset day of d to 1\nset year of d to \(parts.year!)\nset month of d to \(parts.month!)\nset day of d to \(parts.day!)\nset hours of d to \(parts.hour!)\nset minutes of d to \(parts.minute!)\nset seconds of d to 0"
        }
        return """
        if application "Microsoft Outlook" is not running then return "NOT_RUNNING"
        set fs to (ASCII character 31)
        set rs to (ASCII character 30)
        \(when(from))
        set fromDate to d
        \(when(to))
        set toDate to d
        set out to ""
        tell application "Microsoft Outlook"
            set found to (calendar events whose start time ≥ fromDate and start time < toDate)
            repeat with e in found
                set place to ""
                try
                    set place to location of e
                end try
                set host to ""
                try
                    set host to organizer of e
                end try
                set out to out & (id of e as text) & fs & (subject of e) & fs & ((start time of e) as «class isot» as string) & fs & ((end time of e) as «class isot» as string) & fs & place & fs & (all day flag of e as text) & fs & host & rs
            end repeat
        end tell
        return out
        """
    }

    /// An AppleScript string literal.
    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\n") + "\""
    }

    /// Addresses from "Ana <ana@example.com>, sam@example.com; lee@example.com": only ones
    /// with an @ and no spaces.
    public static func addresses(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .compactMap { part -> String? in
                var address = part.trimmingCharacters(in: .whitespaces)
                if let open = address.lastIndex(of: "<"), let close = address.lastIndex(of: ">"), open < close {
                    address = String(address[address.index(after: open)..<close])
                }
                address = address.trimmingCharacters(in: .whitespaces)
                guard address.contains("@"), !address.contains(" "), !address.hasPrefix("@"), !address.hasSuffix("@") else { return nil }
                return address
            }
    }

    /// AppleScript that writes a draft and opens it in its own window for the person to read
    /// and send. It never sends. With `replyTo` (a message id from `mail`), it's a reply to
    /// everyone or the sender, with the text above the quoted message.
    public static func draftScript(to: [String], cc: [String] = [], subject: String, body: String, replyTo: String? = nil, replyAll: Bool = false) -> String {
        let html = "<p>" + body.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>") + "</p>"
        var lines = ["if application \"Microsoft Outlook\" is not running then return \"NOT_RUNNING\"", "tell application \"Microsoft Outlook\""]
        if let replyTo, let id = Int(replyTo) {
            lines.append("    set m to reply to (message id \(id))\(replyAll ? " with reply to all" : "") without opening window")
            lines.append("    set content of m to \(literal(html)) & (content of m)")
            if !subject.isEmpty { lines.append("    set subject of m to \(literal(subject))") }
        } else {
            lines.append("    set m to make new outgoing message with properties {subject:\(literal(subject)), content:\(literal(html))}")
        }
        for address in to { lines.append("    make new to recipient at m with properties {email address:{address:\(literal(address))}}") }
        for address in cc { lines.append("    make new cc recipient at m with properties {email address:{address:\(literal(address))}}") }
        lines += ["    open m", "    activate", "end tell", "return \"OK\""]
        return lines.joined(separator: "\n")
    }

    /// Writes a draft and opens it in Outlook (`draftScript`).
    public static func draft(to: [String], cc: [String] = [], subject: String, body: String, replyTo: String? = nil, replyAll: Bool = false) async throws(Failure) {
        try check(try await run(draftScript(to: to, cc: cc, subject: subject, body: body, replyTo: replyTo, replyAll: replyAll)))
    }

    /// Reads `mailScript`'s output.
    public static func parseMail(_ output: String, timeZone: TimeZone = .current) throws(Failure) -> [MailMessage] {
        try check(output)
        return records(output).compactMap { fields in
            guard fields.count >= 9, let received = date(fields[4], timeZone: timeZone) else { return nil }
            return MailMessage(id: fields[0], subject: fields[1], senderName: fields[2], senderAddress: fields[3], received: received,
                               isRead: fields[5] == "true", priority: priority(fields[6]), isFlagged: fields[7] == "1",
                               preview: fields[8...].joined(separator: field).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        .sorted { $0.received > $1.received }
    }

    /// Reads `calendarScript`'s output.
    public static func parseCalendar(_ output: String, timeZone: TimeZone = .current) throws(Failure) -> [CalendarEntry] {
        try check(output)
        return records(output).compactMap { fields in
            guard fields.count >= 7, let start = date(fields[2], timeZone: timeZone), let end = date(fields[3], timeZone: timeZone) else { return nil }
            return CalendarEntry(id: fields[0], title: fields[1], start: start, end: end, location: fields[4], isAllDay: fields[5] == "true", organizer: fields[6])
        }
        .sorted { $0.start < $1.start }
    }

    public static func mail(hours: Int = 24, limit: Int = 60) async throws(Failure) -> [MailMessage] {
        try parseMail(try await run(mailScript(hours: hours, limit: limit)))
    }

    public static func calendar(on day: Date = .now, calendar: Calendar = .current) async throws(Failure) -> [CalendarEntry] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return try parseCalendar(try await run(calendarScript(from: start, to: end, calendar: calendar)))
    }

    static func run(_ script: String) async throws(Failure) -> String {
        let result = await Shell.run(["osascript", "-e", script], in: FileManager.default.temporaryDirectory, trimming: false)
        if result.status != 0 { throw failure(result.stderr) }
        return result.stdout.trimmingCharacters(in: .newlines)
    }

    static func failure(_ stderr: String) -> Failure {
        if stderr.contains("-1743") || stderr.localizedCaseInsensitiveContains("not authorized") { return .notAllowed }
        if stderr.contains("-600") { return .notRunning }
        return .failed(stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "no answer")
    }

    static func check(_ output: String) throws(Failure) {
        if output == "NOT_RUNNING" { throw .notRunning }
        if output == "EMPTY_INBOX" { throw .newOutlook }
    }

    static func records(_ output: String) -> [[String]] {
        output.components(separatedBy: record)
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
            .map { $0.components(separatedBy: field) }
    }

    /// `2026-10-23T08:15:00`, in the Mac's time zone.
    static func date(_ text: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    static func priority(_ text: String) -> MailMessage.Priority {
        let lower = text.lowercased()
        if lower.contains("high") { return .high }
        if lower.contains("low") { return .low }
        return .normal
    }
}
