import DanteKit
import Foundation
import Observation

/// The chosen theme and editor font size, remembered between launches.
@MainActor
@Observable
final class ThemeStore {
    private let defaults: UserDefaults

    var id: ThemeID {
        didSet { defaults.set(id.rawValue, forKey: "theme") }
    }

    var editorFontSize: Double {
        didSet { defaults.set(editorFontSize, forKey: "editorFontSize") }
    }

    var theme: Theme { id.theme }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        id = defaults.string(forKey: "theme").flatMap(ThemeID.init(rawValue:)) ?? .dark
        let size = defaults.double(forKey: "editorFontSize")
        editorFontSize = size > 0 ? size : 13
    }

    func cycle() { id = id.next }

    func adjustFontSize(by delta: Double) {
        editorFontSize = min(28, max(9, editorFontSize + delta))
    }
}
