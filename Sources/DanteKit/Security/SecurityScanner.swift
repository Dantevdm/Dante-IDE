import Foundation

/// Dante's own scanner: the rules in `SecurityRules` over every text file, plus checks that
/// look at a whole file (Dockerfiles, workflows) or the repository (committed .env files and
/// keys, unlocked dependencies). Pure: files come in through `read`.
public enum SecurityScanner {
    /// What git knows, for the repository checks. Paths are project-relative.
    public struct GitView: Sendable {
        public var tracked: Set<String>
        public var ignored: Set<String>
        public init(tracked: Set<String>, ignored: Set<String> = []) {
            self.tracked = tracked
            self.ignored = ignored
        }
    }

    /// Larger files are data or bundles, not code.
    public static let sizeLimit = 1_000_000

    /// Scans the project's files. `never` paths (from `project.yaml`) are neither read nor reported.
    public static func scan(files: [String], read: (String) -> String?, git: GitView? = nil,
                            never: (String) -> Bool = { _ in false }) -> [SecurityFinding] {
        var findings: [SecurityFinding] = []
        let vendored = vendoredFolders(files)
        for path in files where !never(path) && isScannable(path) && !isVendored(path, in: vendored) {
            guard let text = read(path) else { continue }
            findings += scan(text: text, path: path)
        }
        findings += repository(files: files.filter { !never($0) }, git: git)
        return sorted(findings)
    }

