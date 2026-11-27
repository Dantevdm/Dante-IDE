import Foundation
import Testing
@testable import DanteKit

struct CustomerTests {
    private let yaml = """
    name: Acme Insurance
    summary: Policies and claims.
    detect:
      remotes: [bitbucket.org/acme]
      paths: acme
    theme: acme-blue
    infrastructure:
      tool: cloudformation
      format: json
      notes: [Tags come from parameters.]
    rules:
      - title: No wildcard resources
        severity: blocker
        pattern: '"Resource"\\s*:\\s*"\\*"'
        files: ["**/*.json"]
      - title: No Terraform state in the repo
        forbid: ["*.tfstate"]
      - Keep secrets in Secrets Manager
    naming:
      - what: Stack export
        of: export
        shape: "${AppId}-${StackName}-${Environment}-*"
      - what: IAM role name
        of: RoleName
        type: AWS::IAM::Role
        pattern: '^\\$\\{AppName\\}-[A-Za-z]+Role-\\$\\{Environment\\}$'
        example: "${AppName}-LambdaRole-${Environment}"
    process:
      - title: RFC
        when: Any change to infrastructure
        paths: ["infra/**"]
        steps: [Validate the template., Raise the RFC.]
    skills:
      - name: acme-cfn
        when: before raising an RFC
    mcp:
      acme-docs:
        command: npx
        args: [-y, acme-docs-mcp]
      broken: {}
    """

    private let template = """
    {
      "AWSTemplateFormatVersion": "2010-09-09",
      "Resources": {
        "Role": {
          "Type": "AWS::IAM::Role",
          "Properties": {
            "RoleName": {"Fn::Sub": "${AppName}-Lambda-${Environment}"},
            "Policies": [{"PolicyDocument": {"Statement": [{"Effect": "Allow", "Resource": "*"}]}}]
          }
        }
      },
      "Outputs": {
        "RoleArn": {"Export": {"Name": {"Fn::Sub": "${AppId}-${StackName}-${Environment}-RoleArn"}}},
        "Old": {"Export": {"Name": {"Fn::Sub": "${AWS::StackName}-Old"}}}
      }
    }
    """

    @Test func readsAProfileLeniently() {
        let profile = CustomerProfile.parse(yaml, id: "acme")
        #expect(profile.name == "Acme Insurance")
        #expect(profile.detectPaths == ["acme"])
        #expect(profile.theme == "acme-blue")
        #expect(profile.infrastructure?.sentence == "Infrastructure is always CloudFormation in JSON.")
        #expect(profile.rules.map(\.id) == ["no-wildcard-resources", "no-terraform-state-in-the-repo", "keep-secrets-in-secrets-manager"])
        #expect(profile.rules[0].severity == .blocker)
        #expect(!profile.rules[2].isCheckable)
        #expect(profile.naming.map(\.id) == ["stack-export", "iam-role-name"])
        #expect(profile.process.first?.steps.count == 2)
        #expect(profile.skills == [.init(name: "acme-cfn", when: "before raising an RFC")])
        #expect(profile.servers.map(\.name) == ["acme-docs"])
        #expect(profile.servers.first?.summary == "npx -y acme-docs-mcp")
        #expect(profile.problems == ["MCP server broken needs a command or a url."])
        #expect(CustomerProfile.parse("name: [", id: "x").problems.count == 1)
    }

    @Test func shapesBecomePatterns() {
        let naming = CustomerProfile.Naming(id: "e", what: "Export", shape: "${AppId}-${Environment}-*")
        #expect(naming.accepts("${AppId}-${Environment}-RoleArn"))
        #expect(!naming.accepts("${AWS::StackName}-RoleArn"))
        #expect(!naming.accepts("${AppId}-${Environment}-"))
    }

    @Test func aProjectChoosesWhatApplies() {
        let profile = CustomerProfile.parse(yaml, id: "acme")
        var choice = CustomerChoice()
        #expect(choice.applied(from: [profile]).isEmpty)
        choice.apply("acme", true)
        choice.set("acme", CustomerProfile.key("rule", "no-wildcard-resources"), on: false)
        choice.set("acme", "theme", on: false)
        choice.set("acme", CustomerProfile.key("mcp", "acme-docs"), on: false)
        let applied = try! #require(choice.applied(from: [profile]).first)
        #expect(applied.rules.count == 2)
        #expect(applied.theme == nil)
        #expect(applied.servers.isEmpty)
        #expect(!choice.isOn("acme", "theme"))
        choice.apply("acme", false)
        #expect(choice.isEmpty && choice.off.isEmpty)

        let defaults = UserDefaults(suiteName: "customer-tests")!
        defaults.removePersistentDomain(forName: "customer-tests")
        let root = URL(filePath: "/home/me/shop")
        choice.apply("acme", true)
        choice.save(projectRoot: root, defaults: defaults)
        #expect(CustomerChoice.load(projectRoot: root, defaults: defaults) == choice)
    }

