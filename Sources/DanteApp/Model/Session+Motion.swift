import DanteKit
import Foundation

/// Motion pieces: making a new one (folder, manifest, starter scene, project data, then the
/// agent with a production brief), asking for changes, and the project data scenes draw.
extension Session {
    /// Paths a scene may not load: the project's `claude.never` rules.
    var motionRefused: (String) -> Bool {
        let never = workspace?.claudeRules.never ?? []
        return { path in never.contains { ClaudeRules.path(path, matches: $0) } }
    }

    /// The project data a piece asked for, built like the Map's.
    func motionData(_ kinds: [String]) async -> [String: Any]? {
        guard let workspace, !kinds.isEmpty else { return nil }
        let root = workspace.url
        let files = workspace.files
        var system: SystemMap?
        var infra: Infrastructure?
        if kinds.contains("system") {
            if let cache = mapCache, cache.revision == workspace.revision, let cached = cache.system {
                system = cached
            } else {
                let compose = ComposeFile.load(projectRoot: root)
                let read = MapView.reader(root: root)
                system = await Task.detached(priority: .userInitiated) { SystemMap.build(files: files, read: read, compose: compose) }.value
            }
        }
        if kinds.contains("infra") {
            infra = await Task.detached(priority: .userInitiated) {
                Infrastructure.detect(files: files.filter(Infrastructure.isCandidate)) { path in
                    let url = root.appending(path: path)
                    guard ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < 2_000_000 else { return nil }
                    return try? String(contentsOf: url, encoding: .utf8)
                }
            }.value
        }
        var stats: [String: Int] = [:]
        if kinds.contains("stats") {
            stats["files"] = files.count
            stats["code files"] = files.filter(SystemMap.isCode).count
            stats["tests"] = files.filter { SystemMap.isCode($0) && SystemMap.isTest($0) }.count
            let log = await Shell.run(["git", "rev-list", "--count", "HEAD"], in: root)
            if let commits = Int(log.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) { stats["commits"] = commits }
        }
        return MotionData.json(project: workspace.name, system: system, infra: infra, stats: stats)
    }

    /// The agents that make motion pieces here: Claude and Codex, when they're on this Mac.
    /// Local models and the cloud helpers don't: motion design needs a frontier model.
    var motionMakers: [AgentEngine] {
        var makers: [AgentEngine] = []
        if SystemStatus.detect().claudePath != nil { makers.append(.claude) }
        if Self.codexPath != nil, workspace.map({ RemoteRegistry.project(containing: $0.url) == nil }) ?? true { makers.append(.codex) }
        return makers
    }

