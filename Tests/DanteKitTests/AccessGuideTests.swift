import Foundation
import Testing
@testable import DanteKit

@Test func aServerReadingTheAuthorizationHeaderNeedsAKey() {
    let files = [
        "api/internal/auth/middleware.go": """
        func Require(next http.Handler) http.Handler {
            return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
                token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
        """,
        "api/internal/auth/middleware_test.go": "r.Header.Get(\"Authorization\") // Bearer",
        "api/scripts/seed.sh": "#!/bin/sh\ndocker compose exec db psql -c 'insert into admins …'\ncurl -H \"Authorization: Bearer $KEY\" http://localhost:8080/api/keys",
        "api/scripts/make-key.sh": "#!/bin/sh\ncurl -X POST \"$API_URL/api/keys\" -H \"Authorization: Bearer $ADMIN_KEY\"",
        "api/scripts/migrate.sh": "#!/bin/sh",
        "admin/package.json": #"{"scripts": {"dev": "vite", "tokens": "node scripts/generate-tokens.mjs", "lint": "eslint ."}}"#,
        "admin/scripts/generate-tokens.mjs": "// writes src/styles/tokens.css and src/theme/theme.ts from the brand's colours",
        "admin/package-lock.json": "{}",
    ]
    let guide = AccessGuide.detect(files: Array(files.keys).sorted(), read: { files[$0] }, variables: ["SHOP_ADMIN_KEY", "POSTGRES_PASSWORD", "OPENAI_API_KEY"], component: "api")
    #expect(guide.signIn == [.apiKey])
    #expect(guide.header == "Authorization: Bearer <key>")
    #expect(guide.evidence.contains { $0.contains("api/internal/auth/middleware.go") })
    #expect(!guide.evidence.contains { $0.contains("_test.go") })
    #expect(guide.headline.hasPrefix("Requests need an API key (Authorization: Bearer <key>)"))
    // The admin key from the environment, never a database's or a vendor's.
    #expect(guide.steps.contains { $0.title == "The first key is SHOP_ADMIN_KEY" && $0.place == .note })
    #expect(!guide.steps.contains { $0.title.contains("POSTGRES") || $0.title.contains("OPENAI") })
    // A seed script runs in its folder; a package script that runs a file covers that file.
    // A seed script that talks to localhost says it's for the local stack.
    let seed = guide.steps.first { $0.run == "./scripts/seed.sh" }
    #expect(seed?.folder == "api" && seed?.place == .local)
    #expect(seed?.note?.contains("local stack") == true)
    let key = guide.steps.first { $0.run == "./scripts/make-key.sh" }
    #expect(key?.note?.contains("{url}") == true)
    #expect(!guide.steps.contains { $0.run == "./scripts/migrate.sh" })
    // Design tokens aren't a way in, by package script or by file.
    #expect(!guide.steps.contains { $0.run?.contains("tokens") == true })
    let localOnly = AccessGuide(signIn: [.apiKey], steps: [seed!])
    #expect(localOnly.headline.contains("only found how to make one on the local stack"))
}

@Test func anAPIKeyHeaderIsNamedTheWayPeopleWriteIt() {
    #expect(AccessGuide.apiKeyHeader(in: #"key := r.Header.Get("x-api-key")"#) == "X-API-Key")
    #expect(AccessGuide.apiKeyHeader(in: #"req.headers['X-Shop-Api-Token']"#) == "X-Shop-API-Token")
    #expect(AccessGuide.apiKeyHeader(in: #"fetch(url, {headers: {"Content-Type": "x"}})"#) == nil)
}

@Test func djangoMakesItsFirstAdminInsideTheApp() {
    let files = ["manage.py": "", "shop/views.py": "from django.contrib.auth import authenticate"]
    let guide = AccessGuide.detect(files: Array(files.keys), read: { files[$0] }, component: "web")
    #expect(guide.signIn == [.password])
    #expect(guide.steps.first == AccessGuide.Step(title: "Make the first admin", place: .console, component: "web",
                                                  run: "python manage.py createsuperuser", note: "Django's admin is at {url}/admin."))
}

@Test func aReadmeSectionAboutGettingInBecomesAStep() {
    let readme = """
    # Shop

    ## Running

    ```sh
    make dev
    ```

    ## Getting an API key

    ```sh
    # one per person
    $ curl -X POST http://localhost:8080/api/keys -d '{"name":"Ana"}'
    ```

    ## Sign-in for the admin

    Ask Sam for an invitation.
    """
    let sections = AccessGuide.readmeSections(readme)
    #expect(sections == [
        .init(heading: "Getting an API key", command: #"curl -X POST {url}/api/keys -d '{"name":"Ana"}'"#, text: nil),
        .init(heading: "Sign-in for the admin", command: nil, text: "Ask Sam for an invitation."),
    ])
    let step = AccessGuide.Step(title: "x", place: .local, run: sections[0].command)
    #expect(step.command(url: URL(string: "https://shop.example.app/")) == #"curl -X POST https://shop.example.app/api/keys -d '{"name":"Ana"}'"#)
}

@Test func theFileWinsAndReadsLeniently() {
    let yaml = """
    sign_in: API key
    header: "X-API-Key: <key>"
    summary: Every request needs a key; admins make them.
    steps:
      - title: Make the first admin key
        where: console
        component: api
        run: ./make-key --admin
        note: Prints it once.
      - name: Open the admin
        command: open {url}/admin
      - Keys last a year.
    """
    let guide = AccessGuide.read(yaml: yaml)
    #expect(guide?.isWritten == true)
    #expect(guide?.signIn == [.apiKey])
    #expect(guide?.headline == "Every request needs a key; admins make them.")
    #expect(guide?.steps.map(\.place) == [.console, .local, .note])
    #expect(guide?.steps[0].component == "api")
    #expect(guide?.steps[1].run == "open {url}/admin")
    #expect(AccessGuide.read(yaml: "nothing: here") == nil)
}

@Test func aDraftSavesAsAFileThatReadsBack() {
    let draft = AccessGuide(signIn: [.apiKey, .password], header: "Authorization: Bearer <key>",
                            steps: [.init(title: "Run \"seed\"", place: .local, folder: "api", run: "./scripts/seed.sh")])
    let back = AccessGuide.read(yaml: draft.yaml)
    #expect(back?.signIn == draft.signIn)
    #expect(back?.header == draft.header)
    #expect(back?.steps == draft.steps)
    #expect(draft.brief(appName: "shop", url: nil).contains(AccessGuide.path))
}
