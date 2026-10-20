import Foundation
import Testing
@testable import DanteKit

struct InfrastructureTests {
    static let files: [String: String] = [
        "infra/cloudformation/shop-alb-stack/templates/shop-alb-template.json": """
        {"AWSTemplateFormatVersion": "2010-09-09", "Parameters": {"Listener": {"Type": "String"}},
         "Resources": {
          "TargetGroup": {"Type": "AWS::ElasticLoadBalancingV2::TargetGroup", "Properties": {"Port": 8080}},
          "ListenerRule": {"Type": "AWS::ElasticLoadBalancingV2::ListenerRule", "Properties": {"ListenerArn": {"Ref": "Listener"}, "Actions": [{"TargetGroupArn": {"Ref": "TargetGroup"}}]}},
          "Ingress": {"Type": "AWS::EC2::SecurityGroupIngress", "Properties": {"FromPort": 8080}},
          "DnsRecord": {"Type": "AWS::Route53::RecordSet", "Properties": {"Name": "shop.example.com"}}
         },
         "Outputs": {"TargetGroupArn": {"Value": {"Ref": "TargetGroup"}}}}
        """,
        "infra/cloudformation/shop-alb-stack/templates/shop-alb-prod-baked.json": """
        {"AWSTemplateFormatVersion": "2010-09-09", "Resources": {"TargetGroup": {"Type": "AWS::ElasticLoadBalancingV2::TargetGroup"}}}
        """,
        "infra/cloudformation/shop-alb-stack/parameters/shop-alb-params-non-prod.json": #"[{"ParameterKey": "Listener", "ParameterValue": "x"}]"#,
        "infra/cloudformation/shop-ecs-stack/templates/shop-ecs-template.yaml": """
        AWSTemplateFormatVersion: '2010-09-09'
        Resources:
          Logs:
            Type: AWS::Logs::LogGroup
          Cluster:
            Type: AWS::ECS::Cluster
          Task:
            Type: AWS::ECS::TaskDefinition
            Properties:
              ContainerDefinitions:
                - Image: !ImportValue shop-ecr-uri
                  LogConfiguration:
                    Options:
                      awslogs-group: !Ref Logs
          Service:
            Type: AWS::ECS::Service
            DependsOn: Task
            Properties:
              Cluster: !Ref Cluster
              TaskDefinition: !Ref Task
              LoadBalancers:
                - TargetGroupArn: !ImportValue shop-target-group
        """,
        "infra/cloudformation/shop-ecr-stack/template/shop-ecr-non-prod.json": """
        {"AWSTemplateFormatVersion": "2010-09-09", "Resources": {"Repository": {"Type": "AWS::ECR::Repository"}}}
        """,
        "infra/containers/Dockerfile": "FROM eclipse-temurin:21",
        "infra/azure-devops/pipelines/azure-pipelines-release-nonprod.yml": """
        trigger:
          branches:
            include:
              - develop
        stages:
          - stage: PackageNonProd
            jobs:
              - job: ImageBuild
                steps:
                  - script: docker build -f infra/containers/Dockerfile -t shop .
                    displayName: Build image
                  - task: AWSShellScript@1
                    displayName: Push to ECR
                    inputs:
                      inlineScript: |
                        aws ecr get-login-password | docker login
                        docker push $(repo)
          - stage: MigrateNonProd
            dependsOn: PackageNonProd
            jobs:
              - deployment: Migrate
                environment: shop-nonprod
                strategy:
                  runOnce:
                    deploy:
                      steps:
                        - bash: flyway -locations=filesystem:database migrate
                          displayName: Flyway migrate
          - stage: RolloutNonProd
            dependsOn: MigrateNonProd
            jobs:
              - job: Deploy
                steps:
                  - task: AWSShellScript@1
                    inputs:
                      inlineScript: aws ecs update-service --force-new-deployment --service $(service)
        """,
        "services/web/package.json": #"{"name":"web"}"#,
    ]

    func detect() -> Infrastructure {
        Infrastructure.detect(files: Array(Self.files.keys), read: { Self.files[$0] })
    }

    @Test func readsStacksAndTheirResources() {
        let infra = detect()
        #expect(infra.provider == .aws)
        #expect(infra.stacks.map(\.name) == ["shop-alb-stack", "shop-ecr-stack", "shop-ecs-stack"])
        let alb = infra.stacks[0]
        // The template and its baked copy are one stack; environments come from file names.
        #expect(alb.files.count == 2 && Set(alb.environments) == ["prod", "non-prod"])
        #expect(infra.resources.filter { $0.stack == "shop-alb-stack" }.count == 4)
        let service = infra.resources.first { $0.name == "Service" }
        #expect(service?.service == "ECS service" && service?.tier == .compute && service?.line != nil)
        #expect(infra.resources.first { $0.name == "Repository" }?.tier == .registry)
        #expect(infra.dockerfiles == ["infra/containers/Dockerfile"])
    }

