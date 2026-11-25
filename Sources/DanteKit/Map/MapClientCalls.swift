import Foundation

/// A frontend often reaches its API through a helper of its own: `request('/overview')`, where
/// `request` fetches `` `/api${path}` ``, or an axios instance made with `baseURL: '/api'` and
/// called as `api.get('/overview')`. The paths in those calls carry no `/api`, so they're only
/// found once the helper's prefix is known. Pure.
public struct APIHelpers: Equatable, Sendable {
    /// Helper functions by name, with the prefix they put before the path they're given.
    public var functions: [String: String] = [:]
    /// Prefixes from `baseURL: '/api'`, put before `x.get('/path')` calls in the same files.
    public var baseURLs: [String] = []

    public init(functions: [String: String] = [:], baseURLs: [String] = []) {
        self.functions = functions
        self.baseURLs = baseURLs
    }

    public var isEmpty: Bool { functions.isEmpty && baseURLs.isEmpty }

    /// The helpers defined in a frontend's files.
    public static func find(in texts: [String]) -> APIHelpers {
        var helpers = APIHelpers()
        for text in texts {
            if SystemMap.has(text, "${") {
                let range = NSRange(text.startIndex..., in: text)
                for match in prefixedPath.matches(in: text, range: range) {
                    guard let prefix = Range(match.range(at: 1), in: text).map({ String(text[$0]) }),
                          let variable = Range(match.range(at: 2), in: text).map({ String(text[$0]) }),
                          let before = Range(NSRange(location: 0, length: match.range.location), in: text),
                          let name = enclosingFunction(in: text[before], taking: variable) else { continue }
                    helpers.functions[name] = prefix
                }
            }
            if SystemMap.has(text, "baseURL") {
                let range = NSRange(text.startIndex..., in: text)
                for match in baseURL.matches(in: text, range: range) {
                    if let prefix = Range(match.range(at: 1), in: text).map({ String(text[$0]) }), !helpers.baseURLs.contains(prefix) {
                        helpers.baseURLs.append(prefix)
                    }
                }
            }
        }
        // Fetch's own name, or names so short they match everything, would add noise.
        for name in helpers.functions.keys where ["fetch", "get", "post", "put", "patch", "delete", "url"].contains(name) || name.count < 3 {
            helpers.functions[name] = nil
        }
        return helpers
    }

    /// The paths a file calls through these helpers, with their prefixes.
    public func paths(in text: String) -> [String] {
        guard !isEmpty else { return [] }
        var found: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        if !functions.isEmpty {
            for match in Self.call.matches(in: text, range: range) {
                guard let name = Range(match.range(at: 1), in: text).map({ String(text[$0]) }),
                      let prefix = functions[name],
                      let path = Range(match.range(at: 2), in: text).map({ String(text[$0]) }) else { continue }
                found.append(Self.join(prefix, path))
            }
        }
        if let prefix = baseURLs.first, baseURLs.count == 1 {
            for match in Self.methodCall.matches(in: text, range: range) {
                if let path = Range(match.range(at: 1), in: text).map({ String(text[$0]) }), !path.hasPrefix(prefix + "/") {
                    found.append(Self.join(prefix, path))
                }
            }
        }
        return found
    }

    static func join(_ prefix: String, _ path: String) -> String {
        (prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix) + path
    }

    /// The nearest function header before a template that takes `variable` as its first
    /// parameter: `function request<T>(path`, `const request = async (path`, `request(path: string)`.
    static func enclosingFunction(in text: Substring, taking variable: String) -> String? {
        let tail = String(text.suffix(1500))
        let range = NSRange(tail.startIndex..., in: tail)
        for match in header.matches(in: tail, range: range).reversed() {
            guard let name = [1, 3].lazy.compactMap({ Range(match.range(at: $0), in: tail) }).first.map({ String(tail[$0]) }),
                  let parameter = [2, 4].lazy.compactMap({ Range(match.range(at: $0), in: tail) }).first.map({ String(tail[$0]) }) else { continue }
            if parameter == variable { return name }
        }
        return nil
    }

    /// `` `/api${path}` `` or `` `/api/v1${endpoint}` ``.
    private static let prefixedPath = try! NSRegularExpression(pattern: #"`(/[A-Za-z][\w/-]*?)\$\{\s*([A-Za-z_]\w*)\s*\}"#)
    /// A function's name and first parameter.
    private static let header = try! NSRegularExpression(
        pattern: #"function\s+([A-Za-z_$][\w$]*)\s*(?:<[^>()]*>)?\s*\(\s*([A-Za-z_$][\w$]*)|\b([A-Za-z_$][\w$]*)\s*[:=]\s*(?:async\s*)?(?:<[^>()]*>)?\s*\(\s*([A-Za-z_$][\w$]*)"#)
    private static let baseURL = try! NSRegularExpression(pattern: #"baseURL\s*:\s*["'`](/[A-Za-z][\w/-]*)["'`]"#)
    /// `request('/x')`, `request<User>('/me', …)`.
    private static let call = try! NSRegularExpression(
        pattern: #"\b([A-Za-z_$][\w$]*)\s*(?:<[^()]*?>)?\(\s*["'`](/[A-Za-z][^"'`\s?$]*)"#)
    /// `api.get('/x')`, `http.post<T>('/x', …)`.
    private static let methodCall = try! NSRegularExpression(
        pattern: #"\.(?:get|post|put|patch|delete)\s*(?:<[^()]*?>)?\(\s*["'`](/[A-Za-z][^"'`\s?$]*)"#)
}
