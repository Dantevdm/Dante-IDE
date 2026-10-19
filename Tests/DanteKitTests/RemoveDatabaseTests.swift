import DanteKit
import Foundation
import Testing

struct RemoveDatabaseTests {
    private let plan = NewDatabasePlan(engine: .postgres, project: "Shop", port: 5434, password: "pw" + "123")

    private func created(in compose: String?) -> (compose: String, env: String, example: String) {
        let composeText = ComposeEditing.adding(service: plan.composeService, volume: plan.volume, to: compose)
        let env = EnvFile.setting(plan.envValues, in: "API_KEY=x\n", comment: "PostgreSQL for local development, added by Dante")
        let example = EnvFile.setting(plan.exampleValues, in: nil, comment: "PostgreSQL for local development")
        return (composeText, env, example)
    }

    @Test func undoesTheWizardInAProjectThatHadNoCompose() {
        let files = created(in: nil)
        let read: (String) -> String? = { ["compose.yaml": files.compose, ".env": files.env, ".env.example": files.example][$0] }
        let removal = DatabaseRemoval.plan(for: plan.connection, composePath: "compose.yaml", read: read)
        #expect(removal.service == "db")
        #expect(removal.volume == "db-data")
        let byPath = Dictionary(uniqueKeysWithValues: removal.edits.map { ($0.path, $0) })
        // The compose file only had this database, so it goes.
        #expect(byPath["compose.yaml"]?.text == nil && byPath["compose.yaml"] != nil)
        #expect(byPath[".env"]?.text == "API_KEY=x\n")
        #expect(byPath[".env"]?.changes == ["DATABASE_URL", "POSTGRES_PASSWORD"])
        #expect(byPath[".env.example"] != nil && byPath[".env.example"]?.text == nil)
    }

    @Test func leavesTheRestOfAComposeFileAlone() {
        let before = """
        # the app
        services:
          web:
            build: .
            ports:
              - "8080:8080"
            volumes:
              - cache:/cache

        volumes:
          cache:
        """
        let files = created(in: before + "\n")
        let removed = ComposeEditing.removing(service: "db", from: files.compose)
        #expect(removed.found && removed.volume == "db-data")
        #expect(removed.text == before + "\n")
        #expect(ComposeEditing.removing(service: "nope", from: before).found == false)
    }

    @Test func keepsAPasswordAnotherServiceReads() {
        let compose = """
        services:
          db:
            image: postgres:17-alpine
            environment:
              POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
            volumes:
              - db-data:/var/lib/postgresql/data
          backup:
            image: backup
            environment:
              PGPASSWORD: ${POSTGRES_PASSWORD}
            volumes:
              - db-data:/data
        volumes:
          db-data:
        """
        let env = "POSTGRES_PASSWORD=pw\nDATABASE_URL=postgres://shop:pw@localhost:5434/shop\n"
        let removal = DatabaseRemoval.plan(for: plan.connection, composePath: "compose.yaml") { ["compose.yaml": compose, ".env": env][$0] }
        let composeEdit = removal.edits.first { $0.path == "compose.yaml" }
        // The backup service still mounts the volume and reads the password, so neither goes.
        #expect(removal.service == "db" && removal.volume == nil)
        #expect(composeEdit?.text?.contains("db-data:") == true)
        #expect(composeEdit?.text?.contains("backup:") == true)
        #expect(composeEdit?.text?.contains("image: postgres") == false)
        #expect(removal.edits.first { $0.path == ".env" }?.text == "POSTGRES_PASSWORD=pw\n")
    }

    @Test func sqliteLosesItsKeyAndFile() {
        let sqlite = NewDatabasePlan(engine: .sqlite, project: "Shop")
        let env = EnvFile.setting(sqlite.envValues, in: "A=1\n", comment: "SQLite for local development, added by Dante")
        let removal = DatabaseRemoval.plan(for: sqlite.connection, composePath: nil) { $0 == ".env" ? env : nil }
        #expect(removal.file == "data/shop.sqlite")
        #expect(removal.edits.map(\.path) == [".env"])
        #expect(removal.edits.first?.text == "A=1\n")
    }
}
