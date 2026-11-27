import Foundation

/// A customer's way of working, kept in the company library (`<library>/customers/<id>/`,
/// outside every repo): rules the code must keep, naming standards, processes such as an RFC
/// before an infrastructure change, the infrastructure tool they always use, their theme,
/// the Claude Code skills that know their world and MCP servers of their own. A project picks
/// which customers apply, and which of their parts, on this Mac (`CustomerChoice`); the agents
/// get it in their brief and through `dante mcp`'s customer tools, like a small MCP per customer.
public struct CustomerProfile: Identifiable, Equatable, Sendable {
    public enum Severity: String, Equatable, Sendable, Comparable, CaseIterable {
        case note, issue, blocker
        public static func < (a: Severity, b: Severity) -> Bool { a.order < b.order }
        var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
        init(text: String?) { self = Severity(rawValue: (text ?? "").lowercased()) ?? .issue }
    }

    /// Something the code must or mustn't have.
    public struct Rule: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var detail: String
        public var severity: Severity
        /// Files that mustn't exist ("**/*.tf").
        public var forbid: [String]
        /// At least one file like this must exist.
        public var require: [String]
        /// A line matching this regular expression breaks the rule…
        public var pattern: String?
        /// …in files like these (all text files when empty).
        public var files: [String]

        public init(id: String, title: String, detail: String = "", severity: Severity = .issue, forbid: [String] = [], require: [String] = [],
                    pattern: String? = nil, files: [String] = []) {
            self.id = id
            self.title = title
            self.detail = detail
            self.severity = severity
            self.forbid = forbid
            self.require = require
            self.pattern = pattern
            self.files = files
        }

