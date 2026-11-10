import Foundation
import Testing
@testable import DanteKit

@Test func managedSizesArePricedAndRestoresNamed() {
    #expect(DODatabaseSizes.monthly("db-s-2vcpu-4gb", nodes: 2) == 120)
    #expect(DODatabaseSizes.monthly("db-unknown") == nil)
    #expect(DODatabaseSizes.title("db-s-1vcpu-1gb") == "1 vCPU · 1 GB")
    let backup = DODatabaseBackup(createdAt: "2026-11-09T03:15:00Z", sizeGigabytes: 0.2)
    #expect(backup.date != nil)
    let name = DODatabaseSizes.restoredName(String(repeating: "a", count: 60), backup: backup.date!)
    #expect(name.count == 63)
    #expect(DOSignIn.scopes.contains("database:update"))
}
