import Foundation
import Yams

/// How someone gets into the app once it runs: the way it signs people in (an API key, a
/// password, single sign-on or nothing) and the first steps (make the first key, seed an admin).
/// It's `.dante/access.yaml` when the project has one; otherwise `detect` drafts it from the
/// code, the env names, scripts and the README, and the agent can write the file properly.
public struct AccessGuide: Equatable, Sendable {
    public static let path = ".dante/access.yaml"

    public enum SignIn: String, Equatable, Sendable, CaseIterable {
        case apiKey = "api-key", password, sso, none

        public var title: String {
            switch self {
            case .apiKey: "API key"
            case .password: "Password"
            case .sso: "Single sign-on"
            case .none: "Open"
            }
        }

        public var symbol: String {
            switch self {
            case .apiKey: "key.horizontal"
            case .password: "lock"
            case .sso: "person.badge.key"
            case .none: "lock.open"
            }
        }
    }

    public enum Place: String, Equatable, Sendable {
        /// Inside the running app (DigitalOcean's console), where its database and secrets are.
        case console
        /// On this Mac, in a terminal tab in `folder`.
        case local
        /// Nothing to run: something to know or look up.
        case note
    }

    public struct Step: Equatable, Sendable, Identifiable {
        public var title: String
        public var place: Place
        public var component: String?
        public var folder: String?
        public var run: String?
        public var note: String?
        public var id: String { title + (run ?? "") }

        public init(title: String, place: Place, component: String? = nil, folder: String? = nil, run: String? = nil, note: String? = nil) {
            self.title = title
            self.place = place
            self.component = component
            self.folder = folder
            self.run = run
            self.note = note
        }

        /// The command with `{url}` replaced by the live address (without a trailing slash).
        public func command(url: URL?) -> String? {
            guard let run else { return nil }
            guard let url else { return run }
            var address = url.absoluteString
            while address.hasSuffix("/") { address.removeLast() }
            return run.replacingOccurrences(of: "{url}", with: address)
        }
    }

    public var signIn: [SignIn]
    /// What a request carries, such as `Authorization: Bearer <key>`.
    public var header: String?
    public var summary: String?
    public var steps: [Step]
    /// Where `detect` saw each clue (files, env names), so the card can say why it thinks so.
    public var evidence: [String]
    /// True when it came from `.dante/access.yaml` rather than a guess.
    public var isWritten: Bool

    public init(signIn: [SignIn] = [], header: String? = nil, summary: String? = nil, steps: [Step] = [], evidence: [String] = [], isWritten: Bool = false) {
        self.signIn = signIn
        self.header = header
        self.summary = summary
        self.steps = steps
        self.evidence = evidence
        self.isWritten = isWritten
    }

    public var isEmpty: Bool { signIn.isEmpty && steps.isEmpty && summary == nil }

    /// The sentence at the top of the card.
    public var headline: String {
        if let summary, !summary.isEmpty { return summary }
        let ways = signIn.filter { $0 != .none }
        if ways.isEmpty { return signIn == [.none] ? "Anyone with the address can use it; there's no sign-in." : "Dante couldn't tell how this app signs people in." }
        var sentence: String
        switch ways[0] {
        case .apiKey: sentence = "Requests need an API key" + (header.map { " (\($0))" } ?? "")
        case .password: sentence = "People sign in with a password"
        case .sso: sentence = "People sign in through single sign-on"
        case .none: sentence = ""
        }
        if ways.count > 1 { sentence += ", and " + ways.dropFirst().map { $0.title.lowercased() }.joined(separator: " and ") + " is used too" }
        return sentence + (steps.isEmpty ? "." : ". The first one has to be made:")
    }

    // MARK: Reading the file

