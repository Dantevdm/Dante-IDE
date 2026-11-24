import Foundation

/// Why a story broke, in a sentence a person can act on: the app wasn't running, a call the
/// step made failed on the server (and which handler serves it), the page threw, the screen no
/// longer has what the story looks for (and what changed since it last passed), or it shows
/// something else. Says whether the app or the story is likely wrong. Pure.
public struct StoryDiagnosis: Equatable, Sendable {
    public enum Cause: String, Equatable, Sendable {
        case appDown, serverError, denied, pageError, missingElement, ambiguous, wrongText, wrongPage, timeout, unknown
    }

    /// Who most likely needs to change.
    public enum Blame: String, Equatable, Sendable {
        case app, story, either, setup

        public var title: String {
            switch self {
            case .app: "The app looks wrong"
            case .story: "The story looks wrong"
            case .either: "The app or the story"
            case .setup: "Nothing to fix in the code"
            }
        }
    }

    public var cause: Cause
    public var blame: Blame
    public var headline: String
    /// Supporting facts, each a sentence.
    public var details: [String]
    /// The step it broke in (1-based).
    public var step: Int?
    /// The failed call behind it.
    public var call: StoryScenario.Call?
    /// The code that serves that call.
    public var handler: (file: String, line: Int)?
    /// Files changed since the story last passed that it likely touches.
    public var changed: [String]
    /// Error lines from the server's log during the run.
    public var serverLines: [String]

    public static func == (a: StoryDiagnosis, b: StoryDiagnosis) -> Bool {
        a.cause == b.cause && a.blame == b.blame && a.headline == b.headline && a.details == b.details && a.step == b.step && a.call == b.call
            && a.handler?.file == b.handler?.file && a.handler?.line == b.handler?.line && a.changed == b.changed && a.serverLines == b.serverLines
    }

