import Foundation

/// A scanner the user may have installed. Dante runs it when it's there and reads its JSON;
/// it never installs one (Settings › Tools shows the command to type).
public struct SecurityTool: Sendable, Identifiable {
    public var name: String
    public var executable: String
    /// What it adds to Dante's own rules.
    public var purpose: String
    public var install: String
    /// Whether it has anything to look at in this project.
    var applies: @Sendable (URL) -> Bool
    var arguments: @Sendable (URL) -> [String]
    var parse: @Sendable (String, URL) -> [SecurityFinding]
    /// Sends the project's dependency list to an online database, so it runs only when
    /// checking online is on.
    public var sendsDependencies = false
    public var id: String { name }

    public static let all: [SecurityTool] = [semgrep, gitleaks, osvScanner, govulncheck, npmAudit, pipAudit]

    static let semgrep = SecurityTool(
        name: "Semgrep", executable: "semgrep", purpose: "Thousands of code rules across languages, with data-flow checks",
        install: "brew install semgrep", applies: { _ in true },
        arguments: { _ in ["scan", "--config", "p/default", "--json", "--quiet", "--metrics", "off", "--timeout", "30", "."] },
        parse: { output, _ in SecurityToolOutput.semgrep(output) })

    static let gitleaks = SecurityTool(
        name: "Gitleaks", executable: "gitleaks", purpose: "Hundreds of secret formats",
        install: "brew install gitleaks", applies: { _ in true },
        arguments: { _ in ["detect", "--no-git", "--source", ".", "--report-format", "json", "--report-path", "/dev/stdout", "--redact", "--no-banner", "--exit-code", "0"] },
        parse: { output, _ in SecurityToolOutput.gitleaks(output) })

    static let osvScanner = SecurityTool(
        name: "OSV-Scanner", executable: "osv-scanner", purpose: "Known vulnerabilities in every lockfile",
        install: "brew install osv-scanner", applies: { _ in true },
        arguments: { _ in ["scan", "source", "-r", "--format", "json", "."] },
        parse: { output, _ in SecurityToolOutput.osvScanner(output) },
        sendsDependencies: true)

    static let govulncheck = SecurityTool(
        name: "govulncheck", executable: "govulncheck", purpose: "Go vulnerabilities your code actually calls",
        install: "go install golang.org/x/vuln/cmd/govulncheck@latest",
        applies: { FileManager.default.fileExists(atPath: $0.appending(path: "go.mod").path) },
        arguments: { _ in ["-json", "./..."] },
        parse: { output, _ in SecurityToolOutput.govulncheck(output) },
        sendsDependencies: true)

    static let npmAudit = SecurityTool(
        name: "npm audit", executable: "npm", purpose: "Advisories for the packages in package-lock.json",
        install: "Comes with Node.js",
        applies: { FileManager.default.fileExists(atPath: $0.appending(path: "package-lock.json").path) },
        arguments: { _ in ["audit", "--json"] },
        parse: { output, _ in SecurityToolOutput.npmAudit(output) },
        sendsDependencies: true)

    static let pipAudit = SecurityTool(
        name: "pip-audit", executable: "pip-audit", purpose: "Advisories for Python requirements",
        install: "brew install pip-audit",
        applies: { FileManager.default.fileExists(atPath: $0.appending(path: "requirements.txt").path) },
        arguments: { _ in ["-f", "json", "-r", "requirements.txt", "--progress-spinner", "off"] },
        parse: { output, _ in SecurityToolOutput.pipAudit(output) },
        sendsDependencies: true)

