import Foundation
import Security

// MARK: Runs, whichever service ran them

/// Where a pipeline runs: production, somewhere before it, or not known.
public enum PipelineEnvironment: String, Codable, Sendable, CaseIterable, Comparable {
    case nonProd, prod, other

    public var title: String {
        switch self {
        case .nonProd: "Non-prod"
        case .prod: "Prod"
        case .other: "Other"
        }
    }

    public static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }

    /// From a pipeline's name, file or stage names: "cd-nonprod", "RolloutNonProd" and
    /// "uat" are before production; "prod", "production" and "live" are production.
    public static func classify(_ texts: [String]) -> PipelineEnvironment {
        let words = texts.flatMap(Self.words)
        let joined = words.joined()
        if joined.contains("nonprod") || joined.contains("preprod") || joined.contains("nonproduction") { return .nonProd }
        let before: Set<String> = ["dev", "develop", "development", "test", "testing", "qa", "uat", "sit", "staging", "sandbox", "int", "integration", "np"]
        if words.contains(where: before.contains) { return .nonProd }
        let production: Set<String> = ["prod", "production", "prd", "live"]
        if words.contains(where: production.contains) { return .prod }
        return .other
    }

    /// Lowercased words, split at punctuation and between camel-case humps.
    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if !character.isLetter && !character.isNumber {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                if character.isUppercase, let previous, previous.isLowercase, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }
}

public struct PipelineStage: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// What the YAML calls it (`RolloutNonProd`): the name a retry needs.
    public var identifier: String
    public var name: String
    public var state: PipelineRun.Status

    public init(id: String, identifier: String, name: String, state: PipelineRun.Status) {
        self.id = id
        self.identifier = identifier
        self.name = name
        self.state = state
    }
}

public struct PipelineRun: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case queued, running, succeeded, failed, canceled, partial, skipped

        public var isActive: Bool { self == .queued || self == .running }
        public var title: String {
            switch self {
            case .queued: "Queued"
            case .running: "Running"
            case .succeeded: "Succeeded"
            case .failed: "Failed"
            case .canceled: "Cancelled"
            case .partial: "Partly succeeded"
            case .skipped: "Skipped"
            }
        }
    }

    public var id: Int
    public var pipeline: String
    public var pipelineID: Int
    /// The pipeline's file in the repo, when the service says.
    public var file: String?
    public var number: String
    public var status: Status
    public var branch: String
    public var commit: String
    /// "a push", "by hand", "a pull request", "a schedule".
    public var reason: String
    public var requestedBy: String
    public var queued: Date?
    public var started: Date?
    public var finished: Date?
    public var url: URL?
    public var environment: PipelineEnvironment
    public var stages: [PipelineStage]

    public init(id: Int, pipeline: String, pipelineID: Int = 0, file: String? = nil, number: String = "", status: Status,
                branch: String = "", commit: String = "", reason: String = "", requestedBy: String = "",
                queued: Date? = nil, started: Date? = nil, finished: Date? = nil, url: URL? = nil,
                environment: PipelineEnvironment? = nil, stages: [PipelineStage] = []) {
        self.id = id
        self.pipeline = pipeline
        self.pipelineID = pipelineID
        self.file = file
        self.number = number
        self.status = status
        self.branch = branch
        self.commit = commit
        self.reason = reason
        self.requestedBy = requestedBy
        self.queued = queued
        self.started = started
        self.finished = finished
        self.url = url
        self.environment = environment ?? PipelineEnvironment.classify([pipeline, file ?? ""])
        self.stages = stages
    }

    /// How long it ran, or has been running.
    public func duration(now: Date = .now) -> TimeInterval? {
        guard let started = started ?? queued else { return nil }
        return (finished ?? now).timeIntervalSince(started)
    }

    public var failedStage: PipelineStage? { stages.first { $0.state == .failed } }
}

extension PipelineRun {
    /// A GitHub Actions run as a pipeline run (no stages; `gh run view --log-failed` has the log).
    public init(_ run: CIRun) {
        let finished: Status = switch run.conclusion {
        case "success": .succeeded
        case "failure", "timed_out", "startup_failure": .failed
        case "cancelled": .canceled
        case "skipped": .skipped
        default: .partial
        }
        let status: Status = run.isRunning ? (run.status == "queued" ? .queued : .running) : finished
        self.init(id: run.id, pipeline: run.workflow, number: "\(run.id)", status: status, branch: run.branch,
                  reason: run.title, queued: run.created, started: run.created, url: run.url)
    }
}

