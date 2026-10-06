import Foundation
import Testing
@testable import DanteKit

@MainActor @Suite struct PreferencesTests {
    private func defaults() -> UserDefaults {
        let name = "dante-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func startsWithDefaultsAndRemembersChanges() {
        let store = defaults()
        let preferences = Preferences(defaults: store)
        #expect(preferences.completesWhileTyping && preferences.claudeAsksFirst)
        #expect(preferences.autoSave == .off && preferences.claudeModel == .default)
        #expect(preferences.indentWidth(for: .swift) == 4 && preferences.indentWidth(for: .typescript) == 2)

        preferences.indentWidth = 8
        preferences.autoSave = .afterDelay
        preferences.claudeModel = .sonnet
        preferences.claudeAsksFirst = false
        let reloaded = Preferences(defaults: store)
        #expect(reloaded.indentWidth(for: .typescript) == 8)
        #expect(reloaded.autoSave == .afterDelay && reloaded.claudeModel.argument == "sonnet" && !reloaded.claudeAsksFirst)
        #expect(Preferences.ClaudeModel.default.argument == nil)
    }

    @Test func tidiesOnSave() {
        #expect(SaveTidy.apply(to: "a  \nb\t\r\nc ", trimTrailingWhitespace: true, finalNewline: true) == "a\nb\r\nc\n")
        #expect(SaveTidy.apply(to: "a  ", trimTrailingWhitespace: false, finalNewline: false) == "a  ")
        #expect(SaveTidy.apply(to: "", trimTrailingWhitespace: true, finalNewline: true) == "")

        let preferences = Preferences(defaults: defaults())
        preferences.trimsTrailingWhitespace = true
        // Two trailing spaces are a line break in markdown.
        #expect(preferences.tidied("line  \n", language: .markdown) == "line  \n")
        #expect(preferences.tidied("let a = 1  \n", language: .swift) == "let a = 1\n")
    }
}
