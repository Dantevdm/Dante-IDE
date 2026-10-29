import Foundation
import Testing
@testable import DanteKit

struct CompanionTickerTests {
    typealias Snapshot = CompanionSnapshot

    static let run = Snapshot.Approval(id: "a1", job: nil, from: "Main conversation", title: "Run go test ./...", detail: "go test ./...")

    @Test func nowSaysWhatsGoingOn() {
        let jobs = [Snapshot.Job(id: "j1", title: "Add retries", state: .working, label: "Working", lastReply: ""),
                    Snapshot.Job(id: "j2", title: "Fix login", state: .ready, label: "Ready", lastReply: "")]
        let snapshot = Snapshot(server: "Studio", projects: [
            Snapshot.Project(id: "/home/me/shop", name: "shop", lead: "Claude", working: true, lastReply: "", jobs: jobs, approvals: [Self.run]),
        ])
        let ticker = CompanionTicker.make(snapshot, connected: true, noted: [])
        #expect(ticker.now.map(\.title) == ["1 step waits for you", "Claude is working in shop", "1 job running", "1 job ready to review"])
        #expect(ticker.now[0].detail == "shop: Run go test ./...")
        #expect(ticker.since.isEmpty)
    }

    @Test func quietAndOffline() {
        let idle = Snapshot(server: "Studio", projects: [
            Snapshot.Project(id: "/home/me/shop", name: "shop", lead: "Codex", working: false, lastReply: "", jobs: [], approvals: []),
        ])
        #expect(CompanionTicker.make(idle, connected: true, noted: []).now.map(\.title) == ["All quiet on Studio"])
        #expect(CompanionTicker.make(idle, connected: false, noted: []).now.map(\.title) == ["Not connected to your Mac"])
    }

    @Test func sinceListsEventsNewestFirst() {
        let snapshot = Snapshot(server: "Studio", projects: [
            Snapshot.Project(id: "/home/me/shop", name: "shop", lead: "Claude", working: false, lastReply: "", jobs: [], approvals: []),
        ])
        let job = Snapshot.Job(id: "j1", title: "Add retries", state: .failed, label: "Failed", lastReply: "")
        let noted = [
            CompanionTicker.Noted(.replied(project: "/home/me/shop", job: nil, text: "## Done\n**Tests** pass now. Next I'd add more."), at: Date(timeIntervalSince1970: 1)),
            CompanionTicker.Noted(.jobChanged(project: "/home/me/shop", job), at: Date(timeIntervalSince1970: 2)),
        ]
        let since = CompanionTicker.make(snapshot, connected: true, noted: noted).since
        #expect(since.map(\.title) == ["Job stopped in shop", "Claude finished in shop"])
        #expect(since[0].kind == .trouble && since[1].detail == "Done")
        #expect(CompanionTicker.gist("Tests pass now. Next I'd add more.") == "Tests pass now.")
    }
}
