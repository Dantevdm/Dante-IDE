import Foundation
import Testing
@testable import DanteKit

@Suite struct ProblemsTests {
    func diagnostic(_ line: Int, _ severity: LSPDiagnostic.Severity) -> LSPDiagnostic {
        LSPDiagnostic(range: LSPRange(start: LSPPosition(line: line, character: 0), end: LSPPosition(line: line, character: 1)), severity: severity, message: "m\(line)")
    }

    @Test func groupsByFileWithErrorsFirst() {
        let files = Problems.files([
            "/p/Sources/b.swift": [diagnostic(1, .warning)],
            "/p/Sources/a.swift": [diagnostic(2, .warning), diagnostic(3, .hint)],
            "/p/Sources/z.swift": [diagnostic(4, .error), diagnostic(5, .warning)],
            "/p/.build/x.swift": [diagnostic(1, .error)],
            "/elsewhere/c.swift": [diagnostic(1, .error)],
            "/p/only-hints.swift": [diagnostic(1, .hint)],
        ], root: URL(filePath: "/p"))
        #expect(files.map(\.path) == ["Sources/z.swift", "Sources/a.swift", "Sources/b.swift"])
        #expect(files[0].errors == 1 && files[0].warnings == 1 && files[1].diagnostics.count == 1)
        let withHints = Problems.files(["/p/only-hints.swift": [diagnostic(1, .hint)]], root: URL(filePath: "/p"), includeHints: true)
        #expect(withHints.count == 1)
    }
}
