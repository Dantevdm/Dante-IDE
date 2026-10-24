import Foundation

/// What a job may do on its own. Every job is kept to its worktree and branch: it never
/// pushes, tags, merges, switches branches, publishes or deploys, whatever the approval level.
/// In away mode it also goes ahead without asking for edits inside its worktree that the
/// project's rules don't flag, and for building, testing, linting and committing.
public enum JobGuard {
    public enum Verdict: Equatable, Sendable {
        case approve
        /// Wait for the person, with why when it isn't the usual reason.
        case ask
        case refuse(String)
    }

    /// The verdict for a job as it stands: refusals always, then once away time is up every
    /// step waits (questions are answered as usual), else away mode or the approval level.
    public static func verdict(for job: JobRecord, toolName: String, input: JSONValue, hasNote: Bool, now: Date = Date()) -> Verdict? {
        let verdict = verdict(toolName: toolName, input: input, worktree: job.worktreeURL, away: job.isAway, hasNote: hasNote,
                              commands: job.commands ?? [])
        if case .refuse = verdict { return verdict }
        if job.outOfTime(at: now) { return ApprovalPolicy.questionTools.contains(toolName) ? nil : .ask }
        return verdict
    }

    /// nil when the job's usual approval level should decide.
    public static func verdict(toolName: String, input: JSONValue, worktree: URL, away: Bool, hasNote: Bool, commands: [String] = []) -> Verdict? {
        if Hands.Tool.of(mcpName: toolName) != nil {
            return .refuse("Jobs don't use Hands (apps, the keyboard and mouse); only the main conversation can, with the person watching.")
        }
        if toolName == "Bash", let command = input["command"]?.string {
            if let reason = forbidden(command) { return .refuse(reason) }
            guard away else { return nil }
            return !hasNote && runsUnattended(command, also: commands, worktree: worktree) ? .approve : .ask
        }
        if ApprovalPolicy.editTools.contains(toolName) {
            for path in paths(in: input) where !inside(path, worktree) {
                return .refuse("Jobs only change files in their own worktree (\(worktree.path)); \(path) is outside it.")
            }
            guard away else { return nil }
            return hasNote || paths(in: input).contains(where: ApprovalPolicy.isControlFile) ? .ask : .approve
        }
        // Questions, web access and anything else wait for the person while away.
        return away && !ApprovalPolicy.questionTools.contains(toolName) ? .ask : nil
    }

    /// Environment for a job's agent: every push URL is rewritten to a scheme git doesn't know,
    /// so `git push` fails even from a script the job wrote (`npm test` running a push).
    /// Fetching still works.
    public static let noPush: [String: String] = [
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "url.dante-job-cannot-push:.pushInsteadOf",
        "GIT_CONFIG_VALUE_0": "",
    ]

    /// What the agent is told when a step is refused, so it doesn't read it as the command
    /// failing and try another way round.
    public static func toAgent(_ reason: String) -> String {
        "Dante refused this before it ran: it's a rule for jobs, not an error in the command, so don't retry it or find another way to do it. \(reason) Carry on without it, and say at the end what's left for the person."
    }

