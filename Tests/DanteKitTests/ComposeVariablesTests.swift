import Foundation
import Testing
@testable import DanteKit

@Suite("Compose variables")
struct ComposeVariablesTests {
    let compose = """
    services:
      app:
        build: .
        ports: ["127.0.0.1:${PORT:-3000}:3000"]
        environment:
          DATABASE_URL: postgres://shop:${POSTGRES_PASSWORD}@db:5432/shop
          SESSION_SECRET: ${SESSION_SECRET}
          REGION: ${REGION:?Set REGION in .env}
          PRICE: "$$5"
      db:
        image: postgres:17
        environment:
          POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD in .env}
          # OLD_PASSWORD: ${OLD_PASSWORD:?gone}
          LOG_LEVEL: $LOG_LEVEL
    """

    @Test func readsEveryFormOnce() {
        let references = ComposeVariables.references(in: compose)
        #expect(references.map(\.name) == ["PORT", "POSTGRES_PASSWORD", "SESSION_SECRET", "REGION", "LOG_LEVEL"])
        #expect(references.first { $0.name == "POSTGRES_PASSWORD" }?.required == true)
        #expect(references.first { $0.name == "PORT" }?.hasDefault == true)
    }

    @Test func requiredAndBlankSecretsAreMissing() {
        let example = "REGION=af-south-1\nSESSION_SECRET=change-me\n"
        let missing = ComposeVariables.missing(compose: compose, env: ["PATH": "/bin"], example: example)
        #expect(missing.map(\.name) == ["POSTGRES_PASSWORD", "SESSION_SECRET", "REGION"])
        #expect(missing[0] == .init(name: "POSTGRES_PASSWORD", blocks: true, fill: .generated))
        #expect(missing[1].blocks == false && missing[1].fill == .generated)
        #expect(missing[2].fill == .example("af-south-1"))
        // LOG_LEVEL starts blank, which is fine; PORT has a default.
        #expect(ComposeVariables.missing(compose: compose, env: ["POSTGRES_PASSWORD": "a", "SESSION_SECRET": "b", "REGION": "c"]).isEmpty)
        // ":?" counts empty as missing.
        #expect(ComposeVariables.missing(compose: compose, env: ["POSTGRES_PASSWORD": "", "SESSION_SECRET": "b", "REGION": "c"]).map(\.name) == ["POSTGRES_PASSWORD"])
    }

    @Test func composeErrorsAddNames() {
        let error = "error while interpolating services.db.environment.POSTGRES_PASSWORD: required variable POSTGRES_PASSWORD is missing a value: Set POSTGRES_PASSWORD in .env"
        #expect(ComposeVariables.named(inError: error) == ["POSTGRES_PASSWORD"])
        let missing = ComposeVariables.missing(compose: "services: {}", env: [:], alsoRequired: ["API_HOST"])
        #expect(missing == [.init(name: "API_HOST", blocks: true, fill: .ask)])
    }

    @Test func planFillsWhatItCan() {
        let missing: [ComposeVariables.Missing] = [
            .init(name: "DB_PASSWORD", blocks: true, fill: .generated),
            .init(name: "REGION", blocks: true, fill: .example("af-south-1")),
            .init(name: "API_HOST", blocks: true, fill: .ask),
            .init(name: "QUEUE", blocks: true, fill: .ask),
        ]
        let lines = ComposeVariables.plan(missing, typed: ["API_HOST": " api.local "], password: { "generated" })
        #expect(lines.map(\.key) == ["DB_PASSWORD", "REGION", "API_HOST"])
        #expect(lines.map(\.value) == ["generated", "af-south-1", "api.local"])
    }

    @Test func secretsByName() {
        for name in ["POSTGRES_PASSWORD", "DB_PASS", "JWT_SECRET", "GITHUB_TOKEN", "STRIPE_API_KEY", "MYSQL_ROOT_PASSWORD"] {
            #expect(ComposeVariables.isSecret(name), "\(name)")
        }
        for name in ["PORT", "PASSPORT_URL", "REGION", "KEYCLOAK_URL", "TOKEN_URL_BASE"] {
            #expect(!ComposeVariables.isSecret(name), "\(name)")
        }
    }

    @Test func theShellWinsOverDotEnv() {
        let env = ComposeVariables.environment(shell: ["REGION": "eu"], dotEnv: "REGION=af\nPORT=4000\n")
        #expect(env["REGION"] == "eu" && env["PORT"] == "4000")
    }
}
