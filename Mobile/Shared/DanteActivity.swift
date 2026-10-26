import ActivityKit
import Foundation

/// The Live Activity the app keeps on the Lock Screen and in the Dynamic Island while agents
/// on the Mac work or wait. Shared by the app and the widget extension, so it carries plain
/// values (the app fills them from `CompanionGlance`).
struct DanteActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        /// waiting, working, review or offline (`CompanionGlance.Mood`).
        var mood: String
        var headline: String
        var detail: String
        var waiting: Int
        var working: Int
    }

    /// The paired Mac's name.
    var server: String
}