// MARK: Azure DevOps

/// An Azure DevOps repository, from its git remote, or pipelines named by links someone
/// pasted (when the code lives elsewhere and Azure DevOps only builds it).
public struct AzureDevOpsRemote: Equatable, Sendable {
    public var organization: String
    public var project: String
    public var repository: String
    /// Pipelines picked by link: only these are read. Empty means every pipeline building
    /// `repository`.
    public var definitions: [Int] = []

    public init(organization: String, project: String, repository: String, definitions: [Int] = []) {
        self.organization = organization
        self.project = project
        self.repository = repository
        self.definitions = definitions
    }

    /// A pipeline's page: `…/_build?definitionId=12` (the classic and the new pages),
    /// `…/_build/results?buildId=…&definitionId=12`, on dev.azure.com or org.visualstudio.com.
    /// A link without a pipeline id gives the project's pipelines.
    public static func link(_ text: String) -> AzureDevOpsRemote? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func decoded(_ part: Substring) -> String { String(part).removingPercentEncoding ?? String(part) }
        var parts = url.path.split(separator: "/")
        let organization: String
        if host == "dev.azure.com" {
            guard !parts.isEmpty else { return nil }
            organization = decoded(parts.removeFirst())
        } else if host.hasSuffix(".visualstudio.com") {
            organization = String(host.dropLast(".visualstudio.com".count))
            parts.removeAll { $0.lowercased() == "defaultcollection" }
        } else {
            return nil
        }
        guard let project = parts.first, !project.hasPrefix("_") else { return nil }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }) { a, _ in a }
        let definition = (query["definitionid"] ?? query["pipelineid"]).flatMap { Int($0) }
        return AzureDevOpsRemote(organization: organization, project: decoded(project), repository: "", definitions: definition.map { [$0] } ?? [])
    }

    /// The run a link points at (`…/_build/results?buildId=345`), whose pipeline Dante looks up.
    public static func linkedRun(_ text: String) -> Int? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return components.queryItems?.first { $0.name.lowercased() == "buildid" }?.value.flatMap { Int($0) }
    }

    /// The same project with another linked pipeline.
    public func adding(_ other: AzureDevOpsRemote) -> AzureDevOpsRemote {
        var merged = self
        merged.definitions = Array(Set(definitions + other.definitions)).sorted()
        return merged
    }

    /// `https://[user@]dev.azure.com/org/project/_git/repo`, `https://org.visualstudio.com/[DefaultCollection/]project/_git/repo`
    /// or `git@ssh.dev.azure.com:v3/org/project/repo`.
    public static func parse(_ remote: String) -> AzureDevOpsRemote? {
        let text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        func decoded(_ part: Substring) -> String { String(part).removingPercentEncoding ?? String(part) }
        if text.contains("ssh.dev.azure.com") {
            guard let range = text.range(of: "v3/") else { return nil }
            let parts = text[range.upperBound...].split(separator: "/")
            guard parts.count >= 3 else { return nil }
            return AzureDevOpsRemote(organization: decoded(parts[0]), project: decoded(parts[1]), repository: decoded(parts[2]).replacingOccurrences(of: ".git", with: ""))
        }
        guard let url = URL(string: text), let host = url.host?.lowercased() else { return nil }
        var parts = url.path.split(separator: "/").map { $0 }
        guard let git = parts.firstIndex(of: "_git"), git + 1 < parts.count else { return nil }
        let repository = decoded(parts[git + 1])
        parts = Array(parts[..<git])
        if host == "dev.azure.com" {
            guard parts.count >= 2 else { return nil }
            return AzureDevOpsRemote(organization: decoded(parts[0]), project: decoded(parts[1]), repository: repository)
        }
        if host.hasSuffix(".visualstudio.com") {
            let organization = String(host.dropLast(".visualstudio.com".count))
            parts.removeAll { $0.lowercased() == "defaultcollection" }
            guard let project = parts.first else { return nil }
            return AzureDevOpsRemote(organization: organization, project: decoded(project), repository: repository)
        }
        return nil
    }

    public var base: URL {
        URL(string: "https://dev.azure.com")!.appending(path: organization).appending(path: project)
    }

    /// Where a person makes a token for Dante.
    public var tokensPage: URL { URL(string: "https://dev.azure.com")!.appending(path: organization).appending(path: "_usersSettings/tokens") }
    public var pipelinesPage: URL { base.appending(path: "_build") }
}

