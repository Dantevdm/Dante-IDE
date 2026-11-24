import Foundation

/// One scenario of a story as it last ran: its steps with their pictures, and what the browser
/// saw (failed calls, page errors, console errors). Built from a Playwright run's results and
/// the record `dante-story.ts` writes for each test.
public struct StoryScenario: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case happy, empty, invalid, error, slow, mobile, access, other

        /// From the test's tags, first match wins.
        static func from(tags: [String]) -> Kind {
            for tag in tags {
                let word = tag.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@"))
                if let kind = Kind(rawValue: word) { return kind }
                switch word {
                case "edge", "validation": return .invalid
                case "failure", "down", "outage": return .error
                case "phone", "small": return .mobile
                case "auth", "signin", "login", "denied": return .access
                case "main", "golden": return .happy
                default: continue
                }
            }
            return .other
        }

        public var title: String {
            switch self {
            case .happy: "Happy path"
            case .empty: "Nothing there yet"
            case .invalid: "Wrong input"
            case .error: "Server trouble"
            case .slow: "Slow network"
            case .mobile: "On a phone"
            case .access: "Signed in or not"
            case .other: "Scenario"
            }
        }
    }

    public struct Step: Codable, Equatable, Sendable, Identifiable {
        public var title: String
        public var passed: Bool
        /// Milliseconds.
        public var ms: Int
        /// The picture taken when it ended (absolute).
        public var shot: String?
        public var url: String?
        public var error: String?
        public var index: Int
        public var id: Int { index }
    }

    /// A call that answered 400 or more, or didn't answer.
    public struct Call: Codable, Equatable, Sendable, Hashable {
        public var method: String
        public var url: String
        /// 0 when it didn't answer.
        public var status: Int
        public var failure: String?
        public var body: String?
        /// The step it happened in (1-based; 0 before the first).
        public var step: Int
        /// Answered by the story itself (failApi, fakeApi), on purpose.
        public var faked: Bool

        /// "/api/orders" from the full URL, without the query.
        public var path: String { URLComponents(string: url)?.path ?? url }
    }

    public struct Line: Codable, Equatable, Sendable, Hashable {
        public var text: String
        public var step: Int
    }

    public var feature: String
    public var title: String
    /// Project path of the story file.
    public var file: String
    public var kind: Kind
    public var status: TestResult.Status
    public var duration: TimeInterval?
    public var steps: [Step]
    public var issues: [TestResult.Issue]
    public var calls: [Call]
    public var pageErrors: [Line]
    public var console: [Line]
    public var video: String?
    public var trace: String?
    /// What the feature is for, from a `story` annotation.
    public var about: String?
    /// "390×844" when not the desktop's size.
    public var viewport: String?
    /// When it ran.
    public var date: Date?

    public var id: String { file + "#" + feature + "/" + title }
    public var failedStep: Step? { steps.first { !$0.passed } ?? (status == .failed ? steps.last : nil) }
}

/// A feature: one describe block (or one file) and its scenarios.
public struct StoryFeature: Equatable, Identifiable, Sendable {
    public var name: String
    public var file: String
    public var about: String?
    public var scenarios: [StoryScenario]
    public var id: String { file + "#" + name }

    public var failed: Int { scenarios.count { $0.status == .failed } }
    public var passed: Int { scenarios.count { $0.status == .passed } }
}

