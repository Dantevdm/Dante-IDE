import Foundation

/// Garbage to throw at routes, and what a response to it gives away. The probes look for
/// injection without doing harm: nothing drops, deletes or updates, so a route that does run
/// one only reads.
public struct FuzzPayload: Equatable, Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case empty, types, overflow, unicode, sql, nosql, script, traversal, template, format, json

        public var label: String {
            switch self {
            case .empty: "Empty and null"
            case .types: "Wrong types"
            case .overflow: "Too long and too big"
            case .unicode: "Odd characters"
            case .sql: "SQL injection"
            case .nosql: "NoSQL injection"
            case .script: "Script injection"
            case .traversal: "Path traversal"
            case .template: "Template injection"
            case .format: "Format strings"
            case .json: "Broken JSON"
            }
        }
    }

    public var kind: Kind
    public var name: String
    public var value: String

    public init(_ kind: Kind, _ name: String, _ value: String) {
        self.kind = kind
        self.name = name
        self.value = value
    }
}

/// Where a payload goes.
public enum FuzzPlace: String, Sendable, Codable {
    case path, query, body
}

public struct FuzzCase: Equatable, Sendable, Identifiable, Codable {
    public var route: BliksemRoute
    public var place: FuzzPlace
    public var payload: FuzzPayload
    public var id: String { route.id + "|" + place.rawValue + "|" + payload.name }
}

/// Something a fuzz response gave away.
public struct FuzzFinding: Equatable, Sendable, Identifiable, Codable {
    public enum Severity: Int, Sendable, Codable, Comparable {
        case low, medium, high, critical
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
        public var label: String { ["Low", "Medium", "High", "Critical"][rawValue] }
    }

    public enum Problem: String, Sendable, Codable {
        case serverError, stackTrace, sqlError, reflected, traversal, template, hang, dropped, slow

        public var title: String {
            switch self {
            case .serverError: "Crashes with a server error"
            case .stackTrace: "Shows a stack trace"
            case .sqlError: "Shows a database error"
            case .reflected: "Echoes a script back unescaped"
            case .traversal: "Serves files outside its folder"
            case .template: "Runs template expressions"
            case .hang: "Hangs"
            case .dropped: "Drops the connection"
            case .slow: "Slows right down"
            }
        }

        public var advice: String {
            switch self {
            case .serverError: "Check the input and answer 400 with a reason instead of letting the error escape."
            case .stackTrace: "Turn off detailed errors outside development and log the trace instead of returning it."
            case .sqlError: "The input reached the query as text: use parameters, and don't return database errors."
            case .reflected: "Escape output for HTML, or answer JSON with the right content type."
            case .traversal: "Resolve the path and refuse anything outside the folder it should serve from."
            case .template: "Never render user input as a template; pass it as data."
            case .hang: "Bound the work a request can cause: limits on sizes, depth and time."
            case .dropped: "The server process may have crashed on this input: check its logs."
            case .slow: "Limit input sizes, and check what this input makes the code do."
            }
        }
    }

    public var route: String
    public var problem: Problem
    public var severity: Severity
    /// What was sent, short: "query: ' OR '1'='1".
    public var sent: String
    /// The status, or "no answer".
    public var answer: String
    /// The line of the body that gave it away, cut short.
    public var evidence: String?
    /// How many cases found the same problem on the same route.
    public var count: Int = 1

    public var id: String { route + "|" + problem.rawValue }
}

public enum Fuzz {
    /// The XSS probe's marker; reflected only when echoed back unescaped.
    static let marker = "dante7bliksem"

    public static let payloads: [FuzzPayload] = [
        .init(.empty, "empty", ""),
        .init(.empty, "null", "null"),
        .init(.empty, "undefined", "undefined"),
        .init(.types, "negative", "-1"),
        .init(.types, "zero", "0"),
        .init(.types, "float", "1.5e308"),
        .init(.types, "huge number", "99999999999999999999999999"),
        .init(.types, "boolean", "true"),
        .init(.types, "array", "[1,2]"),
        .init(.overflow, "10k characters", String(repeating: "A", count: 10_000)),
        .init(.unicode, "emoji and right-to-left", "😀\u{202E}ñ漢字"),
        .init(.unicode, "null byte", "a\u{0000}b"),
        .init(.unicode, "newlines", "a\r\nX-Dante: 1"),
        .init(.sql, "quote", "'\""),
        .init(.sql, "or true", "' OR '1'='1"),
        .init(.sql, "union", "1 UNION SELECT NULL--"),
        .init(.nosql, "operator", "{\"$gt\":\"\"}"),
        .init(.nosql, "where", "';return true;'"),
        .init(.script, "script tag", "<script>\(marker)</script>"),
        .init(.script, "attribute", "\"><img src=x onerror=\(marker)>"),
        .init(.traversal, "dot dot", "../../../../../../etc/passwd"),
        .init(.traversal, "encoded", "..%2f..%2f..%2f..%2fetc%2fpasswd"),
        .init(.template, "curly", "{{1337*1337}}"),
        .init(.template, "dollar", "${1337*1337}"),
        .init(.format, "printf", "%s%s%s%x%d"),
    ]

