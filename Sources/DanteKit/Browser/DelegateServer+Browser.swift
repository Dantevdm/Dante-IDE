import Foundation

/// The agents' own browser as `dante mcp` tools, listed with `DANTE_BROWSER=1`. One browser
/// per server process, made on first use.
@MainActor
public final class BrowserTools {
    public nonisolated static let environment = "DANTE_BROWSER"

    public enum Tool: String, CaseIterable, Sendable {
        case open = "browser_open"
        case read = "browser_read"
        case click = "browser_click"
        case type = "browser_type"
        case back = "browser_back"
        case resize = "browser_resize"
        case screenshot = "browser_screenshot"

        public static func of(mcpName: String) -> Tool? {
            mcpName.hasPrefix("mcp__dante__") ? Tool(rawValue: String(mcpName.dropFirst(12))) : nil
        }

        /// The activity line in the panel.
        public func describe(_ input: JSONValue, done: Bool) -> String {
            switch self {
            case .open: (done ? "Opened " : "Opening ") + (input["url"]?.string ?? "a page") + " in its browser"
            case .read: done ? "Read the page" : "Reading the page"
            case .click: done ? "Clicked on the page" : "Clicking on the page"
            case .type: done ? "Typed on the page" : "Typing on the page"
            case .back: done ? "Went back a page" : "Going back a page"
            case .resize: (done ? "Resized" : "Resizing") + " its browser to \(input["width"]?.int ?? 0) wide"
            case .screenshot: done ? "Took a screenshot of the page" : "Taking a screenshot of the page"
            }
        }
    }

    private let hosts: BrowserHosts
    private let shots: URL
    private var browser: AgentBrowser?

    public nonisolated init(hosts: BrowserHosts, shots: URL) {
        self.hosts = hosts
        self.shots = shots
    }

    func call(_ tool: Tool, arguments: JSONValue) async -> JSONValue {
        let browser = self.browser ?? {
            AgentBrowser.tidy(shots)
            let made = AgentBrowser(hosts: hosts, shots: shots)
            self.browser = made
            return made
        }()
        do {
            switch tool {
            case .open:
                guard let text = arguments["url"]?.string, let url = BrowserHosts.url(from: text) else {
                    return DelegateServer.text("browser_open needs a url, like http://localhost:3000/orders.", isError: true)
                }
                return DelegateServer.text(try await browser.open(url))
            case .read:
                return DelegateServer.text(try await browser.read())
            case .click:
                guard let ref = arguments["ref"]?.int else { return DelegateServer.text("browser_click needs a control's ref number.", isError: true) }
                return DelegateServer.text(try await browser.click(ref))
            case .type:
                guard let ref = arguments["ref"]?.int, let text = arguments["text"]?.string else {
                    return DelegateServer.text("browser_type needs a ref and text.", isError: true)
                }
                return DelegateServer.text(try await browser.type(ref, text: text, submit: arguments["submit"]?.bool ?? false))
            case .back:
                return DelegateServer.text(try await browser.back())
            case .resize:
                return DelegateServer.text(try await browser.resize(width: arguments["width"]?.int ?? 1280, height: arguments["height"]?.int ?? 800))
            case .screenshot:
                let shot = try await browser.screenshot(fullPage: arguments["full_page"]?.bool ?? false)
                return ["content": [
                    ["type": "image", "data": .string(shot.jpeg), "mimeType": "image/jpeg"],
                    ["type": "text", "text": .string("Saved for the person at \(shot.file.path).")],
                ], "isError": false]
            }
        } catch {
            return DelegateServer.text(error.localizedDescription, isError: true)
        }
    }
}

extension DelegateServer {
    static let browserInstructions = "You have a browser of your own (browser_open, browser_read, browser_click, browser_type, browser_back, browser_resize, browser_screenshot) for checking the app you're building as a user would: it runs on this Mac, visits only the app's local addresses (and test hosts the project lists), keeps no cookies or sign-ins, and never touches the person's browser. Start the app first if it isn't running. Read a page to get numbered controls, act on them by number, and look at screenshots when layout matters. Page errors and failed requests come with every read. Use only test accounts and data from the project."

    static let browserTools: [JSONValue] = [
        [
            "name": "browser_open",
            "description": "Open a page of the app in your own browser and read it: its text, numbered controls, page errors and failed requests.",
            "inputSchema": ["type": "object", "properties": [
                "url": ["type": "string", "description": "Like http://localhost:3000/orders, localhost:5173 or just a port (3000)."],
            ], "required": ["url"]],
        ],
        [
            "name": "browser_read",
            "description": "Read the open page again: text, numbered controls (refs change as the page does), page errors and failed requests.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "browser_click",
            "description": "Click a control on the page by its number from the last read, then read the page.",
            "inputSchema": ["type": "object", "properties": [
                "ref": ["type": "integer", "description": "The control's number."],
            ], "required": ["ref"]],
        ],
        [
            "name": "browser_type",
            "description": "Type into a field (or choose an option in a select) by its number, optionally pressing Return to submit, then read the page.",
            "inputSchema": ["type": "object", "properties": [
                "ref": ["type": "integer", "description": "The field's number."],
                "text": ["type": "string", "description": "The text, replacing what's there; for a select, the option's label."],
                "submit": ["type": "boolean", "description": "Press Return afterwards."],
            ], "required": ["ref", "text"]],
        ],
        [
            "name": "browser_back",
            "description": "Go back a page, then read it.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "browser_resize",
            "description": "Change the browser's size, for example 390 wide to check a phone layout (1280×800 to start).",
            "inputSchema": ["type": "object", "properties": [
                "width": ["type": "integer"], "height": ["type": "integer"],
            ], "required": ["width"]],
        ],
        [
            "name": "browser_screenshot",
            "description": "A picture of the page as it looks now; full_page for the whole length. Kept for the person to see.",
            "inputSchema": ["type": "object", "properties": [
                "full_page": ["type": "boolean"],
            ]],
        ],
    ]
}
