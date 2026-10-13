import Foundation

/// Which Claude conversation belongs to which task, per Mac. Claude Code's session ids
/// only mean something on the machine that has the transcripts, so they stay out of the repo.
public enum TaskConversations {
    static func key(_ root: URL) -> String { "taskConversations." + root.standardizedFileURL.path }

    public static func conversation(for task: String, in root: URL, defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: key(root)) as? [String: String])?[task]
    }

    public static func set(_ conversation: String?, for task: String, in root: URL, defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: key(root)) as? [String: String]) ?? [:]
        all[task] = conversation
        defaults.set(all, forKey: key(root))
    }
}