    /// Bodies for routes that take one, sent as JSON.
    public static let bodies: [FuzzPayload] = [
        .init(.json, "empty body", ""),
        .init(.json, "cut off", "{\"a\":"),
        .init(.json, "not an object", "\"text\""),
        .init(.json, "array", "[]"),
        .init(.json, "null", "null"),
        .init(.types, "wrong types", "{\"id\":\"x\",\"amount\":\"lots\",\"quantity\":-1,\"email\":12,\"items\":{\"a\":1},\"date\":\"yesterday\"}"),
        .init(.overflow, "deep nesting", String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)),
        .init(.overflow, "1 MB string", "{\"name\":\"" + String(repeating: "A", count: 1_000_000) + "\"}"),
        .init(.sql, "injection in fields", "{\"id\":\"1' OR '1'='1\",\"name\":\"'\\\"\",\"email\":\"a@b.test'--\"}"),
        .init(.nosql, "operators in fields", "{\"id\":{\"$gt\":\"\"},\"email\":{\"$ne\":null}}"),
        .init(.script, "script in fields", "{\"name\":\"<script>\(marker)</script>\"}"),
        .init(.template, "template in fields", "{\"name\":\"{{1337*1337}}\"}"),
    ]

    /// Query parameters most APIs read.
    static let queryNames = ["id", "q", "page", "limit", "sort", "filter"]

    /// Cases for each route: its parameters, its query and, when asked for writes, its body.
    public static func cases(for routes: [BliksemRoute], includeWrites: Bool, kinds: Set<FuzzPayload.Kind> = Set(FuzzPayload.Kind.allCases)) -> [FuzzCase] {
        var cases: [FuzzCase] = []
        for route in routes where route.isRead || includeWrites {
            for payload in payloads where kinds.contains(payload.kind) {
                if !route.parameters.isEmpty { cases.append(.init(route: route, place: .path, payload: payload)) }
                if route.isRead { cases.append(.init(route: route, place: .query, payload: payload)) }
            }
            if route.takesBody {
                for payload in bodies where kinds.contains(payload.kind) { cases.append(.init(route: route, place: .body, payload: payload)) }
            }
        }
        return cases
    }

    /// The request for a case. Path parameters get the payload; other parameters sample values.
    public static func request(_ fuzz: FuzzCase, base: URL, timeout: TimeInterval) -> URLRequest? {
        let unreserved = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127))).union(CharacterSet(charactersIn: "-._~"))
        let encode: (String) -> String = { $0.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        let path: String
        var query: String?
        switch fuzz.place {
        case .path:
            // Already-encoded probes go as they are, so the server decodes them once.
            let value = fuzz.payload.name == "encoded" ? fuzz.payload.value : encode(fuzz.payload.value)
            path = fuzz.route.filled { _ in value.isEmpty ? "%20" : value }
        case .query:
            path = fuzz.route.samplePath
            query = queryNames.map { "\($0)=\(encode(fuzz.payload.value))" }.joined(separator: "&")
        case .body:
            path = fuzz.route.samplePath
        }
        guard let url = BliksemTarget.url(base, path: path, query: query) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = fuzz.route.method
        request.setValue("Dante Bliksem", forHTTPHeaderField: "User-Agent")
        if fuzz.place == .body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(fuzz.payload.value.utf8)
        }
        return request
    }

    static let stackTrace = [
        #"at [\w$.<>]+\([\w$]+\.(java|kt|scala):\d+\)"#,
        #"Traceback \(most recent call last\)"#,
        #"\bat .+ \(.+\.(js|ts|mjs|cjs):\d+:\d+\)"#,
        #"goroutine \d+ \[running\]"#,
        #"\bpanic: "#,
        #"System\.\w+Exception"#,
        #"\.cs:line \d+"#,
        #"Exception in thread ""#,
        #"File "[^"]+\.py", line \d+"#,
        #"\.rb:\d+:in `"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static let sqlError = [
        #"SQL syntax"#, #"syntax error at or near"#, #"unterminated quoted string"#, #"SQLSTATE\["#, #"\bORA-\d{5}"#,
        #"sqlite3?\.OperationalError"#, #"SQLITE_ERROR"#, #"PSQLException"#, #"\bpq: "#, #"ER_PARSE_ERROR"#,
        #"Unclosed quotation mark"#, #"quoted string not properly terminated"#, #"JDBCException"#, #"SQLGrammarException"#,
        #"MongoServerError"#, #"Microsoft OLE DB"#, #"PG::SyntaxError"#,
    ].map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    /// The line a pattern matched, cut short.
    static func match(_ patterns: [NSRegularExpression], in body: String) -> String? {
        let ns = body as NSString
        for pattern in patterns {
            guard let found = pattern.firstMatch(in: body, range: NSRange(location: 0, length: min(ns.length, 200_000))) else { continue }
            let line = ns.lineRange(for: found.range)
            return String(ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        }
        return nil
    }

    /// What a response to a case gives away, if anything.
    /// - Parameters:
    ///   - status: nil when no answer came; `error` then says why ("timed out").
    ///   - baselineStatus: the route's answer to a plain request, so a route that's already
    ///     broken isn't blamed on the payload.
    public static func classify(_ fuzz: FuzzCase, status: Int?, error: String? = nil, contentType: String? = nil,
                                body: String, duration: Double, timeout: Double, baselineStatus: Int? = nil) -> FuzzFinding? {
        let sent = "\(fuzz.place.rawValue): " + shown(fuzz.payload)
        func finding(_ problem: FuzzFinding.Problem, _ severity: FuzzFinding.Severity, _ evidence: String? = nil) -> FuzzFinding {
            FuzzFinding(route: fuzz.route.id, problem: problem, severity: severity, sent: sent,
                        answer: status.map(String.init) ?? (error ?? "no answer"), evidence: evidence)
        }
        guard let status else {
            if error == "timed out" { return finding(.hang, .medium, "No answer within \(Int(timeout)) s") }
            return finding(.dropped, .high, error)
        }
        if body.contains("root:x:0:0") || body.contains("root:*:0:0") { return finding(.traversal, .critical, match([try! NSRegularExpression(pattern: "root:.:0:0")], in: body)) }
        if let line = match(sqlError, in: body) { return finding(.sqlError, fuzz.payload.kind == .sql || fuzz.payload.kind == .nosql ? .critical : .high, line) }
        // Only on errors: a page can name its own scripts' files and lines.
        if status >= 400, let line = match(stackTrace, in: body) { return finding(.stackTrace, .high, exceptionLine(body) ?? line) }
        if fuzz.payload.kind == .template, body.contains("1787569") { return finding(.template, .critical, "1337×1337 came back worked out: 1787569") }
        if fuzz.payload.kind == .script, body.contains("<script>\(marker)") || body.contains("onerror=\(marker)") {
            let html = contentType?.lowercased().contains("html") ?? false
            return finding(.reflected, html ? .high : .low, html ? "Echoed into an HTML page" : "Echoed back, though not as HTML")
        }
        if status >= 500, baselineStatus.map({ $0 < 500 }) ?? true { return finding(.serverError, .high, firstLine(body)) }
        if duration > min(5, timeout * 0.6) { return finding(.slow, .medium, "Took \(BliksemStats.time(duration))") }
        return nil
    }

    /// Findings merged by route and problem, worst first.
    public static func merged(_ findings: [FuzzFinding]) -> [FuzzFinding] {
        var byID: [String: FuzzFinding] = [:]
        var order: [String] = []
        for finding in findings {
            if var existing = byID[finding.id] {
                existing.count += 1
                if finding.severity > existing.severity { existing.severity = finding.severity; existing.sent = finding.sent; existing.evidence = finding.evidence }
                byID[finding.id] = existing
            } else {
                byID[finding.id] = finding
                order.append(finding.id)
            }
        }
        return order.compactMap { byID[$0] }.sorted { ($0.severity, $1.route) > ($1.severity, $0.route) }
    }

    /// A payload as text a person can read: long ones shortened, invisible characters named.
    static func shown(_ payload: FuzzPayload) -> String {
        if payload.value.isEmpty { return "(\(payload.name))" }
        if payload.value.count > 60 { return "(\(payload.name))" }
        return payload.value.replacingOccurrences(of: "\u{0000}", with: "\\0").replacingOccurrences(of: "\r\n", with: "\\r\\n")
            .replacingOccurrences(of: "\u{202E}", with: "\\u202E")
    }

    static let exception = try! NSRegularExpression(pattern: #"^\s*(?:[\w$.]+(?:Error|Exception)\b[:\s(].*|panic: .*)$"#, options: .anchorsMatchLines)

    /// The line naming the exception ("ValueError: invalid literal…"), which says more than
    /// "Traceback (most recent call last):". Python puts it last, Java and Go first.
    static func exceptionLine(_ body: String) -> String? {
        let ns = body as NSString
        let matches = exception.matches(in: body, range: NSRange(location: 0, length: min(ns.length, 200_000)))
        let pick = body.contains("Traceback (most recent call last)") ? matches.last : matches.first
        return pick.map { String(ns.substring(with: $0.range).trimmingCharacters(in: .whitespaces).prefix(160)) }
    }

    static func firstLine(_ body: String) -> String? {
        let line = body.split(whereSeparator: \.isNewline).first.map { String($0.prefix(160)) }
        return line?.isEmpty == false ? line : nil
    }
}
