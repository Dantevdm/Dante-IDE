import Foundation

/// One security problem: what, where, why it matters and how to fix it.
public struct SecurityFinding: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Severity: String, Codable, CaseIterable, Comparable, Sendable {
        case critical, high, medium, low, info

        public var title: String { rawValue.capitalized }

        /// How much one finding costs the project's score.
        public var weight: Int {
            switch self {
            case .critical: 40
            case .high: 15
            case .medium: 5
            case .low: 1
            case .info: 0
            }
        }

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            allCases.firstIndex(of: lhs)! > allCases.firstIndex(of: rhs)!
        }

        /// One step milder, for findings in tests and examples.
        public var milder: Severity {
            switch self {
            case .critical: .high
            case .high: .medium
            case .medium: .low
            case .low, .info: .info
            }
        }
    }

    public enum Category: String, Codable, CaseIterable, Sendable {
        case secrets, privacy, encryption, code, dependencies, containers, pipelines, infrastructure, repository, audit

        public var title: String {
            switch self {
            case .secrets: "Secrets"
            case .privacy: "Personal information"
            case .encryption: "Encryption"
            case .code: "Injection and code"
            case .dependencies: "Dependencies"
            case .containers: "Containers"
            case .pipelines: "CI pipelines"
            case .infrastructure: "Infrastructure"
            case .repository: "Repository"
            case .audit: "Agent audit"
            }
        }

        public var symbol: String {
            switch self {
            case .secrets: "key"
            case .privacy: "person.text.rectangle"
            case .encryption: "lock"
            case .code: "chevron.left.forwardslash.chevron.right"
            case .dependencies: "shippingbox"
            case .containers: "cube"
            case .pipelines: "arrow.triangle.branch"
            case .infrastructure: "server.rack"
            case .repository: "folder"
            case .audit: "sparkle.magnifyingglass"
            }
        }
    }

    /// Stable across edits that move the line: the rule, the file and the line's text, with
    /// "#2", "#3" for the same text again further down the file.
    public var id: String
    public var rule: String
    public var category: Category
    public var severity: Severity
    public var title: String
    /// Why it matters, in a sentence or two.
    public var why: String
    /// How to fix it.
    public var fix: String
    /// The project-relative file, empty for a project-wide finding.
    public var file: String
    /// 1-based; 0 when the finding is about the whole file.
    public var line: Int
    /// The line, with any secret in it masked.
    public var evidence: String
    /// "CWE-89" and the like.
    public var reference: String?
    /// Which scanner found it: "Dante", "Semgrep", "OSV", "Claude".
    public var source: String

    public init(id: String? = nil, rule: String, category: Category, severity: Severity, title: String, why: String, fix: String,
                file: String, line: Int, evidence: String = "", reference: String? = nil, source: String = "Dante") {
        self.rule = rule
        self.category = category
        self.severity = severity
        self.title = title
        self.why = why
        self.fix = fix
        self.file = file
        self.line = line
        self.evidence = evidence
        self.reference = reference
        self.source = source
        self.id = id ?? Self.id(rule: rule, file: file, text: evidence)
    }

    public static func id(rule: String, file: String, text: String) -> String {
        "\(rule):\(file):\(String(fnv(text.trimmingCharacters(in: .whitespaces)), radix: 16))"
    }

    /// The id without its repeat number: every line with the same text shares it.
    public var lineID: String {
        guard let hash = id.lastIndex(of: "#"), id[id.index(after: hash)...].allSatisfy(\.isNumber) else { return id }
        return String(id[..<hash])
    }

    /// FNV-1a, so ids stay the same from run to run (Swift's `hashValue` doesn't).
    static func fnv(_ text: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }

    /// "src/db.ts:42", or the file alone.
    public var location: String { line > 0 ? "\(file):\(line)" : file }
}

/// Masks secrets in text that's shown or stored: the first four characters stay.
public enum Redact {
    public static func mask(_ value: String) -> String {
        guard value.count > 6 else { return String(repeating: "•", count: value.count) }
        return String(value.prefix(4)) + String(repeating: "•", count: min(value.count - 4, 12))
    }

    /// The line with the given range masked, trimmed and kept short.
    public static func line(_ text: String, masking range: Range<String.Index>? = nil, limit: Int = 200) -> String {
        var line = text
        if let range { line.replaceSubrange(range, with: mask(String(text[range]))) }
        line = line.trimmingCharacters(in: .whitespaces)
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}