    public static func sorted(_ findings: [SecurityFinding]) -> [SecurityFinding] {
        findings.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.file != $1.file { return $0.file < $1.file }
            return $0.line < $1.line
        }
    }

    // MARK: One file

    /// The findings in one file's text. Also used on the lines an agent's edit adds.
    public static func scan(text: String, path: String) -> [SecurityFinding] {
        let type = fileType(path)
        let rules = SecurityRules.all.filter { applies($0, to: type) }
        let inTest = isTest(path)
        let isExample = isExampleFile(path)
        var findings: [SecurityFinding] = []
        var seen = Set<String>()
        var lineNumber = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            guard !raw.isEmpty, raw.utf8.count < 2_000 else { continue }
            let line = String(raw)
            if suppressed(line) { continue }
            let comment = isComment(line, type: type)
            for rule in rules {
                if rule.skipsComments && comment { continue }
                if rule.category == .secrets && isExample { continue }
                let range = NSRange(line.startIndex..., in: line)
                guard let match = rule.pattern.firstMatch(in: line, range: range),
                      let matched = Range(match.range, in: line) else { continue }
                if let unless = rule.unless, unless.firstMatch(in: line, range: range) != nil { continue }
                // "password changed by its owner" says what happened; it doesn't log a password.
                if rule.id == "pii.log" {
                    let probe = withoutProse(line)
                    if rule.pattern.firstMatch(in: probe, range: NSRange(probe.startIndex..., in: probe)) == nil { continue }
                }
                if rule.category == .secrets, isPlaceholder(String(line[matched])) { continue }
                if rule.id == "secret.connection", isLocal(line[matched.upperBound...]) { continue }
                var severity = rule.severity
                if inTest && rule.category != .secrets { severity = severity.milder }
                let evidence = Redact.line(line, masking: rule.masks ? matched : nil)
                let finding = SecurityFinding(rule: rule.id, category: rule.category, severity: severity, title: rule.title,
                                              why: rule.why, fix: rule.fix, file: path, line: lineNumber, evidence: evidence,
                                              reference: rule.reference)
                findings.append(numbered(finding, &seen))
            }
            if line.contains(where: \.isNumber) {
                for finding in identityNumbers(in: line, path: path, lineNumber: lineNumber, inTest: inTest) {
                    findings.append(numbered(finding, &seen))
                }
            }
        }
        if type.kinds.contains(.dockerfile) { findings += dockerfile(text, path: path) }
        if type.kinds.contains(.workflow) { findings += workflow(text, path: path) }
        return findings
    }

    /// `nosec`, `dante:ignore`, `nosemgrep` and `gitleaks:allow` on a line leave it alone.
    static func suppressed(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("dante:ignore") || lower.contains("nosec") || lower.contains("nosemgrep") || lower.contains("gitleaks:allow")
    }

    static func isPlaceholder(_ value: String) -> Bool {
        let lower = value.lowercased()
        if SecurityRules.placeholders.contains(where: { lower.contains($0) }) { return true }
        // Made-up values: keyboard runs and the alphabet in order.
        if ["abcdefgh", "bcdefghi", "12345678", "qwertyui", "0123456789"].contains(where: { lower.contains($0) }) { return true }
        if lower.contains("://user:") || lower.contains("://username:") { return true }
        // "xxxxxxxx", "00000000": one character repeated.
        let letters = lower.filter { $0.isLetter || $0.isNumber }
        if let first = letters.first, letters.count >= 6, letters.allSatisfy({ $0 == first }) { return true }
        return false
    }

    /// The same line again further down a file is its own finding, "#2" and on, so each place
    /// shows and an edit that makes one line match another isn't lost in it.
    static func numbered(_ finding: SecurityFinding, _ seen: inout Set<String>) -> SecurityFinding {
        var finding = finding
        let base = finding.id
        var count = 1
        while !seen.insert(finding.id).inserted {
            count += 1
            finding.id = "\(base)#\(count)"
        }
        return finding
    }

    /// The line with prose string literals emptied: a message with spaces and no placeholder
    /// (%s, {name}, ${x}, =) only describes what happened. Keys and format strings stay.
    static func withoutProse(_ line: String) -> String {
        var out = ""
        var literal: String?
        var quote: Character = "\""
        var escaped = false
        for character in line {
            guard var text = literal else {
                if character == "\"" || character == "'" || character == "`" { literal = ""; quote = character }
                out.append(character)
                continue
            }
            if escaped { escaped = false; text.append(character); literal = text; continue }
            if character == "\\" { escaped = true; text.append(character); literal = text; continue }
            if character == quote {
                let prose = text.contains(" ") && !text.contains(where: { "%{=:".contains($0) })
                out += prose ? "" : text
                out.append(character)
                literal = nil
                continue
            }
            text.append(character)
            literal = text
        }
        return out + (literal ?? "")
    }

    /// A connection string's host on this machine: a development setting.
    static func isLocal(_ host: Substring) -> Bool {
        ["localhost", "127.0.0.1", "0.0.0.0", "[::1]", "host.docker.internal"].contains { host.lowercased().hasPrefix($0) }
    }

    static func isComment(_ line: String, type: FileType) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("<!--") { return true }
        if trimmed.hasPrefix("#") { return !["c", "h", "cpp", "m", "mm"].contains(type.ext) || trimmed.hasPrefix("# ") }
        if trimmed.hasPrefix("--") { return type.ext == "sql" || type.ext == "lua" }
        return false
    }


    // MARK: Identity and card numbers

    private static let digitRuns = try! NSRegularExpression(pattern: #"(?<![\w.-])(?:\d[ -]?){12,18}\d(?![\w.-])"#)

    /// South African ID numbers and payment card numbers, checked with their checksums so
    /// ordinary numbers don't count.
    static func identityNumbers(in line: String, path: String, lineNumber: Int, inTest: Bool) -> [SecurityFinding] {
        var findings: [SecurityFinding] = []
        for match in digitRuns.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            guard let range = Range(match.range, in: line) else { continue }
            let raw = String(line[range])
            let digits = raw.filter(\.isNumber)
            let evidence = Redact.line(line, masking: range)
            if digits.count == 13, raw.allSatisfy(\.isNumber), isSouthAfricanID(digits) {
                findings.append(SecurityFinding(
                    rule: "pii.sa-id", category: .privacy, severity: inTest ? .medium : .high, title: "South African ID number",
                    why: "An ID number is personal information under POPIA; in code or fixtures it's copied to every clone and backup.",
                    fix: "Use generated test numbers (Dante can make valid fake ones) or load real ones from the database, encrypted.",
                    file: path, line: lineNumber, evidence: evidence, reference: "POPIA s19"))
            } else if (13...19).contains(digits.count), isCardNumber(digits), !testCards.contains(digits) {
                findings.append(SecurityFinding(
                    rule: "pii.card", category: .privacy, severity: inTest ? .high : .critical, title: "Payment card number",
                    why: "Card numbers fall under PCI DSS and POPIA; storing them in code or logs is a breach on its own.",
                    fix: "Remove it; use your payment provider's test cards and tokens instead of real numbers.",
                    file: path, line: lineNumber, evidence: evidence, reference: "PCI DSS 3.4"))
            }
        }
        return findings
    }

    /// YYMMDD SSSS C A Z: a real date, citizenship 0 or 1, and a Luhn check digit.
    public static func isSouthAfricanID(_ digits: String) -> Bool {
        let numbers = digits.compactMap(\.wholeNumberValue)
        guard numbers.count == 13 else { return false }
        let month = numbers[2] * 10 + numbers[3]
        let day = numbers[4] * 10 + numbers[5]
        guard (1...12).contains(month), (1...31).contains(day), numbers[10] <= 1 else { return false }
        // Runs such as 0101010101010 are filler, not people.
        guard Set(numbers).count > 3 else { return false }
        return luhn(numbers)
    }

    static func isCardNumber(_ digits: String) -> Bool {
        let numbers = digits.compactMap(\.wholeNumberValue)
        guard let first = numbers.first, [2, 3, 4, 5, 6].contains(first), Set(numbers).count > 3 else { return false }
        return luhn(numbers)
    }

    static func luhn(_ numbers: [Int]) -> Bool {
        var sum = 0
        for (index, digit) in numbers.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    /// Payment providers' published test cards.
    static let testCards: Set<String> = [
        "4242424242424242", "4000056655665556", "5555555555554444", "2223003122003222", "5200828282828210", "5105105105105100",
        "378282246310005", "371449635398431", "6011111111111117", "6011000990139424", "3056930009020004", "36227206271667",
        "4111111111111111", "4012888888881881", "4000000000000002", "4000000000009995", "4000002500003155", "4000000000003220",
        "5454545454545454", "4917610000000000", "4988080000000000", "3530111333300000", "6200000000000005",
    ]

    // MARK: Whole files

    static func dockerfile(_ text: String, path: String) -> [SecurityFinding] {
        var findings: [SecurityFinding] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var stages = Set<String>()
        var lastUser: String?
        var lastFrom = 0
        for (index, line) in lines.enumerated() {
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let instruction = words.first?.uppercased() else { continue }
            if instruction == "FROM", words.count >= 2 {
                lastFrom = index + 1
                lastUser = nil
                let name = (words.dropFirst().first { !$0.hasPrefix("--") } ?? "").lowercased()
                // An earlier stage, by its alias, isn't an image.
                let isStage = stages.contains(name)
                if let alias = words.firstIndex(where: { $0.uppercased() == "AS" }), alias + 1 < words.count {
                    stages.insert(words[alias + 1].lowercased())
                }
                if name != "scratch", !isStage, !name.contains("$"), !name.contains("@sha256:") {
                    let tag = name.split(separator: "/").last.flatMap { $0.contains(":") ? $0.split(separator: ":").last.map(String.init) : nil }
                    if tag == nil || tag == "latest" {
                        findings.append(SecurityFinding(
                            rule: "docker.latest", category: .containers, severity: .low, title: "Base image not pinned",
                            why: "Without a fixed tag or digest, each build can pull a different image, including a compromised one.",
                            fix: "Pin a version tag, or better a digest (image@sha256:…).", file: path, line: index + 1,
                            evidence: Redact.line(line), reference: "CWE-829"))
                    }
                }
            } else if instruction == "USER", words.count >= 2 {
                lastUser = words[1]
            }
        }
        if lastFrom > 0 {
            let user = lastUser?.lowercased()
            if user == nil || user == "root" || user == "0" || user?.hasPrefix("0:") == true || user?.hasPrefix("root:") == true {
                findings.append(SecurityFinding(
                    rule: "docker.root", category: .containers, severity: .medium, title: "Container runs as root",
                    why: "If the app is broken into, the attacker is root in the container, a short step from the host.",
                    fix: "Create a user and add `USER app` before the final CMD.", file: path, line: lastFrom,
                    evidence: Redact.line(lines[lastFrom - 1]), reference: "CWE-250"))
            }
        }
        return findings
    }

    static func workflow(_ text: String, path: String) -> [SecurityFinding] {
        guard text.contains("pull_request_target") else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let index = lines.firstIndex(where: { $0.contains("github.event.pull_request.head") || $0.contains("github.head_ref") }) else { return [] }
        return [SecurityFinding(
            rule: "gha.pwn-request", category: .pipelines, severity: .critical, title: "Pull request code runs with your secrets",
            why: "pull_request_target runs with write access and secrets, and this workflow checks out the PR's own code, so anyone opening a PR can run code with them.",
            fix: "Use pull_request for building PR code, or don't check out the PR head in pull_request_target jobs.",
            file: path, line: index + 1, evidence: Redact.line(String(lines[index])), reference: "CWE-829")]
    }

    // MARK: The repository

    static func repository(files: [String], git: GitView?) -> [SecurityFinding] {
        var findings: [SecurityFinding] = []
        let present = Set(files)
        for path in files {
            let name = (path as NSString).lastPathComponent.lowercased()
            if isEnvFile(name) {
                if let git, git.tracked.contains(path) {
                    findings.append(SecurityFinding(
                        rule: "repo.env-committed", category: .secrets, severity: .high, title: "Environment file committed",
                        why: ".env files hold passwords and keys; once committed they stay in the history.",
                        fix: "git rm --cached the file, add it to .gitignore, rotate what's in it, and commit an .env.example instead.",
                        file: path, line: 0, reference: "CWE-538"))
                } else if let git, !git.ignored.contains(path) {
                    findings.append(SecurityFinding(
                        rule: "repo.env-unignored", category: .secrets, severity: .medium, title: "Environment file not ignored",
                        why: "Nothing stops this file from being committed with the next `git add .`.",
                        fix: "Add it to .gitignore.", file: path, line: 0, reference: "CWE-538"))
                }
            }
            if isKeyFile(name), git?.tracked.contains(path) ?? false {
                findings.append(SecurityFinding(
                    rule: "repo.key-file", category: .secrets, severity: .high, title: "Key or certificate store committed",
                    why: "Private keys in the repository can be used by anyone who can clone it.",
                    fix: "Remove it from git, rotate the key, and load it from the Keychain or a secret manager.",
                    file: path, line: 0, reference: "CWE-321"))
            }
            if name == "package.json", !path.contains("node_modules/") {
                let folder = (path as NSString).deletingLastPathComponent
                let locks = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock", "npm-shrinkwrap.json"]
                let locked = locks.contains { present.contains(folder.isEmpty ? $0 : "\(folder)/\($0)") }
                // A workspace package is locked by the root's lockfile.
                let rootLocked = locks.contains { present.contains($0) }
                if !locked, !rootLocked {
                    findings.append(SecurityFinding(
                        rule: "deps.unlocked", category: .dependencies, severity: .low, title: "Dependencies not locked",
                        why: "Without a lockfile every install can pull newer versions, including a hijacked release.",
                        fix: "Commit the lockfile your package manager writes, and install with npm ci or equivalent.",
                        file: path, line: 0, reference: "CWE-829"))
                }
            }
        }
        return findings
    }

    static func isEnvFile(_ name: String) -> Bool {
        guard name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env") else { return false }
        return !["example", "sample", "template", "dist", "defaults", "schema", "test"].contains { name.contains($0) }
    }

    static func isKeyFile(_ name: String) -> Bool {
        if ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"].contains(name) { return true }
        let ext = (name as NSString).pathExtension
        return ["pem", "key", "p12", "pfx", "jks", "keystore", "p8"].contains(ext)
    }

    // MARK: Files

    struct FileType: Equatable {
        var ext: String
        var kinds: Set<LineRule.FileKind>
    }

    static func fileType(_ path: String) -> FileType {
        let name = (path as NSString).lastPathComponent.lowercased()
        var ext = (name as NSString).pathExtension
        var kinds = Set<LineRule.FileKind>()
        if name == "dockerfile" || name.hasPrefix("dockerfile.") || ext == "dockerfile" || name.hasSuffix(".dockerfile") {
            kinds.insert(.dockerfile)
            ext = "dockerfile"
        }
        let yaml = ext == "yml" || ext == "yaml"
        if yaml, name.hasPrefix("docker-compose") || name.hasPrefix("compose") { kinds.insert(.compose) }
        if yaml, path.hasPrefix(".github/workflows/") || path.contains("/.github/workflows/") { kinds.insert(.workflow) }
        if ext == "tf" || ext == "hcl" { kinds.insert(.terraform) }
        if yaml, !kinds.contains(.compose), !kinds.contains(.workflow) { kinds.insert(.kubernetes) }
        if ext == "plist" { kinds.insert(.plist) }
        return FileType(ext: ext, kinds: kinds)
    }

    static func applies(_ rule: LineRule, to type: FileType) -> Bool {
        switch rule.files {
        case .any: true
        case .extensions(let extensions): extensions.contains(type.ext)
        case .kind(let kind): type.kinds.contains(kind)
        }
    }

    /// Text that's worth reading: not binaries, data, bundles, lockfiles or vendored code.
    public static func isScannable(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        if skippedExtensions.contains(ext) { return false }
        if name.hasSuffix(".min.js") || name.hasSuffix(".min.css") || name.hasSuffix(".map") { return false }
        if lockfiles.contains(name) { return false }
        if ["node_modules/", ".git/", "vendor/", ".build/", "deriveddata/", "__pycache__/", ".venv/", "venv/", "site-packages/"]
            .contains(where: { lower.hasPrefix($0) || lower.contains("/" + $0) }) { return false }
        return true
    }

    /// Folders of bundled third-party code: a folder below the root that keeps its own licence,
    /// inside one where apps keep bundled libraries (resources, assets, static, public, lib,
    /// third_party). A monorepo's own packages, which have licences too, don't sit there.
    public static func vendoredFolders(_ files: [String]) -> [String] {
        let licences: Set<String> = ["license", "license.md", "license.txt", "licence", "licence.md", "licence.txt", "copying"]
        let places: Set<String> = ["resources", "assets", "static", "public", "lib", "libs", "third_party", "third-party", "thirdparty", "external", "extern"]
        var folders: Set<String> = []
        for path in files where licences.contains((path as NSString).lastPathComponent.lowercased()) {
            let parts = path.lowercased().split(separator: "/").dropLast()
            guard parts.count >= 2, parts.dropLast().contains(where: { places.contains(String($0)) }) else { continue }
            folders.insert((path as NSString).deletingLastPathComponent + "/")
        }
        return folders.sorted()
    }

    public static func isVendored(_ path: String, in folders: [String]) -> Bool {
        folders.contains { path.hasPrefix($0) }
    }

    static let lockfiles: Set<String> = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "go.sum", "cargo.lock", "poetry.lock",
                                         "pipfile.lock", "gemfile.lock", "composer.lock", "package.resolved", "bun.lockb", "bun.lock"]

    static let skippedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "ico", "icns", "pdf", "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "jar", "war",
        "class", "o", "a", "so", "dylib", "dll", "exe", "bin", "wasm", "ttf", "otf", "woff", "woff2", "mp3", "mp4", "mov", "wav",
        "db", "sqlite", "sqlite3", "parquet", "avro", "csv", "tsv", "xlsx", "xls", "docx", "pptx", "psd", "sketch", "svg",
        "car", "nib", "storyboardc", "metallib", "pyc", "lockb", "snap", "pb",
    ]

    /// Tests, fixtures and examples: problems there are one step milder.
    public static func isTest(_ path: String) -> Bool {
        CodePlace.of(path) != .shipped
    }

    /// Example and template files whose values are meant to be replaced.
    static func isExampleFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return ["example", "sample", "template", ".dist"].contains { name.contains($0) } || name.hasSuffix(".md")
    }
}
