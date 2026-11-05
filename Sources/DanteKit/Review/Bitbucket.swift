import Foundation

/// A repository on Bitbucket Cloud, read from git's remote URL:
/// `https://sam@bitbucket.org/acme/shop.git`, `git@bitbucket.org:acme/shop.git` or
/// `ssh://git@bitbucket.org/acme/shop.git`.
public struct BitbucketRemote: Equatable, Sendable {
    public var workspace: String
    public var repository: String
    /// The user named in an https remote, which picks git's saved sign-in.
    public var user: String?
    public var isSSH: Bool

    public static func parse(_ remote: String) -> BitbucketRemote? {
        let text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        var user: String?
        var path: Substring
        var ssh = false
        if let url = URL(string: text), let scheme = url.scheme, ["https", "http", "ssh"].contains(scheme) {
            guard url.host?.lowercased() == "bitbucket.org" else { return nil }
            ssh = scheme == "ssh"
            user = ssh ? nil : url.user
            path = Substring(url.path)
        } else if let at = text.firstIndex(of: "@"), let colon = text.firstIndex(of: ":"), at < colon {
            // scp-like: git@bitbucket.org:acme/shop.git
            guard text[text.index(after: at)..<colon].lowercased() == "bitbucket.org" else { return nil }
            ssh = true
            path = text[text.index(after: colon)...]
        } else {
            return nil
        }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        var repository = parts[1]
        if repository.hasSuffix(".git") { repository.removeLast(4) }
        guard !parts[0].isEmpty, !repository.isEmpty else { return nil }
        return BitbucketRemote(workspace: parts[0], repository: repository, user: user?.isEmpty == true ? nil : user, isSSH: ssh)
    }

    public var webURL: URL { URL(string: "https://bitbucket.org/\(workspace)/\(repository)")! }

    /// The https URL git keeps a sign-in for: the remote's own when it's https, so the same
    /// saved token git pushes with is the one found.
    public var credentialURL: String {
        "https://\(user.map { "\(Self.escaped($0))@" } ?? "")bitbucket.org/\(workspace)/\(repository).git"
    }

    var apiPath: String { "/2.0/repositories/\(Self.escaped(workspace))/\(Self.escaped(repository))" }