public enum AzureDevOps {
    /// Pipelines whose YAML lives in this repository, or the ones picked by link: id → (name, file).
    public static func definitions(_ data: Data, repository: String, only picked: [Int] = []) -> [Int: (name: String, file: String?)] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["value"] as? [[String: Any]] else { return [:] }
        var result: [Int: (name: String, file: String?)] = [:]
        for value in values {
            guard let id = value["id"] as? Int, let name = value["name"] as? String else { continue }
            if !picked.isEmpty {
                if !picked.contains(id) { continue }
            } else if repository.isEmpty {
                // A project picked by link without a pipeline: all of them.
            } else if let repo = (value["repository"] as? [String: Any])?["name"] as? String, repo.lowercased() != repository.lowercased() { continue }
            result[id] = (name, (value["process"] as? [String: Any])?["yamlFilename"] as? String)
        }
        return result
    }

    /// Builds, newest first.
    public static func runs(_ data: Data, files: [Int: String] = [:]) -> [PipelineRun] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["value"] as? [[String: Any]] else { return [] }
        return values.compactMap { value -> PipelineRun? in
            guard let id = value["id"] as? Int, let definition = value["definition"] as? [String: Any],
                  let name = definition["name"] as? String else { return nil }
            let pipelineID = definition["id"] as? Int ?? 0
            let reason: String = switch value["reason"] as? String ?? "" {
            case "individualCI", "batchedCI": "a push"
            case "manual": "by hand"
            case "pullRequest": "a pull request"
            case "schedule": "a schedule"
            case "resourceTrigger", "buildCompletion": "another pipeline"
            case let other: other
            }
            let web = ((value["_links"] as? [String: Any])?["web"] as? [String: Any])?["href"] as? String
            return PipelineRun(
                id: id, pipeline: name, pipelineID: pipelineID, file: files[pipelineID], number: value["buildNumber"] as? String ?? "\(id)",
                status: status(state: value["status"] as? String, result: value["result"] as? String),
                branch: (value["sourceBranch"] as? String ?? "").replacingOccurrences(of: "refs/heads/", with: ""),
                commit: value["sourceVersion"] as? String ?? "", reason: reason,
                requestedBy: (value["requestedFor"] as? [String: Any])?["displayName"] as? String ?? "",
                queued: date(value["queueTime"]), started: date(value["startTime"]), finished: date(value["finishTime"]),
                url: web.flatMap(URL.init(string:)))
        }
        .sorted { ($0.queued ?? .distantPast) > ($1.queued ?? .distantPast) }
    }

    /// A build's timeline: its stages in order, and what failed with the log to read.
    public static func timeline(_ data: Data) -> (stages: [PipelineStage], failures: [PipelineFailure]) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = json["records"] as? [[String: Any]] else { return ([], []) }
        var byID: [String: [String: Any]] = [:]
        for record in records { if let id = record["id"] as? String { byID[id] = record } }
        func ofType(_ type: String) -> [[String: Any]] {
            records.filter { $0["type"] as? String == type }.sorted { ($0["order"] as? Int ?? 0) < ($1["order"] as? Int ?? 0) }
        }
        let stages = ofType("Stage").map { record in
            PipelineStage(id: record["id"] as? String ?? "", identifier: record["identifier"] as? String ?? record["name"] as? String ?? "",
                          name: record["name"] as? String ?? "", state: status(state: record["state"] as? String, result: record["result"] as? String))
        }
        // The failed tasks (else jobs), each under its stage.
        func ancestor(_ record: [String: Any], type: String) -> [String: Any]? {
            var current = record
            while let parent = current["parentId"] as? String, let next = byID[parent] {
                if next["type"] as? String == type { return next }
                current = next
            }
            return nil
        }
        let failedTasks = ofType("Task").filter { $0["result"] as? String == "failed" }
        let failed = failedTasks.isEmpty ? ofType("Job").filter { $0["result"] as? String == "failed" } : failedTasks
        let failures = failed.map { record in
            let issues = (record["issues"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "error" }
                .compactMap { $0["message"] as? String }
            return PipelineFailure(stage: ancestor(record, type: "Stage")?["name"] as? String ?? "",
                                   job: (record["type"] as? String == "Job" ? record : ancestor(record, type: "Job"))?["name"] as? String ?? "",
                                   step: record["type"] as? String == "Task" ? record["name"] as? String ?? "" : "",
                                   issues: issues,
                                   logURL: ((record["log"] as? [String: Any])?["url"] as? String).flatMap(URL.init(string:)))
        }
        return (stages, failures)
    }

    static func status(state: String?, result: String?) -> PipelineRun.Status {
        switch state {
        case "notStarted", "pending", "postponed": return .queued
        case "inProgress", "cancelling": return .running
        default: break
        }
        return switch result {
        case "succeeded", "succeededWithIssues": .succeeded
        case "partiallySucceeded": .partial
        case "failed": .failed
        case "canceled", "abandoned": .canceled
        case "skipped": .skipped
        default: state == "completed" ? .succeeded : .queued
        }
    }

    /// ISO 8601 with up to seven fractional digits, as Azure DevOps writes them.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let whole = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: whole)
    }
}

