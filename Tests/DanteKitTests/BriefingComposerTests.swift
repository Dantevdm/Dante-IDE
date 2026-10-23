import Foundation
import Testing
@testable import DanteKit

struct BriefingComposerTests {
    static let zone = TimeZone(identifier: "Africa/Johannesburg")!
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    static func at(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    static func message(_ id: String, _ subject: String, from name: String, _ address: String, preview: String = "",
                        read: Bool = false, flagged: Bool = false, priority: MailMessage.Priority = .normal) -> MailMessage {
        MailMessage(id: id, subject: subject, senderName: name, senderAddress: address, received: at("2026-10-23 07:00"),
                    isRead: read, priority: priority, isFlagged: flagged, preview: preview)
    }

    // MARK: Mail

    @Test func peopleBeatRobots() {
        let mail = [
            Self.message("1", "Your weekly digest", from: "Acme News", "newsletter@acme.example", preview: "Top stories. Unsubscribe"),
            Self.message("2", "Can you review the rollout plan today?", from: "Ana Sousa", "ana@example.com", preview: "Hi,\nCan you review the rollout plan before 3pm? It blocks the release."),
            Self.message("3", "Build succeeded", from: "Azure DevOps", "azuredevops@example.com"),
            Self.message("4", "Lunch", from: "Sam Lee", "sam@example.com", preview: "Sushi?", read: true),
            Self.message("5", "Contract renewal", from: "Legal", "notifications@example.com", flagged: true),
        ]
        let important = MailTriage.important(mail)
        #expect(important.map(\.id) == ["2", "5"])
        #expect(important[0].reasons.contains("time-sensitive"))
        #expect(important[0].gist == "Can you review the rollout plan before 3pm?")
    }

    @Test func gistSkipsGreetingsAndQuotes() {
        #expect(MailTriage.gist("Hi Dan,\n\nThe invoice from Mr. Smith is attached. Please pay by Friday.\n\nThanks\nSam", subject: "x")
            == "The invoice from Mr. Smith is attached.")
        #expect(MailTriage.gist("> earlier text\nhttps://example.com\n", subject: "Status") == "Status")
        #expect(MailTriage.gist("On Monday, Sam wrote:\nold", subject: "Re: plan") == "Re: plan")
    }

    @Test func importantMailIsSpoken() {
        let important = MailTriage.important([Self.message("9", "RE: FW: Q3 budget sign-off", from: "Ana Sousa", "ana@example.com",
                                                           preview: "Need your approval today.", priority: .high)])
        let section = BriefingComposer.mail(.success(important))
        #expect(section.summary == "One email looks important: Ana Sousa about the Q3 budget sign-off.")
        #expect(section.status == .attention)
        #expect(BriefingComposer.mail(.success([])).summary == "Nothing in your inbox needs you.")
        #expect(BriefingComposer.mail(.failure(.notRunning)).problem == "Outlook isn’t open on the Mac.")
    }

    // MARK: Projects

    @Test func gitLogIsRead() {
        let output = ["a1\u{1F}Ana Sousa\u{1F}ana@example.com\u{1F}2026-10-22T16:00:00+02:00\u{1F}feat(export): Add CSV export\u{1E}",
                      "\nb2\u{1F}Sam Lee\u{1F}sam@example.com\u{1F}2026-10-22T17:30:00+02:00\u{1F}Fix login loop\u{1E}\n"].joined()
        let commits = ProjectDigest.parseLog(output)
        #expect(commits.map(\.hash) == ["a1", "b2"])
        #expect(commits[0].subject == "feat(export): Add CSV export")
        #expect(ProjectDigest.logArguments(since: Date(timeIntervalSince1970: 100)).contains("--since=100"))
    }

    @Test func mondaysLookBackToFriday() {
        let friday = ProjectDigest.cutOff(at: Self.at("2026-10-26 07:30"), calendar: Self.calendar)
        #expect(friday == Self.at("2026-10-23 06:00"))
        #expect(ProjectDigest.cutOff(at: Self.at("2026-10-23 07:30"), calendar: Self.calendar) == Self.at("2026-10-22 06:00"))
    }

    @Test func commitsBecomeSentences() {
        let commits = [
            ProjectDigest.Commit(hash: "1", author: "Ana Sousa", date: Self.at("2026-10-22 15:00"), subject: "feat(export): Add CSV export"),
            ProjectDigest.Commit(hash: "2", author: "Ana Sousa", date: Self.at("2026-10-22 16:00"), subject: "OPS-142: Retry failed uploads (#88)"),
            ProjectDigest.Commit(hash: "3", author: "Dan", email: "dan@example.com", date: Self.at("2026-10-22 17:00"), subject: "Update README."),
        ]
        let input = BriefingComposer.Input(now: Self.at("2026-10-23 07:30"), me: ["dan@example.com"],
                                           projects: [ProjectDigest(id: "p1", name: "Order desk", commits: commits,
                                                                    tests: TestRecord(date: Self.at("2026-10-22 18:00"), label: "go", passed: 40, failed: 0, skipped: 0, duration: 3))])
        let section = BriefingComposer.projects(input)
        #expect(section.summary == "In Order desk, Ana Sousa made two changes and you made one change: update README and retry failed uploads, and more. Tests are passing.")
        #expect(section.status == .good)
        #expect(section.items.map(\.title) == ["Ana Sousa · Order desk", "You · Order desk"])
        #expect(BriefingComposer.speakable("fix(login): Handle expired tokens") == "handle expired tokens")
        #expect(BriefingComposer.speakable("JWT refresh for API") == "JWT refresh for API")
        #expect(BriefingComposer.speakable("Explore from the iPhone and iPad: docs, pictures and diagrams") == "explore from the iPhone and iPad")
        #expect(BriefingComposer.speakable("Fix: typo") == "typo")
    }

