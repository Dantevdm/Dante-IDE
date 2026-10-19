import DanteKit
import Testing

struct ShellSnippetTests {
    @Test func untaggedCommandsAreRecognised() {
        #expect(ShellSnippet.command(from: "docker compose up -d db", language: nil) == "docker compose up -d db")
        #expect(ShellSnippet.command(from: "$ cp .env.example .env\n$ docker compose up -d db\n", language: nil)
                == "cp .env.example .env && docker compose up -d db")
        #expect(ShellSnippet.command(from: "PORT=8080 ./run.sh", language: nil) == "PORT=8080 ./run.sh")
    }

    @Test func shellBlocksAreTidied() {
        let block = """
        # start the database
        docker compose up \\
          -d db

        psql -h localhost -p 5434
        """
        #expect(ShellSnippet.command(from: block, language: "bash") == "docker compose up -d db && psql -h localhost -p 5434")
        #expect(ShellSnippet.command(from: "make test", language: "sh") == "make test")
    }

    @Test func codeIsNotACommand() {
        #expect(ShellSnippet.command(from: "let x = 1", language: nil) == nil)
        #expect(ShellSnippet.command(from: "docker compose up", language: "yaml") == nil)
        #expect(ShellSnippet.command(from: "SELECT * FROM users;", language: nil) == nil)
        #expect(ShellSnippet.command(from: "services:\n  db:\n    image: postgres", language: nil) == nil)
        #expect(ShellSnippet.command(from: "\n# only a comment\n", language: "bash") == nil)
    }
}
