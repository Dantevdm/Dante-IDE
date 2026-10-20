import Foundation
import Testing
@testable import DanteKit

@Suite("Agent HQ")
struct AgentOfficeTests {
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func job(_ kind: String = "turn", _ provider: AgentJob.Provider = .claude, model: String = "claude", day: Double = 0,
             title: String = "", files: [String]? = nil) -> AgentJob {
        AgentJob(date: start.addingTimeInterval(day * 86_400), kind: kind, provider: provider, model: model, project: "shop", title: title, files: files)
    }

    @Test func filesFindTheirRooms() {
        #expect(OfficeRole.of(path: "api/orders.go") == .backend)
        #expect(OfficeRole.of(path: "api/orders_test.go") == .quality)
        #expect(OfficeRole.of(path: "web/src/components/Cart.tsx") == .frontend)
        #expect(OfficeRole.of(path: "web/src/components/Cart.test.tsx") == .quality)
        #expect(OfficeRole.of(path: "db/migrations/0042_refunds.sql") == .data)
        #expect(OfficeRole.of(path: ".github/workflows/ci.yml") == .devops)
        #expect(OfficeRole.of(path: "Dockerfile") == .devops)
        #expect(OfficeRole.of(path: "infra/main.tf") == .devops)
        #expect(OfficeRole.of(path: "README.md") == .docs)
        #expect(OfficeRole.of(path: "Sources/App/Views/HomeView.swift") == .frontend)
        #expect(OfficeRole.of(path: "Sources/Kit/Security/Scanner.swift") == .security)
        #expect(OfficeRole.of(path: "Tests/KitTests/ParserTests.swift") == .quality)
    }

    @Test func jobsFindTheirRooms() {
        #expect(OfficeRole.of(job: job("audit")) == .security)
        #expect(OfficeRole.of(job: job("look", .local)) == .frontend)
        #expect(OfficeRole.of(job: job("triage", .local)) == .quality)
        #expect(OfficeRole.of(job: job("summary", .local)) == .research)
        #expect(OfficeRole.of(job: job("subagent", model: "Explore", title: "Fix the tests")) == .research)
        #expect(OfficeRole.of(job: job("subagent", model: "general-purpose", title: "Write the migration")) == .data)
        #expect(OfficeRole.of(job: job(files: ["web/a.tsx", "web/b.css", "api/c.go"])) == .frontend)
        #expect(OfficeRole.of(job: job(files: ["api/c.go", "web/a.tsx"])) == .backend)
        #expect(OfficeRole.of(job: job(title: "Why does checkout fail?")) == .research)
        #expect(OfficeRole.of(job: job(title: "Make the deploy pipeline faster")) == .devops)
    }

    @Test func toolsFindTheirRooms() {
        #expect(OfficeRole.of(tool: "Edit", path: "web/src/pages/Cart.tsx", command: nil) == .frontend)
        #expect(OfficeRole.of(tool: "Grep", path: nil, command: nil) == .research)
        #expect(OfficeRole.of(tool: "Bash", path: nil, command: "swift test --filter Office") == .quality)
        #expect(OfficeRole.of(tool: "Bash", path: nil, command: "docker compose up -d") == .devops)
        #expect(OfficeRole.of(tool: "Bash", path: nil, command: "psql -c 'select 1'") == .data)
        #expect(OfficeRole.of(tool: "Bash", path: nil, command: "gitleaks detect") == .security)
        #expect(OfficeRole.of(tool: "Bash", path: nil, command: "go build ./...") == .backend)
    }

    @Test func roomsAreFurnishedByTheirWork() {
        let jobs = (0..<13).map { job(day: Double($0) * 0.001, files: ["api/x\($0).go"]) } + [job("audit", day: 0.02)]
        let office = AgentOffice.build(jobs: jobs, project: "shop", now: start.addingTimeInterval(2_000), calendar: calendar)
        let backend = office.rooms.first { $0.role == .backend }!
        #expect(backend.jobs == 13 && backend.level == 3)
        #expect(backend.next == "17 more jobs: a bookshelf and a screen wall")
        #expect(abs(backend.progress - 1.0 / 18) < 0.001)
        #expect(backend.warmth == 1 && backend.traffic == 1)
        #expect(backend.crew == [.init(name: "Claude", look: "claude", jobs: 13)])
        #expect(backend.recent.count == 6 && backend.recent.first?.title == "turn")
        let security = office.rooms.first { $0.role == .security }!
        #expect(security.level == 1 && security.next == "3 more jobs: a rug and a lamp")
        let data = office.rooms.first { $0.role == .data }!
        #expect(data.level == 0 && data.warmth == 0 && data.opened == nil)
        #expect(AgentOffice.level(jobs: 75) == 5 && AgentOffice.level(jobs: 0) == 0)
    }

    @Test func quietRoomsGoDusty() {
        let office = AgentOffice.build(jobs: [job(files: ["api/a.go"])], project: "shop", now: start.addingTimeInterval(40 * 86_400), calendar: calendar)
        #expect(office.rooms.first { $0.role == .backend }!.warmth == 0.15)
    }