    @Test func onlyTheBusiestProjectsAreSaid() {
        let projects = (1...5).map { n in
            ProjectDigest(id: "p\(n)", name: "P\(n)", commits: (0..<(6 - n)).map { ProjectDigest.Commit(hash: "\(n)-\($0)", author: "Sam", date: .now, subject: "Work \($0)") })
        }
        let section = BriefingComposer.projects(.init(now: .now, projects: projects))
        #expect(section.summary.hasPrefix("In P1, Sam made five changes"))
        #expect(section.summary.hasSuffix("And changes in two other projects."))
        #expect(section.items.count == 5)
    }

    @Test func problemsAreSaidEvenWhenQuiet() {
        let input = BriefingComposer.Input(now: .now, projects: [
            ProjectDigest(id: "p", name: "Shop", tests: TestRecord(date: .now, label: "npm", passed: 9, failed: 2, skipped: 0, duration: 1), criticalFindings: 1),
        ])
        let section = BriefingComposer.projects(input)
        #expect(section.summary == "Two tests are failing in Shop. Shop has one critical security finding.")
        #expect(section.status == .attention)
        let quiet = BriefingComposer.projects(.init(now: .now, projects: [ProjectDigest(id: "q", name: "Quiet")]))
        #expect(quiet.summary == "No new changes in your projects.")
        #expect(quiet.status == .quiet)
    }

    // MARK: Pipelines

    @Test func failuresClearedByALaterPass() {
        let ci = [
            CIRun(id: 3, title: "", workflow: "deploy", branch: "main", status: "completed", conclusion: "success", created: Self.at("2026-10-22 18:00")),
            CIRun(id: 2, title: "", workflow: "deploy", branch: "main", status: "completed", conclusion: "failure", created: Self.at("2026-10-22 12:00")),
            CIRun(id: 1, title: "", workflow: "test", branch: "feature", status: "completed", conclusion: "failure", created: Self.at("2026-10-22 11:00")),
        ]
        let runs = [PipelineRun(id: 7, pipeline: "infra", status: .running, branch: "main")]
        let section = BriefingComposer.pipelines(.init(now: .now, projects: [ProjectDigest(id: "p", name: "Shop", ci: ci, pipelines: runs)]))
        #expect(section.summary == "test in Shop on feature failed. One other run passed. One run still going.")
        #expect(section.status == .bad)
        #expect(section.items.count == 1)
        let good = BriefingComposer.pipelines(.init(now: .now, projects: [ProjectDigest(id: "p", name: "Shop", ci: [ci[0]])]))
        #expect(good.summary == "Pipelines look good: one run passed.")
        #expect(BriefingComposer.pipelines(.init(now: .now, projects: [])).summary.isEmpty)
    }

    // MARK: Calendar

    @Test func todaysMeetings() {
        let entries = [
            CalendarEntry(id: "a", title: "Stand-up", start: Self.at("2026-10-23 09:00"), end: Self.at("2026-10-23 09:15")),
            CalendarEntry(id: "b", title: "Design review", start: Self.at("2026-10-23 14:00"), end: Self.at("2026-10-23 15:00"), location: "Room 4"),
            CalendarEntry(id: "c", title: "Budget", start: Self.at("2026-10-23 14:30"), end: Self.at("2026-10-23 15:00")),
            CalendarEntry(id: "d", title: "Leave: Sam", start: Self.at("2026-10-23 00:00"), end: Self.at("2026-10-24 00:00"), isAllDay: true),
        ]
        let locale = Locale(identifier: "en_GB")
        let section = BriefingComposer.today(.success(entries), now: Self.at("2026-10-23 07:30"), calendar: Self.calendar, locale: locale)
        #expect(section.summary == "Three meetings today: the first is Stand-up at 09:00. Design review and Budget overlap. All day: Leave: Sam.")
        #expect(section.items.first { $0.id == "cal|b" }?.detail == "14:00 · Room 4")
        let later = BriefingComposer.today(.success(entries), now: Self.at("2026-10-23 16:00"), calendar: Self.calendar, locale: locale)
        #expect(later.summary == "No more meetings today. All day: Leave: Sam.")
        let clear = BriefingComposer.today(.success([]), now: .now, calendar: Self.calendar, locale: locale)
        #expect(clear.summary == "Your calendar is clear today.")
    }

    @Test func wholeBriefingReadsInOrder() {
        let briefing = BriefingComposer.compose(.init(now: Self.at("2026-10-23 07:30"), name: "Dan", projects: [], mail: .success([]),
                                                      calendar: .success([])), calendar: Self.calendar, locale: Locale(identifier: "en_GB"))
        #expect(briefing.sections.map(\.kind) == [.projects, .pipelines, .mail, .calendar])
        #expect(briefing.spoken == "Good morning, Dan. Nothing in your inbox needs you. Your calendar is clear today.")
    }
}