    /// Writes a new piece and asks `makers` to make it: the agent in charge in the main
    /// conversation, any other in a job of its own making its own version beside it.
    /// Returns the manifest's path.
    @discardableResult
    func createMotion(ask: String, title: String, kind: MotionPiece.Kind, duration: Double, data: [String],
                      answers: [String: MotionQuestions.Answer] = [:], makers: [AgentEngine]? = nil) async -> String? {
        guard let workspace else { return nil }
        let lead = claude?.engine ?? .claude
        let makers = (makers ?? [lead]).filter(motionMakers.contains)
        guard !makers.isEmpty else {
            errorMessage = "Motion pieces need Claude Code or Codex on this Mac."
            return nil
        }
        let name = title.isEmpty ? String(ask.prefix(60)) : title
        let folderPath = MotionPiece.newFolder(for: name, existing: Set(workspace.files))
        var piece = MotionPiece(title: title.isEmpty ? "Untitled" : title, kind: kind,
                                duration: MotionQuestions.length(for: answers) ?? duration, brief: ask, data: data)
        (piece.width, piece.height) = MotionQuestions.size(for: answers)
        if piece.height > piece.width { piece.fps = 30 }
        if kind == .deck { piece.stops = stride(from: 6.0, to: piece.duration, by: 6).map { $0 } }
        let brand = BrandKit.load(name: workspace.name, files: workspace.files) { try? String(contentsOf: workspace.url.appending(path: $0), encoding: .utf8) }
        let projectData = await motionData(data)
        let both = makers.count > 1
        // The lead makes its version here; another agent makes its own in a job.
        let here = makers.contains(lead) ? lead : nil
        let elsewhere = makers.filter { $0 != here }
        var manifest: String?
        if let here {
            do {
                var mine = piece
                mine.maker = here.title
                try Self.scaffold(mine, data: projectData, at: workspace.url.appending(path: folderPath))
            } catch {
                errorMessage = "Couldn’t create \(folderPath): \(error.localizedDescription)"
                return nil
            }
            workspace.refreshFileIndex()
            manifest = folderPath + "/" + MotionPiece.manifestName
            area = .docs
            docPath = manifest
            let note = both ? "Two versions are being made at once: this is \(here.title)'s; \(elsewhere.map(\.title).joined(separator: " and ")) makes another in a job. Make yours your own." : nil
            askClaude(MotionBrief.create(ask: ask, folder: folderPath, piece: piece, brand: brand, data: projectData, libraries: MotionLibrary.all.map(\.briefLine),
                                         answers: answers, version: note))
        }
        for engine in elsewhere {
            let jobFolder = here == nil ? folderPath : "\(folderPath)-\(engine.rawValue)"
            let note = both ? "Two versions are being made at once: this is \(engine.title)'s, in a job; \(lead.title) makes another in the main checkout. Make yours your own." : nil
            let brief = MotionBrief.create(ask: ask, folder: jobFolder, piece: piece, brand: brand, data: projectData, libraries: MotionLibrary.all.map(\.briefLine),
                                           answers: answers, version: note)
            var theirs = piece
            theirs.maker = engine.title
            let job = await jobs.start(brief: brief, engine: engine, title: "\(engine.title)'s \(piece.title == "Untitled" ? "motion piece" : piece.title)") { [theirs] worktree in
                try Self.scaffold(theirs, data: projectData, at: worktree.appending(path: jobFolder))
            }
            if let job {
                if here == nil { showJob(job.id) }
            } else {
                errorMessage = jobs.startFailure ?? jobs.unavailable ?? "\(engine.title)'s version couldn’t start."
                jobs.clearStartFailure()
            }
        }
        return manifest
    }

    /// A new piece's folder: manifest, starter scene, project data, and renders kept out of git.
    nonisolated static func scaffold(_ piece: MotionPiece, data: [String: Any]?, at folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try piece.yaml.write(to: folder.appending(path: MotionPiece.manifestName), atomically: true, encoding: .utf8)
        try MotionStarter.html(title: piece.title).write(to: folder.appending(path: "index.html"), atomically: true, encoding: .utf8)
        try "renders/\n".write(to: folder.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        if let data {
            let json = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: folder.appending(path: MotionData.fileName))
        }
    }

    /// Every version of the piece at `folder`: this checkout's, a sibling another agent made
    /// here (`<folder>-codex` after its job merged), and those still in jobs' worktrees.
    func motionVersions(of folder: String) -> [MotionVersion] {
        guard let workspace else { return [] }
        let base = MotionVersion.base(of: folder)
        var versions: [MotionVersion] = []
        func add(_ url: URL, root: URL, job: JobRecord?) {
            let manifest = url.appending(path: MotionPiece.manifestName)
            guard FileManager.default.fileExists(atPath: manifest.path), !versions.contains(where: { $0.folder == url }) else { return }
            let piece = MotionPiece.parse((try? String(contentsOf: manifest, encoding: .utf8)) ?? "")
            let maker = piece.maker.isEmpty ? job?.engine.title ?? MotionVersion.suffixMaker(url.lastPathComponent) ?? "" : piece.maker
            versions.append(MotionVersion(folder: url, root: root, maker: maker, job: job?.id, jobTitle: job?.title))
        }
        let candidates = [base] + AgentEngine.allCases.map { "\(base)-\($0.rawValue)" }
        for candidate in candidates { add(workspace.url.appending(path: candidate), root: workspace.url, job: nil) }
        for job in jobs.records where job.outcome == .open {
            for candidate in candidates { add(job.worktreeURL.appending(path: candidate), root: job.worktreeURL, job: job) }
        }
        return versions.count > 1 ? versions : []
    }

