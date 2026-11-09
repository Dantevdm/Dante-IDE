import Foundation

/// What Ship › Deploy asks the agent in charge: fix the findings, or say why a deploy failed.
/// The agent edits the repo only; deploying stays a button in Dante.
public enum DeployBrief {
    static let rules = "Change only files in this repository (.do/app.yaml, Dockerfiles, .dockerignore, the app's code). Never put a secret's value in a file: secrets stay type: SECRET without a value, and Dante asks for them when deploying. Don't deploy, push or call DigitalOcean yourself; say what you changed and what I should check before deploying again."

    public static func advice(_ items: [DOAdvice], hasFile: Bool) -> String {
        let list = items.map { item in
            "- [\(item.severity.title.lowercased())] \(item.title)\(item.place.map { " (\($0))" } ?? ""): \(item.detail) Fix: \(item.fix)"
        }.joined(separator: "\n")
        return """
        Dante checked how this project deploys to DigitalOcean App Platform\(hasFile ? " (\(DOAppSpec.path))" : "") and found these. Fix what can be fixed in the repo, most severe first; for anything that has to change in DigitalOcean's settings instead, tell me exactly where.

        \(list)

        \(rules)
        """
    }

    public static func failedDeployment(app: DOApp, failure: (place: String, message: String), logs: String) -> String {
        let tail = logs.split(separator: "\n").suffix(60).joined(separator: "\n")
        return """
        The DigitalOcean App Platform deployment of \(app.name) failed at \(failure.place): \(failure.message)
        \(tail.isEmpty ? "" : "\nThe end of the build log:\n```\n\(tail)\n```\n")
        Find the cause in this repository (\(DOAppSpec.path), the Dockerfile, the build or start command, the port the app listens on, missing environment variables) and fix it. \(rules)
        """
    }

    public static func failedDeploy(problem: String, lines: [String]) -> String {
        let tail = lines.suffix(60).joined(separator: "\n")
        return """
        Deploying this project to DigitalOcean App Platform from Dante failed: \(problem)
        \(tail.isEmpty ? "" : "\nThe end of the output:\n```\n\(tail)\n```\n")
        Work out why and fix what's in the repository. \(rules)
        """
    }
}