        /// Whether Dante can check it, or it's only told to the agents.
        public var isCheckable: Bool { !forbid.isEmpty || !require.isEmpty || pattern != nil }
    }

    /// How a kind of name is written.
    public struct Naming: Identifiable, Equatable, Sendable {
        public var id: String
        /// "IAM role name", "Stack export".
        public var what: String
        /// A regular expression the name must match…
        public var pattern: String?
        /// …or a shape: `${AppId}-${StackName}-${Environment}-*`, `*` for any part.
        public var shape: String?
        public var example: String?
        /// Where the names come from: "file" (file names), "logical-id" (CloudFormation
        /// resources), "export" (Outputs' Export names), "tag:<Key>" (a tag's value), or a
        /// CloudFormation property's name ("RoleName"). Nil: told to the agents only.
        public var of: String?
        /// Only resources of this CloudFormation type ("AWS::IAM::Role").
        public var resourceType: String?
        /// Files to look in (CloudFormation templates, or file names for "file").
        public var files: [String]

        public init(id: String, what: String, pattern: String? = nil, shape: String? = nil, example: String? = nil, of: String? = nil,
                    resourceType: String? = nil, files: [String] = []) {
            self.id = id
            self.what = what
            self.pattern = pattern
            self.shape = shape
            self.example = example
            self.of = of
            self.resourceType = resourceType
            self.files = files
        }

        /// The rule as a regular expression: the pattern, or the shape made into one.
        public var regex: String? {
            if let pattern, !pattern.isEmpty { return pattern }
            guard let shape, !shape.isEmpty else { return nil }
            var result = "^"
            for character in shape {
                result += character == "*" ? ".+" : NSRegularExpression.escapedPattern(for: String(character))
            }
            return result + "$"
        }

        public func accepts(_ name: String) -> Bool {
            guard let regex, let expression = try? NSRegularExpression(pattern: regex) else { return true }
            return expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }

        /// How to write it, for people and agents: the shape or pattern and the example.
        public var how: String {
            var text = shape.map { "`\($0)`" } ?? pattern.map { "matching `\($0)`" } ?? ""
            if let example { text += (text.isEmpty ? "" : ", ") + "e.g. `\(example)`" }
            return text
        }
    }

    /// A way of working: when it applies and its steps.
    public struct Process: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var when: String
        public var steps: [String]
        /// Changes to files like these need it; an agent's edit there carries a note.
        public var paths: [String]

        public init(id: String, title: String, when: String = "", steps: [String] = [], paths: [String] = []) {
            self.id = id
            self.title = title
            self.when = when
            self.steps = steps
            self.paths = paths
        }
    }

    /// The infrastructure tool they always use.
    public struct Infrastructure: Equatable, Sendable {
        /// "cloudformation", "terraform", "cdk", "bicep", "pulumi".
        public var tool: String
        /// "json" or "yaml", for CloudFormation.
        public var format: String?
        public var notes: [String]

        public init(tool: String, format: String? = nil, notes: [String] = []) {
            self.tool = tool.lowercased()
            self.format = format?.lowercased()
            self.notes = notes
        }

        public var toolName: String {
            switch tool {
            case "cloudformation", "cfn": "CloudFormation"
            case "terraform", "tf": "Terraform"
            case "cdk": "AWS CDK"
            case "bicep": "Bicep"
            case "pulumi": "Pulumi"
            case "arm": "ARM templates"
            default: tool
            }
        }

        public var sentence: String {
            var text = "Infrastructure is always \(toolName)"
            if let format { text += " in \(format.uppercased())" }
            return text + "."
        }
    }

    /// A Claude Code skill that knows this customer's world.
    public struct Skill: Identifiable, Equatable, Sendable {
        public var name: String
        public var when: String?
        public var id: String { name }
        public init(name: String, when: String? = nil) {
            self.name = name
            self.when = when
        }
    }

    /// One of their own MCP servers, as Claude Code's `mcpServers` entry.
    public struct Server: Identifiable, Equatable, Sendable {
        public var name: String
        public var config: JSONValue
        public var id: String { name }
        public init(name: String, config: JSONValue) {
            self.name = name
            self.config = config
        }

        /// What it runs, for the page: "npx acme-mcp" or its URL.
        public var summary: String {
            if let url = config["url"]?.string { return url }
            let args = config["args"]?.array?.compactMap(\.string) ?? []
            return ([config["command"]?.string ?? "?"] + args).joined(separator: " ")
        }
    }

    /// The folder's name.
    public var id: String
    public var folder: URL?
    public var name: String
    public var summary: String
    /// Git remotes, words in the project's path and files that say a project is theirs.
    public var detectRemotes: [String]
    public var detectPaths: [String]
    public var detectFiles: [String]
    /// A theme in the company library (or the customer's own themes/ folder).
    public var theme: String?
    public var infrastructure: Infrastructure?
    public var rules: [Rule]
    public var naming: [Naming]
    public var process: [Process]
    public var skills: [Skill]
    public var servers: [Server]
    /// Markdown beside customer.yaml (their guides), for the agents to read.
    public var docs: [URL]
    /// What couldn't be read.
    public var problems: [String]

    public init(id: String, folder: URL? = nil, name: String, summary: String = "", detectRemotes: [String] = [], detectPaths: [String] = [],
                detectFiles: [String] = [], theme: String? = nil, infrastructure: Infrastructure? = nil, rules: [Rule] = [], naming: [Naming] = [],
                process: [Process] = [], skills: [Skill] = [], servers: [Server] = [], docs: [URL] = [], problems: [String] = []) {
        self.id = id
        self.folder = folder
        self.name = name
        self.summary = summary
        self.detectRemotes = detectRemotes
        self.detectPaths = detectPaths
        self.detectFiles = detectFiles
        self.theme = theme
        self.infrastructure = infrastructure
        self.rules = rules
        self.naming = naming
        self.process = process
        self.skills = skills
        self.servers = servers
        self.docs = docs
        self.problems = problems
    }

    public var file: URL? { folder?.appending(path: "customer.yaml") }

    // MARK: Parts a project can switch off

    /// Keys for `CustomerChoice.off`: "rule:<id>", "naming:<id>", "process:<id>",
    /// "skill:<name>", "mcp:<name>", "theme", "infrastructure".
    public static func key(_ kind: String, _ id: String? = nil) -> String { id.map { "\(kind):\($0)" } ?? kind }

    /// The profile with the parts in `off` left out.
    public func applying(off: Set<String>) -> CustomerProfile {
        var applied = self
        if off.contains("theme") { applied.theme = nil }
        if off.contains("infrastructure") { applied.infrastructure = nil }
        applied.rules.removeAll { off.contains(Self.key("rule", $0.id)) }
        applied.naming.removeAll { off.contains(Self.key("naming", $0.id)) }
        applied.process.removeAll { off.contains(Self.key("process", $0.id)) }
        applied.skills.removeAll { off.contains(Self.key("skill", $0.name)) }
        applied.servers.removeAll { off.contains(Self.key("mcp", $0.name)) }
        return applied
    }

    public var isEmpty: Bool {
        theme == nil && infrastructure == nil && rules.isEmpty && naming.isEmpty && process.isEmpty && skills.isEmpty && servers.isEmpty
    }

    // MARK: Reading

    /// Reads customer.yaml leniently: lists may be single values, ids default to the title.
    public static func parse(_ yaml: String, id: String, folder: URL? = nil) -> CustomerProfile {
        var profile = CustomerProfile(id: id, folder: folder, name: id)
        let root: [String: Any]
        do {
            guard let loaded = try SafeYAML.load(yaml) as? [String: Any] else {
                profile.problems.append("customer.yaml is empty or isn’t a map of fields.")
                return profile
            }
            root = loaded
        } catch {
            profile.problems.append("customer.yaml can’t be read: \(error.localizedDescription)")
            return profile
        }
        profile.name = text(root["name"]) ?? id
        profile.summary = text(root["summary"]) ?? ""
        if let detect = root["detect"] as? [String: Any] {
            profile.detectRemotes = list(detect["remotes"] ?? detect["remote"])
            profile.detectPaths = list(detect["paths"] ?? detect["path"])
            profile.detectFiles = list(detect["files"] ?? detect["file"])
        }
        profile.theme = text(root["theme"])
        if let value = root["infrastructure"] {
            if let tool = value as? String {
                profile.infrastructure = Infrastructure(tool: tool)
            } else if let map = value as? [String: Any], let tool = text(map["tool"]) {
                profile.infrastructure = Infrastructure(tool: tool, format: text(map["format"]), notes: list(map["notes"] ?? map["note"]))
            } else {
                profile.problems.append("infrastructure needs a tool, like `tool: cloudformation`.")
            }
        }
        var used: Set<String> = []
        for (index, entry) in items(root["rules"]).enumerated() {
            if let title = entry as? String {
                profile.rules.append(Rule(id: uniqueID(title, &used), title: title))
                continue
            }
            guard let map = entry as? [String: Any], let title = text(map["title"]) ?? text(map["id"]) else {
                profile.problems.append("Rule \(index + 1) has no title.")
                continue
            }
            var rule = Rule(id: uniqueID(text(map["id"]) ?? title, &used), title: title, detail: text(map["detail"] ?? map["why"]) ?? "",
                            severity: Severity(text: text(map["severity"])), forbid: list(map["forbid"]), require: list(map["require"]),
                            pattern: text(map["pattern"]), files: list(map["files"] ?? map["in"]))
            if let pattern = rule.pattern, (try? NSRegularExpression(pattern: pattern)) == nil {
                profile.problems.append("Rule “\(title)”: the pattern isn’t a regular expression Dante can read.")
                rule.pattern = nil
            }
            profile.rules.append(rule)
        }
        used = []
        for (index, entry) in items(root["naming"]).enumerated() {
            guard let map = entry as? [String: Any], let what = text(map["what"]) ?? text(map["title"]) ?? text(map["id"]) else {
                profile.problems.append("Naming \(index + 1) needs `what` (the kind of name).")
                continue
            }
            var naming = Naming(id: uniqueID(text(map["id"]) ?? what, &used), what: what, pattern: text(map["pattern"]), shape: text(map["shape"]),
                                example: text(map["example"]), of: text(map["of"]), resourceType: text(map["type"] ?? map["resource"]),
                                files: list(map["files"] ?? map["in"]))
            if let regex = naming.regex, (try? NSRegularExpression(pattern: regex)) == nil {
                profile.problems.append("Naming “\(what)”: the pattern isn’t a regular expression Dante can read.")
                naming.pattern = nil
                naming.shape = nil
            }
            profile.naming.append(naming)
        }
        used = []
        for (index, entry) in items(root["process"] ?? root["processes"]).enumerated() {
            guard let map = entry as? [String: Any], let title = text(map["title"]) ?? text(map["name"]) ?? text(map["id"]) else {
                profile.problems.append("Process \(index + 1) has no title.")
                continue
            }
            profile.process.append(Process(id: uniqueID(text(map["id"]) ?? title, &used), title: title, when: text(map["when"]) ?? "",
                                           steps: list(map["steps"]), paths: list(map["paths"] ?? map["files"])))
        }
        for entry in items(root["skills"]) {
            if let name = entry as? String {
                profile.skills.append(Skill(name: name))
            } else if let map = entry as? [String: Any], let name = text(map["name"]) {
                profile.skills.append(Skill(name: name, when: text(map["when"])))
            }
        }
        let servers = (root["mcp"] as? [String: Any]).map { ($0["servers"] as? [String: Any]) ?? $0 } ?? [:]
        for name in servers.keys.sorted() {
            guard let config = servers[name].map(json), config.object != nil, config["command"] != nil || config["url"] != nil else {
                profile.problems.append("MCP server \(name) needs a command or a url.")
                continue
            }
            profile.servers.append(Server(name: name, config: config))
        }
        return profile
    }

    /// Reads a customer's folder: customer.yaml and the markdown beside it.
    public static func read(folder: URL) -> CustomerProfile? {
        let file = folder.appending(path: "customer.yaml")
        guard let yaml = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var profile = parse(yaml, id: folder.lastPathComponent, folder: folder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        profile.docs = names.filter { $0.lowercased().hasSuffix(".md") }.sorted().map { folder.appending(path: $0) }
        return profile
    }

    static func text(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        let text = "\(value)".trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func list(_ value: Any?) -> [String] {
        if let values = value as? [Any] { return values.compactMap(text) }
        return text(value).map { [$0] } ?? []
    }

    static func items(_ value: Any?) -> [Any] {
        if let values = value as? [Any] { return values }
        // A map of id → body is read as a list with those ids.
        if let map = value as? [String: Any] {
            return map.keys.sorted().map { key in
                guard var body = map[key] as? [String: Any] else { return ["id": key, "title": text(map[key]) ?? key] }
                if body["id"] == nil { body["id"] = key }
                return body
            }
        }
        return []
    }

    static func uniqueID(_ text: String, _ used: inout Set<String>) -> String {
        let base = ThemeMaker.slug(text).isEmpty ? "item" : ThemeMaker.slug(text)
        var id = base, count = 2
        while used.contains(id) { id = "\(base)-\(count)"; count += 1 }
        used.insert(id)
        return id
    }

    static func json(_ value: Any) -> JSONValue {
        switch value {
        case let value as String: .string(value)
        case let value as Bool: .bool(value)
        case let value as Int: .number(Double(value))
        case let value as Double: .number(value)
        case let value as [Any]: .array(value.map(json))
        case let value as [String: Any]: .object(value.mapValues(json))
        case is NSNull: .null
        default: .string("\(value)")
        }
    }
}

// MARK: - The library and a project's choice

public enum CustomerLibrary {
    /// Every customer in the library's customers/ folder, by name.
    public static func load(library: URL?) -> [CustomerProfile] {
        guard let folder = library?.appending(path: "customers", directoryHint: .isDirectory),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.compactMap { CustomerProfile.read(folder: folder.appending(path: $0, directoryHint: .isDirectory)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Starts a customer: a folder with a customer.yaml to fill in. Returns the file.
    @discardableResult
    public static func create(name: String, in library: URL) throws -> URL {
        let id = ThemeMaker.slug(name)
        guard !id.isEmpty else { throw ThemeMaker.Failure(message: "A customer needs a name with letters or digits.") }
        let folder = library.appending(path: "customers/\(id)", directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw ThemeMaker.Failure(message: "There’s already a customer called \(id).") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "customer.yaml")
        try template(name: name).write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// A customer.yaml to fill in, every section shown once.
    public static func template(name: String) -> String {
        """
        # \(name): how we always work for them. Dante reads this for every project you apply it to
        # (Docs › Standards › Customer), tells the agents, checks the code and notes agents' edits.
        name: \(name)
        summary: One line on who they are and what we build for them.

        # Says a project is theirs, so Dante can suggest applying this.
        detect:
          remotes: []      # parts of a git remote, e.g. bitbucket.org/their-workspace
          paths: []        # words in the project's folder path
          files: []        # files only their projects have

        # A theme in the company library's themes/ (Docs › Standards).
        theme:

        infrastructure:
          tool: cloudformation   # cloudformation, terraform, cdk, bicep, pulumi
          format: json           # json or yaml (CloudFormation)
          notes:
            - Every resource is tagged from parameters, never literal values.

        rules:
          - title: No wildcard resources in IAM policies
            severity: blocker    # blocker, issue or note
            pattern: '"Resource"\\s*:\\s*"\\*"'
            files: ["**/*.json"]
            detail: Scope every statement to explicit ARNs.
          - title: Every policy statement has a Sid
            severity: issue

        naming:
          - what: Stack export
            of: export           # file, logical-id, export, tag:<Key>, or a property like RoleName
            shape: "${AppId}-${StackName}-${Environment}-*"
            example: "${AppId}-${StackName}-${Environment}-RoleArn"
          - what: IAM role name
            of: RoleName
            type: AWS::IAM::Role
            shape: "${AppName}-*Role-${Environment}"

        process:
          - title: RFC for infrastructure changes
            when: Any change to a CloudFormation template bound for their accounts
            paths: ["infra/**", "**/*.template.json"]
            steps:
              - Validate the template with their validator.
              - Raise the RFC with the right change type.
              - Wait for approval before deploying.

        # Claude Code skills that know their world (in ~/.claude/skills).
        skills: []
          # - name: their-skill
          #   when: before raising an RFC

        # Their own MCP servers, passed to Claude Code for projects this applies to.
        mcp: {}
          # their-docs:
          #   command: npx
          #   args: ["-y", "their-docs-mcp"]
        """
    }
}

/// Which customers apply to a project, and the parts switched off, kept per Mac.
public struct CustomerChoice: Codable, Equatable, Sendable {
    public var customers: [String]
    public var off: [String]

    public init(customers: [String] = [], off: [String] = []) {
        self.customers = customers
        self.off = off
    }

    public var isEmpty: Bool { customers.isEmpty }

    /// Keys in `off` are "<customer>/<part key>".
    public func isOn(_ customer: String, _ key: String) -> Bool { !off.contains("\(customer)/\(key)") }

    public mutating func set(_ customer: String, _ key: String, on: Bool) {
        let full = "\(customer)/\(key)"
        off.removeAll { $0 == full }
        if !on { off.append(full) }
    }

    public mutating func apply(_ customer: String, _ on: Bool) {
        customers.removeAll { $0 == customer }
        if on { customers.append(customer) } else { off.removeAll { $0.hasPrefix(customer + "/") } }
    }

    /// The chosen customers from the library, with their switched-off parts left out.
    public func applied(from library: [CustomerProfile]) -> [CustomerProfile] {
        customers.compactMap { id in
            guard let profile = library.first(where: { $0.id == id }) else { return nil }
            let prefix = id + "/"
            return profile.applying(off: Set(off.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }))
        }
    }

    static func key(_ projectRoot: URL) -> String { "customers." + projectRoot.standardizedFileURL.path }

    public static func load(projectRoot: URL, defaults: UserDefaults = .standard) -> CustomerChoice {
        guard let data = defaults.data(forKey: key(projectRoot)), let choice = try? JSONDecoder().decode(CustomerChoice.self, from: data) else {
            return CustomerChoice()
        }
        return choice
    }

    public func save(projectRoot: URL, defaults: UserDefaults = .standard) {
        if isEmpty && off.isEmpty {
            defaults.removeObject(forKey: Self.key(projectRoot))
        } else if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key(projectRoot))
        }
    }

    /// For `dante mcp`: the applied customers' folders and switched-off parts.
    public func environmentValue(library: [CustomerProfile]) -> String? {
        let folders = customers.compactMap { id in library.first { $0.id == id }?.folder?.path }
        guard !folders.isEmpty, let data = try? JSONEncoder().encode(Passed(folders: folders, off: off)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    struct Passed: Codable {
        var folders: [String]
        var off: [String]
    }

    /// The customers `environmentValue` names, read back in `dante mcp`.
    public static func applied(environmentValue value: String) -> [CustomerProfile] {
        guard let passed = try? JSONDecoder().decode(Passed.self, from: Data(value.utf8)) else { return [] }
        let profiles = passed.folders.compactMap { CustomerProfile.read(folder: URL(filePath: $0, directoryHint: .isDirectory)) }
        return CustomerChoice(customers: profiles.map(\.id), off: passed.off).applied(from: profiles)
    }
}

/// Whether a project looks like a customer's, so the page can suggest applying them.
public enum CustomerDetect {
    /// Why this project looks like theirs, or nil.
    public static func reason(_ profile: CustomerProfile, remotes: [String], projectPath: String, files: [String]) -> String? {
        let lowered = remotes.map { $0.lowercased() }
        if let remote = profile.detectRemotes.first(where: { wanted in lowered.contains { $0.contains(wanted.lowercased()) } }) {
            return "Its git remote is on \(remote)."
        }
        let path = projectPath.lowercased()
        if let word = profile.detectPaths.first(where: { path.contains($0.lowercased()) }) {
            return "Its folder’s path says \(word)."
        }
        for pattern in profile.detectFiles {
            if let file = files.first(where: { CustomerCheck.matches($0, pattern) }) { return "It has \(file)." }
        }
        return nil
    }
}

// MARK: - Checking a project

public struct CustomerFinding: Identifiable, Equatable, Sendable {
    public var customer: String
    /// "rule", "naming", "infrastructure".
    public var kind: String
    public var itemID: String
    public var title: String
    public var detail: String
    public var severity: CustomerProfile.Severity
    public var file: String?
    public var line: Int?

    public var id: String { "\(customer)/\(kind):\(itemID)@\(file ?? ""):\(line ?? 0)#\(detail)" }
}

public enum CustomerCheck {
    /// Most findings kept per rule, so one sweeping rule doesn't bury the rest.
    public static let limitPerItem = 25

    /// A path against a pattern: `**/` matches no folders too, a pattern without a slash
    /// matches the file's name anywhere.
    public static func matches(_ path: String, _ pattern: String) -> Bool {
        if ClaudeRules.path(path, matches: pattern) { return true }
        if pattern.hasPrefix("**/") { return matches(path, String(pattern.dropFirst(3))) }
        return false
    }

    /// A file's text for a check: nil past 2 MB or when it isn't UTF-8.
    public static func readText(_ url: URL) -> String? {
        guard ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < 2_000_000 else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static let textExtensions: Set<String> = ["json", "yaml", "yml", "template", "tf", "ts", "tsx", "js", "jsx", "py", "go", "java", "kt", "kts", "cs",
                                              "rb", "php", "swift", "rs", "sql", "sh", "md", "xml", "properties", "toml", "gradle", "html", "css", "scss"]

    /// Checks a project against the applied customers. `read` gives a file's text, nil for
    /// one that can't be read (or is too big).
    public static func run(_ customers: [CustomerProfile], files: [String], read: (String) -> String?) -> [CustomerFinding] {
        var findings: [CustomerFinding] = []
        var cache: [String: String?] = [:]
        func text(_ file: String) -> String? {
            if let cached = cache[file] { return cached }
            let value = read(file)
            cache[file] = value
            return value
        }
        let templates = files.filter { CloudFormationNames.mayBeTemplate($0) }
        for customer in customers {
            if let infrastructure = customer.infrastructure {
                findings += infrastructureFindings(infrastructure, customer: customer, files: files, templates: templates, read: text)
            }
            for rule in customer.rules {
                var found: [CustomerFinding] = []
                func add(_ detail: String, _ file: String?, _ line: Int?) {
                    found.append(CustomerFinding(customer: customer.name, kind: "rule", itemID: rule.id, title: rule.title, detail: detail,
                                                 severity: rule.severity, file: file, line: line))
                }
                for file in files where rule.forbid.contains(where: { matches(file, $0) }) { add("This file shouldn’t exist.", file, nil) }
                if !rule.require.isEmpty, !files.contains(where: { file in rule.require.contains { matches(file, $0) } }) {
                    add("Nothing matches \(rule.require.joined(separator: ", ")).", nil, nil)
                }
                if let pattern = rule.pattern, let expression = try? NSRegularExpression(pattern: pattern) {
                    let scope = files.filter { file in
                        rule.files.isEmpty ? textExtensions.contains((file as NSString).pathExtension.lowercased()) : rule.files.contains { matches(file, $0) }
                    }
                    search: for file in scope {
                        guard let body = text(file) else { continue }
                        for (index, line) in body.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                            let line = String(line)
                            if expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                                add(line.trimmingCharacters(in: .whitespaces).prefix(160).description, file, index + 1)
                                if found.count >= limitPerItem { break search }
                            }
                        }
                    }
                }
                findings += found.prefix(limitPerItem)
            }
            for naming in customer.naming {
                guard let of = naming.of, naming.regex != nil else { continue }
                var found: [CustomerFinding] = []
                let names: [(name: String, file: String, line: Int?)]
                if of.lowercased() == "file" {
                    names = files.filter { file in naming.files.isEmpty || naming.files.contains { matches(file, $0) } }
                        .map { ((($0 as NSString).lastPathComponent), $0, nil) }
                } else {
                    let scope = templates.filter { file in naming.files.isEmpty || naming.files.contains { matches(file, $0) } }
                    names = scope.flatMap { file -> [(name: String, file: String, line: Int?)] in
                        guard let body = text(file) else { return [] }
                        return CloudFormationNames.values(of: of, resourceType: naming.resourceType, in: body, file: file).map { ($0.value, file, $0.line) }
                    }
                }
                for entry in names where !naming.accepts(entry.name) {
                    found.append(CustomerFinding(customer: customer.name, kind: "naming", itemID: naming.id, title: naming.what,
                                                 detail: "“\(entry.name)” should be \(naming.how).", severity: .issue, file: entry.file, line: entry.line))
                    if found.count >= limitPerItem { break }
                }
                findings += found
            }
        }
        return findings.sorted { ($0.severity, $1.file ?? "", $1.line ?? 0) > ($1.severity, $0.file ?? "", $0.line ?? 0) }
    }

    static func infrastructureFindings(_ infrastructure: CustomerProfile.Infrastructure, customer: CustomerProfile, files: [String], templates: [String],
                                       read: (String) -> String?) -> [CustomerFinding] {
        var findings: [CustomerFinding] = []
        func add(_ detail: String, _ file: String?) {
            guard findings.count < limitPerItem else { return }
            findings.append(CustomerFinding(customer: customer.name, kind: "infrastructure", itemID: infrastructure.tool, title: infrastructure.sentence,
                                            detail: detail, severity: .blocker, file: file, line: nil))
        }
        let wanted = ["cfn": "cloudformation", "tf": "terraform"][infrastructure.tool] ?? infrastructure.tool
        // Only read the templates when CloudFormation would be the wrong tool.
        let cloudFormation: Set<String> = wanted == "cloudformation" || wanted == "cdk" ? [] : Set(templates.filter { read($0).map(CloudFormationNames.isTemplate) ?? false })
        let others: [(tool: String, name: String, test: (String) -> Bool)] = [
            ("terraform", "Terraform", { $0.hasSuffix(".tf") }),
            ("cdk", "CDK", { ($0 as NSString).lastPathComponent == "cdk.json" }),
            ("bicep", "Bicep", { $0.hasSuffix(".bicep") }),
            ("pulumi", "Pulumi", { ($0 as NSString).lastPathComponent.hasPrefix("Pulumi.") && $0.hasSuffix(".yaml") }),
            ("cloudformation", "CloudFormation", { cloudFormation.contains($0) }),
        ]
        for other in others where other.tool != wanted {
            // CloudFormation beside CDK is CDK's own output.
            if other.tool == "cloudformation", wanted == "cdk" { continue }
            for file in files where !file.contains("node_modules/") && !file.contains("cdk.out/") && other.test(file) {
                add("\(other.name) here, but \(customer.name) uses \(infrastructure.toolName).", file)
            }
        }
        if wanted == "cloudformation", let format = infrastructure.format {
            for file in templates {
                let isJSON = file.lowercased().hasSuffix(".json")
                guard isJSON != (format == "json"), let body = read(file), CloudFormationNames.isTemplate(body) else { continue }
                add("A CloudFormation template in \(isJSON ? "JSON" : "YAML"); \(customer.name) writes them in \(format.uppercased()).", file)
            }
        }
        return findings
    }

    /// An agent's edit to a file, against the applied customers: the rules its added lines
    /// break and the processes changes there need. Nil when none.
    public static func note(for change: ProposedChange, root: URL, customers: [CustomerProfile]) -> String? {
        guard !customers.isEmpty else { return nil }
        let base = root.standardizedFileURL.path + "/"
        var path = change.url.path.hasPrefix(base) ? String(change.url.path.dropFirst(base.count)) : change.displayPath
        var paths: [String] = [path]
        var added: [(path: String, text: String)] = []
        for line in change.lines {
            if line.kind == .file {
                path = line.text.trimmingCharacters(in: .whitespaces)
                paths.append(path)
                continue
            }
            if line.kind == .added { added.append((path, line.text)) }
        }
        var notes: [String] = []
        for customer in customers {
            for rule in customer.rules {
                if paths.contains(where: { file in rule.forbid.contains { matches(file, $0) } }) {
                    notes.append("\(customer.name): \(rule.title).")
                    continue
                }
                guard let pattern = rule.pattern, let expression = try? NSRegularExpression(pattern: pattern) else { continue }
                if added.contains(where: { line in
                    (rule.files.isEmpty || rule.files.contains { matches(line.path, $0) })
                        && expression.firstMatch(in: line.text, range: NSRange(line.text.startIndex..., in: line.text)) != nil
                }) {
                    notes.append("\(customer.name): \(rule.title).")
                }
            }
            for process in customer.process where paths.contains(where: { file in process.paths.contains { matches(file, $0) } }) {
                notes.append("\(customer.name): this change needs \(process.title)\(process.when.isEmpty ? "" : " (\(process.when.lowercasedFirst))").")
            }
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

/// Names in CloudFormation templates, for naming rules.
public enum CloudFormationNames {
    public static func mayBeTemplate(_ file: String) -> Bool {
        let lower = file.lowercased()
        guard !lower.contains("node_modules/"), !lower.contains("cdk.out/"), !lower.hasPrefix("."), !lower.contains("/.") else { return false }
        let name = (lower as NSString).lastPathComponent
        guard !["package.json", "package-lock.json", "tsconfig.json", "composer.json"].contains(name) else { return false }
        return ["json", "yaml", "yml", "template"].contains((lower as NSString).pathExtension)
    }

    public static func isTemplate(_ text: String) -> Bool {
        text.contains("AWSTemplateFormatVersion") || (text.contains("Resources") && text.contains("AWS::"))
    }

    static func load(_ text: String, file: String) -> [String: Any]? {
        guard isTemplate(text) else { return nil }
        if file.lowercased().hasSuffix(".json") || text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        }
        let plain = text.replacingOccurrences(of: #"!(Ref|GetAtt|Sub|Join|Select|Split|If|Equals|Not|And|Or|FindInMap|Base64|Cidr|ImportValue|GetAZs|Condition|Transform)\b"#,
                                              with: "", options: .regularExpression)
        return (try? SafeYAML.load(plain)) as? [String: Any]
    }

    /// A name's text: a plain string, or the string inside `Fn::Sub`. `Ref` and joins have no
    /// fixed text and are skipped.
    static func nameText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let map = value as? [String: Any], let sub = map["Fn::Sub"] {
            if let text = sub as? String { return text }
            if let list = sub as? [Any], let text = list.first as? String { return text }
        }
        return nil
    }

    /// The names a naming rule's `of` picks out of a template, each with its line.
    public static func values(of: String, resourceType: String?, in text: String, file: String) -> [(value: String, line: Int?)] {
        guard let root = load(text, file: file) else { return [] }
        let resources = root["Resources"] as? [String: Any] ?? [:]
        var values: [String] = []
        let lowered = of.lowercased()
        if lowered == "export" {
            for (_, output) in root["Outputs"] as? [String: Any] ?? [:] {
                if let export = (output as? [String: Any])?["Export"] as? [String: Any], let name = nameText(export["Name"]) { values.append(name) }
            }
        } else {
            for (logicalID, value) in resources {
                guard let body = value as? [String: Any] else { continue }
                if let resourceType, (body["Type"] as? String) != resourceType { continue }
                if lowered == "logical-id" { values.append(logicalID); continue }
                let properties = body["Properties"] as? [String: Any] ?? [:]
                if lowered.hasPrefix("tag:") {
                    let key = String(of.dropFirst(4))
                    for tag in properties["Tags"] as? [Any] ?? [] {
                        if let tag = tag as? [String: Any], (tag["Key"] as? String) == key, let name = nameText(tag["Value"]) { values.append(name) }
                    }
                } else if let name = nameText(properties[of]) {
                    values.append(name)
                }
            }
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return values.sorted().map { value in
            (value, lines.firstIndex { $0.contains(value) }.map { $0 + 1 })
        }
    }
}

// MARK: - What the agents are told

public enum CustomerBrief {
    /// For the system prompt; nil when no customer applies.
    public static func brief(_ customers: [CustomerProfile]) -> String? {
        let customers = customers.filter { !$0.isEmpty }
        guard !customers.isEmpty else { return nil }
        var parts: [String] = []
        for customer in customers {
            var lines = ["This project is built for \(customer.name)\(customer.summary.isEmpty ? "" : " (\(customer.summary))"). Follow their way of working; say when a request would break it."]
            if let infrastructure = customer.infrastructure { lines.append(infrastructure.sentence + infrastructure.notes.map { " " + $0 }.joined()) }
            if !customer.rules.isEmpty {
                lines.append("Rules: " + customer.rules.map { "\($0.title)\($0.severity == .blocker ? " (must)" : "")" }.joined(separator: "; ") + ".")
            }
            if !customer.naming.isEmpty {
                lines.append("Naming: " + customer.naming.map { "\($0.what) \($0.how)" }.joined(separator: "; ") + ".")
            }
            for process in customer.process {
                lines.append("Process, \(process.title)\(process.when.isEmpty ? "" : ", when \(process.when.lowercasedFirst)"): \(process.steps.joined(separator: " "))")
            }
            for skill in customer.skills {
                lines.append("Use the \(skill.name) skill\(skill.when.map { " \($0)" } ?? "").")
            }
            if let theme = customer.theme { lines.append("Their UI theme is \(theme) (ui_standards theme=\(theme)).") }
            parts.append(lines.joined(separator: " "))
        }
        parts.append("customer_rules gives each rule's full text and their guides; customer_check checks the project, or a name before you use it.")
        return parts.joined(separator: "\n")
    }

    /// The `customer_rules` tool's answer: everything, or one part (`topic`: a rule, naming,
    /// process or guide's title or id).
    public static func report(_ customers: [CustomerProfile], topic: String? = nil) -> String {
        guard !customers.isEmpty else {
            return "No customer applies to this project. Customers live in the company library's customers/ folder and are applied on Docs › Standards."
        }
        if let topic, !topic.isEmpty {
            let wanted = topic.lowercased()
            for customer in customers {
                if let doc = customer.docs.first(where: { $0.lastPathComponent.lowercased() == wanted || Standards.title(of: $0).lowercased().contains(wanted) }),
                   let text = try? String(contentsOf: doc, encoding: .utf8) {
                    return "# \(customer.name): \(Standards.title(of: doc))\n\n" + String(text.prefix(30_000))
                }
                if let rule = customer.rules.first(where: { $0.id == wanted || $0.title.lowercased().contains(wanted) }) { return describe(rule, customer) }
                if let naming = customer.naming.first(where: { $0.id == wanted || $0.what.lowercased().contains(wanted) }) {
                    return "\(customer.name) names \(naming.what): \(naming.how)."
                }
                if let process = customer.process.first(where: { $0.id == wanted || $0.title.lowercased().contains(wanted) }) { return describe(process, customer) }
            }
            return "Nothing called \(topic). " + report(customers)
        }
        var lines: [String] = []
        for customer in customers {
            lines.append("# \(customer.name)")
            if !customer.summary.isEmpty { lines.append(customer.summary) }
            if let infrastructure = customer.infrastructure {
                lines.append("")
                lines.append(infrastructure.sentence)
                lines += infrastructure.notes.map { "- " + $0 }
            }
            if !customer.rules.isEmpty {
                lines += ["", "## Rules"]
                lines += customer.rules.map { "- [\($0.severity.rawValue)] \($0.title)\($0.detail.isEmpty ? "" : ": \($0.detail)")" }
            }
            if !customer.naming.isEmpty {
                lines += ["", "## Naming"]
                lines += customer.naming.map { "- \($0.what): \($0.how)" }
            }
            for process in customer.process {
                lines += ["", describe(process, customer)]
            }
            if !customer.skills.isEmpty {
                lines += ["", "## Skills"]
                lines += customer.skills.map { "- \($0.name)\($0.when.map { ": \($0)" } ?? "")" }
            }
            if let theme = customer.theme { lines += ["", "Theme: \(theme) (read it with ui_standards theme=\(theme))."] }
            if !customer.docs.isEmpty {
                lines += ["", "## Guides (read one with topic)"]
                lines += customer.docs.map { "- \(Standards.title(of: $0)) (\($0.lastPathComponent))" }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ rule: CustomerProfile.Rule, _ customer: CustomerProfile) -> String {
        var text = "\(customer.name) rule (\(rule.severity.rawValue)): \(rule.title)."
        if !rule.detail.isEmpty { text += "\n\(rule.detail)" }
        if !rule.forbid.isEmpty { text += "\nNo files like \(rule.forbid.joined(separator: ", "))." }
        if !rule.require.isEmpty { text += "\nThere must be a file like \(rule.require.joined(separator: ", "))." }
        if let pattern = rule.pattern { text += "\nLines matching `\(pattern)`\(rule.files.isEmpty ? "" : " in \(rule.files.joined(separator: ", "))") break it." }
        return text
    }

    static func describe(_ process: CustomerProfile.Process, _ customer: CustomerProfile) -> String {
        var lines = ["## \(process.title) (\(customer.name))"]
        if !process.when.isEmpty { lines.append("When: \(process.when)") }
        if !process.paths.isEmpty { lines.append("Changes to: \(process.paths.joined(separator: ", "))") }
        lines += process.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }
        return lines.joined(separator: "\n")
    }

    /// `customer_check` with a name: whether it's written as the customer's naming says.
    public static func checkName(_ customers: [CustomerProfile], name: String, what: String?) -> String {
        let candidates = customers.flatMap { customer in customer.naming.map { (customer, $0) } }.filter { _, naming in
            guard let what, !what.isEmpty else { return true }
            return naming.what.lowercased().contains(what.lowercased()) || naming.id == what.lowercased() || naming.of?.lowercased() == what.lowercased()
        }
        guard !candidates.isEmpty else {
            return "No naming rule for \(what ?? "that"). Rules: " + customers.flatMap { $0.naming.map(\.what) }.joined(separator: ", ")
        }
        return candidates.map { customer, naming in
            naming.accepts(name) ? "OK for \(customer.name)'s \(naming.what) (\(naming.how))." : "Not OK for \(customer.name)'s \(naming.what): it should be \(naming.how)."
        }.joined(separator: "\n")
    }

    /// `customer_check`'s report of a whole-project check.
    public static func checkReport(_ findings: [CustomerFinding]) -> String {
        guard !findings.isEmpty else { return "The project keeps every rule Dante can check. Rules without a pattern are yours to keep." }
        var lines = ["\(findings.count) finding\(findings.count == 1 ? "" : "s"), worst first:"]
        for finding in findings.prefix(60) {
            let place = finding.file.map { " \($0)\(finding.line.map { ":\($0)" } ?? "")" } ?? ""
            lines.append("- [\(finding.severity.rawValue)] \(finding.customer), \(finding.title):\(place) \(finding.detail)")
        }
        if findings.count > 60 { lines.append("…and \(findings.count - 60) more.") }
        return lines.joined(separator: "\n")
    }
}