    /// Makes `version` the piece at `folder` in this checkout: the files there now go to the
    /// Trash (renders stay), and the version's are copied in.
    func adoptMotion(_ version: MotionVersion, into folder: String) {
        guard let workspace else { return }
        let target = workspace.url.appending(path: folder)
        guard version.folder.standardizedFileURL != target.standardizedFileURL else { return }
        let manager = FileManager.default
        do {
            for file in (try? manager.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent != "renders" {
                try manager.trashItem(at: file, resultingItemURL: nil)
            }
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
            for file in try manager.contentsOfDirectory(at: version.folder, includingPropertiesForKeys: nil) where file.lastPathComponent != "renders" {
                try manager.copyItem(at: file, to: target.appending(path: file.lastPathComponent))
            }
        } catch {
            errorMessage = "Couldn’t use \(version.maker.isEmpty ? "that" : version.maker + "’s") version: \(error.localizedDescription)"
        }
        workspace.refreshFileIndex()
    }

    /// The agent that critiques a version: the other one when it's here, else the same one
    /// with fresh eyes (a read-only question, outside the conversation).
    func motionCritic(for version: MotionVersion?) -> AgentEngine? {
        let available = motionMakers
        let maker = AgentEngine.allCases.first { $0.title == version?.maker } ?? claude?.engine ?? .claude
        return available.first { $0 != maker } ?? available.first
    }

    /// Asks the critic to review the piece in `folder` (a version's own folder, under `root`):
    /// stills of its beats on a contact sheet, the lint, and a read-only question.
    func critiqueMotion(source: MotionSource, maker: String) async {
        guard motionCritiques[source.folder]?.isRunning != true else { return }
        let version = MotionVersion(folder: source.folder, root: source.projectRoot, maker: maker, job: nil, jobTitle: nil)
        guard let critic = motionCritic(for: version) else {
            motionCritiques[source.folder] = .failed("A critique needs Claude Code or Codex on this Mac.")
            return
        }
        motionCritiques[source.folder] = .running(critic: critic.title, since: .now)
        let root = source.projectRoot
        let relative = ProposedChange.relativePath(of: source.folder, in: root)
        let started = Date()
        let ledger = AgentLedger.standard
        let project = workspace?.name ?? root.lastPathComponent
        let lint = MotionLint.check(MotionLint.sceneFiles(in: source.folder), brand: source.brand).map(\.message)
        let stills = await MotionRenderer.stills(source: source, times: MotionCritique.times(for: source.piece), width: MotionFrames.width,
                                                 into: source.folder.appending(path: "renders/critique"), refused: motionRefused)
        let sheet = stills.files.first { $0.lastPathComponent == "contact-sheet.png" } ?? stills.files.first
        let prompt = MotionCritique.prompt(piece: source.piece, folder: relative,
                                           contactSheet: sheet.map { ProposedChange.relativePath(of: $0, in: root) } ?? "",
                                           lint: stills.errors.map { "Script error: \($0)" } + lint,
                                           maker: maker.isEmpty ? "another agent" : maker)
        do {
            let text: String, model: String
            var tokens = (input: 0, output: 0)
            switch critic {
            case .codex:
                guard let path = Self.codexPath else { throw MotionExporter.Failure(message: "Codex isn’t installed.") }
                let chosen = Preferences.shared.codexModel.isEmpty ? nil : Preferences.shared.codexModel
                let reply = try await Codex(executable: path).ask(prompt, in: root.path, model: chosen, images: sheet.map { [$0.path] } ?? [], timeout: 900)
                text = reply.text
                model = chosen ?? "codex"
                tokens = (reply.inputTokens, reply.outputTokens)
            case .claude:
                guard let executable = SystemStatus.detect().claudePath else { throw MotionExporter.Failure(message: "Claude Code isn’t installed.") }
                let chosen = Preferences.shared.claudeModel.argument
                let reply = try await ClaudeOpinion(executable: executable).ask(prompt, in: root.path, model: chosen, timeout: 900)
                text = reply.text
                model = chosen ?? "claude"
                tokens = (reply.inputTokens, reply.outputTokens)
            }
            let critique = MotionCritique.parse(text, critic: critic.title)
            motionCritiques[source.folder] = critique.notes.isEmpty && critique.summary == nil ? .failed("\(critic.title) didn’t give any notes.") : .done(critique)
            ledger.append(AgentJob(kind: "critique", provider: critic == .codex ? .codex : .claude, model: model, project: project,
                                   promptTokens: tokens.input, outputTokens: tokens.output, seconds: Date().timeIntervalSince(started),
                                   requestedBy: "you", title: "Critique of \(source.piece.title)", why: "A second pair of eyes on a motion piece",
                                   gist: critique.summary.flatMap { AgentJob.gist(of: $0) } ?? "\(critique.notes.count) notes"))
        } catch {
            motionCritiques[source.folder] = .failed(error.localizedDescription)
            ledger.append(AgentJob(kind: "critique", provider: critic == .codex ? .codex : .claude, model: critic.title.lowercased(), project: project,
                                   seconds: Date().timeIntervalSince(started), outcome: .failed, requestedBy: "you",
                                   title: "Critique of \(source.piece.title)", gist: AgentJob.gist(of: error.localizedDescription)))
        }
    }

    /// Asks the agent to change a piece, at the moment the user is looking at: the main
    /// conversation for this checkout's version, the job's for a version still in a job.
    func changeMotion(folder: String, ask: String, at time: Double?, version: MotionVersion? = nil) {
        guard let workspace else { return }
        let url = version?.folder ?? workspace.url.appending(path: folder)
        let manifest = (try? String(contentsOf: url.appending(path: MotionPiece.manifestName), encoding: .utf8)) ?? ""
        let piece = MotionPiece.parse(manifest, fallbackTitle: url.lastPathComponent)
        let brand = BrandKit.load(name: workspace.name, files: workspace.files) { try? String(contentsOf: workspace.url.appending(path: $0), encoding: .utf8) }
        let relative = version.map { ProposedChange.relativePath(of: $0.folder, in: $0.root) } ?? folder
        let brief = MotionBrief.change(ask: ask, folder: relative, piece: piece, brand: brand, at: time, libraries: MotionLibrary.all.map(\.briefLine))
        if let job = version?.job {
            showJob(job)
            askClaude(brief, in: jobs.sessions[job])
        } else {
            askClaude(brief)
        }
    }

    /// Shows the piece on the Stage, full screen: a deck holds at each slide.
    func presentMotion(_ source: MotionSource) {
        StageController.shared.present(source, refused: motionRefused)
    }

    /// Writes the guessed brand kit to `.dante/brand.yaml` and opens it, so it can be tuned.
    func writeBrandKit() {
        guard let workspace else { return }
        let url = workspace.url.appending(path: BrandKit.path)
        if !FileManager.default.fileExists(atPath: url.path) {
            let kit = BrandKit.detect(name: workspace.name, files: workspace.files) { try? String(contentsOf: workspace.url.appending(path: $0), encoding: .utf8) }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try kit.yaml.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                errorMessage = "Couldn’t write \(BrandKit.path): \(error.localizedDescription)"
                return
            }
            workspace.refreshFileIndex()
        }
        open(file: url)
    }