    /// - Parameters:
    ///   - routes: the project's routes, to find the handler of a failed call.
    ///   - changed: files changed since the story last passed (nil when it never has).
    ///   - serverLog: the server's log lines from the run.
    public static func explain(_ scenario: StoryScenario, routes: [BliksemRoute] = [], changed: [String]? = nil,
                               serverLog: [String] = []) -> StoryDiagnosis? {
        guard scenario.status == .failed else { return nil }
        let step = scenario.failedStep
        let stepName = step.map { "“\($0.title)”" } ?? "the story"
        let message = ([step?.error] + scenario.issues.map(\.message)).compactMap { $0 }.joined(separator: "\n")
        let server = errorLines(serverLog)
        var diagnosis = StoryDiagnosis(cause: .unknown, blame: .either, headline: "", details: [], step: step?.index, call: nil, handler: nil,
                                       changed: [], serverLines: server)
        let inStep = scenario.calls.filter { !$0.faked && (step == nil || $0.step == step!.index) }

        // The app wasn't there at all.
        if message.contains("ERR_CONNECTION_REFUSED") || message.contains("ECONNREFUSED") || inStep.contains(where: { $0.failure?.contains("ERR_CONNECTION_REFUSED") == true }) {
            diagnosis.cause = .appDown
            diagnosis.blame = .setup
            diagnosis.headline = "Nothing answered at the app’s address, so the story couldn’t start: the app wasn’t running."
            diagnosis.details = ["Start the web app (and what it calls), then run the story again."]
            return diagnosis
        }

        // A call the step made failed on the server.
        if let call = inStep.last(where: { $0.status >= 500 }) ?? inStep.last(where: { $0.status == 0 && $0.failure?.contains("ABORTED") != true }) {
            diagnosis.cause = .serverError
            diagnosis.blame = .app
            diagnosis.call = call
            let answer = call.status == 0 ? "got no answer (\(call.failure ?? "the connection failed"))" : "answered \(call.status)"
            diagnosis.headline = "\(call.method) \(call.path) \(answer) during \(stepName), so the screen couldn’t go on."
            if let route = route(serving: call, in: routes), let file = route.file, let line = route.line {
                diagnosis.handler = (file, line)
                diagnosis.details.append("It’s served by \((file as NSString).lastPathComponent):\(line).")
            }
            if let body = call.body.map({ Self.short($0) }), !body.isEmpty { diagnosis.details.append("It said: \(body)") }
            if let first = server.first { diagnosis.details.append("The server logged: \(first)") }
            diagnosis.changed = changed ?? []
            return diagnosis
        }

        // The page itself threw.
        if let error = scenario.pageErrors.last(where: { step == nil || $0.step == step!.index }) ?? scenario.pageErrors.last {
            diagnosis.cause = .pageError
            diagnosis.blame = .app
            let first = error.text.split(separator: "\n").first.map(String.init) ?? error.text
            diagnosis.headline = "The page threw \(short(first)) during \(stepName)."
            if let place = sourcePlace(in: error.text) { diagnosis.details.append("It came from \(place).") }
            diagnosis.changed = changed ?? []
            return diagnosis
        }

        // Refused: the story's sign-in or the app's access rules.
        if let call = inStep.last(where: { $0.status == 401 || $0.status == 403 }) {
            diagnosis.cause = .denied
            diagnosis.blame = .either
            diagnosis.call = call
            diagnosis.headline = "\(call.method) \(call.path) was refused (\(call.status)) during \(stepName): the story isn’t signed in as the app expects, or the app’s access rules changed."
            if let route = route(serving: call, in: routes), let file = route.file, let line = route.line { diagnosis.handler = (file, line) }
            diagnosis.changed = changed ?? []
            return diagnosis
        }

        let locator = Self.locator(in: message)
        if message.contains("strict mode violation") {
            diagnosis.cause = .ambiguous
            diagnosis.blame = .story
            let count = message.firstMatch(of: /resolved to (\d+) elements/).map { String($0.1) }
            diagnosis.headline = "In \(stepName) the story looks for \(locator ?? "an element") and finds \(count.map { "\($0) of them" } ?? "several"), so it can’t tell which one a person would use."
            diagnosis.details = ["Narrow it to the one in its section (within a region or row), or by its exact name."]
            return diagnosis
        }
        let visibility = ["toBeVisible", "toBeAttached", "toBeEnabled", "toBeChecked", "toBeInViewport"].contains { message.contains($0) }
        if !visibility, let expectation = expectation(in: message) {
            if message.contains("toHaveURL") {
                diagnosis.cause = .wrongPage
                diagnosis.headline = "After \(stepName) the app was on \(expectation.received ?? "another page"), not \(expectation.expected ?? "the page the story expects")."
            } else {
                diagnosis.cause = .wrongText
                diagnosis.headline = "In \(stepName) the screen showed \(expectation.received.map { "“\(short($0))”" } ?? "something else") where the story expects \(expectation.expected.map { "“\(short($0))”" } ?? "other text")."
            }
            diagnosis.blame = changedScreen(changed) ? .either : .app
        } else if let locator, visibility || message.contains("Timeout") || message.contains("waiting for") || message.contains("not found") || message.contains("to be visible") {
            diagnosis.cause = .missingElement
            diagnosis.headline = "In \(stepName) the screen never showed \(locator)."
            diagnosis.blame = changedScreen(changed) ? .either : .app
        } else if message.contains("Test timeout of") || message.contains("Timeout") {
            diagnosis.cause = .timeout
            diagnosis.headline = "\(step.map { "“\($0.title)”" } ?? "The story") took too long and was stopped."
            diagnosis.blame = .either
        } else {
            let first = message.split(separator: "\n").first.map(String.init) ?? "It failed"
            diagnosis.headline = "It broke in \(stepName): \(short(first))"
        }

        // What else the browser saw in that step.
        if let call = inStep.last(where: { $0.status >= 400 && $0.status != 404 }) {
            diagnosis.call = call
            diagnosis.details.append("\(call.method) \(call.path) answered \(call.status) in that step.")
            if let route = route(serving: call, in: routes), let file = route.file, let line = route.line { diagnosis.handler = (file, line) }
        }
        if let error = scenario.console.last(where: { $0.step == step?.index && $0.text.lowercased().contains("error") }) {
            diagnosis.details.append("The console said: \(short(error.text))")
        }
        if let changed {
            diagnosis.changed = changed
            if !changed.isEmpty, diagnosis.cause == .missingElement || diagnosis.cause == .wrongText || diagnosis.cause == .wrongPage {
                diagnosis.details.append("The screen’s code changed since the story last passed: if that was on purpose, the story needs to follow; if not, the change broke it.")
            }
        } else if diagnosis.cause == .missingElement || diagnosis.cause == .wrongText {
            diagnosis.details.append("It hasn’t passed before, so the story may never have matched the screen.")
            diagnosis.blame = .story
        }
        if let first = server.first { diagnosis.details.append("The server logged: \(first)") }
        return diagnosis
    }

    static func changedScreen(_ changed: [String]?) -> Bool { !(changed ?? []).isEmpty }

    /// The route a call reached: its path as written, or without leading api/version parts on
    /// either side (a dev server's proxy often adds or strips /api).
    public static func route(serving call: StoryScenario.Call, in routes: [BliksemRoute]) -> BliksemRoute? {
        let path = call.path
        if let exact = routes.first(where: { $0.file != nil && $0.serves(method: call.method, path: path) }) { return exact }
        let core = coreParts(path)
        return routes.first { route in
            guard route.file != nil, route.method == call.method.uppercased() else { return false }
            let theirs = coreParts(route.path)
            return theirs.count == core.count && zip(theirs, core).allSatisfy { BliksemRoute.parameter($0) != nil || $0 == $1 }
        }
    }

