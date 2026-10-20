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
                try Self.scaffold(piece, data: projectData, at: workspace.url.appending(path: folderPath))
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
            let job = await jobs.start(brief: brief, engine: engine, title: "\(engine.title)'s \(piece.title == "Untitled" ? "motion piece" : piece.title)") { worktree in
                try Self.scaffold(piece, data: projectData, at: worktree.appending(path: jobFolder))
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

    /// The same piece made by an agent in a job: its folder in that job's worktree.
    func motionVersions(of folder: String) -> [(engine: AgentEngine, job: JobRecord, folder: URL)] {
        jobs.records.filter { $0.outcome == .open }.compactMap { job in
            for candidate in AgentEngine.allCases.map({ "\(folder)-\($0.rawValue)" }) + [folder] {
                let url = job.worktreeURL.appending(path: candidate)
                if FileManager.default.fileExists(atPath: url.appending(path: MotionPiece.manifestName).path) { return (job.engine, job, url) }
            }
            return nil
        }
    }

    /// Asks the agent to change a piece, at the moment the user is looking at.
    func changeMotion(folder: String, ask: String, at time: Double?) {
        guard let workspace else { return }
        let url = workspace.url.appending(path: folder)
        let manifest = (try? String(contentsOf: url.appending(path: MotionPiece.manifestName), encoding: .utf8)) ?? ""
        let piece = MotionPiece.parse(manifest, fallbackTitle: url.lastPathComponent)
        let brand = BrandKit.load(name: workspace.name, files: workspace.files) { try? String(contentsOf: workspace.url.appending(path: $0), encoding: .utf8) }
        askClaude(MotionBrief.change(ask: ask, folder: folder, piece: piece, brand: brand, at: time, libraries: MotionLibrary.all.map(\.briefLine)))
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
