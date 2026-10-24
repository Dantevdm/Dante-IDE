import Foundation

/// "Reply to Ana that Thursday works", done on the Mac: finds Ana's latest email in Outlook and
/// opens a reply there for you to read and send. Nothing is sent for you, and it only reads
/// mail when the morning update may.
public enum MailReplies {
    /// The newest message from the person named, leaving out mailing lists and notifications:
    /// every spoken word must be one of the sender's name words or start the address.
    public static func pick(_ who: String, in messages: [MailMessage]) -> MailMessage? {
        let spoken = words(who)
        guard !spoken.isEmpty else { return nil }
        return messages
            .filter { !MailTriage.isBulk($0) }
            .filter { message in
                let names = words(message.senderName)
                let local = message.senderAddress.lowercased().split(separator: "@").first.map(String.init) ?? ""
                let parts = local.split(whereSeparator: { ".-_".contains($0) }).map(String.init)
                return spoken.allSatisfy { word in names.contains(word) || parts.contains(word) || (spoken.count == 1 && local.hasPrefix(word)) }
            }
            .max { $0.received < $1.received }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }

    /// The name to greet: the sender's first name, else the name as said.
    static func firstName(of message: MailMessage, said: String) -> String {
        let name = message.senderName.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        if !name.isEmpty, !name.contains("@") { return name }
        return said.split(separator: " ").first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? said
    }

    /// Drafts the reply and returns what to say about it.
    public static func draft(_ reply: MailReply, readsMail: Bool, name: String?) async -> String {
        guard readsMail else {
            return "I don’t read your mail yet. Turn on Include important mail from Outlook in Settings › Agents › Morning update, and I can draft replies."
        }
        let mail: [MailMessage]
        do { mail = try await Outlook.mail(hours: 72, limit: 120) } catch { return error.localizedDescription }
        guard let message = pick(reply.who, in: mail) else { return "I couldn’t find a recent email from \(reply.who)." }
        let body = reply.body(firstName: firstName(of: message, said: reply.who), signedBy: name)
        do {
            try await Outlook.draft(to: [], subject: "", body: body, replyTo: message.id)
        } catch {
            return error.localizedDescription
        }
        return "Your reply to \(message.sender) about \(BriefingComposer.speakableSubject(message.subject)) is open in Outlook. Send it when you’re happy."
    }

    /// `draft` with the preferences.
    @MainActor public static func draft(_ reply: MailReply) async -> String {
        let preferences = Preferences.shared
        return await draft(reply, readsMail: preferences.briefingReadsMail, name: preferences.assistantName.isEmpty ? nil : preferences.assistantName)
    }
}
