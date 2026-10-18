import Foundation

/// A package the project depends on, read from its lockfile or manifest.
public struct Dependency: Hashable, Sendable {
    /// OSV's ecosystem names: npm, PyPI, Go, crates.io, RubyGems, Packagist, SwiftURL.
    public var ecosystem: String
    public var name: String
    public var version: String
    /// The file it was read from.
    public var file: String

    public init(ecosystem: String, name: String, version: String, file: String) {
        self.ecosystem = ecosystem
        self.name = name
        self.version = version
        self.file = file
    }
}

/// Reads dependencies from lockfiles, so advisories match exact versions.
public enum Dependencies {
    public static func read(root: URL, files: [String]) -> [Dependency] {
        var found: [Dependency] = []
        for path in files where isLockfile(path) {
            guard let text = try? String(contentsOf: root.appending(path: path), encoding: .utf8) else { continue }
            found += parse(text, file: path)
        }
        var seen = Set<String>()
        return found.filter { seen.insert("\($0.ecosystem)|\($0.name)|\($0.version)").inserted }
    }

    static func isLockfile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "go.mod", "requirements.txt", "poetry.lock", "Pipfile.lock",
                "Cargo.lock", "Gemfile.lock", "composer.lock", "Package.resolved"].contains(name) && !path.contains("node_modules/")
    }

    public static func parse(_ text: String, file: String) -> [Dependency] {
        switch (file as NSString).lastPathComponent {
        case "package-lock.json": packageLock(text, file: file)
        case "yarn.lock": yarnLock(text, file: file)
        case "pnpm-lock.yaml": pnpmLock(text, file: file)
        case "go.mod": goMod(text, file: file)
        case "requirements.txt": requirements(text, file: file)
        case "poetry.lock", "Cargo.lock": tomlPackages(text, file: file, ecosystem: file.hasSuffix("Cargo.lock") ? "crates.io" : "PyPI")
        case "Pipfile.lock": pipfileLock(text, file: file)
        case "Gemfile.lock": gemfileLock(text, file: file)
        case "composer.lock": composerLock(text, file: file)
        case "Package.resolved": packageResolved(text, file: file)
        default: []
        }
    }

    static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    static func packageLock(_ text: String, file: String) -> [Dependency] {
        guard let root = object(text) else { return [] }
        if let packages = root["packages"] as? [String: [String: Any]] {
            return packages.compactMap { key, value -> Dependency? in
                guard !key.isEmpty, let version = value["version"] as? String, value["link"] as? Bool != true else { return nil }
                let name = value["name"] as? String ?? key.components(separatedBy: "node_modules/").last ?? key
                return Dependency(ecosystem: "npm", name: name, version: version, file: file)
            }.sorted { $0.name < $1.name }
        }
        var found: [Dependency] = []
        func walk(_ dependencies: [String: Any]?) {
            for (name, value) in dependencies ?? [:] {
                guard let value = value as? [String: Any], let version = value["version"] as? String else { continue }
                found.append(Dependency(ecosystem: "npm", name: name, version: version, file: file))
                walk(value["dependencies"] as? [String: Any])
            }
        }
        walk(root["dependencies"] as? [String: Any])
        return found.sorted { $0.name < $1.name }
    }

    static func yarnLock(_ text: String, file: String) -> [Dependency] {
        var found: [Dependency] = []
        var names: [String] = []
        for line in text.split(separator: "\n") {
            if !line.hasPrefix(" "), !line.hasPrefix("#"), line.hasSuffix(":") {
                // "lodash@^4.17.0", "@scope/pkg@npm:^1.0.0":
                names = line.dropLast().split(separator: ",").map { spec in
                    let trimmed = spec.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                    let at = trimmed.dropFirst().firstIndex(of: "@") ?? trimmed.endIndex
                    return String(trimmed[..<at])
                }
            } else if let name = names.first, line.trimmingCharacters(in: .whitespaces).hasPrefix("version") {
                let version = line.split(separator: " ", omittingEmptySubsequences: true).last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\":")) } ?? ""
                found.append(Dependency(ecosystem: "npm", name: name, version: version, file: file))
                names = []
            }
        }
        return found
    }

    static func pnpmLock(_ text: String, file: String) -> [Dependency] {
        var found: [Dependency] = []
        var inPackages = false
        for line in text.split(separator: "\n") {
            if !line.hasPrefix(" ") { inPackages = line.hasPrefix("packages:"); continue }
            guard inPackages, line.hasPrefix("  "), !line.hasPrefix("   "), line.hasSuffix(":") else { continue }
            // "  /lodash@4.17.21:", "  '@scope/pkg@1.0.0(peer@2)':"
            var key = line.trimmingCharacters(in: .whitespaces).dropLast().trimmingCharacters(in: CharacterSet(charactersIn: "'\"/"))
            if let paren = key.firstIndex(of: "(") { key = String(key[..<paren]) }
            guard let at = key.dropFirst().lastIndex(of: "@") else { continue }
            found.append(Dependency(ecosystem: "npm", name: String(key[..<at]), version: String(key[key.index(after: at)...]), file: file))
        }
        return found
    }

    static func goMod(_ text: String, file: String) -> [Dependency] {
        var found: [Dependency] = []
        var inBlock = false
        for raw in text.split(separator: "\n") {
            let line = raw.split(separator: "//").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if line.hasPrefix("require (") { inBlock = true; continue }
            if inBlock, line == ")" { inBlock = false; continue }
            let parts = line.split(separator: " ").map(String.init)
            if inBlock, parts.count >= 2 {
                found.append(Dependency(ecosystem: "Go", name: parts[0], version: parts[1], file: file))
            } else if parts.first == "require", parts.count >= 3 {
                found.append(Dependency(ecosystem: "Go", name: parts[1], version: parts[2], file: file))
            }
        }
        return found
    }

    static func requirements(_ text: String, file: String) -> [Dependency] {
        text.split(separator: "\n").compactMap { raw in
            let line = raw.split(separator: "#").first?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let range = line.range(of: "==") else { return nil }
            let name = line[..<range.lowerBound].split(separator: "[").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let version = line[range.upperBound...].split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return name.isEmpty || version.isEmpty ? nil : Dependency(ecosystem: "PyPI", name: name, version: version, file: file)
        }
    }

    static func tomlPackages(_ text: String, file: String, ecosystem: String) -> [Dependency] {
        var found: [Dependency] = []
        var name: String?
        var version: String?
        func flush() {
            if let name, let version { found.append(Dependency(ecosystem: ecosystem, name: name, version: version, file: file)) }
            name = nil
            version = nil
        }
        for line in text.split(separator: "\n") {
            if line.hasPrefix("[[package]]") { flush(); continue }
            if line.hasPrefix("[") { flush(); continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            guard parts.count == 2 else { continue }
            if parts[0] == "name" { name = parts[1] }
            if parts[0] == "version" { version = parts[1] }
        }
        flush()
        return found
    }

    static func pipfileLock(_ text: String, file: String) -> [Dependency] {
        guard let root = object(text) else { return [] }
        return ["default", "develop"].flatMap { section in
            (root[section] as? [String: [String: Any]] ?? [:]).compactMap { name, value -> Dependency? in
                (value["version"] as? String).map { Dependency(ecosystem: "PyPI", name: name, version: $0.replacingOccurrences(of: "==", with: ""), file: file) }
            }
        }.sorted { $0.name < $1.name }
    }

    static func gemfileLock(_ text: String, file: String) -> [Dependency] {
        var found: [Dependency] = []
        var inSpecs = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces) == "specs:" { inSpecs = true; continue }
            if !line.hasPrefix(" ") { inSpecs = false; continue }
            // Exactly four spaces: a gem, not one of its requirements.
            guard inSpecs, line.hasPrefix("    "), !line.hasPrefix("     "),
                  let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")") else { continue }
            let name = line[..<open].trimmingCharacters(in: .whitespaces)
            let version = String(line[line.index(after: open)..<close])
            found.append(Dependency(ecosystem: "RubyGems", name: name, version: version, file: file))
        }
        return found
    }

    static func composerLock(_ text: String, file: String) -> [Dependency] {
        guard let root = object(text) else { return [] }
        return ["packages", "packages-dev"].flatMap { key in
            (root[key] as? [[String: Any]] ?? []).compactMap { package in
                guard let name = package["name"] as? String, let version = package["version"] as? String else { return nil }
                return Dependency(ecosystem: "Packagist", name: name, version: version.hasPrefix("v") ? String(version.dropFirst()) : version, file: file)
            }
        }
    }

    static func packageResolved(_ text: String, file: String) -> [Dependency] {
        guard let root = object(text) else { return [] }
        let pins = root["pins"] as? [[String: Any]] ?? ((root["object"] as? [String: Any])?["pins"] as? [[String: Any]] ?? [])
        return pins.compactMap { pin in
            guard let location = pin["location"] as? String ?? pin["repositoryURL"] as? String,
                  let version = (pin["state"] as? [String: Any])?["version"] as? String else { return nil }
            let name = location.hasSuffix(".git") ? String(location.dropLast(4)) : location
            return Dependency(ecosystem: "SwiftURL", name: name, version: version, file: file)
        }
    }
}

