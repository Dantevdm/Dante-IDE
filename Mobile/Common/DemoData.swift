#if DEBUG
import Foundation

/// Made-up projects, pipelines and an update for checking the iPad's screens in the simulator.
enum DemoData {
    static let snapshot = CompanionSnapshot(server: "Studio", projects: [
        .init(id: "/home/me/shop", name: "shop", lead: "Claude", working: true, lastReply: "Adding tax to the order totals and a test for it.",
              jobs: [.init(id: "j1", title: "Fix the flaky checkout test", state: .working, label: "Working", lastReply: "")],
              approvals: [], approvalMode: .edits),
        .init(id: "/home/me/acme-shop", name: "acme-shop", lead: "Codex", working: false, lastReply: "", jobs: [], approvals: []),
    ], recent: [.init(id: "/home/me/notes", name: "notes")])

    static var briefing: Briefing {
        let now = Date()
        let stages: [Briefing.Pipeline.Stage] = [.init(name: "Build", status: .good, state: "Succeeded"), .init(name: "Test", status: .good, state: "Succeeded"),
                                                 .init(name: "Non-prod", status: .good, state: "Succeeded"), .init(name: "Prod", status: .quiet, state: "Waiting", active: true)]
        return Briefing(date: now, greeting: "Good afternoon.", sections: [
            .init(kind: .projects, summary: "In shop, you made five changes: order totals include tax and checkout retries a failed card once. In acme-shop, Sam made two changes. Tests are passing.",
                  status: .good, items: [.init(id: "a", title: "You · shop", detail: "order totals include tax", time: now.addingTimeInterval(-3600)),
                                         .init(id: "b", title: "Sam · acme-shop", detail: "faster search", time: now.addingTimeInterval(-7200))]),
            .init(kind: .pipelines, summary: "Pipelines look good: three runs passed. One run still going.", status: .good),
            .init(kind: .mail, summary: "Two messages need you: Ana asks about Thursday's release, and the bank's API key expires Friday.", status: .attention,
                  items: [.init(id: "m1", title: "Ana · Thursday release", status: .attention), .init(id: "m2", title: "API key expires Friday", status: .attention)]),
            .init(kind: .calendar, summary: "Two meetings: stand-up at 9:30 and release planning at 14:00.", status: .good,
                  items: [.init(id: "c1", title: "Release planning", time: now.addingTimeInterval(5400))]),
        ], pipelines: [
            .init(id: "p1", project: "shop", name: "shop-deploy", branch: "main", number: "20261029.4", status: .attention, state: "Running",
                  started: now.addingTimeInterval(-600), requestedBy: "Sam", reason: "Individual CI", commit: "4f2a9c1", environment: "Prod", stages: stages,
                  history: [.good, .good, .bad, .good]),
            .init(id: "p2", project: "acme-shop", name: "acme-web", branch: "main", number: "#412", status: .good, state: "Succeeded",
                  started: now.addingTimeInterval(-4000), finished: now.addingTimeInterval(-3500), history: [.good, .good]),
            .init(id: "p3", project: "shop", name: "shop-nightly", branch: "develop", status: .bad, state: "Failed",
                  started: now.addingTimeInterval(-30000), finished: now.addingTimeInterval(-29000),
                  stages: [.init(name: "Build", status: .good, state: "Succeeded"), .init(name: "Test", status: .bad, state: "Failed")]),
        ])
    }

    /// A repository for the Changes screen: a staged edit, new and changed files, two commits to push.
    static func git(_ action: CompanionGitAction) -> CompanionGit {
        let now = Date()
        var git = CompanionGit(branch: "feature/tax", upstream: "origin/feature/tax", ahead: 2, behind: 1,
            changes: [
                .init(path: "Sources/Shop/Order.swift", staged: "M"),
                .init(path: "Sources/Shop/Tax.swift", unstaged: "?"),
                .init(path: "Tests/ShopTests/TaxTests.swift", unstaged: "?"),
                .init(path: "README.md", unstaged: "M"),
            ],
            branches: [.init(name: "feature/tax", isCurrent: true, subject: "Add tax to order totals"), .init(name: "main", subject: "Release 1.4"),
                       .init(name: "origin/main", isRemote: true), .init(name: "origin/feature/cart", isRemote: true)],
            commits: [
                .init(hash: "a1b2c3d", subject: "Add tax to order totals", date: now.addingTimeInterval(-1_800), unpushed: true),
                .init(hash: "e4f5a6b", subject: "Round prices to the cent", date: now.addingTimeInterval(-5_400), unpushed: true),
                .init(hash: "c7d8e9f", subject: "Release 1.4", date: now.addingTimeInterval(-86_400 * 2)),
            ],
            message: "", notice: nil)
        switch action {
        case .writeMessage:
            git.message = "Add tax to order totals\n\nOrders now add VAT per line and round to the cent, with tests."
        case .push:
            git.notice = "Pushed feature/tax"
            git.ahead = 0
            git.commits = git.commits.map { var commit = $0; commit.unpushed = false; return commit }
        case .diff(let path, let staged):
            git.diff = CompanionGit.Diff(path: path, staged: staged, lines: [
                .init(kind: .hunk, text: "@@ -12,7 +12,9 @@ struct Order {"),
                .init(kind: .context, text: "    var lines: [Line]", number: 12),
                .init(kind: .removed, text: "    var total: Decimal { lines.reduce(0) { $0 + $1.price } }", number: 13),
                .init(kind: .added, text: "    var subtotal: Decimal { lines.reduce(0) { $0 + $1.price } }", number: 13),
                .init(kind: .added, text: "    var tax: Decimal { Tax.vat(on: subtotal) }", number: 14),
                .init(kind: .added, text: "    var total: Decimal { (subtotal + tax).rounded(to: 2) }", number: 15),
                .init(kind: .context, text: "}", number: 16),
            ])
        default:
            break
        }
        return git
    }
}
#endif
