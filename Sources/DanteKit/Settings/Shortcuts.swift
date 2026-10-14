import Foundation
import Observation

/// A key and its modifiers, as the menus use them. `key` is one character, or a name for
/// the keys that have none: left, right, up, down, return, tab, space, delete, escape,
/// and f1 to f12.
public struct KeyBinding: Codable, Equatable, Hashable, Sendable {
    public enum Modifier: String, Codable, CaseIterable, Sendable, Comparable {
        // Display order, as macOS menus show them.
        case control, option, shift, command

        var symbol: String {
            switch self {
            case .control: "⌃"
            case .option: "⌥"
            case .shift: "⇧"
            case .command: "⌘"
            }
        }

        public static func < (a: Modifier, b: Modifier) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    public var key: String
    public var modifiers: Set<Modifier>

    public init(_ key: String, _ modifiers: Set<Modifier> = [.command]) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.modifiers = modifiers
    }

    static let names: [String: String] = ["left": "←", "right": "→", "up": "↑", "down": "↓", "return": "↩", "tab": "⇥", "space": "Space", "delete": "⌫", "escape": "⎋"]

    /// "⌃⇧F", as a menu shows it.
    public var display: String {
        modifiers.sorted().map(\.symbol).joined() + (Self.names[key] ?? key.uppercased())
    }
}

/// A menu command whose shortcut can be changed.
public struct ShortcutCommand: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var menu: String
    public var defaultBinding: KeyBinding?

    init(_ id: String, _ title: String, _ menu: String, _ binding: KeyBinding?) {
        self.id = id
        self.title = title
        self.menu = menu
        self.defaultBinding = binding
    }
}

/// The menus' shortcuts: defaults, with the person's changes from user defaults on top.
@MainActor
@Observable
public final class Shortcuts {
    public static let shared = Shortcuts()

    public static let commands: [ShortcutCommand] = [
        .init("settings", "Settings…", "Dante", KeyBinding(",")),
        .init("newProject", "New Project…", "File", KeyBinding("n")),
        .init("newWindow", "New Window", "File", KeyBinding("n", [.command, .shift])),
        .init("openFolder", "Open Folder…", "File", KeyBinding("o")),
        .init("clone", "Clone Repository…", "File", KeyBinding("c", [.command, .shift])),
        .init("openRemote", "Open Remote…", "File", KeyBinding("o", [.command, .control])),
        .init("save", "Save", "File", KeyBinding("s")),
        .init("saveAll", "Save All", "File", KeyBinding("s", [.command, .option])),
        .init("closeTab", "Close Tab", "File", KeyBinding("w")),
        .init("exportDoc", "Export Doc as PDF…", "File", KeyBinding("e", [.command, .shift])),
        .init("printDoc", "Print Doc…", "File", KeyBinding("p")),
        .init("searchOrAsk", "Search or Ask…", "Edit", KeyBinding("k")),
        .init("openQuickly", "Open Quickly…", "Edit", KeyBinding("p")),
        .init("findInProject", "Find in Project…", "Edit", KeyBinding("f", [.command, .shift])),
        .init("goToSymbol", "Go to Symbol…", "Edit", KeyBinding("o", [.command, .shift])),
        .init("jumpToDefinition", "Jump to Definition", "Edit", KeyBinding("j", [.command, .control])),
        .init("editWithClaude", "Edit with Claude…", "Edit", KeyBinding("i")),
        .init("findReferences", "Find References", "Edit", KeyBinding("f", [.command, .control, .shift])),
        .init("renameSymbol", "Rename Symbol…", "Edit", KeyBinding("e", [.command, .control])),
        .init("formatDocument", "Format Document", "Edit", KeyBinding("i", [.control, .shift])),
        .init("problems", "Problems", "Edit", KeyBinding("m", [.command, .shift])),
        .init("finishTask", "Finish Task…", "Git", nil),
        .init("sourceControl", "Source Control", "Git", KeyBinding("g", [.control, .shift])),
        .init("push", "Push", "Git", nil),
        .init("pull", "Pull", "Git", nil),
        .init("fetch", "Fetch", "Git", nil),
        .init("switchBranch", "Switch Branch…", "Git", KeyBinding("b", [.control, .shift])),
        .init("toggleTerminal", "Show or Hide Terminal", "View", KeyBinding("`", [.control])),
        .init("back", "Back", "View", KeyBinding("left", [.command, .control])),
        .init("forward", "Forward", "View", KeyBinding("right", [.command, .control])),
        .init("newTerminal", "New Terminal", "View", KeyBinding("`", [.control, .shift])),
        .init("askClaude", "Ask Claude", "View", KeyBinding("l")),
        .init("toggleClaude", "Show or Hide Claude", "View", KeyBinding("l", [.command, .option])),
        .init("nextTab", "Next Tab", "View", KeyBinding("]", [.command, .shift])),
        .init("previousTab", "Previous Tab", "View", KeyBinding("[", [.command, .shift])),
        .init("split", "Split Editor", "View", KeyBinding("\\")),
        .init("focusOtherPane", "Focus Other Pane", "View", KeyBinding("\\", [.command, .option])),
        .init("nextTheme", "Next Theme", "View", KeyBinding("t", [.command, .option])),
        .init("biggerText", "Bigger Text", "View", KeyBinding("+")),
        .init("smallerText", "Smaller Text", "View", KeyBinding("-")),
        .init("actualSize", "Actual Size", "View", KeyBinding("0")),
        .init("debugStart", "Start Debugging", "Debug", KeyBinding("f5", [])),
        .init("debugContinue", "Continue", "Debug", KeyBinding("y", [.command, .control])),
        .init("debugStepOver", "Step Over", "Debug", KeyBinding("f6", [])),
        .init("debugStepIn", "Step Into", "Debug", KeyBinding("f7", [])),
        .init("debugStepOut", "Step Out", "Debug", KeyBinding("f8", [])),
        .init("debugStop", "Stop Debugging", "Debug", KeyBinding("f5", [.shift])),
        .init("debugToggleBreakpoint", "Toggle Breakpoint", "Debug", KeyBinding("f9", [])),
    ]