    /// Refreshes a piece's data.json from the code as it is now.
    func refreshMotionData(folder: String) async {
        guard let workspace else { return }
        let url = workspace.url.appending(path: folder)
        let manifest = (try? String(contentsOf: url.appending(path: MotionPiece.manifestName), encoding: .utf8)) ?? ""
        let piece = MotionPiece.parse(manifest)
        guard let data = await motionData(piece.data),
              let json = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? json.write(to: url.appending(path: MotionData.fileName))
        workspace.refreshFileIndex()
    }

    /// The agent asked to see frames (`motion_frames`): render them into the piece's
    /// renders/frames/ and write the result its server is waiting for.
    func renderMotionFrames(_ input: JSONValue, root jobRoot: URL? = nil) {
        guard let workspace, let folder = MotionFrames.folder(input["folder"]?.string) else { return }
        let times = MotionFrames.times((input["times"]?.array ?? []).compactMap { $0.double })
        guard !times.isEmpty else { return }
        // A job's agent works in its worktree.
        let root = jobRoot ?? workspace.url
        let key = MotionFrames.key(folder: folder, times: times)
        let output = root.appending(path: MotionFrames.framesFolder(folder))
        let files = jobRoot.map { FileIndex.scan($0) } ?? workspace.files
        let source = MotionSource.load(folder: root.appending(path: folder), projectRoot: root, files: files, projectName: workspace.name, revision: workspace.revision)
        let refused = motionRefused
        Task {
            // Last round's frames go, so the agent never reads a stale one.
            if let old = try? FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil) {
                for file in old where file.pathExtension == "png" || file.lastPathComponent == "result.json" { try? FileManager.default.removeItem(at: file) }
            }
            var result = MotionFrames.Result(key: key, files: [], errors: [])
            if FileManager.default.fileExists(atPath: source.folder.appending(path: source.piece.scene).path) {
                let (files, errors) = await MotionRenderer.stills(source: source, times: times, width: MotionFrames.width, into: output, refused: refused)
                let relative = files.map { ProposedChange.relativePath(of: $0, in: root) }
                result.contactSheet = relative.first { $0.hasSuffix("contact-sheet.png") }
                result.files = relative.filter { !$0.hasSuffix("contact-sheet.png") }
                result.errors = errors
                result.lint = MotionLint.check(MotionLint.sceneFiles(in: source.folder), brand: source.brand).map(\.message)
            } else {
                result.errors = ["\(folder)/\(source.piece.scene) doesn't exist."]
            }
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try? JSONEncoder().encode(result).write(to: root.appending(path: MotionFrames.resultPath(folder)))
        }
    }
}

/// One version of a motion piece: this checkout's, or one an agent made in a job's worktree.
struct MotionVersion: Identifiable, Equatable {
    var folder: URL
    /// The checkout it's in: the project, or the job's worktree.
    var root: URL
    /// "Claude", "Codex", or empty when nobody said.
    var maker: String
    var job: String?
    var jobTitle: String?

    var id: URL { folder }
    var label: String { maker.isEmpty ? folder.lastPathComponent : "\(maker)’s" }

    /// The piece's own folder for one of its versions: `launch-codex` → `launch`.
    static func base(of folder: String) -> String {
        for engine in AgentEngine.allCases where folder.hasSuffix("-\(engine.rawValue)") {
            return String(folder.dropLast(engine.rawValue.count + 1))
        }
        return folder
    }

    static func suffixMaker(_ name: String) -> String? {
        AgentEngine.allCases.first { name.hasSuffix("-\($0.rawValue)") }?.title
    }
}

/// A critique in progress, done or failed.
enum MotionCritiqueState: Equatable {
    case running(critic: String, since: Date)
    case done(MotionCritique.Critique)
    case failed(String)

    var isRunning: Bool { if case .running = self { true } else { false } }
}
