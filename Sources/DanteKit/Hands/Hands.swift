import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Hands: the agent in charge opens apps, finds folders and, when allowed, uses the keyboard
/// and mouse, through Dante's MCP server (`dante mcp`, with `DANTE_HANDS=1`). Off until turned
/// on in Settings › Agents. The control tools ask every time at any approval level, jobs never
/// get them, and they never reach Dante itself, terminals, System Settings or password
/// prompts. The kill switch (the badge's Stop, ⌃⌥⌘. anywhere, or turning Hands off) writes
/// `stopFlag`, which every call checks first, typing between characters too.
public enum Hands {
    public enum Tool: String, CaseIterable, Sendable {
        case openApp = "open_app"
        case findFolders = "find_folders"
        case revealInFinder = "reveal_in_finder"
        case frontmostApp = "frontmost_app"
        case screenshot
        case typeText = "type_text"
        case pressKeys = "press_keys"
        case click

        public var mcpName: String { "mcp__dante__" + rawValue }

        /// Acts on what's on screen: asks at every approval level.
        public var controls: Bool {
            switch self {
            case .screenshot, .typeText, .pressKeys, .click: true
            default: false
            }
        }

        /// "Type “hello” on the keyboard", for approvals and the transcript.
        public func describe(_ input: JSONValue, done: Bool) -> String {
            func quoted(_ text: String) -> String { "“\(text.count > 60 ? text.prefix(57) + "…" : text)”" }
            switch self {
            case .openApp:
                let file = input["path"]?.string.map { " with " + ($0 as NSString).lastPathComponent } ?? ""
                return (done ? "Opened " : "Open ") + (input["app"]?.string ?? "an app") + file
            case .findFolders: return (done ? "Looked for folders named " : "Look for folders named ") + quoted(input["name"]?.string ?? "")
            case .revealInFinder: return (done ? "Showed " : "Show ") + ((input["path"]?.string as NSString?)?.lastPathComponent ?? "a file") + " in Finder"
            case .frontmostApp: return done ? "Checked which app is in front" : "Check which app is in front"
            case .screenshot: return done ? "Took a screenshot" : "Take a screenshot of the screen"
            case .typeText: return (done ? "Typed " : "Type ") + quoted(input["text"]?.string ?? "")
            case .pressKeys: return (done ? "Pressed " : "Press ") + (input["keys"]?.string ?? "keys")
            case .click:
                let point = "\(input["x"]?.int ?? 0), \(input["y"]?.int ?? 0)"
                return (input["double"]?.bool == true ? (done ? "Double-clicked at " : "Double-click at ") : (done ? "Clicked at " : "Click at ")) + point
            }
        }

        public static func of(mcpName: String) -> Tool? {
            guard mcpName.hasPrefix("mcp__dante__") else { return nil }
            return Tool(rawValue: String(mcpName.dropFirst("mcp__dante__".count)))
        }
    }

    public static let environment = "DANTE_HANDS"

