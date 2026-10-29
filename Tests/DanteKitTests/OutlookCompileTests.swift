import Foundation
import Testing
@testable import DanteKit

/// The scripts must compile on this Mac: a word some scripting addition defines (`since`)
/// stopped the mail script with "Expected expression but found parameter name".
struct OutlookCompileTests {
    @Test func scriptsCompile() throws {
        let scripts = [
            Outlook.mailScript(hours: 24, limit: 5),
            Outlook.calendarScript(from: Date(), to: Date().addingTimeInterval(86_400)),
            Outlook.draftScript(to: ["ana@example.com"], subject: "Thursday", body: "Thursday works."),
        ]
        for script in scripts {
            var error: NSDictionary?
            #expect(NSAppleScript(source: script)?.compileAndReturnError(&error) == true, "\(error ?? [:])")
        }
    }
}
