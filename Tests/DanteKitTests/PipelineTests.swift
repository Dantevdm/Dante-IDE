import Foundation
import Testing
@testable import DanteKit

struct PipelineTests {
    @Test func azureRemotesInEveryShape() {
        let https = AzureDevOpsRemote.parse("https://someone@dev.azure.com/Acme/Corporate%20Data/_git/hub")
        #expect(https == AzureDevOpsRemote(organization: "Acme", project: "Corporate Data", repository: "hub"))
        #expect(AzureDevOpsRemote.parse("https://acme.visualstudio.com/DefaultCollection/Shop/_git/api")
                == AzureDevOpsRemote(organization: "acme", project: "Shop", repository: "api"))
        #expect(AzureDevOpsRemote.parse("git@ssh.dev.azure.com:v3/Acme/Shop/api")
                == AzureDevOpsRemote(organization: "Acme", project: "Shop", repository: "api"))
        #expect(AzureDevOpsRemote.parse("git@github.com:acme/api.git") == nil)
        #expect(https?.base.absoluteString == "https://dev.azure.com/Acme/Corporate%20Data")
    }

    @Test func environmentsFromNamesFilesAndStages() {
        #expect(PipelineEnvironment.classify(["infrastructure/azure-devops/pipelines/azure-pipelines-release-nonprod.yml"]) == .nonProd)
        #expect(PipelineEnvironment.classify(["azure-pipelines-release-prod.yml"]) == .prod)
        #expect(PipelineEnvironment.classify(["RolloutNonProd"]) == .nonProd)
        #expect(PipelineEnvironment.classify(["Deploy to Production"]) == .prod)
        #expect(PipelineEnvironment.classify(["release-uat"]) == .nonProd)
        #expect(PipelineEnvironment.classify(["products-ci"]) == .other)
        #expect(PipelineEnvironment.classify(["ci"]) == .other)
    }

    static let builds = """
    {"count": 3, "value": [
      {"id": 41, "buildNumber": "20261022.2", "status": "inProgress", "queueTime": "2026-10-22T10:05:00.1234567Z",
       "startTime": "2026-10-22T10:05:03.5Z", "sourceBranch": "refs/heads/develop", "sourceVersion": "abc123def456",
       "reason": "individualCI", "definition": {"id": 7, "name": "hub-cd-nonprod"}, "requestedFor": {"displayName": "Sam"},
       "_links": {"web": {"href": "https://dev.azure.com/Acme/Shop/_build/results?buildId=41"}}},
      {"id": 40, "buildNumber": "20261022.1", "status": "completed", "result": "failed", "queueTime": "2026-10-22T09:00:00Z",
       "startTime": "2026-10-22T09:00:05Z", "finishTime": "2026-10-22T09:06:05Z", "sourceBranch": "refs/heads/develop",
       "reason": "manual", "definition": {"id": 7, "name": "hub-cd-nonprod"}},
      {"id": 39, "status": "completed", "result": "succeeded", "queueTime": "2026-10-21T09:00:00Z",
       "startTime": "2026-10-21T09:00:00Z", "finishTime": "2026-10-21T09:10:00Z", "sourceBranch": "refs/heads/main",
       "definition": {"id": 8, "name": "hub-cd"}}
    ]}
    """

    @Test func azureRunsReadBack() {
        let runs = AzureDevOps.runs(Data(Self.builds.utf8), files: [8: "pipelines/azure-pipelines-release-prod.yml"])
        #expect(runs.map(\.id) == [41, 40, 39])
        #expect(runs[0].status == .running && runs[0].branch == "develop" && runs[0].reason == "a push" && runs[0].requestedBy == "Sam")
        #expect(runs[0].queued != nil && runs[0].url?.absoluteString.hasSuffix("buildId=41") == true)
        #expect(runs[0].environment == .nonProd)
        #expect(runs[1].status == .failed && runs[1].reason == "by hand" && runs[1].duration() == 360)
        // The file names it production when the name doesn't.
        #expect(runs[2].environment == .prod && runs[2].file == "pipelines/azure-pipelines-release-prod.yml")
    }

    @Test func onlyThisRepositorysPipelines() {
        let json = """
        {"value": [{"id": 7, "name": "hub-cd-nonprod", "repository": {"name": "hub"}, "process": {"yamlFilename": "p/nonprod.yml"}},
                   {"id": 9, "name": "other", "repository": {"name": "elsewhere"}}]}
        """
        let definitions = AzureDevOps.definitions(Data(json.utf8), repository: "HUB")
        #expect(definitions.keys.sorted() == [7])
        #expect(definitions[7]?.file == "p/nonprod.yml")
    }

    @Test func aTimelineGivesStagesAndWhatFailed() {
        let json = """
        {"records": [
          {"id": "s2", "type": "Stage", "name": "Deploy (Non-Prod)", "identifier": "DeployNonProd", "order": 2, "state": "completed", "result": "skipped"},
          {"id": "s1", "type": "Stage", "name": "Migrate (Non-Prod)", "identifier": "MigrateNonProd", "order": 1, "state": "completed", "result": "failed"},
          {"id": "p1", "parentId": "s1", "type": "Phase", "name": "Migrate"},
          {"id": "j1", "parentId": "p1", "type": "Job", "name": "Apply migrations", "result": "failed"},
          {"id": "t1", "parentId": "j1", "type": "Task", "name": "Flyway Migrate", "result": "failed",
           "log": {"url": "https://dev.azure.com/Acme/Shop/_apis/build/builds/40/logs/12"},
           "issues": [{"type": "warning", "message": "slow"}, {"type": "error", "message": "Migration V12 failed: relation \\"orders\\" already exists"},
                      {"type": "error", "message": "Bash exited with code '1'."}]},
          {"id": "t2", "parentId": "j1", "type": "Task", "name": "Info", "result": "succeeded"}
        ]}
        """
        let (stages, failures) = AzureDevOps.timeline(Data(json.utf8))
        #expect(stages.map(\.identifier) == ["MigrateNonProd", "DeployNonProd"])
        #expect(stages.map(\.state) == [.failed, .skipped])
        #expect(failures.count == 1)
        #expect(failures[0].place == "Migrate (Non-Prod) › Apply migrations › Flyway Migrate")
        #expect(failures[0].issues.count == 2)
        #expect(failures[0].headline.hasPrefix("Migration V12 failed"))
        #expect(failures[0].logURL?.lastPathComponent == "12")
        #expect(!failures[0].looksTransient)
    }

    @Test func flakesAreToldApartFromRealFailures() {
        #expect(PipelineFailure(stage: "", job: "", step: "", issues: ["##[error]toomanyrequests: Rate exceeded"]).looksTransient)
        #expect(PipelineFailure(stage: "", job: "", step: "", issues: [], log: "curl: (6) Could not resolve host: registry").looksTransient)
        #expect(!PipelineFailure(stage: "", job: "", step: "", issues: ["error TS2304: Cannot find name 'x'"]).looksTransient)
    }

    @Test func aLogsTailLosesTimestampsAndColours() {
        let log = (1...5).map { "2026-10-22T09:00:0\($0).1234567Z \u{1B}[31mline \($0)\u{1B}[0m" }.joined(separator: "\n")
        #expect(PipelineFailure.tail(log, lines: 2) == "line 4\nline 5")
    }

    @Test func historyMergesAndSaysWhatStartedAndFinished() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let old = PipelineRun(id: 1, pipeline: "cd-nonprod", status: .running, queued: day,
                              stages: [PipelineStage(id: "a", identifier: "Build", name: "Build", state: .running)])
        let history = PipelineHistory().merging([old])
        #expect(PipelineHistory().events(after: [old]).isEmpty)   // the first look says nothing
        let done = PipelineRun(id: 1, pipeline: "cd-nonprod", status: .failed, queued: day)
        let next = PipelineRun(id: 2, pipeline: "cd-prod", status: .queued, queued: day.addingTimeInterval(60))
        let events = history.events(after: [next, done])
        #expect(events == [.started(next), .finished(done)])
        let merged = history.merging([next, done])
        #expect(merged.runs.map(\.id) == [2, 1])
        #expect(merged.runs[1].status == .failed && merged.runs[1].stages.count == 1)   // stages kept
    }

    @Test func lanesPerEnvironment() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        func run(_ id: Int, _ name: String, _ status: PipelineRun.Status, minutes: Double) -> PipelineRun {
            PipelineRun(id: id, pipeline: name, status: status, queued: day.addingTimeInterval(Double(id) * 3600),
                        started: day.addingTimeInterval(Double(id) * 3600), finished: day.addingTimeInterval(Double(id) * 3600 + minutes * 60))
        }
        let history = PipelineHistory().merging([
            run(5, "cd-nonprod", .failed, minutes: 3), run(4, "cd-nonprod", .succeeded, minutes: 10), run(3, "cd-nonprod", .succeeded, minutes: 6),
            run(2, "cd-prod", .succeeded, minutes: 12),
        ])
        let lanes = history.lanes
        #expect(lanes.map(\.environment) == [.nonProd, .prod])
        #expect(lanes[0].latest.id == 5 && lanes[0].lastGood?.id == 4)
        #expect(lanes[0].succeeded == 2 && lanes[0].finished == 3)
        #expect(lanes[0].typicalDuration == 600)
    }

    @Test func historyIsSavedPerProject() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pipelines-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = URL(fileURLWithPath: "/tmp/some/hub")
        let history = PipelineHistory().merging([PipelineRun(id: 3, pipeline: "cd-prod", status: .succeeded, queued: Date(timeIntervalSince1970: 1_800_000_000))])
        history.save(for: root, in: folder)
        #expect(PipelineHistory.load(for: root, in: folder) == history)
        #expect(PipelineHistory.load(for: URL(fileURLWithPath: "/tmp/other"), in: folder).runs.isEmpty)
    }

    @Test func theHealBriefCarriesTheLogAndTheRules() {
        let run = PipelineRun(id: 40, pipeline: "hub-cd", file: "pipelines/azure-pipelines-release-prod.yml", number: "20261022.1",
                              status: .failed, branch: "main", commit: "abc123def456", reason: "a push")
        let failure = PipelineFailure(stage: "Migrate", job: "Apply", step: "Flyway", issues: ["V12 failed"], log: "ERROR: relation exists")
        let brief = PipelineHeal.brief(run, failures: [failure])
        #expect(brief.contains("prod pipeline \"hub-cd\" failed (run 20261022.1 on main, commit abc123de"))
        #expect(brief.contains("pipelines/azure-pipelines-release-prod.yml"))
        #expect(brief.contains("Failed: Migrate › Apply › Flyway") && brief.contains("- V12 failed") && brief.contains("ERROR: relation exists"))
        #expect(brief.contains("Don't run, re-run or deploy the pipeline"))
        #expect(brief.contains("This is production"))
        #expect(PipelineHeal.brief(PipelineRun(id: 9, pipeline: "ci", status: .failed), failures: [], github: true).contains("gh run view 9 --log-failed"))
    }

    @Test func gitHubRunsBecomePipelineRuns() {
        let ci = CIRun(id: 9, title: "Fix it", workflow: "Deploy staging", branch: "main", status: "completed", conclusion: "failure", created: nil, url: nil)
        let run = PipelineRun(ci)
        #expect(run.status == .failed && run.environment == .nonProd && run.pipeline == "Deploy staging")
    }
}
