import DanteKit
import Foundation
import Observation

/// The morning update, app-wide: made on request (voice, the companion, the Stage) from the
/// open and recent projects, kept for a few minutes so the phone and the Mac say the same thing.
@MainActor @Observable
final class Briefings {
    static let shared = Briefings()

    private(set) var latest: Briefing?
    private(set) var isGathering = false
    @ObservationIgnored private var running: Task<Briefing, Never>?

    /// A fresh briefing, or the last one when it's under five minutes old.
    func make(fresh: Bool = false) async -> Briefing {
        if !fresh, let latest, Date.now.timeIntervalSince(latest.date) < 300 { return latest }
        if let running { return await running.value }
        let task = Task { await BriefingGatherer.gather(.current(projects: Self.projects())) }
        running = task
        isGathering = true
        let briefing = await task.value
        running = nil
        isGathering = false
        latest = briefing
        return briefing
    }

    /// Open projects first, then recent ones, up to eight, each once.
    static func projects() -> [BriefingGatherer.Project] {
        var seen = Set<String>()
        let open = Sessions.all.compactMap { $0.workspace?.url }
        let recent = RecentProjects().items.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        return (open + recent).compactMap { url -> BriefingGatherer.Project? in
            let url = url.standardizedFileURL
            guard seen.insert(url.path).inserted, FileManager.default.fileExists(atPath: url.appending(path: ".git").path) else { return nil }
            return .init(id: CompanionSnapshot.Project.id(for: url), name: url.lastPathComponent, root: url)
        }
        .prefix(8)
        .map { $0 }
    }
}
