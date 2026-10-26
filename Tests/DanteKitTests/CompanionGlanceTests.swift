import Testing
@testable import DanteKit

struct CompanionGlanceTests {
    typealias Snapshot = CompanionSnapshot

    static func project(_ id: String, working: Bool = false, jobs: [Snapshot.Job] = [], approvals: [Snapshot.Approval] = []) -> Snapshot.Project {
        Snapshot.Project(id: "/home/me/\(id)", name: id, lead: "Claude", working: working, lastReply: "Done.\n\nAll **tests** pass.", jobs: jobs, approvals: approvals)
    }

    static let run = Snapshot.Approval(id: "a1", job: nil, from: "Main conversation", title: "Run go test ./...", detail: "go test ./...")
    static let edit = Snapshot.Approval(id: "a2", job: "j1", from: "Add retries", title: "Edit Mailer.swift",
                                        detail: "--- a/Mailer.swift\n+++ b/Mailer.swift\n@@ -1 +1 @@\n+retry()", note: "Flagged by a rule")
    static let question = Snapshot.Approval(id: "a3", job: nil, from: "Main conversation", title: "Question", detail: "",
                                            questions: [.init(question: "Which database?", options: ["Postgres", "SQLite"])])

    @Test func noticesForEachEvent() {
        let snapshot = Snapshot(server: "Studio", projects: [Self.project("shop", approvals: [Self.run, Self.edit, Self.question])])
        let run = CompanionNotice.make(.waiting(project: "/home/me/shop", Self.run), in: snapshot)
        #expect(run.kind == .approval && run.title == "Claude waits · shop" && run.body == "Run go test ./..." && run.approval == "a1" && run.sounds)
        let edit = CompanionNotice.make(.waiting(project: "/home/me/shop", Self.edit), in: snapshot)
        #expect(edit.title == "Add retries waits · shop" && edit.body == "Edit Mailer.swift\nretry()\n⚠︎ Flagged by a rule")
        // A question with options opens the app.
        let asked = CompanionNotice.make(.waiting(project: "/home/me/shop", Self.question), in: snapshot)
        #expect(asked.kind == .open && asked.body == "Which database?\nPostgres · SQLite")
        let job = Snapshot.Job(id: "j1", title: "Add retries", state: .ready, label: "Ready", lastReply: "## Done\nRetries added to the mailer.")
        let ready = CompanionNotice.make(.jobChanged(project: "/home/me/shop", job), in: snapshot)
        #expect(ready.title == "Ready to review · shop" && ready.body == "Add retries\nDone" && ready.identifier == "job.j1")
        let reply = CompanionNotice.make(.replied(project: "/home/me/shop", job: nil, text: "Done.\n\nAll **tests** pass."), in: snapshot)
        #expect(reply.body == "Done. All tests pass." && !reply.sounds && reply.kind == .open)
    }

    @Test func glanceShowsTheMostUrgentFirst() {
        let working = Snapshot.Job(id: "j2", title: "Docs", state: .working, label: "Working", lastReply: "", away: "Away · 20 min left")
        var snapshot = Snapshot(server: "Studio", projects: [Self.project("shop", working: true), Self.project("blog", jobs: [working], approvals: [Self.run])])
        var glance = CompanionGlance.make(snapshot, connected: true)
        #expect(glance.mood == .waiting && glance.headline == "Run go test ./..." && glance.detail == "Claude · blog" && glance.waiting == 1 && glance.working == 2)
        #expect(glance.project == "/home/me/blog" && glance.isActive)
        snapshot.projects[1].approvals = []
        glance = CompanionGlance.make(snapshot, connected: true)
        #expect(glance.mood == .working && glance.headline == "Claude is working" && glance.detail == "shop")
        snapshot.projects[0].working = false
        glance = CompanionGlance.make(snapshot, connected: true)
        #expect(glance.headline == "Job: Docs" && glance.detail == "blog · Away · 20 min left")
        snapshot.projects[1].jobs[0].state = .ready
        #expect(CompanionGlance.make(snapshot, connected: true).mood == .review)
        snapshot.projects[1].jobs = []
        #expect(CompanionGlance.make(snapshot, connected: true).mood == .quiet && !CompanionGlance.make(snapshot, connected: true).isActive)
        // Work the Mac can't be asked about any more.
        snapshot.projects[0].working = true
        let offline = CompanionGlance.make(snapshot, connected: false)
        #expect(offline.mood == .offline && offline.detail == "Can’t reach Studio · shop")
    }
}