/// OSV.dev, Google's open vulnerability database: one batch query for every dependency, then
/// the details of each advisory found. Only package names and versions are sent.
public struct OSV: Sendable {
    public var base: URL
    public init(base: URL = URL(string: "https://api.osv.dev")!) { self.base = base }

    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public func findings(for dependencies: [Dependency], detailLimit: Int = 80) async throws -> [SecurityFinding] {
        guard !dependencies.isEmpty else { return [] }
        var hits: [(Dependency, [String])] = []
        for chunk in stride(from: 0, to: dependencies.count, by: 500).map({ Array(dependencies[$0..<min($0 + 500, dependencies.count)]) }) {
            var request = URLRequest(url: base.appending(path: "v1/querybatch"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.batchBody(chunk)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: "OSV.dev answered \((response as? HTTPURLResponse)?.statusCode ?? 0).") }
            hits += zip(chunk, Self.batchIDs(data)).filter { !$0.1.isEmpty }
        }
        var details: [String: [String: Any]] = [:]
        for id in Array(Set(hits.flatMap(\.1))).sorted().prefix(detailLimit) {
            var request = URLRequest(url: base.appending(path: "v1/vulns/\(id)"))
            request.timeoutInterval = 20
            if let (data, _) = try? await URLSession.shared.data(for: request),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                details[id] = object
            }
        }
        return hits.flatMap { dependency, ids in
            Self.preferred(ids).map { id in
                let vuln = details[id] ?? [:]
                return Self.finding(id: id, summary: vuln["summary"] as? String ?? (vuln["details"] as? String).flatMap { AgentJob.gist(of: $0) },
                                    package: dependency.name, version: dependency.version, severity: Self.severity(vuln),
                                    fixed: Self.fixedVersion(vuln, package: dependency.name), file: dependency.file)
            }
        }
    }

    /// One advisory per problem: a GHSA id and its CVE alias are the same thing.
    static func preferred(_ ids: [String]) -> [String] {
        let ghsa = ids.filter { $0.hasPrefix("GHSA") }
        return ghsa.isEmpty ? ids : ghsa + ids.filter { !$0.hasPrefix("GHSA") && !$0.hasPrefix("CVE") }
    }

    static func batchBody(_ dependencies: [Dependency]) -> Data {
        let queries = dependencies.map { ["package": ["name": $0.name, "ecosystem": $0.ecosystem], "version": $0.version] }
        return (try? JSONSerialization.data(withJSONObject: ["queries": queries])) ?? Data()
    }

    static func batchIDs(_ data: Data) -> [[String]] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return [] }
        return results.map { ($0["vulns"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
    }

    static func severity(_ vuln: [String: Any]) -> SecurityFinding.Severity {
        if let label = (vuln["database_specific"] as? [String: Any])?["severity"] as? String { return SecurityToolOutput.severity(label) }
        for affected in vuln["affected"] as? [[String: Any]] ?? [] {
            if let label = (affected["ecosystem_specific"] as? [String: Any])?["severity"] as? String { return SecurityToolOutput.severity(label) }
        }
        return vuln.isEmpty ? .medium : .medium
    }

    static func fixedVersion(_ vuln: [String: Any], package: String) -> String? {
        for affected in vuln["affected"] as? [[String: Any]] ?? [] {
            let name = (affected["package"] as? [String: Any])?["name"] as? String
            guard name == nil || name == package else { continue }
            for range in affected["ranges"] as? [[String: Any]] ?? [] {
                for event in range["events"] as? [[String: Any]] ?? [] {
                    if let fixed = event["fixed"] as? String { return fixed }
                }
            }
        }
        return nil
    }

    static func finding(id: String, summary: String?, package: String, version: String, severity: SecurityFinding.Severity,
                        fixed: String?, file: String) -> SecurityFinding {
        SecurityFinding(
            id: "deps:\(id):\(package)", rule: "deps.\(id)", category: .dependencies, severity: severity,
            title: "\(package) \(version): \(summary ?? id)",
            why: "\(package) \(version) has a published vulnerability (\(id)). Attackers scan for known ones first.",
            fix: fixed.map { "Upgrade \(package) to \($0) or later." } ?? "No fixed version yet: check the advisory for a workaround.",
            file: file, line: 0, evidence: "", reference: id, source: "OSV.dev")
    }
}
