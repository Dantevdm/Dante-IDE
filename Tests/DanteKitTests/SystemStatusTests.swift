import DanteKit
import Testing

@Suite struct SystemStatusTests {
    @Test func detectsCodexFromExplicitInstallPath() {
        let status = SystemStatus.detect(environment: ["DANTE_CODEX": "/bin/sh"])
        #expect(status.codexPath == "/bin/sh")
    }

    @Test func unavailableCodexIsRepresentedExplicitly() {
        let status = SystemStatus.detect(environment: [:], codexLocator: { _, _, _ in nil })
        #expect(status.codexPath == nil)
    }
}
