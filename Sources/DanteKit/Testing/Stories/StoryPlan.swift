import Foundation

/// What a web app's stories should be, read from the project like the Map: each screen, the
/// calls it makes, what's on it (forms, buttons, links to other screens), and how people get
/// in. Each idea comes with the scenarios worth simulating. Pure.
public struct StoryIdea: Equatable, Sendable, Identifiable {
    public var title: String
    /// Suggested file name in the stories folder.
    public var file: String
    /// What a person does there, in a sentence.
    public var summary: String
    /// Screen names, in the order a person passes them.
    public var screens: [String]
    /// Screen files, for the agent to read.
    public var sources: [String]
    /// "GET /api/orders"
    public var calls: [String]
    /// Button and link labels seen in the screen's code.
    public var controls: [String]
    public var scenarios: [StoryScenario.Kind]
    public var id: String { file }
}

/// One screen as read from its code.
public struct ScreenSketch: Equatable, Sendable {
    public var name: String
    public var file: String
    public var hasForm: Bool
    public var buttons: [String]
    /// Paths it links or navigates to.
    public var links: [String]
    public var calls: [String]
}

public enum StoryPlan {
    /// The web apps in the map (not mobile or command-line clients).
    public static func webApps(_ map: SystemMap) -> [SystemMap.Part] {
        map.parts.filter { $0.lane == .clients && $0.kind == .web && $0.id.hasPrefix("client:") }
    }

