import Foundation

/// Who may call an endpoint: secured by something the code shows (Spring Security rules,
/// `@PreAuthorize`, auth middleware, FastAPI dependencies, `@login_required`), or open, and
/// then why that's likely: a health check, sign-in, a webhook, API docs, or nothing that
/// explains it. Read from the code only; a gateway in front of the app can't be seen.
extension SystemMap {
    public struct Access: Equatable, Sendable, Hashable {
        public enum Level: String, Sendable { case secured, open }
        public enum Reason: String, Sendable {
            /// Secured by a rule, annotation or middleware.
            case protected
            case health, signIn, webhook, docs
            /// Actuator or metrics beyond health: internals worth closing.
            case internals
            /// Open by a rule (`permitAll`) with no reason in its path.
            case permitted
            /// No check found on the route, and nothing project-wide.
            case unchecked
        }

        public var level: Level
        public var reason: Reason
        /// A sentence: why it's open or what secures it.
        public var note: String
        /// Where the deciding rule or annotation is.
        public var file: String?
        public var line: Int?

        /// Open without an evident reason, or exposing internals: worth a look.
        public var isConcern: Bool { level == .open && [.permitted, .unchecked, .internals].contains(reason) }
    }

    /// What applies project-wide: Spring Security's rules in order, whether it's there at all.
    public struct AccessRules: Sendable {
        struct Rule: Sendable {
            var method: String?
            var patterns: [String]
            var open: Bool
            var how: String
            var file: String
            var line: Int
        }

        var springSecurity = false
        var rules: [Rule] = []
        /// `anyRequest()` and what it requires, when the rules end with one.
        var fallback: Rule?

        public init() {}

        /// Reads build files for Spring Security and its configuration classes for rules.
        public static func load(files: [String], read: (String) -> String?) -> AccessRules {
            var result = AccessRules()
            for file in files where ["pom.xml", "build.gradle", "build.gradle.kts"].contains((file as NSString).lastPathComponent) {
                if let text = read(file), has(text, "spring-boot-starter-security") || has(text, "spring-security") || has(text, "starter-oauth2-resource-server") {
                    result.springSecurity = true
                }
            }
            for file in files where isJVM(file) && !isTest(file) {
                guard let text = read(file), has(text, "SecurityFilterChain") || has(text, "authorizeHttpRequests") || has(text, "authorizeRequests")
                        || has(text, "authorizeExchange") || has(text, "WebSecurityConfigurerAdapter") || has(text, "ignoring()") else { continue }
                result.springSecurity = true
                result.read(file: file, text: text)
            }
            return result
        }