    /// Why a command is off limits for a job, if it is.
    public static func forbidden(_ command: String) -> String? {
        let plain = withPlainMessages(command)
        // Commands the approval rules can't split (substitutions) are cut at every separator
        // instead: more cautious, which is right for refusing.
        for part in ApprovalPolicy.commandParts(plain) ?? roughParts(plain) {
            var words = part.split(whereSeparator: \.isWhitespace).map { unquoted(String($0)) }.filter { !$0.contains("=") || $0.hasPrefix("-") }
            // `env git push`, `command git push`, `/usr/bin/git push`: the program that runs.
            while let first = words.first, wrappers.contains((first as NSString).lastPathComponent) {
                words.removeFirst()
                while let option = words.first, option.hasPrefix("-") { words.removeFirst() }
            }
            guard let program = words.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
            let rest = Array(words.dropFirst())
            // A shell or eval running a string: check the string itself.
            if ["sh", "bash", "zsh", "dash", "fish", "ksh"].contains(program), let flag = rest.firstIndex(where: { $0.hasPrefix("-") && $0.contains("c") }) {
                let script = unquoted(rest[(flag + 1)...].joined(separator: " "))
                if let reason = forbidden(script) { return reason }
                continue
            }
            if program == "eval", let reason = forbidden(unquoted(rest.joined(separator: " "))) { return reason }
            switch program {
            case "git":
                if part.range(of: #"-c\s+['"]?alias\."#, options: .regularExpression) != nil { return "Jobs don’t make git aliases." }
                var index = 0
                var sub = ""
                while index < rest.count {
                    let word = rest[index]
                    // `-c key=value` lost its value with the other assignments above.
                    if word == "-c" { index += 1; continue }
                    if ["-C", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"].contains(word) {
                        index += 2
                        continue
                    }
                    if word.hasPrefix("-") { index += 1; continue }
                    sub = word
                    break
                }
                switch sub {
                case "push", "send-pack": return "Jobs don’t push. Dante merges the branch when you accept the job."
                case "config" where rest.contains { $0.hasPrefix("alias.") || $0.contains("pushinsteadof") || $0.contains("pushInsteadOf") }:
                    return "Jobs don’t change how git pushes or add aliases."
                case "tag" where rest.count > 1 && !rest.contains("-l") && !rest.contains("--list"):
                    return "Jobs don’t make tags."
                case "merge", "rebase", "cherry-pick", "pull":
                    return "Jobs stay on their own branch; merging is Dante’s job when you accept it."
                case "switch", "worktree": return "Jobs stay on their own branch in their own worktree."
                case "checkout" where rest.contains("-b") || rest.contains("-B") || !rest.contains("--"):
                    // `git checkout -- file` restores a file; anything else moves the branch.
                    return "Jobs stay on their own branch in their own worktree."
                case "branch" where rest.contains { ["-d", "-D", "-m", "-M", "--delete", "--move", "-f", "--force"].contains($0) }:
                    return "Jobs don’t rename or delete branches."
                case "reset" where rest.contains("--hard"): return "Jobs don’t reset with --hard; ask the person instead."
                case "update-ref", "symbolic-ref", "filter-branch", "filter-repo", "replace":
                    // Refs are shared by every worktree: these would move the main checkout's branch.
                    return "Jobs don’t rewrite branches or history outside their own commits."
                case "fetch" where rest.contains(where: { !$0.hasPrefix("-") && $0.contains(":") }):
                    return "Jobs fetch without refspecs: `fetch <remote> a:b` writes another branch."
                default: break
                }
            case "gh", "glab":
                if let sub = rest.first, ["pr", "mr", "release", "repo", "workflow", "api", "secret", "variable", "ci"].contains(sub) {
                    return "Jobs don’t act on GitHub or GitLab; Dante opens pull requests when you accept the job."
                }
                if rest.first == "run", let action = rest.dropFirst().first, ["rerun", "cancel", "delete"].contains(action) {
                    return "Jobs only read CI runs; rerunning or cancelling them is for the person."
                }
            case "npm", "pnpm", "yarn", "cargo", "twine", "gem", "pod", "poetry", "dotnet":
                if rest.contains("publish") || rest.contains("push") || rest.first == "trunk" { return "Jobs don’t publish packages." }
            case "docker", "podman":
                if rest.first == "push" { return "Jobs don’t push images." }
            case "kubectl", "helm", "terraform", "tofu", "pulumi", "flyctl", "fly", "vercel", "netlify", "heroku", "firebase", "serverless", "sls", "cdk", "eb":
                return "Jobs don’t deploy or change infrastructure."
            case "aws", "gcloud", "az":
                return "Jobs don’t touch cloud accounts."
            default: break
            }
        }
        return nil
    }

    /// Programs that run the rest of the line: looked through to the program they run.
    static let wrappers: Set<String> = ["env", "command", "nohup", "time", "sudo", "exec", "xargs", "nice", "caffeinate"]

    static func unquoted(_ word: String) -> String {
        var text = word
        while let first = text.first, let last = text.last, text.count >= 2, first == last, first == "\"" || first == "'" {
            text = String(text.dropFirst().dropLast())
        }
        return text.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
    }

    /// Building, testing, linting, formatting and local commits: safe to run unattended in a
    /// worktree. Commands that substitute or redirect never are, and nor is `cd` out of the
    /// worktree (into the main checkout, say).
    /// `also` adds a job type's own commands, each matched word by word from the start.
    public static func runsUnattended(_ command: String, also extra: [String] = [], worktree: URL? = nil) -> Bool {
        let command = withPlainMessages(command)
        guard let parts = ApprovalPolicy.commandParts(command), !parts.isEmpty else { return false }
        if let worktree {
            for part in parts {
                let words = part.split(whereSeparator: \.isWhitespace).map { unquoted(String($0)) }
                guard words.first == "cd" || words.first == "pushd" else { continue }
                guard let target = words.dropFirst().first, target != "-", !target.hasPrefix("~"), inside(target, worktree) else { return false }
            }
        }
        if ApprovalPolicy.readsOnly(command) { return true }
        let allowed = extra.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }.filter { !$0.isEmpty }
        return parts.allSatisfy { part in
            let words = part.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = words.first else { return true }
            if allowed.contains(where: { words.starts(with: $0) }) { return true }
            let second = words.dropFirst().first ?? ""
            let third = words.dropFirst(2).first ?? ""
            switch first {
            case "cd", "true", "echo", "mkdir": return true
            case "swift": return ["build", "test", "format"].contains(second)
            case "go": return ["build", "test", "vet", "fmt"].contains(second)
            case "cargo": return ["build", "test", "check", "clippy", "fmt"].contains(second)
            case "npm", "pnpm", "yarn", "bun":
                return second == "test" || (second == "run" && ["test", "lint", "build", "typecheck", "check", "format"].contains(third))
            case "npx": return ["tsc", "eslint", "prettier", "vitest", "jest"].contains(second)
            case "pytest", "ruff", "mypy", "black", "eslint", "tsc", "gofmt", "rustfmt", "swiftlint", "swift-format", "jest", "vitest": return true
            case "python", "python3": return second == "-m" && ["pytest", "doctest", "unittest", "mypy", "ruff", "compileall"].contains(third)
            case "make": return ["test", "check", "lint", "build", "fmt", "format"].contains(second)
            case "git": return ["add", "commit", "status", "diff", "log", "show", "restore"].contains(second)
            default: return false
            }
        }
    }