    /// Reads `.dante/access.yaml` leniently: `sign_in` (or `signIn`, `auth`) as one word or a
    /// list, steps with `where` (console, local, here, mac) and `run`/`command`.
    public static func read(yaml text: String) -> AccessGuide? {
        guard let object = try? Yams.load(yaml: text) as? [String: Any] else { return nil }
        func string(_ keys: String..., in map: [String: Any]) -> String? {
            for key in keys { if let value = map[key] { let text = "\(value)".trimmingCharacters(in: .whitespacesAndNewlines); if !text.isEmpty { return text } } }
            return nil
        }
        var guide = AccessGuide(isWritten: true)
        let raw = object["sign_in"] ?? object["signIn"] ?? object["sign-in"] ?? object["auth"]
        let words = (raw as? [Any])?.map { "\($0)" } ?? (raw.map { ["\($0)"] } ?? [])
        guide.signIn = words.compactMap { word in
            let w = word.lowercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
            switch w {
            case "api-key", "apikey", "key", "token", "bearer", "api-token": return .apiKey
            case "password", "login", "basic": return .password
            case "sso", "oauth", "oidc", "saml", "single-sign-on": return .sso
            case "none", "open", "public": return SignIn.none
            default: return nil
            }
        }
        guide.header = string("header", in: object)
        guide.summary = string("summary", "description", in: object)
        for item in object["steps"] as? [Any] ?? [] {
            if let line = item as? String { guide.steps.append(Step(title: line, place: .note)); continue }
            guard let map = item as? [String: Any], let title = string("title", "name", in: map) else { continue }
            let place: Place = switch (string("where", "place", in: map) ?? "").lowercased() {
            case "console", "app", "remote", "server": .console
            case "local", "here", "mac", "this mac", "terminal": .local
            default: string("run", "command", in: map) == nil ? .note : .local
            }
            guide.steps.append(Step(title: title, place: place, component: string("component", in: map), folder: string("folder", "in", in: map),
                                    run: string("run", "command", in: map), note: string("note", "notes", in: map)))
        }
        return guide.isEmpty ? nil : guide
    }