// MARK: Talking to Azure DevOps

/// Azure DevOps over its REST API, signed in with Microsoft (a bearer token) or with a personal
/// access token (Build: Read & execute) kept in the Keychain. Never on a command line.
public struct AzureDevOpsClient: Sendable {
    public var remote: AzureDevOpsRemote
    var authorization: String

    public init(remote: AzureDevOpsRemote, token: String) {
        self.remote = remote
        authorization = "Basic " + Data(":\(token)".utf8).base64EncodedString()
    }

    /// With an access token from Microsoft sign-in.
    public init(remote: AzureDevOpsRemote, bearer: String) {
        self.remote = remote
        authorization = "Bearer " + bearer
    }

    public enum Failure: Error, Equatable, Sendable {
        case unauthorised, notFound, failed(String)

        public var message: String {
            switch self {
            case .unauthorised: "Azure DevOps refused the sign-in. A token needs Build (Read & execute) for this organisation and may have expired; a Microsoft account needs access to the project."
            case .notFound: "Azure DevOps doesn't know this project, or the token can't see it."
            case .failed(let text): text
            }
        }
    }

    func request(_ path: String, query: [String: String] = [:], method: String = "GET", body: Data? = nil) -> URLRequest {
        var components = URLComponents(url: remote.base.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = (query.merging(["api-version": "7.1"]) { a, _ in a }).sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    func fetch(_ request: URLRequest) async throws(Failure) -> Data {
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch { throw .failed(error.localizedDescription) }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // A bad token gets the sign-in page (203) rather than a 401.
        if code == 401 || code == 403 || code == 203 { throw .unauthorised }
        if code == 404 { throw .notFound }
        guard (200..<300).contains(code) else { throw .failed("Azure DevOps answered \(code).") }
        return data
    }

    /// This repository's pipelines and their latest runs.
    public func runs(top: Int = 40) async throws(Failure) -> [PipelineRun] {
        let definitions = AzureDevOps.definitions(try await fetch(request("_apis/build/definitions", query: ["includeAllProperties": "true"])),
                                                  repository: remote.repository, only: remote.definitions)
        guard !definitions.isEmpty else { return [] }
        let ids = definitions.keys.sorted().map(String.init).joined(separator: ",")
        let data = try await fetch(request("_apis/build/builds", query: ["definitions": ids, "$top": "\(top)", "queryOrder": "queueTimeDescending"]))
        return AzureDevOps.runs(data, files: definitions.compactMapValues(\.file))
    }

    /// Which pipeline a run belongs to.
    public func pipeline(ofRun run: Int) async throws(Failure) -> Int? {
        let data = try await fetch(request("_apis/build/builds/\(run)"))
        return ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["definition"] as? [String: Any])?["id"] as? Int
    }

    public func timeline(of run: Int) async throws(Failure) -> (stages: [PipelineStage], failures: [PipelineFailure]) {
        AzureDevOps.timeline(try await fetch(request("_apis/build/builds/\(run)/timeline")))
    }

    /// A step's log, the last `lines` of it.
    public func log(_ url: URL, lines: Int = 120) async throws(Failure) -> String {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let text = String(decoding: try await fetch(request), as: UTF8.self)
        return PipelineFailure.tail(text, lines: lines)
    }

    /// Runs a stage's failed jobs again.
    public func retry(run: Int, stage: String) async throws(Failure) {
        let body = try? JSONSerialization.data(withJSONObject: ["forceRetryAllJobs": false, "state": "retry"])
        _ = try await fetch(request("_apis/build/builds/\(run)/stages/\(stage)", method: "PATCH", body: body))
    }
}

/// Personal access tokens per Azure DevOps organisation, in the Keychain.
public enum PipelineTokens {
    static let service = "dev.dante.ide.pipelines"

