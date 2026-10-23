import Foundation

/// A message worth hearing about, with why and a one-line gist. Only this leaves the Mac.
public struct ImportantMail: Equatable, Sendable, Identifiable {
    public var message: MailMessage
    public var score: Int
    public var reasons: [String]
    public var gist: String
    public var id: String { message.id }
}

/// Picks the mail that needs you out of a day's inbox, without a model: people over robots,
/// flagged and high priority first, questions and deadlines next. Newsletters, notifications
/// and receipts stay out unless you flagged them.
public enum MailTriage {
    /// Senders whose mail always counts (names or addresses, any case).
    public static func important(_ messages: [MailMessage], vips: [String] = [], limit: Int = 5) -> [ImportantMail] {
        messages.compactMap { message -> ImportantMail? in
            let (score, reasons) = score(message, vips: vips)
            guard score >= threshold else { return nil }
            return ImportantMail(message: message, score: score, reasons: reasons, gist: gist(message.preview, subject: message.subject))
        }
        .sorted { ($0.score, $0.message.received) > ($1.score, $1.message.received) }
        .prefix(limit)
        .map { $0 }
    }

    static let threshold = 4

    static func score(_ message: MailMessage, vips: [String]) -> (Int, [String]) {
        var score = 0
        var reasons: [String] = []
        let vip = vips.contains { vip in
            let vip = vip.lowercased().trimmingCharacters(in: .whitespaces)
            return !vip.isEmpty && (message.senderAddress.lowercased() == vip || message.senderName.lowercased().contains(vip))
        }
        if message.isFlagged { score += 5; reasons.append("flagged") }
        if message.priority == .high { score += 3; reasons.append("high priority") }
        if vip { score += 4; reasons.append("from someone you follow") }
        if isBulk(message) {
            // A robot's mail only counts when you've marked it yourself.
            return message.isFlagged || vip ? (score, reasons) : (0, [])
        }
        score += 2
        if !message.isRead { score += 1 }
        if message.isRead && !message.isFlagged { score -= 2 }
        let text = (message.subject + " " + message.preview.prefix(400)).lowercased()
        if urgent.contains(where: { text.contains($0) }) { score += 2; reasons.append("time-sensitive") }
        if message.preview.prefix(400).contains("?") || message.subject.contains("?") { score += 1; reasons.append("asks you something") }
        if asks.contains(where: { text.contains($0) }) { score += 1; if !reasons.contains("asks you something") { reasons.append("asks you something") } }
        if message.subject.lowercased().hasPrefix("re:") { score += 1 }
        return (score, reasons)
    }

    static let urgent = ["urgent", "asap", "as soon as possible", "today", "deadline", "action required", "eod", "end of day",
                         "outage", "incident", "is down", "blocked", "escalat", "overdue", "by tomorrow"]
    static let asks = ["can you", "could you", "please review", "please approve", "your approval", "need your", "waiting on you", "let me know"]

    /// Mailing lists, notifications, receipts and the like.
    public static func isBulk(_ message: MailMessage) -> Bool {
        let address = message.senderAddress.lowercased()
        let local = address.split(separator: "@").first.map(String.init) ?? address
        if robots.contains(where: { local.contains($0) }) { return true }
        let subject = message.subject.lowercased()
        if bulkSubjects.contains(where: { subject.hasPrefix($0) || subject.contains($0) }) { return true }
        let preview = message.preview.lowercased()
        return preview.contains("unsubscribe") || preview.contains("view in browser") || preview.contains("view this email in your browser")
    }

    static let robots = ["noreply", "no-reply", "donotreply", "do-not-reply", "notification", "notifications", "newsletter", "mailer",
                         "marketing", "news", "digest", "alerts", "updates", "support", "billing", "invoice", "receipts", "bounce", "postmaster",
                         "calendar-notification", "azuredevops", "github", "jira", "confluence"]
    static let bulkSubjects = ["accepted:", "declined:", "tentative:", "automatic reply", "out of office", "your receipt", "your order",
                               "invoice", "newsletter", "webinar", "weekly digest", "daily digest", "[github]", "build succeeded", "password reset"]

    /// The message's first real sentence: greetings, sign-offs, quoted text and links left out,
    /// cut to about 140 characters. Falls back to the subject.
    public static func gist(_ preview: String, subject: String) -> String {
        var lines: [String] = []
        for raw in preview.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if line.isEmpty || line.hasPrefix(">") || lower.hasPrefix("http") { continue }
            if lower.hasPrefix("from:") || lower.hasPrefix("sent:") || lower.hasPrefix("on ") && lower.contains("wrote") { break }
            if isGreeting(lower) { continue }
            lines.append(line)
        }
        let text = lines.joined(separator: " ").replacingOccurrences(of: "  ", with: " ")
        guard !text.isEmpty else { return subject }
        let sentence = firstSentence(text)
        return sentence.count > 140 ? String(sentence.prefix(137)).trimmingCharacters(in: .whitespaces) + "…" : sentence
    }

    static func isGreeting(_ lower: String) -> Bool {
        let words = lower.split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard let first = words.first, words.count <= 4 else { return false }
        return ["hi", "hello", "hey", "dear", "morning", "afternoon", "good", "hallo", "howzit"].contains(first)
            || ["thanks", "regards", "cheers", "best", "kind"].contains(first) && words.count <= 3
    }

    static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "e.g", "i.e", "etc", "vs", "approx", "no"]

    static func firstSentence(_ text: String) -> String {
        var end = text.endIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if ".!?".contains(text[index]), next == text.endIndex || text[next] == " " {
                // Not "e.g." or "Mr."
                let before = (text[text.startIndex..<index].split(separator: " ").last.map(String.init) ?? "").lowercased()
                if text[index] != "." || !abbreviations.contains(before) { end = next; break }
            }
            index = next
        }
        return String(text[text.startIndex..<end]).trimmingCharacters(in: .whitespaces)
    }
}
