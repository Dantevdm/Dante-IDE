import CoreGraphics
import Foundation

/// Hands as `dante mcp` tools: listed only with `DANTE_HANDS=1`.
extension DelegateServer {
    static let handsInstructions = "Hands let you act on the user's Mac outside the project: open_app, find_folders and reveal_in_finder; frontmost_app and screenshot to see where you are; type_text, press_keys and click to use it. The user approves each keyboard, mouse and screenshot step and can stop Hands at any moment. Look before you click, act in small steps, and say what you're doing. Never type passwords or payment details, and never act in Dante, terminals or settings: use Bash for commands instead."

    static let handsTools: [JSONValue] = [
        [
            "name": "open_app",
            "description": "Open (or bring forward) an app on the user's Mac by its name, like Safari, Notes or Xcode, optionally with a file or folder.",
            "inputSchema": ["type": "object", "properties": [
                "app": ["type": "string", "description": "The app's name as Finder shows it."],
                "path": ["type": "string", "description": "Optional file or folder to open in it."],
            ], "required": ["app"]],
        ],
        [
            "name": "find_folders",
            "description": "Find folders in the user's home folder by name with Spotlight, nearest first (Library and hidden folders left out).",
            "inputSchema": ["type": "object", "properties": [
                "name": ["type": "string", "description": "Part of the folder's name."],
            ], "required": ["name"]],
        ],
        [
            "name": "reveal_in_finder",
            "description": "Show a file or folder in the user's home folder in a Finder window.",
            "inputSchema": ["type": "object", "properties": [
                "path": ["type": "string", "description": "An absolute path, or one starting with ~."],
            ], "required": ["path"]],
        ],
        [
            "name": "frontmost_app",
            "description": "Which app and window are in front now.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "screenshot",
            "description": "A picture of the main screen, to see before clicking. Coordinates for click are in the screen's points, which the reply gives.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "type_text",
            "description": "Type text into the frontmost app, as if on the keyboard. Never for passwords or payment details.",
            "inputSchema": ["type": "object", "properties": [
                "text": ["type": "string", "description": "Up to 2,000 characters."],
            ], "required": ["text"]],
        ],
        [
            "name": "press_keys",
            "description": "Press a key with modifiers in the frontmost app, like cmd+s, return, escape, cmd+shift+n or down.",
            "inputSchema": ["type": "object", "properties": [
                "keys": ["type": "string", "description": "Modifiers (cmd, shift, alt, ctrl) and a key, joined with +."],
            ], "required": ["keys"]],
        ],
        [
            "name": "click",
            "description": "Click at a point on the main screen, in points from its top-left corner (from screenshot).",
            "inputSchema": ["type": "object", "properties": [
                "x": ["type": "number"], "y": ["type": "number"],
                "double": ["type": "boolean", "description": "A double-click."],
            ], "required": ["x", "y"]],
        ],
    ]