    /// Shortcuts the person changed; `.some(nil)` means they removed it.
    public private(set) var overrides: [String: KeyBinding?]
    private let defaults: UserDefaults
    static let key = "shortcutOverrides"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Stored].self, from: $0) } ?? [:]
        overrides = stored.mapValues(\.binding)
    }

    /// Codable stand-in for an optional binding, so a removed shortcut survives a relaunch.
    private struct Stored: Codable {
        var binding: KeyBinding?
    }

    public func binding(_ id: String) -> KeyBinding? {
        if let override = overrides[id] { return override }
        return Self.commands.first { $0.id == id }?.defaultBinding
    }

    public func isChanged(_ id: String) -> Bool { overrides[id] != nil }

    /// Called with the command, its old binding and its new one after each change. SwiftUI
    /// doesn't rebuild menus it has already made, so the app updates the menu item here.
    public var onChange: ((ShortcutCommand, KeyBinding?, KeyBinding?) -> Void)?

    public func set(_ binding: KeyBinding?, for id: String) {
        let before = self.binding(id)
        let original = Self.commands.first { $0.id == id }?.defaultBinding
        if binding == original { overrides[id] = nil } else { overrides[id] = .some(binding) }
        save()
        changed(id, from: before)
    }

    public func reset(_ id: String? = nil) {
        let ids = id.map { [$0] } ?? Array(overrides.keys)
        let before = Dictionary(uniqueKeysWithValues: ids.map { ($0, binding($0)) })
        if let id { overrides[id] = nil } else { overrides = [:] }
        save()
        for id in ids { changed(id, from: before[id] ?? nil) }
    }

    private func changed(_ id: String, from before: KeyBinding?) {
        guard let command = Self.commands.first(where: { $0.id == id }) else { return }
        let after = binding(id)
        if after != before { onChange?(command, before, after) }
    }

    /// Other commands already on `binding`.
    public func conflicts(_ binding: KeyBinding, except id: String) -> [ShortcutCommand] {
        Self.commands.filter { $0.id != id && self.binding($0.id) == binding }
    }

    private func save() {
        let stored = overrides.mapValues { Stored(binding: $0) }
        defaults.set(try? JSONEncoder().encode(stored), forKey: Self.key)
    }
}
