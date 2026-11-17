import Foundation
import Testing
@testable import DanteKit

struct MapCommandLineTests {
    private func map(_ files: [String: String]) -> SystemMap {
        let paths = Array(files.keys).sorted()
        return SystemMap.build(files: paths, read: { files[$0] }, modules: ArchitectureGraph.folders(paths))
    }

    @Test func aPythonCommandLineToolCallingAWSDrawsItsCommandsAndServices() {
        let built = map([
            "pyproject.toml": "[project]\nname = \"shop-tool\"\n\n[project.scripts]\nshop = \"shop_tool.cli:main\"\n",
            "src/shop_tool/cli.py": """
            import click
            from .aws import make_client

            @click.group()
            def cli():
                pass

            @cli.command("list-orders")
            @click.option(
                "--limit",
                default=10,
            )
            def list_orders(limit):
                make_client("sqs")

            @cli.command()
            def sync_stock():
                pass
            """,
            "src/shop_tool/aws.py": """
            import boto3

            def make_client(service):
                return boto3.Session().client(service)

            def whoami():
                return boto3.client("sts").get_caller_identity()
            """,
            "src/shop_tool/queues.py": "from .aws import make_client\nq = make_client(\"sqs\")\nhttp = some_client(\"orders\")\n",
            "tests/test_cli.py": "@cli.command(\"not-a-command\")\ndef nope(): pass\n",
        ])
        let cli = built.part("cli")
        #expect(cli?.name == "shop")
        #expect(cli?.kind == .cli)
        #expect(cli?.items.map(\.text) == ["list-orders", "sync-stock"])
        #expect(cli?.items.first?.line == 8)
        let outside = built.parts.filter { $0.lane == .outside }.map(\.id).sorted()
        #expect(outside == ["aws:sqs", "aws:sts"])
        #expect(built.uses("cli").map(\.lane) == [.backend])
        #expect(built.isUseful)
    }

    @Test func otherLanguagesNameAWSByPackageAndCommandsByCobraOrArgparse() {
        let built = map([
            "cmd/shop/main.go": "package main\nimport (\n\t\"github.com/spf13/cobra\"\n\t\"github.com/aws/aws-sdk-go-v2/service/dynamodb\"\n)\nvar root = &cobra.Command{Use: \"shop\"}\nvar sync = &cobra.Command{Use: \"sync\"}\n",
            "web/api/upload.ts": "import { S3Client } from \"@aws-sdk/client-s3\"\n",
        ])
        #expect(built.part("cli")?.items.map(\.text) == ["shop", "sync"])
        #expect(built.part("aws:dynamodb")?.name == "DynamoDB")
        #expect(built.parts.contains { $0.id == "ext:s3" || $0.id == "aws:s3" })
        #expect(SystemMap.commands(files: ["tool.py"], text: { _ in "p = sub.add_parser('import')\n" }).map(\.name) == ["import"])
    }

    @Test func pythonCallsCountOnlyForKnownServicesInBotoProjects() {
        #expect(SystemMap.awsServices(in: "x = client(\"sqs\")", isPython: true, usesBoto: false).isEmpty)
        #expect(SystemMap.awsServices(in: "x = client(\"orders\")", isPython: true, usesBoto: true).isEmpty)
        #expect(SystemMap.awsServices(in: "x = session.resource(\"dynamodb\")", isPython: true, usesBoto: true) == ["dynamodb"])
    }
}
