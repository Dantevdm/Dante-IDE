import Foundation
import Testing
@testable import DanteKit

@Suite struct AlarmTests {
    @Test func readsAlarmSourcesFromProjectYAML() {
        let info = ProjectInfo.parse(projectYAML: """
        operate:
          alarms:
            - { source: cloudwatch, profile: prod, region: eu-west-1, prefix: "shop-" }
            - { source: command, run: "./scripts/alarms.sh" }
            - "datadog-alarms --json"
            - { source: carrier-pigeon }
        """)
        #expect(info.alarms == [.cloudwatch(profile: "prod", region: "eu-west-1", prefix: "shop-"),
                                .command("./scripts/alarms.sh"), .command("datadog-alarms --json")])
        #expect(info.alarms[0].arguments == ["aws", "cloudwatch", "describe-alarms", "--output", "json",
                                             "--alarm-name-prefix", "shop-", "--profile", "prod", "--region", "eu-west-1"])
        #expect(info.alarms[0].label == "CloudWatch · prod · eu-west-1 · shop-*")
    }

    @Test func readsCloudWatchOutput() {
        let json = """
        {
          "MetricAlarms": [
            {
              "AlarmName": "shop-api 5xx",
              "AlarmArn": "arn:aws:cloudwatch:eu-west-1:123456789012:alarm:shop-api 5xx",
              "StateValue": "ALARM",
              "StateReason": "Threshold Crossed: 1 datapoint [12.0] was greater than the threshold (5.0).",
              "StateUpdatedTimestamp": "2026-10-06T14:02:11.512Z"
            },
            { "AlarmName": "shop-queue depth", "StateValue": "INSUFFICIENT_DATA" }
          ],
          "CompositeAlarms": [
            { "AlarmName": "shop-overall", "StateValue": "OK", "StateUpdatedTimestamp": "2026-10-06T13:00:00Z" }
          ]
        }
        """
        let alarms = Alarms.parseCloudWatch(json)
        #expect(alarms.map(\.state) == [.alarm, .unknown, .ok])
        #expect(alarms[0].reason?.hasPrefix("Threshold Crossed") == true && alarms[0].updated != nil)
        #expect(alarms[0].url?.absoluteString == "https://eu-west-1.console.aws.amazon.com/cloudwatch/home?region=eu-west-1#alarmsV2:alarm/shop-api%205xx")
        #expect(alarms[1].id == "cloudwatch:shop-queue depth" && alarms[1].url == nil)
        #expect(alarms[2].updated == Date(timeIntervalSince1970: 1_791_291_600))
    }

    @Test func readsAnyCommandsJSON() {
        let alarms = Alarms.parseCommand("""
        [{"name": "Checkout latency", "state": "firing", "reason": "p95 > 2s", "url": "https://grafana.example.com/a/1"},
         {"id": "dd-7", "name": "Disk", "status": "OK"},
         {"state": "alarm"}]
        """)
        #expect(alarms.count == 2 && alarms[0].state == .alarm && alarms[0].id == "Checkout latency")
        #expect(alarms[1].id == "dd-7" && alarms[1].state == .ok)
        #expect(Alarms.parseCommand(#"{"alarms": [{"name": "x", "state": "weird"}]}"#).first?.state == .unknown)
        #expect(Alarms.parseCommand("not json").isEmpty)
    }

    @Test func flagsAlarmsFiringAfterTheirTaskIsDone() {
        let firing = Alarm(id: "a", name: "API errors", state: .alarm)
        let quiet = Alarm(id: "b", name: "Disk", state: .ok)
        let tasks = [PlanTask(id: "SH-1", title: "Fix API errors", phase: "operate", state: .done, alarm: "a"),
                     PlanTask(id: "SH-2", title: "Disk", phase: "operate", state: .done, alarm: "b")]
        let refired = Alarms.refired([firing, quiet], tasks: tasks)
        #expect(refired.count == 1 && refired[0].task.id == "SH-1")
        // An open task for it means someone's already on it.
        #expect(Alarms.refired([firing], tasks: tasks + [PlanTask(id: "SH-3", title: "Again", phase: "operate", alarm: "a")]).count == 1)
        let prompt = Alarms.investigatePrompt(firing, errors: [])
        #expect(prompt.contains("API errors") && prompt.contains("Don't change anything yet"))
    }

    @Test func keepsTheAlarmOnATask() throws {
        let yaml = try TaskFile(prefix: "SH", tasks: [PlanTask(id: "SH-1", title: "x", phase: "operate", alarm: "arn:1")]).encode()
        #expect(yaml.contains("alarm: arn:1"))
        #expect(try TaskFile.decode(yaml).tasks[0].alarm == "arn:1")
    }

    @MainActor @Test func reportsAlarmsThatStartFiring() async throws {
        let folder = try TemporaryFolder()
        try folder.write("alarms.json", #"[{"id": "a", "name": "API", "state": "ok"}, {"id": "b", "name": "Disk", "state": "alarm"}]"#)
        let monitor = AlarmMonitor()
        var fired: [String] = []
        monitor.onFire = { fired += $0.map(\.id) }
        monitor.watch([.command("cat alarms.json"), .command("exit 3")], in: folder.url, every: .seconds(3600))
        monitor.stop()
        await monitor.poll()
        #expect(monitor.alarms.map(\.id) == ["b", "a"] && fired.isEmpty)
        #expect(monitor.errors["exit 3"] == "Exited with status 3.")
        try folder.write("alarms.json", #"[{"id": "a", "name": "API", "state": "alarm"}, {"id": "b", "name": "Disk", "state": "alarm"}]"#)
        await monitor.poll(notifying: true)
        // Disk was already firing; only API is news.
        #expect(fired == ["a"])
    }
}

struct OperateSpellingTests {
    @Test func readsHealthAndNestedLogs() {
        let info = ProjectInfo.parse(projectYAML: """
        operate:
          health:
            - url: "http://localhost:3000/api/stats"
              expect: 200
            - https://example.com/health
          logs:
            command: "tail -f backend/data/app.log"
        """)
        #expect(info.checks.map(\.name) == ["localhost:3000/api/stats", "example.com/health"])
        #expect(info.logsCommand == "tail -f backend/data/app.log")
        #expect(ProjectInfo.parse(projectYAML: "operate:\n  checks:\n    - { name: api, url: https://x.dev/h }\n  logs: fly logs\n").checks.map(\.name) == ["api"])
    }
}