    public static func token(for organization: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: organization.lowercased(),
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    /// Saves a token, or removes it when nil or empty.
    @discardableResult
    public static func set(_ token: String?, for organization: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: organization.lowercased(),
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return true }
        var item = base
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrLabel as String] = "Dante: Azure DevOps token for \(organization)"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

// MARK: Failing, and healing

/// A step that failed, with what the service said and the end of its log.
public struct PipelineFailure: Equatable, Sendable, Codable {
    public var stage: String
    public var job: String
    public var step: String
    public var issues: [String]
    public var logURL: URL?
    public var log = ""

    public init(stage: String, job: String, step: String, issues: [String], logURL: URL? = nil, log: String = "") {
        self.stage = stage
        self.job = job
        self.step = step
        self.issues = issues
        self.logURL = logURL
        self.log = log
    }

    public var place: String { [stage, job, step].filter { !$0.isEmpty }.joined(separator: " › ") }

    /// The first thing worth reading: an error the service reported, else the log's last error line.
    public var headline: String {
        if let issue = issues.first(where: { !$0.contains("exited with code") }) ?? issues.first { return issue }
        return log.split(separator: "\n").last { $0.localizedCaseInsensitiveContains("error") }.map { String($0) } ?? ""
    }

    /// Whether running it again is likely to work: the network, a timeout, a busy service, or
    /// an agent that went away, not the code or the pipeline.
    public var looksTransient: Bool {
        let text = (issues + [log]).joined(separator: "\n").lowercased()
        let signs = ["timed out", "timeout", "connection reset", "econnreset", "could not resolve host", "temporary failure in name resolution",
                     "toomanyrequests", "429", "rate exceeded", "throttl", "503 service unavailable", "502 bad gateway", "tls handshake",
                     "the agent did not connect", "lost communication with the server", "agent was terminated", "no space left on device",
                     "the operation was canceled", "unexpected eof"]
        return signs.contains { text.contains($0) }
    }

    /// The last lines of a log, with timestamps and ANSI colours taken off.
    public static func tail(_ log: String, lines: Int) -> String {
        let all = log.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var text = String(line).replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            if let match = text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z ?"#, options: .regularExpression) { text.removeSubrange(match) }
            return text
        }
        return all.suffix(lines).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum PipelineHeal {
    /// What the agent is asked when a run fails: find out why from the log and the pipeline
    /// file, fix what's in the repo, and say plainly what has to be done elsewhere. It never
    /// runs the pipeline, deploys or pushes: Dante re-runs it when you say.
    public static func brief(_ run: PipelineRun, failures: [PipelineFailure], github: Bool = false) -> String {
        var lines = [
            "The \(run.environment == .other ? "" : run.environment.title.lowercased() + " ")pipeline \"\(run.pipeline)\" failed (run \(run.number) on \(run.branch.isEmpty ? "its branch" : run.branch)\(run.commit.isEmpty ? "" : ", commit \(run.commit.prefix(8))")\(run.reason.isEmpty ? "" : ", started by \(run.reason)")).",
        ]
        if let file = run.file { lines.append("Its definition is \(file) in this repository.") }
        if github { lines.append("Read the failing steps with `gh run view \(run.id) --log-failed`.") }
        for failure in failures.prefix(4) {
            lines.append("")
            lines.append("Failed: \(failure.place.isEmpty ? "a step" : failure.place)")
            for issue in failure.issues.prefix(6) { lines.append("- \(issue)") }
            if !failure.log.isEmpty {
                lines.append("End of its log:")
                lines.append("```")
                lines.append(failure.log)
                lines.append("```")
            }
        }
        lines += [
            "",
            "Heal it:",
            "1. Say in a sentence what went wrong and whether it's the code, the pipeline definition, the environment (a secret, a permission, a missing resource) or a flake that a re-run would fix.",
            "2. If the fix is in this repository, make it, and run whatever checks you can here (build, tests, a lint of the YAML).",
            "3. If it's outside the repository, don't guess: say exactly what someone has to change and where.",
            "4. Don't run, re-run or deploy the pipeline, and don't push: say when it's ready and Dante will offer to commit, push and re-run the failed stage.",
        ]
        if run.environment == .prod { lines.append("This is production: keep the change as small as it can be, and say what it risks.") }
        return lines.joined(separator: "\n")
    }
}

// MARK: History

/// The runs seen in a project, kept per Mac (Application Support/Dante/pipelines) so history
/// goes back further than the service's first page, and what changed between two looks.
public struct PipelineHistory: Codable, Equatable, Sendable {
    public var runs: [PipelineRun] = []
    public static let limit = 300

