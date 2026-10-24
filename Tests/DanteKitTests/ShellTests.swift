import Foundation
import Testing
@testable import DanteKit

@Suite struct ShellTests {
    @Test func aCommandThatHangsIsStoppedAtItsTimeout() async {
        let started = ContinuousClock.now
        let output = await Shell.run(["sleep", "30"], in: FileManager.default.temporaryDirectory, timeout: .milliseconds(300))
        #expect(output.status == 124)
        #expect(output.stderr.contains("didn’t finish"))
        #expect(started.duration(to: .now) < .seconds(5))
    }

    @Test func cancellingTheTaskStopsTheCommand() async {
        let started = ContinuousClock.now
        let task = Task { await Shell.run(["sleep", "30"], in: FileManager.default.temporaryDirectory) }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let output = await task.value
        #expect(!output.succeeded)
        #expect(started.duration(to: .now) < .seconds(5))
    }

    @Test func aQuickCommandIsUntouchedByItsTimeout() async {
        let output = await Shell.run(["echo", "hi"], in: FileManager.default.temporaryDirectory, timeout: .seconds(10))
        #expect(output == Shell.Output(status: 0, stdout: "hi", stderr: ""))
    }
}