    @Test func detectsTheirProjects() {
        let profile = CustomerProfile.parse(yaml, id: "acme")
        #expect(CustomerDetect.reason(profile, remotes: ["git@bitbucket.org:acme/claims.git".replacingOccurrences(of: ":", with: "/")], projectPath: "/home/me/claims", files: []) != nil)
        #expect(CustomerDetect.reason(profile, remotes: [], projectPath: "/home/me/Work/Acme/claims", files: []) == "Its folder’s path says acme.")
        #expect(CustomerDetect.reason(profile, remotes: ["github.com/me/shop"], projectPath: "/home/me/shop", files: ["a.json"]) == nil)
    }

    @Test func checksAProject() {
        let profile = CustomerProfile.parse(yaml, id: "acme")
        let files = ["infra/role.json", "infra/bucket.yaml", "main.tf", "terraform.tfstate", "package.json"]
        let texts = [
            "infra/role.json": template,
            "infra/bucket.yaml": "AWSTemplateFormatVersion: '2010-09-09'\nResources:\n  Bucket:\n    Type: AWS::S3::Bucket\n",
            "main.tf": "resource \"aws_s3_bucket\" \"b\" {}",
            "package.json": #"{"name": "x"}"#,
        ]
        let findings = CustomerCheck.run([profile], files: files, read: { texts[$0] })
        let titles = Set(findings.map(\.title))
        #expect(titles.contains("No wildcard resources"))
        #expect(findings.first { $0.title == "No wildcard resources" }?.line == 8)
        #expect(findings.contains { $0.title == "No Terraform state in the repo" && $0.file == "terraform.tfstate" })
        #expect(findings.contains { $0.kind == "infrastructure" && $0.file == "main.tf" })
        #expect(findings.contains { $0.kind == "infrastructure" && $0.file == "infra/bucket.yaml" && $0.detail.contains("YAML") })
        #expect(findings.contains { $0.title == "Stack export" && $0.detail.contains("${AWS::StackName}-Old") })
        #expect(!findings.contains { $0.title == "Stack export" && $0.detail.contains("RoleArn") })
        #expect(findings.contains { $0.title == "IAM role name" && $0.detail.contains("${AppName}-Lambda-${Environment}") })
        // Blockers first.
        #expect(findings.first?.severity == .blocker)
    }

    @Test func notesAgentsEdits() throws {
        let profile = CustomerProfile.parse(yaml, id: "acme")
        let root = URL(filePath: "/home/me/shop")
        let edit = try #require(ProposedChange.make(toolName: "Write", input: ["file_path": "/home/me/shop/infra/role.json", "content": .string(#"{"Resource": "*"}"#)], root: root))
        let note = try #require(CustomerCheck.note(for: edit, root: root, customers: [profile]))
        #expect(note.contains("No wildcard resources"))
        #expect(note.contains("needs RFC"))
        let plain = try #require(ProposedChange.make(toolName: "Write", input: ["file_path": "/home/me/shop/src/app.ts", "content": "export {}"], root: root))
        #expect(CustomerCheck.note(for: plain, root: root, customers: [profile]) == nil)
    }

    @Test func tellsTheAgents() {
        let profile = CustomerProfile.parse(yaml, id: "acme")
        let brief = CustomerBrief.brief([profile]) ?? ""
        #expect(brief.contains("built for Acme Insurance"))
        #expect(brief.contains("Infrastructure is always CloudFormation in JSON."))
        #expect(brief.contains("Use the acme-cfn skill before raising an RFC."))
        #expect(brief.contains("ui_standards theme=acme-blue"))
        #expect(CustomerBrief.report([profile], topic: "rfc").contains("1. Validate the template."))
        #expect(CustomerBrief.checkName([profile], name: "${AppId}-${StackName}-${Environment}-Arn", what: "export").hasPrefix("OK"))
        #expect(CustomerBrief.checkName([profile], name: "orders-arn", what: "export").hasPrefix("Not OK"))
        #expect(CustomerBrief.brief([]) == nil)
    }

    @Test func theMCPServerGetsThemFromItsEnvironment() throws {
        let library = FileManager.default.temporaryDirectory.appending(path: "customers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: library) }
        let file = try CustomerLibrary.create(name: "Acme Insurance", in: library)
        #expect(file.path.hasSuffix("customers/acme-insurance/customer.yaml"))
        let loaded = CustomerLibrary.load(library: library)
        #expect(loaded.map(\.name) == ["Acme Insurance"])
        #expect(loaded.first?.problems == [])
        #expect(loaded.first?.naming.count == 2)
        var choice = CustomerChoice(customers: ["acme-insurance"])
        choice.set("acme-insurance", "infrastructure", on: false)
        let value = try #require(choice.environmentValue(library: loaded))
        let applied = CustomerChoice.applied(environmentValue: value)
        #expect(applied.map(\.name) == ["Acme Insurance"])
        #expect(applied.first?.infrastructure == nil)
        #expect(throws: ThemeMaker.Failure.self) { try CustomerLibrary.create(name: "Acme Insurance", in: library) }
    }

    @Test func theConfigCarriesTheirServers() {
        let json = MCPConfigFile.json(command: "/bin/dante", environment: [:], servers: ["acme-docs": ["command": "npx"], "dante": ["command": "evil"]])
        #expect(json.contains("acme-docs"))
        #expect(json.contains("/bin/dante"))
        #expect(!json.contains("evil"))
    }
}