    public init(runs: [PipelineRun] = []) { self.runs = runs }

    /// Newer looks replace older ones by id; newest first; the oldest go past the limit.
    public func merging(_ fresh: [PipelineRun]) -> PipelineHistory {
        var byID = Dictionary(runs.map { ($0.id, $0) }) { a, _ in a }
        for run in fresh {
            var run = run
            // A list doesn't carry stages; keep the ones the timeline gave.
            if run.stages.isEmpty, let known = byID[run.id] { run.stages = known.stages }
            byID[run.id] = run
        }
        let sorted = byID.values.sorted { ($0.queued ?? .distantPast, $0.id) > ($1.queued ?? .distantPast, $1.id) }
        return PipelineHistory(runs: Array(sorted.prefix(Self.limit)))
    }

    public enum Event: Equatable, Sendable {
        case started(PipelineRun)
        case finished(PipelineRun)
    }

    /// Runs that started or finished since the last look. The first look says nothing.
    public func events(after fresh: [PipelineRun]) -> [Event] {
        guard !runs.isEmpty else { return [] }
        let before = Dictionary(runs.map { ($0.id, $0) }) { a, _ in a }
        let newest = runs.compactMap(\.queued).max() ?? .distantPast
        return fresh.compactMap { run in
            if let old = before[run.id] {
                return old.status.isActive && !run.status.isActive ? .finished(run) : nil
            }
            guard (run.queued ?? .distantPast) >= newest else { return nil }
            return run.status.isActive ? .started(run) : .finished(run)
        }
    }

    /// Where each environment stands: its newest run, its last good one, and how often it works.
    public struct Lane: Equatable, Sendable, Identifiable {
        public var environment: PipelineEnvironment
        public var latest: PipelineRun
        public var lastGood: PipelineRun?
        public var succeeded: Int
        public var finished: Int
        public var typicalDuration: TimeInterval?
        public var id: PipelineEnvironment { environment }
    }

    public var lanes: [Lane] {
        Dictionary(grouping: runs, by: \.environment).compactMap { environment, runs -> Lane? in
            guard let latest = runs.first else { return nil }
            let done = runs.filter { !$0.status.isActive && $0.status != .canceled }.prefix(20)
            let durations = done.filter { $0.status == .succeeded }.compactMap { $0.duration() }.sorted()
            return Lane(environment: environment, latest: latest, lastGood: runs.first { $0.status == .succeeded },
                        succeeded: done.filter { $0.status == .succeeded }.count, finished: done.count,
                        typicalDuration: durations.isEmpty ? nil : durations[durations.count / 2])
        }
        .sorted { $0.environment < $1.environment }
    }

    public static func folder() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Dante/pipelines")
    }

    public static func url(for root: URL, in folder: URL = folder()) -> URL {
        folder.appending(path: "\(root.lastPathComponent)-\(String(SecurityFinding.fnv(root.standardizedFileURL.path), radix: 16)).json")
    }

    public static func load(for root: URL, in folder: URL = folder()) -> PipelineHistory {
        guard let data = try? Data(contentsOf: url(for: root, in: folder)) else { return PipelineHistory() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(PipelineHistory.self, from: data)) ?? PipelineHistory()
    }

    public func save(for root: URL, in folder: URL = folder()) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(self).write(to: Self.url(for: root, in: folder), options: .atomic)
    }
}