    /// The guide as `.dante/access.yaml`, for saving a draft so it can be corrected by hand.
    public var yaml: String {
        func quoted(_ text: String) -> String {
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        var lines = ["# How someone gets into this app once it runs. Dante shows it on Ship › Deploy.",
                     "# sign_in: api-key, password, sso or none. Steps run in the app's console (where: console)",
                     "# or on this Mac (where: local); {url} becomes the live address. Never put a key or password here."]
        lines.append("sign_in: [\(signIn.map(\.rawValue).joined(separator: ", "))]")
        if let header { lines.append("header: \(quoted(header))") }
        if let summary { lines.append("summary: \(quoted(summary))") }
        if !steps.isEmpty {
            lines.append("steps:")
            for step in steps {
                lines.append("  - title: \(quoted(step.title))")
                lines.append("    where: \(step.place.rawValue)")
                if let component = step.component { lines.append("    component: \(quoted(component))") }
                if let folder = step.folder { lines.append("    folder: \(quoted(folder))") }
                if let run = step.run { lines.append("    run: \(quoted(run))") }
                if let note = step.note { lines.append("    note: \(quoted(note))") }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Guessing

    static let codeExtensions: Set<String> = ["go", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rb", "java", "kt", "cs", "php", "rs", "ex"]
    static let skipped = ["node_modules/", "vendor/", "dist/", "build/", ".next/", "target/", "third_party/"]
    /// Words in a script's or heading's name that mean "this gets someone in".
    static let firstSteps = try! NSRegularExpression(pattern: #"(seed|token|api[-_ ]?key|keys?\b|admin|superuser|bootstrap|first[-_ ]?user|create[-_ ]?user|sign[-_ ]?in|log[-_ ]?in|access|auth)"#, options: [.caseInsensitive])
    /// Env names that hold the first admin's key or password (not a database's or a vendor's).
    static let bootstrapVariable = try! NSRegularExpression(pattern: #"^(?!(POSTGRES|PG|MYSQL|MARIADB|MONGO|REDIS|RABBIT|MINIO|AWS|AZURE|GCP|OPENAI|ANTHROPIC|STRIPE|SENDGRID|TWILIO|GITHUB|GOOGLE)_).*(ADMIN_(KEY|TOKEN|PASSWORD|SECRET)|ROOT_(KEY|TOKEN)|BOOTSTRAP_\w+|MASTER_KEY|INITIAL_\w*(KEY|TOKEN|PASSWORD))$"#)

    /// Drafts a guide from the project: how its servers check requests, env names for a first
    /// admin, scripts and package scripts that make keys or seed users, framework commands
    /// (Django's createsuperuser) and README sections about getting in.
    /// - Parameters:
    ///   - variables: env names the deployed app gets (from the spec), for bootstrap keys.
    ///   - component: the service a console step runs in.
    public static func detect(files: [String], read: (String) -> String?, variables: [String] = [], component: String? = nil) -> AccessGuide {
        var guide = AccessGuide()
        var apiKey: String?, bearer: String?, password: String?, sso: String?
        var header: String?

        let code = files.filter { file in
            let ext = (file as NSString).pathExtension.lowercased()
            return codeExtensions.contains(ext) && !skipped.contains { file.contains($0) } && CodePlace.of(file) == .shipped
        }
        for file in code.prefix(4000) {
            guard apiKey == nil || bearer == nil || password == nil || sso == nil, let text = read(file), text.utf8.count < 400_000 else { continue }
            let lower = text.lowercased()
            if apiKey == nil, let name = apiKeyHeader(in: text) { apiKey = file; header = header ?? "\(name): <key>" }
            if bearer == nil, readsAuthorization(lower), lower.contains("bearer") { bearer = file }
            if password == nil, ["bcrypt", "argon2", "check_password", "password_hash", "passwordencoder", "verifypassword", "comparepassword", "scrypt("].contains(where: lower.contains),
               ["login", "signin", "sign_in", "sign-in"].contains(where: lower.contains) { password = file }
            if sso == nil, ["next-auth", "nextauth", "passport-", "openid", "oidc", "@azure/msal", "auth0", "@clerk/", "keycloak", "saml", "oauth2client", "authlib"].contains(where: lower.contains) { sso = file }
        }
        if let file = apiKey { guide.signIn.append(.apiKey); guide.evidence.append("\(header ?? "An API key header") is read in \(file)") }
        if let file = bearer {
            if apiKey == nil { guide.signIn.append(.apiKey); header = "Authorization: Bearer <key>" }
            guide.evidence.append("The Authorization header is read in \(file)")
        }
        if let file = password { guide.signIn.append(.password); guide.evidence.append("Passwords are checked in \(file)") }
        if let file = sso { guide.signIn.append(.sso); guide.evidence.append("Single sign-on is set up in \(file)") }
        guide.header = header

        // A first admin's key or password the app reads from its environment.
        for name in variables where bootstrapVariable.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
            let isPassword = name.contains("PASSWORD")
            if guide.signIn.isEmpty { guide.signIn.append(isPassword ? .password : .apiKey) }
            guide.steps.append(Step(title: "The first \(isPassword ? "password" : "key") is \(name)", place: .note,
                                    note: "It's the value given for \(name) when the app was deployed. DigitalOcean keeps it encrypted; Settings › Environment variables in DigitalOcean shows it."))
            guide.evidence.append("\(name) is passed to the app")
        }

        // Django makes its first admin with createsuperuser, inside the app.
        if let manage = files.first(where: { ($0 as NSString).lastPathComponent == "manage.py" && $0.split(separator: "/").count <= 3 }) {
            if !guide.signIn.contains(.password) { guide.signIn.append(.password) }
            guide.steps.append(Step(title: "Make the first admin", place: .console, component: component,
                                    run: "python manage.py createsuperuser", note: "Django's admin is at {url}/admin."))
            guide.evidence.append("Django (\(manage))")
        }

        // Package scripts and script files that make keys, tokens or seed users.
        var covered = Set<String>()
        for file in files where (file as NSString).lastPathComponent == "package.json" && !skipped.contains(where: file.contains) && file.split(separator: "/").count <= 3 {
            guard let data = read(file)?.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let scripts = json["scripts"] as? [String: String] else { continue }
            let folder = (file as NSString).deletingLastPathComponent
            let runner = files.contains(joined(folder, "pnpm-lock.yaml")) ? "pnpm" : files.contains(joined(folder, "yarn.lock")) ? "yarn" : files.contains(joined(folder, "bun.lockb")) ? "bun run" : "npm run"
            for (name, command) in scripts.sorted(by: { $0.key < $1.key }) where matches(firstSteps, name) && !["auth:check", "lint", "test"].contains(name) {
                guide.steps.append(Step(title: "Run \(name) (\(command.count > 48 ? String(command.prefix(45)) + "…" : command))", place: .local, folder: folder.isEmpty ? nil : folder, run: "\(runner) \(name)"))
                covered.formUnion(command.split(separator: " ").map { String($0).replacingOccurrences(of: "./", with: "") })
            }
        }
        for file in files where isScript(file) {
            let name = (file as NSString).lastPathComponent
            let base = ((file as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            let inner = String(file.dropFirst(base.isEmpty ? 0 : base.count + 1))
            guard matches(firstSteps, name), !covered.contains(inner), !covered.contains(name) else { continue }
            guide.steps.append(Step(title: "Run \(inner)", place: .local, folder: base.isEmpty ? nil : base, run: runCommand(inner), note: "Read it first: it may expect the local stack, or take the address as {url}."))
        }

        // README sections about getting in, with their first commands.
        for readme in files where ["readme.md", "readme"].contains((readme as NSString).lastPathComponent.lowercased()) && readme.split(separator: "/").count <= 2 {
            guard let text = read(readme) else { continue }
            for section in readmeSections(text) where guide.steps.count < 8 {
                let folder = (readme as NSString).deletingLastPathComponent
                guide.steps.append(Step(title: section.heading, place: section.command == nil ? .note : .local, folder: folder.isEmpty ? nil : folder,
                                        run: section.command, note: section.command == nil ? section.text : nil))
                guide.evidence.append("\(readme): “\(section.heading)”")
            }
        }
        return guide
    }

    /// The header name a server reads an API key from (`X-API-Key`, `X-Api-Token`…).
    static func apiKeyHeader(in text: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: #"["'`](x-(?:[a-z0-9]+-)?(?:api-?key|api-?token|auth-?token|access-?key))["'`]"#, options: [.caseInsensitive])
        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { return nil }
        // Written the way people see it: X-API-Key.
        return text[range].split(separator: "-").map { part in
            let word = String(part)
            return ["api", "id"].contains(word.lowercased()) ? word.uppercased() : word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: "-")
    }

    /// Code that reads the Authorization header of a request coming in.
    static func readsAuthorization(_ lower: String) -> Bool {
        ["header.get(\"authorization\")", "headers.authorization", "headers[\"authorization\"]", "headers['authorization']", "headers.get(\"authorization\")",
         "headers.get('authorization')", "requestheader(\"authorization\")", "http_authorization", "httpbearer", "get_header(\"authorization\")",
         "req.get('authorization')", "req.get(\"authorization\")", "request.headers[\"authorization\"]", "authorizationheader"].contains(where: lower.contains)
    }

    static func isScript(_ file: String) -> Bool {
        let parts = file.split(separator: "/")
        guard parts.count >= 2, parts.count <= 4, ["scripts", "bin", "tools"].contains(parts[parts.count - 2]) else { return false }
        return ["sh", "bash", "py", "mjs", "js", "ts", "rb", ""].contains((file as NSString).pathExtension.lowercased()) && !skipped.contains(where: file.contains)
    }

    static func runCommand(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "py": "python3 \(path)"
        case "mjs", "js": "node \(path)"
        case "ts": "npx tsx \(path)"
        case "rb": "ruby \(path)"
        default: "./\(path)"
        }
    }

    struct ReadmeSection: Equatable { var heading: String; var command: String?; var text: String? }

    /// Sections whose heading is about getting in, with the first command in their first code
    /// block (local addresses become `{url}`) or, without one, their first sentence.
    static func readmeSections(_ text: String) -> [ReadmeSection] {
        var sections: [ReadmeSection] = []
        let lines = text.components(separatedBy: .newlines)
        var index = 0
        var fenced = false
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("```") { fenced.toggle() }
            guard !fenced, line.hasPrefix("#"), case let heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces),
                  !heading.isEmpty, matches(firstSteps, heading) else { index += 1; continue }
            // The section runs to the next heading outside a code block.
            var body: [String] = []
            var inBlock = false
            index += 1
            while index < lines.count, inBlock || !lines[index].hasPrefix("#") {
                if lines[index].hasPrefix("```") { inBlock.toggle() }
                body.append(lines[index])
                index += 1
            }
            var command: String?
            if let start = body.firstIndex(where: { $0.hasPrefix("```") }) {
                let block = body[(start + 1)...].prefix { !$0.hasPrefix("```") }
                command = block.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && !$0.hasPrefix("#") }
                    .map { $0.hasPrefix("$ ") ? String($0.dropFirst(2)) : $0 }
                    .map(localAddressAsURL)
            }
            let prose = body.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && !$0.hasPrefix("```") && !$0.hasPrefix("|") && !$0.hasPrefix("<") }
            sections.append(ReadmeSection(heading: String(heading.prefix(80)), command: command, text: command == nil ? prose : nil))
        }
        return sections
    }

    /// `http://localhost:8080/api` → `{url}/api`, so a README's example reaches the live app.
    static func localAddressAsURL(_ command: String) -> String {
        let pattern = try! NSRegularExpression(pattern: #"https?://(localhost|127\.0\.0\.1|0\.0\.0\.0)(:\d+)?"#)
        return pattern.stringByReplacingMatches(in: command, range: NSRange(command.startIndex..., in: command), withTemplate: "{url}")
    }

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func joined(_ folder: String, _ name: String) -> String { folder.isEmpty ? name : folder + "/" + name }

    // MARK: Asking the agent

    /// Asks the agent in charge to work out how a first-time person gets in and write the file.
    public func brief(appName: String, url: URL?) -> String {
        let found = evidence.isEmpty && steps.isEmpty ? "Dante found no clues." : """
        Dante's guess, from the code (check it, it may be wrong):
        \((evidence.map { "- \($0)" } + steps.map { "- step: \($0.title)\($0.run.map { " (`\($0)`)" } ?? "")" }).joined(separator: "\n"))
        """
        return """
        Someone opening \(appName)\(url.map { " at \($0.absoluteString)" } ?? "") for the first time needs to know how to get in: whether it wants an API key, a password, single sign-on or nothing, and how the very first key, user or admin gets made on the deployed app (not only locally).

        \(found)

        Read the code that checks requests, the scripts, seeds and docs, and write \(Self.path) in this shape:

        ```yaml
        sign_in: [api-key]            # api-key, password, sso or none
        header: "Authorization: Bearer <key>"
        summary: "One sentence a newcomer reads first."
        steps:
          - title: "Make the first admin key"
            where: console            # console = inside the running app on DigitalOcean; local = this Mac
            component: api            # the service the console opens in
            run: "./seed-admin"       # {url} becomes the live address
            note: "Prints the key once; keep it in a password manager."
        ```

        Prefer steps that work against the deployed app: a command that runs inside the running component (its image must contain it; say so if it doesn't), or one here that takes the live address as {url}. Never put a key, password or token's value in the file. If the app has no way to make its first key on a deployed copy, say so and suggest the smallest change, but don't make it without asking. Don't deploy or push.
        """
    }
}