    /// The tool on the PATH or in the usual install folders.
    public func locate() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var folders = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        folders += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/go/bin", "\(home)/.local/bin", "\(home)/.cargo/bin"]
        return folders.map { "\($0)/\(executable)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs the tool in the project; nil when it doesn't apply or its output can't be read.
    func run(executable path: String, root: URL) async -> [SecurityFinding]? {
        guard applies(root) else { return nil }
        let output = await Shell.run([path] + arguments(root), in: root, trimming: false)
        // Scanners exit non-zero when they find something, so the output decides.
        let text = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("{") || text.hasPrefix("[") else { return nil }
        return parse(text, root).map { finding in
            var finding = finding
            finding.source = name
            return finding
        }
    }
}

/// Readers for each tool's JSON. Pure, so they're tested with saved output.
public enum SecurityToolOutput {
    static func json(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    static func severity(_ text: String?) -> SecurityFinding.Severity {
        switch text?.lowercased() {
        case "critical": .critical
        case "error", "high": .high
        case "warning", "moderate", "medium": .medium
        case "low", "info", "note": .low
        default: .medium
        }
    }

    /// CVSS 3 base score to a severity.
    static func severity(cvss score: Double) -> SecurityFinding.Severity {
        switch score {
        case 9...: .critical
        case 7..<9: .high
        case 4..<7: .medium
        case 0.1..<4: .low
        default: .info
        }
    }

    static func relative(_ path: String) -> String {
        path.hasPrefix("./") ? String(path.dropFirst(2)) : path
    }

    public static func semgrep(_ text: String) -> [SecurityFinding] {
        guard let root = json(text) as? [String: Any], let results = root["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { result in
            guard let rule = result["check_id"] as? String, let path = result["path"] as? String else { return nil }
            let start = result["start"] as? [String: Any]
            let extra = result["extra"] as? [String: Any] ?? [:]
            let metadata = extra["metadata"] as? [String: Any] ?? [:]
            let cwe = (metadata["cwe"] as? [String])?.first ?? metadata["cwe"] as? String
            let message = (extra["message"] as? String ?? rule).trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = extra["lines"] as? String
            let category = categoryFor(rule + " " + (cwe ?? ""))
            return SecurityFinding(
                rule: "semgrep.\(rule.split(separator: ".").last ?? Substring(rule))", category: category,
                severity: severity(metadata["impact"] as? String ?? extra["severity"] as? String),
                title: title(fromRule: String(rule.split(separator: ".").last ?? Substring(rule))), why: message,
                fix: (extra["fix"] as? String).map { "Change it to: \($0)" } ?? "See \(rule) in the Semgrep registry.",
                file: relative(path), line: start?["line"] as? Int ?? 0,
                evidence: lines.map { $0 == "requires login" ? "" : Redact.line($0) } ?? "",
                reference: cwe.flatMap { $0.split(separator: ":").first.map(String.init) })
        }
    }

    public static func gitleaks(_ text: String) -> [SecurityFinding] {
        guard let leaks = json(text) as? [[String: Any]] else { return [] }
        return leaks.compactMap { leak in
            guard let file = leak["File"] as? String else { return nil }
            let rule = leak["RuleID"] as? String ?? "secret"
            return SecurityFinding(
                rule: "gitleaks.\(rule)", category: .secrets, severity: .high,
                title: leak["Description"] as? String ?? "Secret", why: "Gitleaks recognised this as a \(rule) secret.",
                fix: "Revoke it, remove it, and load it from the environment or a secret manager.",
                file: relative(file), line: leak["StartLine"] as? Int ?? 0,
                evidence: Redact.line((leak["Match"] as? String ?? "").replacingOccurrences(of: leak["Secret"] as? String ?? "\u{0}", with: "REDACTED")),
                reference: "CWE-798")
        }
    }

    public static func osvScanner(_ text: String) -> [SecurityFinding] {
        guard let root = json(text) as? [String: Any], let results = root["results"] as? [[String: Any]] else { return [] }
        var findings: [SecurityFinding] = []
        for result in results {
            let source = relative(((result["source"] as? [String: Any])?["path"] as? String).map { ($0 as NSString).lastPathComponent } ?? "")
            for package in result["packages"] as? [[String: Any]] ?? [] {
                let info = package["package"] as? [String: Any] ?? [:]
                let name = info["name"] as? String ?? "?"
                let version = info["version"] as? String ?? "?"
                let groups = package["groups"] as? [[String: Any]] ?? []
                for vuln in package["vulnerabilities"] as? [[String: Any]] ?? [] {
                    let id = vuln["id"] as? String ?? "?"
                    let group = groups.first { ($0["ids"] as? [String])?.contains(id) == true }
                    let score = (group?["max_severity"] as? String).flatMap(Double.init)
                    let label = (vuln["database_specific"] as? [String: Any])?["severity"] as? String
                    let fixed = OSV.fixedVersion(vuln, package: name)
                    findings.append(OSV.finding(id: id, summary: vuln["summary"] as? String, package: name, version: version,
                                                severity: score.map(severity(cvss:)) ?? severity(label), fixed: fixed, file: source))
                }
            }
        }
        return findings
    }

    public static func govulncheck(_ text: String) -> [SecurityFinding] {
        // A stream of JSON objects, one after another.
        var summaries: [String: String] = [:]
        var findings: [SecurityFinding] = []
        var seen = Set<String>()
        for object in JSONStream.objects(text) {
            if let osv = object["osv"] as? [String: Any], let id = osv["id"] as? String {
                summaries[id] = osv["summary"] as? String
            }
            guard let finding = object["finding"] as? [String: Any], let id = finding["osv"] as? String,
                  let trace = finding["trace"] as? [[String: Any]], let first = trace.first else { continue }
            // Only vulnerabilities the code reaches: the trace names a function.
            guard first["function"] != nil, seen.insert(id).inserted else { continue }
            let module = first["module"] as? String ?? "?"
            let position = trace.last?["position"] as? [String: Any]
            let call = trace.last.map { "\($0["package"] as? String ?? "").\($0["function"] as? String ?? "")" } ?? ""
            findings.append(SecurityFinding(
                rule: "deps.\(id)", category: .dependencies, severity: .high,
                title: "\(module) \(first["version"] as? String ?? ""): \(id)",
                why: (summaries[id] ?? "A known vulnerability.") + " Your code calls it (\(call)).",
                fix: (finding["fixed_version"] as? String).map { "Upgrade \(module) to \($0) or later." } ?? "No fixed version yet; avoid the vulnerable call.",
                file: relative((position?["filename"] as? String) ?? "go.mod"), line: position?["line"] as? Int ?? 0,
                evidence: "", reference: id))
        }
        return findings
    }

    public static func npmAudit(_ text: String) -> [SecurityFinding] {
        guard let root = json(text) as? [String: Any], let vulnerabilities = root["vulnerabilities"] as? [String: [String: Any]] else { return [] }
        return vulnerabilities.keys.sorted().compactMap { name in
            guard let vuln = vulnerabilities[name] else { return nil }
            // Advisories are the "via" entries that are objects; strings point at other packages.
            let advisories = (vuln["via"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            guard let advisory = advisories.first else { return nil }
            let fix: String
            if let available = vuln["fixAvailable"] as? [String: Any], let version = available["version"] as? String {
                fix = "Upgrade \(available["name"] as? String ?? name) to \(version)\((available["isSemVerMajor"] as? Bool) == true ? " (a major version)" : "") with npm audit fix."
            } else if vuln["fixAvailable"] as? Bool == true {
                fix = "Run npm audit fix."
            } else {
                fix = "No fix released yet; consider another package."
            }
            let url = advisory["url"] as? String
            return SecurityFinding(
                rule: "deps.npm.\(name)", category: .dependencies, severity: severity(vuln["severity"] as? String),
                title: "\(name) \(vuln["range"] as? String ?? ""): \(advisory["title"] as? String ?? "known vulnerability")",
                why: advisories.count > 1 ? "\(advisories.count) advisories affect this package." : (advisory["title"] as? String ?? ""),
                fix: fix, file: "package-lock.json", line: 0, evidence: "",
                reference: url.map { ($0 as NSString).lastPathComponent } ?? (advisory["cwe"] as? [String])?.first)
        }
    }

    public static func pipAudit(_ text: String) -> [SecurityFinding] {
        guard let root = json(text) as? [String: Any], let dependencies = root["dependencies"] as? [[String: Any]] else { return [] }
        return dependencies.flatMap { dependency -> [SecurityFinding] in
            let name = dependency["name"] as? String ?? "?"
            let version = dependency["version"] as? String ?? "?"
            return (dependency["vulns"] as? [[String: Any]] ?? []).map { vuln in
                let id = vuln["id"] as? String ?? "?"
                let fixes = vuln["fix_versions"] as? [String] ?? []
                return OSV.finding(id: id, summary: (vuln["description"] as? String).flatMap { AgentJob.gist(of: $0) }, package: name,
                                   version: version, severity: .high, fixed: fixes.first, file: "requirements.txt")
            }
        }
    }

    static func categoryFor(_ text: String) -> SecurityFinding.Category {
        let lower = text.lowercased()
        if lower.contains("secret") || lower.contains("hardcoded") || lower.contains("credential") || lower.contains("api key") || lower.contains("cwe-798") { return .secrets }
        if ["personal", "popia", "gdpr", "privacy", "pii", "id number", "identity number", "cwe-532", "cwe-359"].contains(where: lower.contains) { return .privacy }
        if ["encrypt", "plaintext", "plain text", "https", "hsts", "password hash", "cwe-311", "cwe-319"].contains(where: lower.contains) { return .encryption }
        if lower.contains("crypto") || lower.contains("tls") || lower.contains("ssl") || lower.contains("cwe-327") || lower.contains("cwe-295") { return .encryption }
        if lower.contains("dockerfile") || lower.contains("docker-compose") || lower.contains("kubernetes") { return .containers }
        if lower.contains("github-actions") || lower.contains("gitlab") { return .pipelines }
        if lower.contains("terraform") || lower.contains("cloudformation") { return .infrastructure }
        return .code
    }

    /// "detected-sql-injection" → "Detected sql injection".
    static func title(fromRule rule: String) -> String {
        let words = rule.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// Splits concatenated JSON objects (govulncheck's output).
enum JSONStream {
    static func objects(_ text: String) -> [[String: Any]] {
        var objects: [[String: Any]] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                depth -= 1
                if depth == 0, let begin = start,
                   let object = try? JSONSerialization.jsonObject(with: Data(text[begin...index].utf8)) as? [String: Any] {
                    objects.append(object)
                }
            default: break
            }
        }
        return objects
    }
}