    static func coreParts(_ path: String) -> [Substring] {
        var parts = path.split(separator: "/")
        while let first = parts.first, first == "api" || first.firstMatch(of: /^v\d+$/) != nil { parts.removeFirst() }
        return parts
    }

    /// `getByRole('button', { name: 'Pay' })` from Playwright's message.
    static func locator(in message: String) -> String? {
        if let match = message.firstMatch(of: /(getBy\w+\((?:[^()]|\([^()]*\))*\)(?:\.\w+\([^()]*\))*)/) { return String(match.1) }
        if let match = message.firstMatch(of: /(locator\('[^']*'\)|locator\("[^"]*"\))/) { return String(match.1) }
        return nil
    }

    /// Expected and received from an assertion's message.
    static func expectation(in message: String) -> (expected: String?, received: String?)? {
        let expected = message.firstMatch(of: /(?m)^\s*Expected(?: string| pattern| substring)?:\s*(.+)$/).map { clean(String($0.1)) }
        let received = message.firstMatch(of: /(?m)^\s*Received(?: string)?:\s*(.+)$/).map { clean(String($0.1)) }
        guard expected != nil || received != nil else { return nil }
        return (expected, received)
    }

    static func clean(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, text.first == "\"", text.last == "\"" { text = String(text.dropFirst().dropLast()) }
        return text
    }

    /// "Checkout.tsx:42" from a browser stack trace.
    static func sourcePlace(in stack: String) -> String? {
        for line in stack.split(separator: "\n").dropFirst() {
            guard !line.contains("node_modules"), !line.contains("/@vite/"), !line.contains("chunk-"),
                  let match = line.firstMatch(of: /\/([\w.-]+\.(?:tsx?|jsx?|vue|svelte)):(\d+)/) else { continue }
            return "\(match.1):\(match.2)"
        }
        return nil
    }

    /// The server log's lines that name an error, last few, without the compose prefix noise.
    public static func errorLines(_ log: [String], limit: Int = 6) -> [String] {
        let words = ["error", "exception", "panic", "traceback", "fatal", " 500 ", "failed"]
        let found = log.filter { line in
            let lower = line.lowercased()
            return words.contains { lower.contains($0) } && !lower.contains("health")
        }
        return found.suffix(limit).map { short($0, limit: 240) }
    }

    static func short(_ text: String, limit: Int = 160) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    /// The files of a change that a story likely touches: the web app's code, and the handlers
    /// its calls reached.
    public static func relevant(_ changed: [String], frontend: String, handlers: [String]) -> [String] {
        let prefix = frontend.isEmpty || frontend == "." ? "" : frontend + "/"
        let code = ["ts", "tsx", "js", "jsx", "vue", "svelte", "css", "scss", "html"]
        return changed.filter { file in
            if handlers.contains(file) { return true }
            guard prefix.isEmpty || file.hasPrefix(prefix), !file.contains("/stories/"), !file.hasPrefix("stories/") else { return false }
            return code.contains((file as NSString).pathExtension.lowercased())
        }
    }

    /// What to ask the agent in charge: the story, where it broke, why Dante thinks so, and
    /// how to run it again; the agent decides whether the app or the story should change.
    public static func brief(_ scenario: StoryScenario, diagnosis: StoryDiagnosis, rerun: String) -> String {
        var lines = ["A front-end story broke: “\(scenario.feature) › \(scenario.title)” in \(scenario.file)."]
        lines.append("Its steps: " + scenario.steps.map { "\($0.index). \($0.title)\($0.passed ? "" : " (broke here)")" }.joined(separator: "; ") + ".")
        lines.append("Dante’s reading: \(diagnosis.headline) \(diagnosis.details.joined(separator: " "))")
        if let handler = diagnosis.handler { lines.append("The call is served by \(handler.file):\(handler.line).") }
        if !diagnosis.changed.isEmpty { lines.append("Changed since it last passed: \(diagnosis.changed.prefix(12).joined(separator: ", ")).") }
        if !diagnosis.serverLines.isEmpty { lines.append("Server log:\n" + diagnosis.serverLines.joined(separator: "\n")) }
        if let error = scenario.failedStep?.error ?? scenario.issues.first?.message { lines.append("Playwright said:\n" + String(error.prefix(1500))) }
        if let shot = scenario.failedStep?.shot { lines.append("The screen when it broke: \(shot)") }
        lines.append("""
        Decide whether the app or the story is wrong. If the app is wrong, fix the app with the smallest change. If the screen \
        changed on purpose, update the story to match what a person now sees. Never weaken a story just to make it pass (no \
        removed assertions, no longer timeouts to hide slowness). Run it again with: \(rerun)
        """)
        return lines.joined(separator: "\n\n")
    }
}