    /// Exists while Hands are stopped. Shared by the app and every `dante mcp` it starts.
    public static var stopFlag: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Dante/hands-stopped")
    }

    public static func isStopped(flag: URL = stopFlag) -> Bool {
        FileManager.default.fileExists(atPath: flag.path)
    }

    /// The kill switch.
    public static func stop(flag: URL = stopFlag) {
        try? FileManager.default.createDirectory(at: flag.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: flag.path, contents: Data("stopped \(Date())\n".utf8))
    }

    public static func allow(flag: URL = stopFlag) {
        try? FileManager.default.removeItem(at: flag)
    }

    public static let stoppedMessage = "The user stopped Hands with the kill switch. Don't try again; say what you were about to do and let them take over."

    // MARK: Where hands never go

    /// Apps the keyboard and mouse never touch: Dante (it would approve its own steps),
    /// terminals (typing there runs commands without Bash's approval), settings, passwords.
    public static let offLimits: Set<String> = [
        "dev.dante.ide", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "co.zeit.hyper", "com.github.wez.wezterm",
        "com.apple.systempreferences", "com.apple.Settings", "com.apple.keychainaccess", "com.apple.SecurityAgent",
        "com.apple.loginwindow", "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.Passwords", "com.apple.ScreenSharing",
    ]

    /// Why the keyboard or mouse may not act on this app, or nil when it may.
    public static func refusal(bundleID: String?, name: String?) -> String? {
        let id = bundleID ?? ""
        let shown = name ?? (id.isEmpty ? "that app" : id)
        if id.hasPrefix("dev.dante.ide") { return "\(shown) is Dante itself; Hands never act on Dante, so they can't approve their own steps." }
        if offLimits.contains(id) { return "Hands don’t type or click in \(shown): it’s a terminal, settings or password app. Ask the user to do it." }
        return nil
    }

    // MARK: Folders

    /// The Spotlight query for folders whose name contains `name`.
    public static func folderQuery(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "'", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "kMDItemContentType == \"public.folder\" && kMDItemFSName == \"*\(cleaned)*\"cd"
    }

    /// Spotlight's folders under the home folder, outside Library and hidden folders, nearest first.
    public static func rankedFolders(_ paths: [String], home: String, limit: Int = 20) -> [String] {
        paths.filter { path in
            path.hasPrefix(home + "/") && !path.hasPrefix(home + "/Library/")
                && !path.split(separator: "/").contains { $0.hasPrefix(".") }
                && !path.contains("/node_modules/")
        }
        .sorted { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }
        .prefix(limit).map { $0 }
    }

    // MARK: Keys

    /// "cmd+shift+s", "return", "ctrl+a", "f5".
    public struct KeyCombo: Equatable, Sendable {
        public var key: CGKeyCode
        public var flags: CGEventFlags

        public static func parse(_ text: String) -> KeyCombo? {
            let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let last = parts.last, let key = keyCodes[last] else { return nil }
            var flags: CGEventFlags = []
            for modifier in parts.dropLast() {
                switch modifier {
                case "cmd", "command", "⌘": flags.insert(.maskCommand)
                case "shift", "⇧": flags.insert(.maskShift)
                case "alt", "option", "opt", "⌥": flags.insert(.maskAlternate)
                case "ctrl", "control", "⌃": flags.insert(.maskControl)
                case "fn": flags.insert(.maskSecondaryFn)
                default: return nil
                }
            }
            return KeyCombo(key: key, flags: flags)
        }

        public static func == (lhs: KeyCombo, rhs: KeyCombo) -> Bool {
            lhs.key == rhs.key && lhs.flags.rawValue == rhs.flags.rawValue
        }

        /// US ANSI positions; the keyboard layout maps them to characters.
        static let keyCodes: [String: CGKeyCode] = {
            var codes: [String: CGKeyCode] = [
                "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
                "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
                "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
                "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
                ".": 47, "`": 50,
                "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
                "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
                "left": 123, "right": 124, "down": 125, "up": 126,
            ]
            let functions: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
            for (index, code) in functions.enumerated() { codes["f\(index + 1)"] = code }
            return codes
        }()
    }

    // MARK: Acting (in the `dante mcp` process; macOS asks for Dante's permissions)

    public struct Frontmost: Sendable {
        public var name: String
        public var bundleID: String?
        public var windowTitle: String?
    }

    /// The app that owns the frontmost window, from the window list (works without a run loop).
    public static func frontmost() -> Frontmost? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows where (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            return Frontmost(name: app?.localizedName ?? window[kCGWindowOwnerName as String] as? String ?? "An app",
                             bundleID: app?.bundleIdentifier, windowTitle: window[kCGWindowName as String] as? String)
        }
        return nil
    }

    /// The app whose window is under a point (top-left screen coordinates).
    public static func owner(at point: CGPoint) -> Frontmost? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0).contains(point),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            return Frontmost(name: app?.localizedName ?? window[kCGWindowOwnerName as String] as? String ?? "An app",
                             bundleID: app?.bundleIdentifier, windowTitle: window[kCGWindowName as String] as? String)
        }
        return nil
    }

    public static var canControl: Bool { AXIsProcessTrusted() }

    public static let needsAccessibility = "Dante needs Accessibility permission to use the keyboard and mouse: System Settings › Privacy & Security › Accessibility, then turn on Dante. Ask the user to do it; never open or change settings yourself."

    /// Types text into the frontmost app, a character at a time, stopping at the kill switch.
    public static func type(_ text: String, flag: URL = stopFlag) async -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        for character in text {
            if isStopped(flag: flag) { return false }
            let units = Array(String(character).utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                units.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
                event?.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(12))
        }
        return true
    }

    public static func press(_ combo: KeyCombo) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: combo.key, keyDown: down)
            event?.flags = combo.flags
            event?.post(tap: .cghidEventTap)
        }
    }

    public static func click(at point: CGPoint, double: Bool = false) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        for count in 1...(double ? 2 : 1) {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    /// Main screen size in points, for the screenshot's scale note.
    public static var screenSize: CGSize {
        CGDisplayBounds(CGMainDisplayID()).size
    }
}