    /// Claude Code writes commit messages as `-m "$(cat <<'EOF' … EOF)"`. A heredoc with a
    /// quoted delimiter, or without `$` and backquotes, is only text, so it becomes `message`.
    static func withPlainMessages(_ command: String) -> String {
        guard command.contains("<<") else { return command }
        let text = command as NSString
        var result = command
        for match in heredoc.matches(in: command, range: NSRange(location: 0, length: text.length)).reversed() {
            let quoted = match.range(at: 1).length > 0
            let body = text.substring(with: match.range(at: 3))
            guard quoted || !(body.contains("$") || body.contains("`")),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: "message")
        }
        return result
    }

    private static let heredoc = try! NSRegularExpression(pattern: #"\$\(\s*cat\s*<<-?\s*(['"]?)(\w+)\1[ \t]*\n([\s\S]*?)\n[ \t]*\2[ \t]*\n?\s*\)"#)

    static func roughParts(_ command: String) -> [String] {
        var parts = [command]
        for separator in ["&&", "||", ";", "|", "&", "\n", "$(", "`", "<(", "(", ")"] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func paths(in input: JSONValue) -> [String] {
        if let changes = input["changes"]?.array { return changes.compactMap { $0["path"]?.string } }
        return [input["file_path"]?.string, input["notebook_path"]?.string, input["path"]?.string].compactMap { $0 }
    }

    static func inside(_ path: String, _ worktree: URL) -> Bool {
        let file = path.hasPrefix("/") ? URL(filePath: path) : worktree.appending(path: path)
        let url = file.standardizedFileURL.resolvingSymlinksInPath().path
        let root = worktree.standardizedFileURL.resolvingSymlinksInPath().path
        return url == root || url.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
