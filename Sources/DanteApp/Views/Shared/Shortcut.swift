import DanteKit
import SwiftUI

extension KeyBinding {
    /// The SwiftUI shortcut for a menu item.
    var keyboardShortcut: KeyboardShortcut {
        let key: KeyEquivalent = switch self.key {
        case "left": .leftArrow
        case "right": .rightArrow
        case "up": .upArrow
        case "down": .downArrow
        case "return": .return
        case "tab": .tab
        case "space": .space
        case "delete": .delete
        case "escape": .escape
        default: KeyEquivalent(self.key.first ?? " ")
        }
        var flags: EventModifiers = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return KeyboardShortcut(key, modifiers: flags)
    }

    /// The binding a key press makes, or nil for a key that can't be a shortcut on its own.
    init?(event: NSEvent) {
        var modifiers: Set<Modifier> = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        let named: [UInt16: String] = [123: "left", 124: "right", 126: "up", 125: "down", 36: "return", 48: "tab", 49: "space", 51: "delete", 53: "escape"]
        let key = named[event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased() ?? ""
        // Plain letters would fire while typing; a shortcut needs ⌘ or ⌃, or ⌥ with a named key.
        guard !key.isEmpty, modifiers.contains(.command) || modifiers.contains(.control) || (named[event.keyCode] != nil && !modifiers.isEmpty) else { return nil }
        self.init(key, modifiers)
    }
}

extension Shortcuts {
    /// "Hide Claude (⌥⌘L)", or just the title when the command has no shortcut.
    static func label(_ title: String, _ id: String) -> String {
        shared.binding(id).map { "\(title) (\($0.display))" } ?? title
    }
}

extension View {
    /// The menu item's shortcut from `Shortcuts`, so it follows the person's changes.
    func shortcut(_ id: String) -> some View {
        keyboardShortcut(Shortcuts.shared.binding(id)?.keyboardShortcut)
    }
}