    func callHands(_ tool: Hands.Tool, arguments: JSONValue, stopFlag: URL = Hands.stopFlag) async -> JSONValue {
        if Hands.isStopped(flag: stopFlag) { return Self.text(Hands.stoppedMessage, isError: true) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch tool {
        case .openApp:
            guard let app = arguments["app"]?.string?.trimmingCharacters(in: .whitespaces), !app.isEmpty else {
                return Self.text("open_app needs an app name.", isError: true)
            }
            if let refusal = Self.appRefusal(app) { return Self.text(refusal, isError: true) }
            var command = ["open", "-a", app]
            if let path = arguments["path"]?.string, !path.isEmpty {
                let file = Self.expand(path, home: home)
                if let refusal = Self.documentRefusal(file) { return Self.text(refusal, isError: true) }
                command.append(file)
            }
            let result = await Shell.run(command, in: home)
            return result.status == 0 ? Self.text("Opened \(app).")
                : Self.text("Couldn’t open \(app): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))", isError: true)
        case .findFolders:
            guard let name = arguments["name"]?.string, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                return Self.text("find_folders needs part of a name.", isError: true)
            }
            let result = await Shell.run(["mdfind", "-onlyin", home.path, Hands.folderQuery(name)], in: home)
            let found = Hands.rankedFolders(result.stdout.split(separator: "\n").map(String.init), home: home.path)
            return Self.text(found.isEmpty ? "No folders named like \(name) in the home folder." : found.joined(separator: "\n"))
        case .revealInFinder:
            guard let path = arguments["path"]?.string else { return Self.text("reveal_in_finder needs a path.", isError: true) }
            let expanded = URL(filePath: Self.expand(path, home: home)).standardizedFileURL.resolvingSymlinksInPath().path
            guard expanded.hasPrefix(home.path + "/"), FileManager.default.fileExists(atPath: expanded) else {
                return Self.text("\(path) isn’t a file or folder in the home folder.", isError: true)
            }
            _ = await Shell.run(["open", "-R", expanded], in: home)
            return Self.text("Showing \(expanded) in Finder.")
        case .frontmostApp:
            guard let front = Hands.frontmost() else { return Self.text("Couldn’t tell which app is in front.", isError: true) }
            return Self.text([front.name, front.windowTitle.map { "window “\($0)”" }].compactMap { $0 }.joined(separator: ", "))
        case .screenshot:
            let file = FileManager.default.temporaryDirectory.appending(path: "dante-hands-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: file) }
            let result = await Shell.run(["screencapture", "-x", "-m", "-t", "png", file.path], in: home)
            guard result.status == 0, let data = try? Data(contentsOf: file), let image = try? Looker.prepare(data) else {
                return Self.text("Couldn’t take a screenshot. Dante may need Screen Recording permission (System Settings › Privacy & Security); ask the user.", isError: true)
            }
            let size = Hands.screenSize
            return ["content": [
                ["type": "image", "data": .string(image), "mimeType": "image/jpeg"],
                ["type": "text", "text": .string("The main screen is \(Int(size.width))×\(Int(size.height)) points; scale the picture's coordinates to that for click.")],
            ], "isError": false]
        case .typeText, .pressKeys, .click:
            guard Hands.canControl else { return Self.text(Hands.needsAccessibility, isError: true) }
            if tool == .click {
                guard let x = arguments["x"]?.double, let y = arguments["y"]?.double else { return Self.text("click needs x and y.", isError: true) }
                let point = CGPoint(x: x, y: y)
                if let refusal = Hands.refusal(bundleID: Hands.owner(at: point)?.bundleID, name: Hands.owner(at: point)?.name) {
                    return Self.text(refusal, isError: true)
                }
                Hands.click(at: point, double: arguments["double"]?.bool ?? false)
                return Self.text("Clicked at \(Int(x)), \(Int(y)) in \(Hands.owner(at: point)?.name ?? "the screen").")
            }
            let front = Hands.frontmost()
            if let refusal = Hands.refusal(bundleID: front?.bundleID, name: front?.name) { return Self.text(refusal, isError: true) }
            if tool == .pressKeys {
                guard let keys = arguments["keys"]?.string, let combo = Hands.KeyCombo.parse(keys) else {
                    return Self.text("press_keys takes modifiers and one key joined with +, like cmd+s or return.", isError: true)
                }
                Hands.press(combo)
                return Self.text("Pressed \(keys) in \(front?.name ?? "the frontmost app").")
            }
            guard let text = arguments["text"]?.string, !text.isEmpty else { return Self.text("type_text needs text.", isError: true) }
            guard text.count <= 2000 else { return Self.text("That’s more than 2,000 characters; type it in parts.", isError: true) }
            let finished = await Hands.type(text, flag: stopFlag)
            return finished ? Self.text("Typed \(text.count) characters into \(front?.name ?? "the frontmost app").")
                : Self.text(Hands.stoppedMessage, isError: true)
        }
    }

    static func expand(_ path: String, home: URL) -> String {
        path == "~" ? home.path : path.hasPrefix("~/") ? home.path + path.dropFirst(1) : path
    }

    /// Files that run when opened: Hands open documents, never scripts or apps (those go
    /// through Bash, where the person sees the command).
    static let runnable: Set<String> = ["command", "sh", "zsh", "bash", "tool", "app", "py", "rb", "pl", "terminal", "workflow",
                                        "scpt", "scptd", "applescript", "action", "pkg", "mpkg", "dmg", "jar", "webloc", "inetloc", "fileloc"]

    static func documentRefusal(_ path: String) -> String? {
        let resolved = URL(filePath: path).resolvingSymlinksInPath()
        let ext = resolved.pathExtension.lowercased()
        let executable = FileManager.default.isExecutableFile(atPath: resolved.path) && !FileManager.default.fileExists(atPath: resolved.path + "/", isDirectory: nil)
        guard runnable.contains(ext) || runnable.contains((path as NSString).pathExtension.lowercased()) || (executable && ext.isEmpty) else { return nil }
        return "Hands open documents, not scripts or apps (\((path as NSString).lastPathComponent)). Run commands with Bash instead, where the person sees them."
    }

    /// Opening a terminal or settings is allowed by name only if it isn't one Hands keep out of.
    /// A path or bundle id counts by the app it names.
    static func appRefusal(_ app: String) -> String? {
        let named = app.hasPrefix("/") || app.hasPrefix("~") ? ((app as NSString).lastPathComponent) : app
        let lowered = named.lowercased()
        let bundleRefused = ["com.apple.terminal", "com.googlecode.iterm2", "dev.warp", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
                             "org.alacritty", "co.zeit.hyper", "com.github.wez.wezterm", "com.apple.systempreferences", "com.apple.keychainaccess",
                             "com.apple.passwords", "com.1password", "dev.dante.ide", "com.apple.scripteditor2", "com.apple.automator", "org.python.pythonlauncher"]
        if bundleRefused.contains(where: { lowered.hasPrefix($0) }) {
            return "Hands don’t open \(app). Use Bash for commands, and ask the user to change settings or passwords themselves."
        }
        let name = lowered.replacingOccurrences(of: ".app", with: "")
        if ["script editor", "automator", "python launcher", "shortcuts", "launchpad"].contains(name) {
            return "Hands don’t open \(app): it runs scripts."
        }
        let refused = ["terminal", "iterm", "iterm2", "warp", "ghostty", "kitty", "alacritty", "hyper", "wezterm",
                       "system settings", "system preferences", "keychain access", "passwords", "1password", "dante"]
        guard refused.contains(name) else { return nil }
        return "Hands don’t open \(app). Use Bash for commands, and ask the user to change settings or passwords themselves."
    }
}