    /// Reads what a screen's file holds.
    public static func sketch(name: String, file: String, text: String, calls: [String]) -> ScreenSketch {
        let hasForm = text.contains("<form") || text.contains("onSubmit") || text.contains("@submit") || text.contains("(ngSubmit)")
            || text.contains("<input") || text.contains("<Input") || text.contains("<textarea")
        var buttons: [String] = []
        for match in text.matches(of: /<(?:button|Button)\b[^>]*>\s*([^<>{}\n]{2,40}?)\s*</) {
            let label = String(match.1).trimmingCharacters(in: .whitespaces)
            if !label.isEmpty, !buttons.contains(label) { buttons.append(label) }
        }
        var links: [String] = []
        for match in text.matches(of: /(?:to|href|navigate\(|push\(|routerLink)\s*=?\s*\{?\s*["'`](\/[\w\-\/:.]*)["'`]/) {
            let path = String(match.1)
            if !links.contains(path), !path.hasPrefix("/api") { links.append(path) }
        }
        return ScreenSketch(name: name, file: file, hasForm: hasForm, buttons: Array(buttons.prefix(8)), links: Array(links.prefix(10)), calls: calls)
    }

    /// Ideas for a web app: signing in when the app asks for it, a journey through the screens
    /// a person passes on the way to the main thing, then one per screen that does something.
    /// `written` holds features already told, which are left out.
    public static func ideas(app: SystemMap.Part, map: SystemMap, access: AccessGuide?, read: (String) -> String?, written: [String] = []) -> [StoryIdea] {
        let screens: [ScreenSketch] = app.items.compactMap { item in
            guard let file = item.file else { return nil }
            let part = map.part("screen:\(app.id):\(item.text)")
            let calls = part.map { map.uses($0.id).flatMap { group in group.items.map(\.text) } } ?? []
            return sketch(name: item.text, file: file, text: read(file) ?? "", calls: Array(calls.prefix(12)))
        }
        var ideas: [StoryIdea] = []
        let signsIn = access.map { !$0.signIn.isEmpty && !$0.signIn.contains(.none) && $0.signIn != [.apiKey] } ?? false
        let signInScreen = screens.first { screen in
            let name = screen.name.lowercased().replacingOccurrences(of: "_", with: "-")
            return ["login", "signin", "sign-in", "auth"].contains { name.contains($0) }
        }
        if signsIn || signInScreen != nil {
            ideas.append(StoryIdea(title: "Signing in", file: "sign-in.story.ts",
                                   summary: "A person signs in, and someone who isn’t signed in is kept out.",
                                   screens: [signInScreen?.name ?? "sign in"], sources: signInScreen.map { [$0.file] } ?? [],
                                   calls: signInScreen?.calls ?? [], controls: signInScreen?.buttons ?? [], scenarios: [.happy, .invalid, .access]))
        }
        // The longest chain of links from the home screen: the main journey.
        let journey = path(from: screens.first { ["home", "index", "dashboard", "landing"].contains($0.name.lowercased()) } ?? screens.first, in: screens)
        if journey.count >= 3 {
            ideas.append(StoryIdea(title: "The main journey", file: "journey.story.ts",
                                   summary: "A person goes from \(journey.first!.name) to \(journey.last!.name) the way most would: " + journey.map(\.name).joined(separator: " → ") + ".",
                                   screens: journey.map(\.name), sources: journey.map(\.file), calls: Array(journey.flatMap(\.calls).prefix(12)),
                                   controls: Array(journey.flatMap(\.buttons).prefix(10)), scenarios: [.happy, .mobile]))
        }
        for screen in screens where screen.name != signInScreen?.name {
            let reads = screen.calls.filter { $0.hasPrefix("GET ") }
            let writes = screen.calls.filter { !$0.hasPrefix("GET ") }
            guard screen.hasForm || !screen.calls.isEmpty || !screen.buttons.isEmpty else { continue }
            var kinds: [StoryScenario.Kind] = [.happy]
            if !reads.isEmpty { kinds.append(.empty) }
            if screen.hasForm || !writes.isEmpty { kinds.append(.invalid) }
            if !screen.calls.isEmpty { kinds += [.error, .slow] }
            let title = humanised(screen.name)
            let does: String = if !writes.isEmpty, screen.hasForm { "fills in and sends the form" }
                else if !writes.isEmpty { "acts on what’s shown" + (screen.buttons.first.map { " (\($0))" } ?? "") }
                else if !reads.isEmpty { "looks through what’s listed" }
                else { "uses the screen" }
            ideas.append(StoryIdea(title: title, file: slug(screen.name) + ".story.ts", summary: "A person opens \(title) and \(does).",
                                   screens: [screen.name], sources: [screen.file], calls: screen.calls, controls: screen.buttons, scenarios: kinds))
        }
        let told = Set(written.map { $0.lowercased() })
        return ideas.filter { !told.contains($0.title.lowercased()) && !told.contains($0.file.lowercased()) }
    }

    /// Screens linked from `start`, following the first unvisited link each time.
    static func path(from start: ScreenSketch?, in screens: [ScreenSketch]) -> [ScreenSketch] {
        guard var current = start else { return [] }
        var chain = [current]
        while chain.count < 6 {
            let next = current.links.lazy.compactMap { link in screens.first { screen in
                !chain.contains(screen) && matches(link: link, screen: screen.name)
            } }.first
            guard let next else { break }
            chain.append(next)
            current = next
        }
        return chain
    }

    /// "/orders/42" reaches the screen "orders/:id"; "/cart" reaches "cart" or "Cart".
    static func matches(link: String, screen: String) -> Bool {
        let theirs = link.lowercased().split(separator: "/")
        let mine = screen.lowercased().split(separator: "/")
        guard !mine.isEmpty, theirs.count == mine.count else { return false }
        return zip(mine, theirs).allSatisfy { $0.hasPrefix(":") || $0 == $1 }
    }

    /// "orders/:id" → "Order details"; "checkout" → "Checkout"; "ProductList" → "Product list".
    public static func humanised(_ name: String) -> String {
        let parts = name.split(separator: "/").map(String.init)
        var base = parts.first { !$0.hasPrefix(":") } ?? name
        if parts.count > 1, parts.last?.hasPrefix(":") == true {
            base = (base.hasSuffix("s") ? String(base.dropLast()) : base) + " details"
        }
        var spaced = ""
        for (index, char) in base.enumerated() {
            if char.isUppercase, index > 0 { spaced += " " }
            spaced.append(char == "-" || char == "_" ? " " : char)
        }
        let lower = spaced.lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }

    static func slug(_ name: String) -> String {
        let words = humanised(name).lowercased().split { !$0.isLetter && !$0.isNumber }
        return words.isEmpty ? "screen" : words.joined(separator: "-")
    }

    /// The agent's brief for writing (or adding) stories: what Dante understood of the app,
    /// the kit's API and the rules a story keeps.
    public static func brief(ideas: [StoryIdea], app: String, folder: String, baseURL: String, access: AccessGuide?,
                             existing: [String], map: SystemMap?, runCommand: String) -> String {
        var lines: [String] = []
        lines.append("""
        Write front-end stories for \(app): Playwright tests that tell, step by step and in plain words, how a person uses each \
        feature, and that double as the app's end-to-end tests. Dante runs them, shows each step's picture as a storyboard, and \
        explains why one broke.
        """)
        lines.append("""
        How stories are written (the kit is already in \(folder)/):
        - One file per feature: \(folder)/<feature>.story.ts. Import `{ test, expect }` from './dante-story'.
        - One `test.describe('<Feature>', { annotation: { type: 'story', description: '<what a person does here, one sentence>' } }, …)` per file.
        - One `test(...)` per scenario, tagged with its kind: `test('Ana pays for her mugs', { tag: '@happy' }, async ({ page, story }) => { … })`. \
        Kinds: @happy (the usual way), @empty (nothing there yet: `story.fakeApi('**/api/orders', [])`), @invalid (wrong or missing input, \
        and the screen says what's wrong), @error (the server fails: `story.failApi('**/api/orders', 500)`, and the screen copes), @slow \
        (`story.slowApi('**/api/**', 3000)`: it shows it's busy and gets there), @mobile (`test.use({ viewport: { width: 390, height: 844 }, \
        isMobile: true, hasTouch: true })` in a describe of its own; Chromium only), @access (signed out, or without the right).
        - Every action goes in `await story.step('<a person does something>', async () => { … })`, named like a storyboard caption \
        ("Ana opens her cart", "She sees two mugs at R150"). Each step is photographed when it ends.
        - Find things the way a person does: getByRole, getByLabel, getByText, getByPlaceholder. No CSS classes or test ids unless \
        nothing else works. Assert what a person would see (headings, totals, messages), not internals.
        - Use made-up people and data (Ana, Sam, Lee; shop items) and only this local app at \(baseURL). Leave the base URL to the \
        config: `page.goto('/cart')`.
        """)
        if let access {
            var text = "Getting in: " + (access.summary ?? access.signIn.map(\.title).joined(separator: ", ")) + "."
            if let header = access.header { text += " Requests carry \(header)." }
            let steps = access.steps.map { $0.title + ($0.run.map { " (\($0))" } ?? "") }
            if !steps.isEmpty { text += " First steps: " + steps.joined(separator: "; ") + "." }
            text += " Take passwords and keys from environment variables (process.env.STORY_USER, STORY_PASSWORD…), never write them in a story."
            lines.append(text)
        }
        if let map {
            let groups = map.parts.filter { $0.lane == .api }.map { "\($0.name) (\($0.items.prefix(6).map(\.text).joined(separator: ", ")))" }
            let data = map.parts.filter { $0.lane == .data }.map(\.name)
            var text = "What Dante understood of the system:"
            if !groups.isEmpty { text += "\n- API: " + groups.prefix(12).joined(separator: "; ") }
            if !data.isEmpty { text += "\n- Data: " + data.prefix(8).joined(separator: ", ") }
            lines.append(text)
        }
        if !ideas.isEmpty {
            lines.append("The stories to write:\n" + ideas.map { idea in
                var text = "- \(idea.title) (\(folder)/\(idea.file)): \(idea.summary) Scenarios: " + idea.scenarios.map { "@" + $0.rawValue }.joined(separator: ", ") + "."
                if !idea.sources.isEmpty { text += " Read \(idea.sources.joined(separator: ", "))." }
                if !idea.calls.isEmpty { text += " It calls \(idea.calls.prefix(8).joined(separator: ", "))." }
                if !idea.controls.isEmpty { text += " On screen: \(idea.controls.prefix(6).map { "“\($0)”" }.joined(separator: ", "))." }
                return text
            }.joined(separator: "\n"))
        }
        if !existing.isEmpty { lines.append("Already told (leave them as they are unless they're wrong): " + existing.joined(separator: ", ") + ".") }
        lines.append("""
        First look at the running app (browser_open \(baseURL)) so the stories match what's really on screen, then read the screens' \
        code. Run the stories with: \(runCommand)
        Make the @happy scenarios pass. When a scenario fails because the app is wrong (a crash, a missing message, a broken \
        empty state), don't change the app's code: leave that scenario as it should be, and say in your reply which ones fail and why.
        """)
        return lines.joined(separator: "\n\n")
    }
}
