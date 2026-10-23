import AppKit
import ApplicationServices
import Foundation
import Synchronization

/// Reads the frontmost window through Accessibility, the way VoiceOver does: its text and its
/// controls, numbered, so the agent can press one or choose a menu item by name instead of
/// guessing coordinates from a screenshot. Password fields are never read.
public enum WindowReader {
    /// One element of the window, as much as the agent needs.
    public struct Node: Equatable, Sendable {
        public var role: String
        public var title: String
        public var value: String
        public var help: String
        public var enabled: Bool
        /// It answers AXPress (buttons, links, checkboxes, menu buttons, tabs…).
        public var pressable: Bool
        public var children: [Node]

        public init(role: String, title: String = "", value: String = "", help: String = "", enabled: Bool = true,
                    pressable: Bool = false, children: [Node] = []) {
            self.role = role
            self.title = title
            self.value = value
            self.help = help
            self.enabled = enabled
            self.pressable = pressable
            self.children = children
        }
    }

    /// The window as text: headings and static text as they read, each control numbered with
    /// its kind (`[3] button “Send”`). `controls` lists the numbered nodes' paths in order, so
    /// a press finds the same element again.
    public struct Rendered: Equatable, Sendable {
        public var text: String
        public var controls: [[Int]]
    }

    static let controlRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXLink", "AXTab", "AXTextField",
        "AXTextArea", "AXComboBox", "AXSearchField", "AXDisclosureTriangle", "AXSlider", "AXIncrementor", "AXCell", "AXRow",
    ]

    /// Containers that only add depth.
    static let quietRoles: Set<String> = ["AXGroup", "AXSplitGroup", "AXScrollArea", "AXLayoutArea", "AXUnknown", "AXSplitter"]

    static let kinds: [String: String] = [
        "AXButton": "button", "AXCheckBox": "checkbox", "AXRadioButton": "option", "AXPopUpButton": "pop-up", "AXMenuButton": "menu",
        "AXLink": "link", "AXTab": "tab", "AXTextField": "field", "AXTextArea": "text area", "AXComboBox": "combo box",
        "AXSearchField": "search field", "AXDisclosureTriangle": "disclosure", "AXSlider": "slider", "AXIncrementor": "stepper",
        "AXCell": "cell", "AXRow": "row", "AXHeading": "heading", "AXImage": "image", "AXTable": "table", "AXOutline": "list", "AXList": "list",
        "AXWebArea": "page", "AXToolbar": "toolbar", "AXTabGroup": "tabs", "AXSheet": "sheet", "AXWindow": "window",
    ]

    public static func render(_ root: Node, limit: Int = 12_000) -> Rendered {
        var lines: [String] = []
        var controls: [[Int]] = []
        var used = 0
        var seen = Set<String>()

        func clean(_ text: String) -> String {
            let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            return flat.count > 300 ? String(flat.prefix(297)) + "…" : flat
        }

        func walk(_ node: Node, path: [Int], depth: Int) {
            guard used < limit else { return }
            let label = clean(node.title.isEmpty ? node.help : node.title)
            let value = node.role == "AXSecureTextField" ? "" : clean(node.value)
            let isControl = node.pressable || controlRoles.contains(node.role) || node.role == "AXSecureTextField"
            var line: String?
            let indent = String(repeating: "  ", count: min(depth, 8))
            if isControl {
                controls.append(path)
                let kind = node.role == "AXSecureTextField" ? "password field" : (kinds[node.role] ?? "control")
                var parts = ["[\(controls.count)] \(kind)"]
                if !label.isEmpty { parts.append("“\(label)”") }
                if !value.isEmpty, value != label { parts.append(node.role == "AXCheckBox" || node.role == "AXRadioButton" ? (value == "1" ? "on" : "off") : "= \(value)") }
                if !node.enabled { parts.append("(dimmed)") }
                line = parts.joined(separator: " ")
            } else if node.role == "AXStaticText" || node.role == "AXHeading" {
                let text = value.isEmpty ? label : value
                // Lists repeat the same caption in every row; say it once.
                if !text.isEmpty, seen.insert(text).inserted || text.count > 40 {
                    line = node.role == "AXHeading" ? "# \(text)" : text
                }
            } else if !quietRoles.contains(node.role), let kind = kinds[node.role], !label.isEmpty {
                line = "\(kind): \(label)"
            }
            var childDepth = depth
            if let line {
                lines.append(indent + line)
                used += line.count + indent.count + 1
                childDepth += 1
            }
            for (index, child) in node.children.enumerated() { walk(child, path: path + [index], depth: childDepth) }
        }

        walk(root, path: [], depth: 0)
        var text = lines.joined(separator: "\n")
        if used >= limit { text += "\n… (the window has more; scroll or narrow it down)" }
        return Rendered(text: text, controls: controls)
    }

    // MARK: Menus

    /// "File > New > Message", "Format › Font › Bold", "Edit/Copy".
    public static func menuPath(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ">›/→"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The menu item matching `wanted`: exactly (ignoring case and a trailing "…"), else the
    /// only one starting with it.
    public static func match(_ titles: [String], _ wanted: String) -> Int? {
        func key(_ text: String) -> String {
            text.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "").trimmingCharacters(in: .whitespaces)
        }
        let target = key(wanted)
        if let exact = titles.firstIndex(where: { key($0) == target }) { return exact }
        let starts = titles.indices.filter { key(titles[$0]).hasPrefix(target) }
        return starts.count == 1 ? starts[0] : nil
    }

    // MARK: Live (the `dante mcp` process; needs Accessibility)

    /// An element kept between read_window and press_control.
    struct Element: @unchecked Sendable {
        let element: AXUIElement
    }

    /// The last read window's controls, by number, and the app they belong to.
    static let lastRead = Mutex<(pid: pid_t, controls: [Element])>((0, []))

    /// Reads the frontmost app's focused window and remembers its controls for `press`.
    public static func read() -> (app: Hands.Frontmost, rendered: Rendered)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 2)
        guard let window = attribute(root, kAXFocusedWindowAttribute) as AXUIElement? ?? (attribute(root, kAXWindowsAttribute) as [AXUIElement]?)?.first else { return nil }
        var budget = 2_500
        var elements: [[Int]: Element] = [:]
        let tree = snapshot(window, path: [], depth: 0, budget: &budget, elements: &elements)
        let rendered = render(tree)
        lastRead.withLock { $0 = (pid, rendered.controls.compactMap { elements[$0] }) }
        let front = Hands.Frontmost(name: app.localizedName ?? "The app", bundleID: app.bundleIdentifier, windowTitle: tree.title.isEmpty ? nil : tree.title)
        return (front, rendered)
    }

    public enum PressResult: Equatable, Sendable {
        case pressed(String)
        case unknown
        case moved
        case failed
    }

    /// Presses (or focuses, for a field) control `number` from the last read, if that app is
    /// still in front.
    public static func press(_ number: Int) -> PressResult {
        let (pid, controls) = lastRead.withLock { ($0.pid, $0.controls) }
        guard number >= 1, number <= controls.count else { return .unknown }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return .moved }
        let element = controls[number - 1].element
        let role: String = attribute(element, kAXRoleAttribute) ?? ""
        let title: String = attribute(element, kAXTitleAttribute) ?? attribute(element, kAXDescriptionAttribute) ?? ""
        let fields: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"]
        let result = fields.contains(role)
            ? AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            : AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else { return .failed }
        return .pressed(title.isEmpty ? (kinds[role] ?? "control") : "“\(title)”")
    }

    public enum MenuResult: Equatable, Sendable {
        case chosen(String)
        case notFound(missing: String, choices: [String])
        case dimmed(String)
        case failed
    }

    /// Chooses a menu item in the frontmost app by its path from the menu bar.
    public static func choose(_ path: [String], pid: pid_t) -> MenuResult {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        guard var current: AXUIElement = attribute(app, kAXMenuBarAttribute) else { return .failed }
        var chosen: [String] = []
        for (step, wanted) in path.enumerated() {
            var items: [AXUIElement] = attribute(current, kAXChildrenAttribute) ?? []
            // A menu bar item or a submenu item holds its items inside an AXMenu.
            if step > 0, let menu = items.first, (attribute(menu, kAXRoleAttribute) as String?) == "AXMenu" {
                items = attribute(menu, kAXChildrenAttribute) ?? []
            }
            let titles = items.map { (attribute($0, kAXTitleAttribute) as String?) ?? "" }
            guard let index = match(titles, wanted) else {
                return .notFound(missing: wanted, choices: titles.filter { !$0.isEmpty && $0 != "Apple" })
            }
            chosen.append(titles[index])
            current = items[index]
        }
        if (attribute(current, kAXEnabledAttribute) as Bool?) == false { return .dimmed(chosen.joined(separator: " › ")) }
        return AXUIElementPerformAction(current, kAXPressAction as CFString) == .success ? .chosen(chosen.joined(separator: " › ")) : .failed
    }

    static func snapshot(_ element: AXUIElement, path: [Int], depth: Int, budget: inout Int, elements: inout [[Int]: Element]) -> Node {
        budget -= 1
        elements[path] = Element(element: element)
        let role: String = attribute(element, kAXRoleAttribute) ?? ""
        var actions: CFArray?
        AXUIElementCopyActionNames(element, &actions)
        let pressable = ((actions as? [String]) ?? []).contains(kAXPressAction)
        var value = ""
        if role != "AXSecureTextField", let raw: AnyObject = attribute(element, kAXValueAttribute) {
            if let text = raw as? String { value = String(text.prefix(2_000)) } else if let number = raw as? NSNumber { value = number.stringValue }
        }
        var node = Node(role: role, title: attribute(element, kAXTitleAttribute) ?? "", value: value,
                        help: attribute(element, kAXDescriptionAttribute) ?? "", enabled: attribute(element, kAXEnabledAttribute) ?? true,
                        pressable: pressable && !["AXStaticText", "AXImage", "AXWindow", "AXScrollArea", "AXGroup"].contains(role))
        guard depth < 40, budget > 0 else { return node }
        let children: [AXUIElement] = attribute(element, kAXVisibleChildrenAttribute) ?? attribute(element, kAXChildrenAttribute) ?? []
        for (index, child) in children.enumerated() where budget > 0 {
            node.children.append(snapshot(child, path: path + [index], depth: depth + 1, budget: &budget, elements: &elements))
        }
        return node
    }

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }
}