    @Test func erasNeedJobsAndDays() {
        // Twelve jobs in one day is still a garage: a studio needs two days with work.
        let oneDay = (0..<12).map { job(day: Double($0) * 0.001) }
        let garage = AgentOffice.build(jobs: oneDay, project: "shop", now: start.addingTimeInterval(3_600), calendar: calendar)
        #expect(garage.era == .garage)
        #expect(garage.nextEra == "1 more day with work to become a studio")
        let twoDays = oneDay + [job(day: 1)]
        let studio = AgentOffice.build(jobs: twoDays, project: "shop", now: start.addingTimeInterval(2 * 86_400), calendar: calendar)
        #expect(studio.era == .studio)
        #expect(studio.nextEra == "37 more jobs and 3 more days with work to become an office")
    }

    @Test func theAppsGrowthCountsToo() {
        // 200 commits over five days are worth 40 jobs and five days with work.
        let commits = (0..<200).map { start.addingTimeInterval(Double($0 % 5) * 86_400 + Double($0)) }
        let office = AgentOffice.build(jobs: (0..<10).map { job(day: Double($0) * 0.01) }, project: "shop",
                                       growth: .init(commits: commits, files: 900), now: start.addingTimeInterval(6 * 86_400), calendar: calendar)
        #expect(office.era == .office)
        #expect(office.grounds == .init(trees: 16, floors: 1, commits: 200, files: 900))
        #expect(office.milestones.contains { $0.text == "100 commits: the brain's tower grew" })
    }

    @Test func milestonesTellTheStory() {
        let jobs = [job(title: "Read the code"), job(day: 0.1, files: ["db/1.sql"])] + (0..<3).map { job(day: 0.2 + Double($0) * 0.01, files: ["db/\($0).sql"]) }
        let office = AgentOffice.build(jobs: jobs, project: "shop", now: start.addingTimeInterval(86_400), calendar: calendar)
        #expect(office.milestones.map(\.text) == [
            "Data got a rug and a lamp",
            "Data opened: Claude moved in for turn",
            "Research opened: Claude moved in for Read the code",
            "The doors opened: Claude did the first job, Read the code",
        ])
    }

    @Test func theReplayGrowsToNow() {
        let jobs = (0..<30).map { job(day: Double($0), files: ["api/\($0).go"]) }
        let now = start.addingTimeInterval(30 * 86_400)
        let frames = AgentOffice.timeline(jobs: jobs, project: "shop", frames: 6, now: now, calendar: calendar)
        #expect(frames.count == 6)
        #expect(frames.map(\.totalJobs) == frames.map(\.totalJobs).sorted())
        #expect(frames.first!.totalJobs <= 1 && frames.last!.totalJobs == 30)
        #expect(frames.last!.era == .studio && frames.first!.era == .garage)
        #expect(AgentOffice.timeline(jobs: [], project: "shop", now: now).count == 1)
    }

    @Test func workersSitWhereTheyWork() {
        let root = URL(filePath: "/home/me/shop")
        let tools = [
            ToolActivity(id: "1", name: "Read", input: ["file_path": "/home/me/shop/api/a.go"], status: .done),
            ToolActivity(id: "2", name: "Edit", input: ["file_path": "/home/me/shop/web/src/pages/Cart.tsx"], status: .running),
            ToolActivity(id: "3", name: "Task", input: ["subagent_type": "Explore", "description": "Find the refunds"], status: .running),
            ToolActivity(id: "4", name: "Bash", input: ["command": "go test ./..."], status: .awaitingApproval(requestID: "r")),
        ]
        let workers = OfficeWorker.from(tools: tools, working: true, lead: "Codex", root: root)
        #expect(workers.first { $0.waiting }?.role == .quality)
        #expect(workers.first { $0.waiting }?.look == "codex")
        #expect(workers.first { $0.look == "subagent" }?.role == .research)
        #expect(workers.first { $0.look == "subagent" }?.doing == "Find the refunds")
        // Waiting counts as the lead's seat, so it isn't placed twice.
        #expect(workers.filter(\.lead).count == 1)
        let idle = OfficeWorker.from(tools: Array(tools.prefix(2)), working: true, lead: "Claude", root: root)
        #expect(idle.first == OfficeWorker(role: .frontend, look: "claude", name: "Claude", doing: "Edit web/src/pages/Cart.tsx", lead: true))
        #expect(OfficeWorker.from(tools: [], working: false, lead: "Claude", root: root).isEmpty)
    }

    @Test func theLightFollowsTheHour() {
        #expect(AgentOffice.ambience(hour: 2) == "night")
        #expect(AgentOffice.ambience(hour: 7) == "dawn")
        #expect(AgentOffice.ambience(hour: 12) == "day")
        #expect(AgentOffice.ambience(hour: 19) == "dusk")
    }
}