public enum StoryReport {
    /// Scenarios from a run's results: those from story files, with each one's record read
    /// through `read` (an absolute path).
    public static func scenarios(from results: [TestResult], date: Date? = nil, read: (String) -> Data?) -> [StoryScenario] {
        results.filter { $0.suite.hasSuffix(".story.ts") }.map { result in
            let attachments = result.attachments ?? []
            let record = attachments.first { $0.name == StoryKit.recordName }.flatMap { read($0.path) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            var scenario = StoryScenario(feature: featureName(file: result.suite), title: result.name, file: result.suite, kind: .other,
                                         status: result.status, duration: result.duration, steps: [], issues: result.issues, calls: [],
                                         pageErrors: [], console: [], video: attachments.first { $0.kind == .video }?.path,
                                         trace: attachments.first { $0.kind == .trace }?.path, date: date)
            guard let record else { return scenario }
            // titlePath: file, describe blocks…, the test's own title.
            let path = (record["titlePath"] as? [String] ?? []).filter { !$0.isEmpty }
            if path.count >= 3 { scenario.feature = path[1..<(path.count - 1)].joined(separator: " › ") }
            scenario.kind = .from(tags: record["tags"] as? [String] ?? [])
            if scenario.kind == .other { scenario.kind = .from(tags: words(scenario.title)) }
            let annotations = record["annotations"] as? [[String: Any]] ?? []
            scenario.about = annotations.first { ($0["type"] as? String) == "story" }?["description"] as? String
            if let viewport = record["viewport"] as? [String: Any], let width = viewport["width"] as? Int, let height = viewport["height"] as? Int, width < 900 {
                scenario.viewport = "\(width)×\(height)"
            }
            scenario.steps = (record["steps"] as? [[String: Any]] ?? []).enumerated().map { index, step in
                StoryScenario.Step(title: step["title"] as? String ?? "Step \(index + 1)", passed: (step["status"] as? String) != "failed",
                                   ms: number(step["ms"]) ?? 0, shot: step["shot"] as? String, url: step["url"] as? String,
                                   error: (step["error"] as? String).map(TestOutputText.strippingColour), index: index + 1)
            }
            scenario.calls = (record["calls"] as? [[String: Any]] ?? []).compactMap { call in
                guard let url = call["url"] as? String else { return nil }
                return StoryScenario.Call(method: call["method"] as? String ?? "GET", url: url, status: number(call["status"]) ?? 0,
                                          failure: call["failure"] as? String, body: call["body"] as? String, step: number(call["step"]) ?? 0,
                                          faked: call["faked"] as? Bool ?? false)
            }
            func lines(_ key: String) -> [StoryScenario.Line] {
                (record[key] as? [[String: Any]] ?? []).compactMap { line in
                    (line["text"] as? String).map { StoryScenario.Line(text: $0, step: number(line["step"]) ?? 0) }
                }
            }
            scenario.pageErrors = lines("pageErrors")
            scenario.console = lines("console")
            return scenario
        }
    }

    /// Words of a title that might name its kind ("when the server is down" → down).
    static func words(_ title: String) -> [String] {
        title.lowercased().split { !$0.isLetter }.map(String.init)
    }

    static func number(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        return nil
    }

    /// "checkout.story.ts" → "Checkout"; "sign-in.story.ts" → "Sign in".
    public static func featureName(file: String) -> String {
        let stem = (file as NSString).lastPathComponent.replacingOccurrences(of: ".story.ts", with: "")
        let words = stem.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Scenarios grouped into features, in the order their files and blocks came.
    public static func features(_ scenarios: [StoryScenario]) -> [StoryFeature] {
        var order: [String] = []
        var groups: [String: StoryFeature] = [:]
        for scenario in scenarios {
            let key = scenario.file + "#" + scenario.feature
            if groups[key] == nil {
                order.append(key)
                groups[key] = StoryFeature(name: scenario.feature, file: scenario.file, about: scenario.about, scenarios: [])
            }
            groups[key]!.scenarios.append(scenario)
            if groups[key]!.about == nil { groups[key]!.about = scenario.about }
        }
        return order.compactMap { groups[$0] }
    }

    /// The newest of each scenario: a run of some stories replaces only theirs.
    public static func merged(_ old: [StoryScenario], with new: [StoryScenario], files: [String]? = nil) -> [StoryScenario] {
        var out = old
        if let files { out = out.filter { files.contains($0.file) } }
        // New ones take their place, or join at the end of their file's.
        for scenario in new {
            if let index = out.firstIndex(where: { $0.id == scenario.id }) {
                out[index] = scenario
            } else if let index = out.lastIndex(where: { $0.file == scenario.file }) {
                out.insert(scenario, at: index + 1)
            } else {
                out.append(scenario)
            }
        }
        // Files in order, scenarios in the order they came within each.
        let fileOrder = Array(Set(out.map(\.file))).sorted()
        return fileOrder.flatMap { file in out.filter { $0.file == file } }
    }
}