    @Test func linksFollowTheTraffic() {
        let infra = detect()
        func linked(_ a: String, _ b: String) -> Infrastructure.Link? {
            infra.links.first { infra.resource($0.from)?.name == a && infra.resource($0.to)?.name == b }
        }
        // Declared in the template: the service runs its task on the cluster; the task logs.
        #expect(linked("Service", "Task")?.declared == true)
        #expect(linked("Task", "Logs")?.label == "logs to")
        #expect(linked("ListenerRule", "TargetGroup")?.label == "routes to")
        // Across stacks, by kind: DNS → rule, target group → service, task → registry.
        #expect(linked("DnsRecord", "ListenerRule") != nil)
        #expect(linked("TargetGroup", "Service")?.declared == false)
        #expect(linked("Task", "Repository")?.label == "pulls image")
    }

    @Test func readsTheAzurePipeline() throws {
        let infra = detect()
        let pipeline = try #require(infra.pipelines.first)
        #expect(pipeline.system == "Azure DevOps" && pipeline.branches == ["develop"] && pipeline.environment == "non-prod")
        #expect(pipeline.stages.map(\.name) == ["Package non prod", "Migrate non prod", "Rollout non prod"])
        #expect(pipeline.stages.map(\.kind) == [.push, .migrate, .deploy])
        #expect(pipeline.stages[1].dependsOn == ["PackageNonProd"] && pipeline.stages[1].environment == "shop-nonprod")
        #expect(pipeline.stages[0].steps.map(\.title) == ["Build image", "Push to ECR"])
        // What each stage changes.
        func targets(_ stage: String) -> [String] {
            infra.deploys.filter { $0.from == pipeline.id + "#" + stage }.compactMap { infra.resource($0.to)?.name }
        }
        #expect(targets("PackageNonProd") == ["Repository"])
        #expect(targets("MigrateNonProd") == ["Database"])
        #expect(targets("RolloutNonProd") == ["Service"])
        #expect(infra.resource("outside/database")?.isOutside == true)
    }

    @Test func tellsHowItWorks() {
        let story = InfraStory(detect())
        let text = story.lines.map(\.text).joined(separator: "\n")
        #expect(text.contains("Azure DevOps runs azure-pipelines-release-nonprod on every push to develop: package non prod → migrate non prod → rollout non prod."))
        #expect(text.contains("pushes the image to the container registry Repository"))
        #expect(text.contains("migrates the database with Flyway"))
        #expect(text.contains("rolls out the ECS service Service"))
        #expect(text.contains("Reaches the app through a DNS record (DnsRecord) → the listener rule ListenerRule → the target group TargetGroup → the ECS service Service → the database."))
        #expect(story.lines.map(\.title).contains("Defined in"))
    }

    @Test func terraformAndGitHubActions() throws {
        let files: [String: String] = [
            "deploy/main.tf": """
            resource "aws_lambda_function" "api" {
              role = aws_iam_role.api.arn
            }
            resource "aws_iam_role" "api" {}
            resource "aws_apigatewayv2_api" "http" {}
            resource "aws_apigatewayv2_integration" "api" {
              api_id = aws_apigatewayv2_api.http.id
              integration_uri = aws_lambda_function.api.invoke_arn
            }
            variable "region" {}
            """,
            ".github/workflows/deploy.yml": """
            name: Deploy
            on:
              push:
                branches: [main]
            jobs:
              test:
                runs-on: ubuntu-latest
                steps:
                  - uses: actions/checkout@v4
                  - run: npm test
              deploy:
                needs: test
                environment: production
                steps:
                  - run: terraform apply -auto-approve
            """,
        ]
        let infra = Infrastructure.detect(files: Array(files.keys), read: { files[$0] })
        #expect(infra.stacks.map(\.tool) == ["Terraform"])
        #expect(infra.resources.first { $0.name == "aws_lambda_function.api" }?.service == "Function")
        #expect(infra.links.contains { $0.from == "deploy/aws_lambda_function.api" && $0.to == "deploy/aws_iam_role.api" && $0.label == "secured by" })
        let pipeline = try #require(infra.pipelines.first)
        #expect(pipeline.system == "GitHub Actions" && pipeline.name == "Deploy" && pipeline.branches == ["main"])
        #expect(pipeline.stages.map(\.id) == ["test", "deploy"] && pipeline.stages.map(\.kind) == [.test, .stack])
        #expect(pipeline.environment == "production")
    }

    @Test func plainFilesAreLeftAlone() {
        let files = ["package.json": #"{"scripts":{}}"#, "docs/openapi.yaml": "openapi: 3.0.0\npaths: {}", "config/app.json": #"{"Resources": "none"}"#]
        #expect(Infrastructure.detect(files: Array(files.keys), read: { files[$0] }).isEmpty)
    }
}
