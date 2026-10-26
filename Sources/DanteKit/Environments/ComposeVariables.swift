import Foundation

/// The variables a compose file fills in from `.env` and the environment, and which of them
/// would stop it: `${VAR:?message}` with no value is an error before any service starts, and an
/// unset password left blank (`${DB_PASSWORD}`) starts a database that then refuses everyone.
/// `plan` fills them in: a new password for a secret, the example file's value, or a question.
public enum ComposeVariables {
    public struct Reference: Equatable, Sendable {
        public var name: String
        /// `${VAR:?…}` or `${VAR?…}`: compose stops without a value.
        public var required: Bool
        /// `${VAR:-…}` or `${VAR-…}`.
        public var hasDefault: Bool
        /// `:` forms count an empty value as missing too.
        public var emptyIsMissing: Bool

        public init(name: String, required: Bool = false, hasDefault: Bool = false, emptyIsMissing: Bool = false) {
            self.name = name
            self.required = required
            self.hasDefault = hasDefault
            self.emptyIsMissing = emptyIsMissing
        }
    }

    /// One missing value and where its fill comes from.
    public struct Missing: Equatable, Sendable, Identifiable {
        public enum Fill: Equatable, Sendable {
            /// A new random value: passwords, secrets, keys and tokens.
            case generated
            /// The value in `.env.example` (or `.sample`, `.template`, `.dist`).
            case example(String)
            /// Nothing to go on; the person types it.
            case ask
        }

        public var name: String
        /// Compose won't start without it; otherwise it would start blank.
        public var blocks: Bool
        public var fill: Fill
        public var id: String { name }
    }

    nonisolated(unsafe) private static let pattern = try! NSRegularExpression(
        pattern: #"\$\$|\$\{([A-Za-z_][A-Za-z0-9_]*)(?:(:?)([-?+=])[^}]*)?\}|\$([A-Za-z_][A-Za-z0-9_]*)"#)

    /// Every variable the file refers to, once each (a required use wins), in order of first use.
    /// Comment lines are skipped and `$$` is a literal dollar.
    public static func references(in yaml: String) -> [Reference] {
        var order: [String] = []
        var found: [String: Reference] = [:]
        for raw in yaml.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), line.contains("$") else { continue }
            let text = raw as NSString
            for match in pattern.matches(in: raw, range: NSRange(location: 0, length: text.length)) {
                let braced = match.range(at: 1), bare = match.range(at: 4)
                guard braced.location != NSNotFound || bare.location != NSNotFound else { continue }
                let name = text.substring(with: braced.location != NSNotFound ? braced : bare)
                let colon = match.range(at: 2).location != NSNotFound && match.range(at: 2).length > 0
                let op = match.range(at: 3).location != NSNotFound ? text.substring(with: match.range(at: 3)) : ""
                var reference = Reference(name: name, required: op == "?", hasDefault: op == "-" || op == "=" || op == "+", emptyIsMissing: colon)
                if let earlier = found[name] {
                    reference.required = reference.required || earlier.required
                    reference.hasDefault = reference.hasDefault && earlier.hasDefault
                    reference.emptyIsMissing = reference.emptyIsMissing || earlier.emptyIsMissing
                } else {
                    order.append(name)
                }
                found[name] = reference
            }
        }
        return order.compactMap { found[$0] }
    }

    /// Names that hold secrets, so a missing one can be made up rather than asked for.
    public static func isSecret(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["PASSWORD", "PASSWD", "PASS", "SECRET", "TOKEN", "API_KEY", "PRIVATE_KEY", "SIGNING_KEY", "ENCRYPTION_KEY", "SALT"]
            .contains { upper == $0 || upper.hasSuffix("_" + $0) }
            || upper.hasSuffix("PASSWORD") || upper.hasSuffix("SECRET")
    }

    /// The names compose's own error names: "required variable X is missing a value".
    public static func named(inError message: String) -> [String] {
        let regex = try? NSRegularExpression(pattern: #"required variable ([A-Za-z_][A-Za-z0-9_]*) is missing a value"#)
        let text = message as NSString
        var names: [String] = []
        for match in regex?.matches(in: message, range: NSRange(location: 0, length: text.length)) ?? [] {
            let name = text.substring(with: match.range(at: 1))
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// What's missing, given the values from `.env` and the environment compose runs in, and how
    /// each would be filled. `alsoRequired` adds names from compose's error, which may come from
    /// a file this didn't read (an `include:` or an override).
    public static func missing(compose yaml: String, env: [String: String], example: String? = nil, alsoRequired: [String] = []) -> [Missing] {
        let examples = example.map(EnvFile.values) ?? [:]
        var references = references(in: yaml)
        for name in alsoRequired where !references.contains(where: { $0.name == name }) {
            references.append(Reference(name: name, required: true, emptyIsMissing: true))
        }
        return references.compactMap { reference in
            let value = env[reference.name]
            let unset = value == nil || (reference.emptyIsMissing && value?.isEmpty == true)
            let required = reference.required || alsoRequired.contains(reference.name)
            guard unset else { return nil }
            // Unset without a default starts blank: that only matters for a secret.
            guard required || (!reference.hasDefault && isSecret(reference.name)) else { return nil }
            let fill: Missing.Fill
            if isSecret(reference.name) {
                fill = .generated
            } else if let sample = examples[reference.name], !sample.isEmpty, !isPlaceholder(sample) {
                fill = .example(sample)
            } else {
                fill = .ask
            }
            return Missing(name: reference.name, blocks: required, fill: fill)
        }
    }

    static func isPlaceholder(_ value: String) -> Bool {
        let lower = value.lowercased()
        return ["change", "replace", "your", "xxx", "todo", "<", "example", "secret", "password"].contains { lower.contains($0) }
    }

    /// The example env file beside `.env`, when there is one.
    public static let exampleNames = [".env.example", ".env.sample", ".env.template", ".env.dist"]

    /// The lines to write: generated secrets, example values and what the person typed.
    public static func plan(_ missing: [Missing], typed: [String: String], password: () -> String = { NewDatabasePlan.makePassword() }) -> [(key: String, value: String)] {
        missing.compactMap { item in
            switch item.fill {
            case .generated: return (item.name, password())
            case .example(let value): return (item.name, typed[item.name].flatMap { $0.isEmpty ? nil : $0 } ?? value)
            case .ask:
                guard let value = typed[item.name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
                return (item.name, value)
            }
        }
    }

    /// The environment compose interpolates from: the shell's, then the project's `.env`, which
    /// compose reads only when the shell doesn't set the name.
    public static func environment(shell: [String: String], dotEnv: String?) -> [String: String] {
        var values = dotEnv.map(EnvFile.values) ?? [:]
        for (key, value) in shell { values[key] = value }
        return values
    }
}
