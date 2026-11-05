import DanteKit
import Foundation
import Observation

/// Quality › Review's state for one window: what everyone has read (`CodeReview`), who's
/// reviewing here (git's user.name) and the people who could be asked.
@MainActor
@Observable
final class ReviewModel {
    var coverage: CodeReview.Coverage?
    var policy = CodeReview.Policy()
    var reviewer: String?
    var people: [String] = []
    var loading = false
    var errorMessage: String?
    private var loadedRevision = -1

    /// The repository's pull requests on its git host, read with git's own sign-in.
    var host = HostReview()

    struct HostReview {
        enum Status: Equatable { case unknown, notHosted, loading, failed(BitbucketError), loaded }
        var status: Status = .unknown
        var remote: BitbucketRemote?
        var branch: String?
        var base: String?
        /// The branch's own open pull request, if it has one.
        var current: BitbucketPullRequest?
        var others: [BitbucketPullRequest] = []
        var threads: [BitbucketThread] = []
        var checked: Date?

        /// Open threads per file, for the file rows.
        var openThreads: [String: Int] {
            threads.reduce(into: [:]) { counts, thread in
                if let path = thread.root.path, !thread.resolved { counts[path, default: 0] += 1 }
            }
        }
    }

    /// Reads the branch's pull request, its reviewers and comments from Bitbucket. Network, so
    /// it runs when Review opens (at most every two minutes) and on Check again, not per edit.
    func loadHost(root: URL, force: Bool = false) async {
        if host.status == .loading { return }
        if !force, let checked = host.checked, Date().timeIntervalSince(checked) < 120 { return }
        let origin = await Shell.run(["git", "remote", "get-url", "origin"], in: root, timeout: .seconds(10))
        guard origin.status == 0, let remote = BitbucketRemote.parse(origin.stdout) else {
            host = HostReview(status: .notHosted, checked: Date())
            return
        }
        async let branchRead = Shell.run(["git", "rev-parse", "--abbrev-ref", "HEAD"], in: root, timeout: .seconds(10))
        async let baseRead = Shell.run(["git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: root, timeout: .seconds(10))
        let branch = await branchRead.stdout, base = await baseRead
        var next = host
        next.remote = remote
        next.branch = branch.isEmpty || branch == "HEAD" ? nil : branch
        next.base = base.status == 0 ? base.stdout.replacingOccurrences(of: "origin/", with: "") : nil
        next.status = .loading
        host = next
        guard let signIn = await BitbucketSignIn.borrow(for: remote, in: root) else {
            host.status = .failed(.noSignIn(ssh: remote.isSSH))
            host.checked = Date()
            return
        }
        let client = BitbucketClient(remote: remote, signIn: signIn)
        do throws(BitbucketError) {
            let open = try await client.openPullRequests(branch: nil)
            let current = open.first { $0.source == next.branch }
            next.current = current
            next.others = open.filter { $0.id != current?.id }
            next.threads = []
            if let current { next.threads = BitbucketThread.threads(try await client.comments(of: current.id)) }
            next.status = .loaded
        } catch {
            next.status = .failed(error)
        }
        next.checked = Date()
        host = next
    }

    /// Re-reads the marks and the files' hashes; cheap enough for each workspace revision.
    func load(root: URL, revision: Int, force: Bool = false) async {
        guard force || revision != loadedRevision, !loading else { return }
        loading = true
        defer { loading = false }
        loadedRevision = revision
        let policy = CodeReview.Policy.load(projectRoot: root)
        let log = CodeReview.load(in: root)
        async let blobs = CodeReview.currentBlobs(in: root, policy: policy)
        async let reviewer = CodeReview.reviewer(in: root)
        let current = await blobs
        // A git read that failed (a lock, a busy disk) mustn't blank the page.
        if current.isEmpty, self.coverage?.files.isEmpty == false { return }
        let coverage = CodeReview.coverage(blobs: current, log: log, required: policy.required)
        self.policy = policy
        self.coverage = coverage
        self.reviewer = await reviewer
        if people.isEmpty { people = await CodeReview.people(in: root, log: log) }
    }

    func file(_ path: String) -> CodeReview.FileReview? {
        coverage?.files.first { $0.path == path }
    }

    /// Marks files as read (or raises a concern, or takes the mark back) as they are now.
    func mark(_ paths: [String], _ verdict: CodeReview.Verdict, note: String? = nil, root: URL) async {
        guard let reviewer else {
            errorMessage = "Git doesn't know your name in this repository. Set it with git config user.name, then try again."
            return
        }
        // A few files are hashed as they are on disk now (one just saved from the editor);
        // a whole folder uses the hashes from the last load.
        let known = Dictionary(uniqueKeysWithValues: paths.compactMap { path in file(path).map { (path, $0.blob) } })
        let hashed = await CodeReview.hash(paths.count <= 50 ? paths : paths.filter { known[$0] == nil }, in: root)
        let now = Date()
        let lines = paths.compactMap { path -> String? in
            guard let blob = hashed[path] ?? known[path] else { return nil }
            return CodeReview.line(CodeReview.Mark(path: path, blob: blob, by: reviewer, at: now, verdict: verdict, note: note))
        }
        write(lines, root: root)
        await load(root: root, revision: loadedRevision, force: true)
    }

    /// Asks someone to look at files, folders or everything ("").
    func request(_ paths: [String], of person: String, note: String?, root: URL) async {
        guard let reviewer, let person = person.nonEmptyTrimmed else { return }
        write([CodeReview.line(CodeReview.Request(paths: paths, reviewer: person, by: reviewer, at: Date(), note: note))], root: root)
        if !people.contains(where: { $0.caseInsensitiveCompare(person) == .orderedSame }) { people.append(person) }
        await load(root: root, revision: loadedRevision, force: true)
    }

    private func write(_ lines: [String], root: URL) {
        do {
            try CodeReview.append(lines, in: root)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't write \(CodeReview.file): \(error.localizedDescription)"
        }
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let text = trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

extension Session {
    /// The open file's path in the project, when it's one Review counts.
    var activeReviewPath: String? {
        guard let workspace, let document = workspace.activeDocument else { return nil }
        return ReviewView.relative(document.url, to: workspace.git.root)
    }

    /// Git › Mark File as Reviewed (⌃⇧R) and the status bar's chip: marks the open file as read
    /// as it is now, saved first so the mark is on what's on screen; again takes the mark back.
    func toggleReviewedActiveFile() {
        guard let workspace, let path = activeReviewPath else { return }
        if workspace.activeDocument?.isDirty == true { saveActive() }
        let mine = review.reviewer.map { review.file(path)?.reviewed(by: $0) ?? false } ?? false
        Task {
            if review.coverage == nil { await review.load(root: workspace.git.root, revision: workspace.revision) }
            await review.mark([path], mine ? .cleared : .reviewed, root: workspace.git.root)
        }
    }
}