        mutating func read(file: String, text: String) {
            let ns = text as NSString
            func line(at offset: Int) -> Int { ns.substring(to: offset).reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }
            // `.requestMatchers(HttpMethod.GET, "/a", "/b").permitAll()` and the older matchers;
            // `web.ignoring().requestMatchers(…)` skips security entirely.
            let matcher = try! NSRegularExpression(pattern: #"(ignoring\(\)\s*\.\s*)?(?:requestMatchers|antMatchers|mvcMatchers|pathMatchers|regexMatchers)\s*\(([^)]*)\)\s*(?:\.\s*(permitAll|authenticated|fullyAuthenticated|hasRole|hasAnyRole|hasAuthority|hasAnyAuthority|denyAll|access|hasIpAddress|rememberMe)\b)?"#)
            for match in matcher.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let arguments = ns.substring(with: match.range(at: 2))
                let ignoring = match.range(at: 1).location != NSNotFound
                guard ignoring || match.range(at: 3).location != NSNotFound else { continue }
                let verb = ignoring ? "ignoring" : ns.substring(with: match.range(at: 3))
                let patterns = arguments.matches(of: /"([^"]*)"/).map { String($0.1) }
                guard !patterns.isEmpty else { continue }
                let method = arguments.firstMatch(of: /HttpMethod\.(\w+)/).map { String($0.1) }
                rules.append(Rule(method: method, patterns: patterns, open: verb == "permitAll" || verb == "ignoring",
                                  how: verb == "ignoring" ? "ignored by Spring Security" : verb + "()", file: file, line: line(at: match.range.location)))
            }
            // The Kotlin DSL: authorize("/ping", permitAll).
            for match in text.matches(of: /authorize\(\s*(?:HttpMethod\.(\w+)\s*,\s*)?"([^"]+)"\s*,\s*(permitAll|authenticated|hasRole|hasAuthority|denyAll)/) {
                rules.append(Rule(method: match.1.map(String.init), patterns: [String(match.2)], open: match.3 == "permitAll", how: String(match.3),
                                  file: file, line: line(at: NSRange(text.startIndex..<match.range.lowerBound, in: text).length)))
            }
            let anyRequest = try! NSRegularExpression(pattern: #"any(?:Request|Exchange)\(\)\s*\.\s*(permitAll|authenticated|fullyAuthenticated|hasRole|hasAnyRole|hasAuthority|hasAnyAuthority|denyAll|access)"#)
            if let match = anyRequest.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                let verb = ns.substring(with: match.range(at: 1))
                fallback = Rule(method: nil, patterns: ["/**"], open: verb == "permitAll", how: "anyRequest()." + verb + "()", file: file, line: line(at: match.range.location))
            }
        }

        /// The first rule matching, as Spring applies them in order.
        func rule(method: String?, path: String) -> Rule? {
            for rule in rules where rule.method == nil || method == nil || rule.method == method {
                if rule.patterns.contains(where: { AccessRules.matches($0, path) }) { return rule }
            }
            return fallback
        }

        /// Ant-style patterns: `**` any depth, `*` one segment, `{id}` a segment.
        static func matches(_ pattern: String, _ path: String) -> Bool {
            var regex = "^"
            var rest = Substring(pattern.hasPrefix("/") ? pattern : "/" + pattern)
            while let character = rest.first {
                if rest.hasPrefix("/**") {
                    regex += "(/.*)?"
                    rest = rest.dropFirst(3)
                } else if rest.hasPrefix("**") {
                    regex += ".*"
                    rest = rest.dropFirst(2)
                } else if character == "*" {
                    regex += "[^/]*"
                    rest = rest.dropFirst()
                } else if character == "{" {
                    regex += "[^/]+"
                    rest = rest.drop { $0 != "}" }.dropFirst()
                } else {
                    regex += NSRegularExpression.escapedPattern(for: String(character))
                    rest = rest.dropFirst()
                }
            }
            regex += "/?$"
            // Route variables stand for a value.
            let concrete = path.replacing(/\{[^}]*\}/, with: "x")
            return concrete.range(of: regex, options: .regularExpression) != nil
        }
    }

    /// The access of a route registered at `line` of `file`.
    public static func access(method: String?, path: String, file: String, line: Int, text: String, rules: AccessRules) -> Access {
        if let secured = securedInCode(file: file, line: line, text: text) { return secured }
        if isJVM(file), rules.springSecurity {
            if let rule = rules.rule(method: method, path: path) {
                if !rule.open { return Access(level: .secured, reason: .protected, note: "Needs a signed-in caller: \(rule.how) in \((rule.file as NSString).lastPathComponent).", file: rule.file, line: rule.line) }
                return openAccess(path: path, text: text, how: rule.how == "ignored by Spring Security" ? "Spring Security ignores it" : "\(rule.how) lets anyone call it",
                                  file: rule.file, line: rule.line, permitted: true)
            }
            if rules.rules.isEmpty, rules.fallback == nil {
                return Access(level: .secured, reason: .protected, note: "Spring Security is in the project and, without rules, every request needs a login.")
            }
            return Access(level: .secured, reason: .protected, note: "Spring Security's rules don't name it; Spring then requires a login.")
        }
        if isJVM(file) {
            return openAccess(path: path, text: text, how: "The project has no Spring Security, so nothing here checks the caller", file: nil, line: nil, permitted: false)
        }
        return openAccess(path: path, text: text, how: "No auth check found on the route or its router", file: nil, line: nil, permitted: false)
    }

    /// Open: why that's probably meant, or a concern.
    static func openAccess(path: String, text: String, how: String, file: String?, line: Int?, permitted: Bool) -> Access {
        let lower = path.lowercased()
        let segments = lower.split(separator: "/").map(String.init)
        func any(_ words: [String]) -> Bool { segments.contains { segment in words.contains { segment == $0 || segment.hasPrefix($0 + "-") || segment.hasPrefix($0 + "_") } } }
        let reason: Access.Reason
        let why: String
        if any(["health", "healthz", "healthcheck", "ping", "ready", "readyz", "readiness", "live", "livez", "liveness", "status", "version"])
            || lower.hasSuffix("/actuator/health") || lower.hasSuffix("/actuator/info") {
            reason = .health
            why = "A health check: open so load balancers and monitors can reach it. Keep it free of data."
        } else if any(["actuator", "metrics", "prometheus", "env", "heapdump", "threaddump", "debug", "admin"]) {
            reason = .internals
            why = "It exposes the app's internals: usually only for the internal network or a signed-in admin."
        } else if isWebhookRoute(path) {
            reason = .webhook
            let verified = has(text, "signature") || has(text, "Signature") || has(text, "hmac") || has(text, "Hmac") || has(text, "constructEvent") || has(text, "verify")
            why = verified ? "A webhook: an outside service calls it, and the code checks the request's signature."
                : "A webhook: an outside service calls it, so it should check the request's signature; none found here."
        } else if any(["login", "logout", "signin", "sign-in", "signup", "sign-up", "register", "token", "refresh", "oauth", "oauth2", "callback", "sso", "saml", "password", "forgot", "reset", "verify", "auth"]) {
            reason = .signIn
            why = "Sign-in: it has to be open so people can log in."
        } else if any(["swagger", "swagger-ui", "api-docs", "openapi", "docs", "redoc"]) {
            reason = .docs
            why = "API docs: fine in development, usually closed in production."
        } else {
            reason = permitted ? .permitted : .unchecked
            why = "Anyone can call it. If it isn't meant to be public, protect it."
        }
        return Access(level: .open, reason: reason, note: how + ". " + why, file: file, line: line)
    }

    /// An annotation or middleware on the route itself, or on its class, file or router.
    static func securedInCode(file: String, line: Int, text: String) -> Access? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard line >= 1, line <= lines.count else { return nil }
        let routeLine = lines[line - 1]
        func found(_ how: String, at number: Int) -> Access {
            Access(level: .secured, reason: .protected, note: "Needs a signed-in caller: \(how).", file: file, line: number)
        }
        if isJVM(file) {
            // Method annotations sit just above the mapping (or below it, before the method).
            let start = max(0, line - 8)
            let end = min(lines.count, line + 6)
            for index in start..<end {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if index >= line, trimmed.contains("(") && !trimmed.hasPrefix("@") { break }
                if trimmed.hasPrefix("@PermitAll") || trimmed.hasPrefix("@AnonymousAllowed") { return nil }
                if let annotation = trimmed.firstMatch(of: /^@(PreAuthorize|Secured|RolesAllowed|PostAuthorize|IsAuthenticated)\b/) {
                    return found("@\(annotation.1) on the method", at: index + 1)
                }
            }
            // On the class.
            if let classLine = lines.firstIndex(where: { $0.range(of: #"\b(class|interface)\s+\w"#, options: .regularExpression) != nil }) {
                for index in max(0, classLine - 8)..<classLine {
                    if let annotation = lines[index].trimmingCharacters(in: .whitespaces).firstMatch(of: /^@(PreAuthorize|Secured|RolesAllowed)\b/) {
                        return found("@\(annotation.1) on the class", at: index + 1)
                    }
                }
            }
            return nil
        }
        let auth = /\b(?:require(?:Auth|User|Login|Session|Role|Admin|Permission)\w*|ensure\w*(?:Auth|Logged)\w*|(?:is|must)(?:Authenticated|LoggedIn|Admin)|[Aa]uth(?:enticate[d]?|orize|Middleware|Guard|Required|Check|Handler)?|verify(?:Token|Jwt|JWT|User|Session)|jwt\w*|passport\.authenticate|withAuth|protect(?:ed)?(?:Route)?|currentUser|current_user|get_current_\w+|login_required|permission_required|IsAuthenticated|\w+Guard|clerkMiddleware)\b/
        // Names only: a path like '/authors' or a handler like listAuthors isn't a check.
        func code(_ line: String) -> String { line.replacing(/"[^"]*"|'[^']*'|`[^`]*`/, with: "\"\"") }
        // On the route's own line: `router.get("/x", requireAuth, handler)`, `Depends(get_current_user)`.
        if let hit = code(routeLine).firstMatch(of: auth) {
            return found("\(hit.0) on the route", at: line)
        }
        // Python: decorators below the route, and the handler's parameters.
        if (file as NSString).pathExtension == "py" {
            for index in line..<min(lines.count, line + 6) {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("@"), let hit = trimmed.firstMatch(of: /@(login_required|permission_required|requires_auth|jwt_required|auth_required|\w*auth\w*)/) {
                    return found("@\(hit.1)", at: index + 1)
                }
                if trimmed.hasPrefix("def ") || trimmed.hasPrefix("async def ") {
                    var signature = trimmed
                    var next = index + 1
                    while !signature.contains(":") || signature.filter({ $0 == "(" }).count > signature.filter({ $0 == ")" }).count, next < min(lines.count, index + 8) {
                        signature += lines[next]
                        next += 1
                    }
                    if let hit = signature.firstMatch(of: /(?:Depends|Security)\(\s*(\w+)/), hit.1.lowercased().contains("user") || hit.1.lowercased().contains("auth") || hit.1.lowercased().contains("token") {
                        return found("Depends(\(hit.1))", at: index + 1)
                    }
                    break
                }
            }
        }
        // A router or app protected before the route: `router.use(requireAuth)`, `r.Use(auth)`,
        // `APIRouter(dependencies=[Depends(auth)])`.
        for index in 0..<(line - 1) {
            let candidate = lines[index]
            guard candidate.contains(".use(") || candidate.contains(".Use(") || candidate.contains("dependencies=") || candidate.contains(".With(") else { continue }
            if let hit = code(candidate).firstMatch(of: auth) { return found("\(hit.0) for the router", at: index + 1) }
        }
        return nil
    }
}