    /// Bitbucket's own page for opening a pull request from a branch, which signs in with the
    /// browser: nothing is written through the API.
    public func newPullRequestURL(source: String, destination: String?) -> URL {
        var components = URLComponents(url: webURL.appending(path: "pull-requests/new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "source", value: source)] + (destination.map { [URLQueryItem(name: "dest", value: $0)] } ?? [])
        return components.url!
    }

    static func escaped(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/@:"))) ?? text
    }
}

/// git's own saved sign-in for a Bitbucket remote, borrowed for one request and kept only in
/// memory: never written, logged or shown. An Atlassian API token or OAuth token goes as a
/// bearer token, an app password with its user name.
public struct BitbucketSignIn: Sendable, CustomStringConvertible {
    let username: String
    let secret: String

    public var description: String { "BitbucketSignIn(hidden)" }

    init(username: String, secret: String) {
        self.username = username
        self.secret = secret
    }

    var usesBasic: Bool { secret.hasPrefix("ATBB") && !username.isEmpty && username != "x-token-auth" }

    var header: String {
        usesBasic ? "Basic " + Data("\(username):\(secret)".utf8).base64EncodedString() : "Bearer \(secret)"
    }

    /// Reads `git credential fill`'s answer: `username=` and `password=` lines.
    static func reading(_ output: String) -> BitbucketSignIn? {
        var username = "", secret = ""
        for line in output.split(separator: "\n") {
            if line.hasPrefix("username=") { username = String(line.dropFirst(9)) }
            if line.hasPrefix("password=") { secret = String(line.dropFirst(9)) }
        }
        return secret.isEmpty ? nil : BitbucketSignIn(username: username, secret: secret)
    }

    /// Asks git's credential helpers for the sign-in git uses with `remote`, never prompting:
    /// no terminal, no askpass, no credential manager window.
    public static func borrow(for remote: BitbucketRemote, in directory: URL) async -> BitbucketSignIn? {
        let environment = Shell.environment(for: directory).merging([
            "GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "never", "GIT_ASKPASS": "/usr/bin/false", "SSH_ASKPASS": "/usr/bin/false",
        ]) { $1 }
        let input = Data("url=\(remote.credentialURL)\n\n".utf8)
        return await Task.detached(priority: .utility) { () -> BitbucketSignIn? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-c", "credential.interactive=never", "credential", "fill"]
            process.currentDirectoryURL = directory
            process.environment = environment
            let out = Pipe(), inPipe = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = inPipe
            do { try process.run() } catch { return nil }
            try? inPipe.fileHandleForWriting.write(contentsOf: input)
            try? inPipe.fileHandleForWriting.close()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return reading(String(decoding: data, as: UTF8.self))
        }.value
    }
}

public struct BitbucketPerson: Equatable, Sendable, Hashable {
    public var name: String
    public var nickname: String?
}

public struct BitbucketParticipant: Equatable, Sendable {
    public enum Verdict: String, Sendable { case approved, changesRequested, none }
    public var person: BitbucketPerson
    public var isReviewer: Bool
    public var verdict: Verdict
}

public struct BitbucketPullRequest: Equatable, Sendable, Identifiable {
    public var id: Int
    public var title: String
    public var state: String
    public var draft: Bool
    public var author: BitbucketPerson
    public var source: String
    public var destination: String
    public var url: URL?
    public var updated: Date?
    public var comments: Int
    public var tasks: Int
    public var participants: [BitbucketParticipant]

    public var reviewers: [BitbucketParticipant] { participants.filter { $0.isReviewer || $0.verdict != .none } }
    public var approvals: Int { participants.count { $0.verdict == .approved } }
    public var changesRequested: Int { participants.count { $0.verdict == .changesRequested } }
}

public struct BitbucketComment: Equatable, Sendable, Identifiable {
    public var id: Int
    public var author: BitbucketPerson
    public var text: String
    public var created: Date?
    /// The file and line it's on (the new side's line, else the old side's); nil for a
    /// comment on the whole pull request.
    public var path: String?
    public var line: Int?
    /// Only on the old side: the line was removed.
    public var onRemovedLine: Bool
    public var parent: Int?
    public var resolved: Bool
    public var url: URL?
}

/// A pull request's comments as threads: a root and its replies, newest thread last.
public struct BitbucketThread: Equatable, Sendable, Identifiable {
    public var root: BitbucketComment
    public var replies: [BitbucketComment]
    public var id: Int { root.id }
    public var resolved: Bool { root.resolved }

    public static func threads(_ comments: [BitbucketComment]) -> [BitbucketThread] {
        let byID = Dictionary(comments.map { ($0.id, $0) }) { first, _ in first }
        func rootID(of comment: BitbucketComment) -> Int {
            var current = comment
            var seen: Set<Int> = [current.id]
            while let parent = current.parent, let next = byID[parent], seen.insert(parent).inserted { current = next }
            return current.id
        }
        var replies: [Int: [BitbucketComment]] = [:]
        for comment in comments where comment.parent != nil {
            let root = rootID(of: comment)
            if root != comment.id { replies[root, default: []].append(comment) }
        }
        return comments.filter { $0.parent == nil || rootID(of: $0) == $0.id }
            .map { BitbucketThread(root: $0, replies: (replies[$0.id] ?? []).sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }) }
            .sorted { ($0.root.created ?? .distantPast) < ($1.root.created ?? .distantPast) }
    }
}

/// Reads Bitbucket Cloud's JSON (API 2.0). Pure, so it's tested with made-up replies.
public enum BitbucketJSON {
    public static func pullRequests(_ data: Data) -> (values: [BitbucketPullRequest], next: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], nil) }
        let values = (object["values"] as? [[String: Any]] ?? []).compactMap(pullRequest)
        return (values, object["next"] as? String)
    }

    public static func comments(_ data: Data) -> (values: [BitbucketComment], next: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], nil) }
        let values = (object["values"] as? [[String: Any]] ?? []).compactMap(comment)
        return (values, object["next"] as? String)
    }

    static func pullRequest(_ value: [String: Any]) -> BitbucketPullRequest? {
        guard let id = value["id"] as? Int else { return nil }
        let participants = (value["participants"] as? [[String: Any]] ?? []).compactMap { item -> BitbucketParticipant? in
            guard let person = person(item["user"]) else { return nil }
            let state = item["state"] as? String
            let verdict: BitbucketParticipant.Verdict = state == "changes_requested" ? .changesRequested
                : (state == "approved" || item["approved"] as? Bool == true) ? .approved : .none
            return BitbucketParticipant(person: person, isReviewer: item["role"] as? String == "REVIEWER", verdict: verdict)
        }
        return BitbucketPullRequest(
            id: id, title: value["title"] as? String ?? "", state: value["state"] as? String ?? "OPEN", draft: value["draft"] as? Bool ?? false,
            author: person(value["author"]) ?? BitbucketPerson(name: "Someone"),
            source: branch(value["source"]), destination: branch(value["destination"]),
            url: html(value), updated: date(value["updated_on"]),
            comments: value["comment_count"] as? Int ?? 0, tasks: value["task_count"] as? Int ?? 0, participants: participants)
    }

    static func comment(_ value: [String: Any]) -> BitbucketComment? {
        guard let id = value["id"] as? Int, value["deleted"] as? Bool != true, value["pending"] as? Bool != true else { return nil }
        let inline = value["inline"] as? [String: Any]
        let to = inline?["to"] as? Int, from = inline?["from"] as? Int
        return BitbucketComment(
            id: id, author: person(value["user"]) ?? BitbucketPerson(name: "Someone"),
            text: ((value["content"] as? [String: Any])?["raw"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            created: date(value["created_on"]), path: inline?["path"] as? String, line: to ?? from, onRemovedLine: to == nil && from != nil,
            parent: (value["parent"] as? [String: Any])?["id"] as? Int, resolved: value["resolution"] is [String: Any], url: html(value))
    }

    static func person(_ value: Any?) -> BitbucketPerson? {
        guard let user = value as? [String: Any] else { return nil }
        let name = user["display_name"] as? String ?? user["nickname"] as? String ?? ""
        return name.isEmpty ? nil : BitbucketPerson(name: name, nickname: user["nickname"] as? String)
    }

    static func branch(_ value: Any?) -> String {
        ((value as? [String: Any])?["branch"] as? [String: Any])?["name"] as? String ?? ""
    }

    static func html(_ value: [String: Any]) -> URL? {
        (((value["links"] as? [String: Any])?["html"] as? [String: Any])?["href"] as? String).flatMap(URL.init(string:))
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

public enum BitbucketError: Error, Equatable, Sendable {
    /// git has no saved https sign-in for the remote (an ssh remote, or none saved).
    case noSignIn(ssh: Bool)
    /// Bitbucket turned the sign-in away for this (401 or 403): a token without pull request scope.
    case refused(Int)
    case notFound
    case failed(String)

    public var explanation: String {
        switch self {
        case .noSignIn(let ssh):
            ssh ? "This repository is reached over ssh, so git has no Bitbucket sign-in Dante can borrow. Pull requests still open in the browser."
                : "git has no saved sign-in for this Bitbucket repository. Push or fetch once from the terminal so git saves one, then check again."
        case .refused(let status):
            "Bitbucket turned down git’s sign-in for reading pull requests (\(status)). An API token needs the read:pullrequest:bitbucket scope; an app password needs Pull requests: Read."
        case .notFound:
            "Bitbucket says this repository isn’t there for git’s sign-in. The token may be for another workspace."
        case .failed(let message):
            "Couldn’t reach Bitbucket: \(message)"
        }
    }
}

/// Reads pull requests and their comments with a borrowed sign-in. Read only: approving,
/// commenting and adding reviewers happen on Bitbucket's own pages.
public struct BitbucketClient: Sendable {
    public var remote: BitbucketRemote
    let signIn: BitbucketSignIn
    /// Ephemeral (nothing cached on disk) and never following a redirect, so the sign-in
    /// can't be carried to another host.
    static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    public init(remote: BitbucketRemote, signIn: BitbucketSignIn) {
        self.remote = remote
        self.signIn = signIn
    }

    /// Open pull requests, the current branch's first when `branch` is given, with their participants.
    public func openPullRequests(branch: String?) async throws(BitbucketError) -> [BitbucketPullRequest] {
        var query = "state=OPEN&pagelen=50&fields=%2Bvalues.participants"
        if let branch {
            let q = "source.branch.name=\"\(branch.replacingOccurrences(of: "\"", with: "\\\""))\""
            query += "&q=" + (q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        }
        let data = try await get(remote.apiPath + "/pullrequests?" + query)
        return BitbucketJSON.pullRequests(data).values
    }

    /// Every comment on a pull request, up to 500.
    public func comments(of id: Int) async throws(BitbucketError) -> [BitbucketComment] {
        var all: [BitbucketComment] = []
        var next: String? = "https://api.bitbucket.org" + remote.apiPath + "/pullrequests/\(id)/comments?pagelen=100"
        var pages = 0
        while let url = next, pages < 5 {
            let page = BitbucketJSON.comments(try await get(absolute: url))
            all += page.values
            next = page.next
            pages += 1
        }
        return all
    }

    func get(_ path: String) async throws(BitbucketError) -> Data {
        try await get(absolute: "https://api.bitbucket.org" + path)
    }

    func get(absolute: String) async throws(BitbucketError) -> Data {
        // Only Bitbucket's API ever gets the sign-in, whatever a `next` link says.
        guard let url = URL(string: absolute), url.scheme == "https", url.host == "api.bitbucket.org" else { throw .failed("an unexpected link") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(signIn.header, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await Self.session.data(for: request) } catch { throw .failed(error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401, 403: throw .refused(status)
        case 404: throw .notFound
        default: throw .failed("Bitbucket answered \(status)")
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
