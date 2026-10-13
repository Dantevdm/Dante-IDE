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
        default: functionKey.map { KeyEquivalent(Character(UnicodeScalar($0)!)) } ?? KeyEquivalent(self.key.first ?? " ")
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
        let functionKeys: [UInt16: String] = [122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12"]
        let key = functionKeys[event.keyCode] ?? named[event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased() ?? ""
        // Plain letters would fire while typing; a shortcut needs ⌘ or ⌃, or ⌥ with a named key.
        // Function keys work on their own.
        guard !key.isEmpty, functionKeys[event.keyCode] != nil || modifiers.contains(.command) || modifiers.contains(.control) || (named[event.keyCode] != nil && !modifiers.isEmpty) else { return nil }
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

/// Puts a changed shortcut on the menu item that's already in the menu bar. SwiftUI's own
/// items won't take back the shortcut they were built with, so a reset to the default can
/// need a restart; `needsRestart` lists those for Settings to say so.
@MainActor @Observable
final class MenuShortcuts {
    static let shared = MenuShortcuts()
    private(set) var needsRestart: Set<String> = []

    static func install() {
        Shortcuts.shared.onChange = { command, before, after in
            guard let item = item(for: command, currently: before) else { return }
            apply(after, to: item)
            // SwiftUI sometimes rewrites the item when it next updates the menus (on a reset it
            // put back the modifiers but not the key), so set it again once that's done.
            for delay in [0.3, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated {
                        let now = Shortcuts.shared.binding(command.id)
                        guard let fresh = MenuShortcuts.item(for: command, currently: now) ?? MenuShortcuts.item(for: command, currently: before) else { return }
                        apply(now, to: fresh)
                        let took = fresh.keyEquivalent == (now?.menuKey ?? "") && fresh.keyEquivalentModifierMask == (now?.menuModifiers ?? [])
                        if took { shared.needsRestart.remove(command.id) } else { shared.needsRestart.insert(command.id) }
                    }
                }
            }
        }
    }

    private static func apply(_ binding: KeyBinding?, to item: NSMenuItem) {
        item.keyEquivalentModifierMask = binding?.menuModifiers ?? []
        item.keyEquivalent = binding?.menuKey ?? ""
    }

    /// The item in the command's menu with its title, or failing that (a title that
    /// changes, like Show/Hide Claude) the one on the old shortcut.
    static func item(for command: ShortcutCommand, currently before: KeyBinding?) -> NSMenuItem? {
        let menus = (NSApp.mainMenu?.items ?? []).compactMap(\.submenu)
        let menu = command.menu == "Dante" ? menus.first : menus.first { $0.title == command.menu }
        let items = (menu.map { [$0] } ?? menus).flatMap(allItems)
        func plain(_ title: String) -> String { title.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "") }
        if let titled = items.first(where: { plain($0.title) == plain(command.title) }) { return titled }
        guard let before else { return nil }
        return items.first { $0.keyEquivalent == before.menuKey && $0.keyEquivalentModifierMask == before.menuModifiers }
    }

    private static func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
    }
}

extension KeyBinding {
    /// The key as an `NSMenuItem` key equivalent.
    var menuKey: String {
        func function(_ key: Int) -> String { String(Character(UnicodeScalar(key)!)) }
        switch key {
        case "left": return function(NSLeftArrowFunctionKey)
        case "right": return function(NSRightArrowFunctionKey)
        case "up": return function(NSUpArrowFunctionKey)
        case "down": return function(NSDownArrowFunctionKey)
        case "return": return "\r"
        case "tab": return "\t"
        case "space": return " "
        case "delete": return "\u{8}"
        case "escape": return "\u{1b}"
        default: return functionKey.map(function) ?? key
        }
    }

    /// The AppKit character for "f1"…"f12", nil for any other key.
    var functionKey: Int? {
        guard key.count >= 2, key.first == "f", let number = Int(key.dropFirst()), (1...12).contains(number) else { return nil }
        return NSF1FunctionKey + number - 1
    }

    var menuModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }
}
