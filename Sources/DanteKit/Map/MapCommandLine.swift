import Foundation

/// Command-line tools and AWS: a CLI is a client people use (its commands are its items, like a
/// web client's screens), and AWS SDK clients are outside services, one per AWS service.
extension SystemMap {
    /// A command the tool offers, where it's declared.
    struct Command: Equatable {
        var name: String
        var file: String
        var line: Int
    }

    // Static, compiled once (Swift regex literals and per-call compiles were slow on big repos).
    private static let clickCommand = try! NSRegularExpression(pattern: #"^\s*@(?!click\.|typer\.)[\w.]+\.(?:command|group)\(\s*(?:name\s*=\s*)?(?:["']([\w:-]+)["'])?[\s\S]*?^\s*(?:async\s+)?def\s+(\w+)"#, options: [.anchorsMatchLines])
    private static let argparseCommand = try! NSRegularExpression(pattern: #"\.add_parser\(\s*["']([\w:-]+)["']"#)
    private static let cobraCommand = try! NSRegularExpression(pattern: #"Use:\s*"([\w:-]+)"#)
    private static let scriptEntry = try! NSRegularExpression(pattern: #"^\s*["']?([\w.-]+)["']?\s*=\s*["'][\w.]+:\w+["']"#, options: [.anchorsMatchLines])
    private static let botoClient = try! NSRegularExpression(pattern: #"(?:client|resource)\(\s*(?:service_name\s*=\s*)?["']([a-z0-9-]+)["']"#)
    private static let sdkPackage = try! NSRegularExpression(pattern: #"(?:@aws-sdk/client-|aws-sdk-go(?:-v2)?/service/|software\.amazon\.awssdk\.services\.)([a-z0-9-]+)"#)

    /// The commands a command-line tool declares: click and typer decorators, argparse
    /// sub-parsers and cobra's `Use:`. Tests are left out.
    static func commands(files: [String], text: (String) -> String) -> [Command] {
        var found: [Command] = []
        for file in files where !isTest(file) {
            let ext = (file as NSString).pathExtension
            guard ext == "py" || ext == "go" else { continue }
            let body = text(file)
            let ns = body as NSString
            func line(_ location: Int) -> Int { ns.substring(to: location).reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }
            let range = NSRange(location: 0, length: ns.length)
            if ext == "py" {
                if body.contains("click") || body.contains("typer") {
                    for match in clickCommand.matches(in: body, range: range) {
                        let given = match.range(at: 1).location == NSNotFound ? nil : ns.substring(with: match.range(at: 1))
                        let name = given ?? ns.substring(with: match.range(at: 2)).replacingOccurrences(of: "_", with: "-")
                        let at = ns.range(of: "@", range: match.range).location
                        found.append(Command(name: name, file: file, line: line(at == NSNotFound ? match.range.location : at)))
                    }
                }
                if body.contains("add_parser") {
                    for match in argparseCommand.matches(in: body, range: range) {
                        found.append(Command(name: ns.substring(with: match.range(at: 1)), file: file, line: line(match.range.location)))
                    }
                }
            } else if body.contains("spf13/cobra") {
                for match in cobraCommand.matches(in: body, range: range) {
                    found.append(Command(name: ns.substring(with: match.range(at: 1)), file: file, line: line(match.range.location)))
                }
            }
        }
        return found
    }

    /// The names a Python project installs as commands (`[project.scripts]` in pyproject.toml,
    /// `[tool.poetry.scripts]`, or setup.py's console_scripts).
    static func scriptNames(files: [String], text: (String) -> String) -> [String] {
        var names: [String] = []
        for file in files where ["pyproject.toml", "setup.cfg"].contains((file as NSString).lastPathComponent) && !file.contains("/") {
            var inScripts = false
            for line in text(file).components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") {
                    inScripts = ["[project.scripts]", "[tool.poetry.scripts]", "[options.entry_points]"].contains(trimmed)
                    continue
                }
                guard inScripts else { continue }
                let ns = trimmed as NSString
                if let match = scriptEntry.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) {
                    names.append(ns.substring(with: match.range(at: 1)))
                }
            }
        }
        if let setup = files.first(where: { $0 == "setup.py" }) {
            let body = text(setup)
            let pattern = try! NSRegularExpression(pattern: #"["']([\w.-]+)\s*=\s*[\w.]+:\w+["']"#)
            let ns = body as NSString
            for match in pattern.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                names.append(ns.substring(with: match.range(at: 1)))
            }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// The AWS services a file's code uses: SDK packages (JavaScript, Go, Java) by name, and in
    /// Python `client("…")`/`resource("…")` calls naming a known service, when the project uses boto3.
    static func awsServices(in body: String, isPython: Bool, usesBoto: Bool) -> Set<String> {
        var found = Set<String>()
        let ns = body as NSString
        let range = NSRange(location: 0, length: ns.length)
        if body.contains("aws") || body.contains("amazon") {
            for match in sdkPackage.matches(in: body, range: range) {
                found.insert(ns.substring(with: match.range(at: 1)))
            }
        }
        if isPython, usesBoto, body.contains("client(") || body.contains("resource(") {
            for match in botoClient.matches(in: body, range: range) {
                let name = ns.substring(with: match.range(at: 1))
                if awsNames[name] != nil { found.insert(name) }
            }
        }
        return found
    }

    /// AWS service ids (boto3's names) with a name and what they're for. Python calls are only
    /// counted for these, since `client("x")` is common elsewhere.
    static let awsNames: [String: (name: String, detail: String)] = [
        "amscm": ("AMS change management", "RFCs and change types"),
        "amsskms": ("AMS SKMS", "managed resources"),
        "sts": ("AWS STS", "identity and roles"),
        "iam": ("AWS IAM", "users and roles"),
        "s3": ("Amazon S3", "object storage"),
        "dynamodb": ("DynamoDB", "key-value tables"),
        "sqs": ("Amazon SQS", "queues"),
        "sns": ("Amazon SNS", "notifications"),
        "lambda": ("AWS Lambda", "functions"),
        "secretsmanager": ("Secrets Manager", "secrets"),
        "ssm": ("Systems Manager", "parameters and run command"),
        "kms": ("AWS KMS", "encryption keys"),
        "cloudformation": ("CloudFormation", "stacks"),
        "cloudwatch": ("CloudWatch", "metrics and alarms"),
        "logs": ("CloudWatch Logs", "logs"),
        "events": ("EventBridge", "events"),
        "eventbridge": ("EventBridge", "events"),
        "ec2": ("Amazon EC2", "servers"),
        "ecs": ("Amazon ECS", "containers"),
        "ecr": ("Amazon ECR", "container images"),
        "eks": ("Amazon EKS", "Kubernetes"),
        "rds": ("Amazon RDS", "databases"),
        "rds-data": ("RDS Data API", "SQL over HTTP"),
        "stepfunctions": ("Step Functions", "workflows"),
        "sfn": ("Step Functions", "workflows"),
        "glue": ("AWS Glue", "data jobs"),
        "athena": ("Athena", "SQL over S3"),
        "kinesis": ("Kinesis", "streams"),
        "firehose": ("Kinesis Firehose", "delivery streams"),
        "bedrock": ("Bedrock", "models"),
        "bedrock-runtime": ("Bedrock", "models"),
        "sagemaker-runtime": ("SageMaker", "model endpoints"),
        "cognito-idp": ("Cognito", "sign-in"),
        "organizations": ("Organizations", "accounts"),
        "sso": ("IAM Identity Center", "sign-in"),
        "sso-oidc": ("IAM Identity Center", "sign-in"),
        "apigateway": ("API Gateway", "APIs"),
        "route53": ("Route 53", "DNS"),
        "elbv2": ("Load balancers", "ELB"),
        "autoscaling": ("Auto Scaling", "scaling groups"),
        "textract": ("Textract", "document text"),
        "comprehend": ("Comprehend", "language"),
        "rekognition": ("Rekognition", "images"),
        "translate": ("Amazon Translate", "translation"),
        "polly": ("Polly", "speech"),
        "appconfig": ("AppConfig", "configuration"),
        "ce": ("Cost Explorer", "costs"),
        "config": ("AWS Config", "resource history"),
        "cloudtrail": ("CloudTrail", "audit log"),
        "securityhub": ("Security Hub", "findings"),
    ]

    /// Ids that name one service twice (`sfn` and `stepfunctions`) share a part.
    static func awsPartID(_ service: String) -> String {
        let same = ["sfn": "stepfunctions", "eventbridge": "events", "bedrock-runtime": "bedrock", "sso-oidc": "sso",
                    "client-s3": "s3", "cloudwatch-logs": "logs", "secrets-manager": "secretsmanager"]
        return "aws:" + (same[service] ?? service)
    }

    static func awsTitle(_ service: String) -> (name: String, detail: String) {
        if let known = awsNames[service] { return known }
        let words = service.split(separator: "-").map { $0.count <= 3 ? $0.uppercased() : $0.prefix(1).uppercased() + $0.dropFirst() }
        return ("AWS " + words.joined(separator: " "), "AWS")
    }
}
